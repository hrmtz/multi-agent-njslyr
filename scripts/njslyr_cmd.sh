#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# njslyr_cmd.sh — njslyrコマンドインターフェース（ワンコマンド体系）
#
# 使用方法:
#   bash scripts/njslyr_cmd.sh <subcommand> [args...]
#
# サブコマンド:
#   suriken <agent_id> [message] [type] [priority]
#       エージェントにスリケン（nudge）を送る。
#       message省略時はnudgeのみ（inboxメッセージなし）。
#       type省略時: system_notice
#       priority省略時: typeに応じたデフォルト（inbox_write.sh参照）
#
#   chop <agent_id>
#       エージェントに /clear を送り、リカバリー後にnudgeする。
#
#   slay <agent_id> [reason]
#       エージェントをリスポーンする（stage3_slay相当）。
#
#   spawn_tengu <target_agent_id> [mission]
#       指定yakuzaNを天狗として使用。ヤクザ天狗をspawnする（idle_start非依存）。
#
#   despawn_tengu [reason]
#       ヤクザ天狗をdespawnして元エージェントを復元する。
#
# 使用例:
#   bash scripts/njslyr_cmd.sh suriken yakuza3
#   bash scripts/njslyr_cmd.sh suriken gryakuza "タスク確認せよ" system_notice P1
#
# 設計書: context/cmd_269-infra-design.md
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Variables ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
STATE_DIR="$PROJECT_ROOT/.state"
mkdir -p "$STATE_DIR"

# ─── 共有ライブラリ読み込み（njslyr.sh関数群を継承）───
# shellcheck source=scripts/njslyr_lib.sh
source "$SCRIPT_DIR/njslyr_lib.sh"

# ─── helper: operation mode check (standalone guard) ───
_get_operation_mode() {
    local mode
    mode=$(awk '/operation_mode:/ {print $2; exit}' "$PROJECT_ROOT/config/settings.yaml" 2>/dev/null)
    echo "${mode:-kyoto_master}"
}

# ─── helper: ntfy fallback for suriken (cross-machine) ───
# ローカルペインが見つからない場合にntfy経由でリモートマシンにスリケンを送る
# 引数: agent_id (必須)
_cmd_suriken_ntfy_fallback() {
    local agent_id="$1"
    if [[ "$(_get_operation_mode)" == "standalone" ]]; then
        return 1  # fallback skip → local-only
    fi

    # inbox unread count を取得
    local unread_count
    unread_count=$(grep -c 'read: false' \
        "$PROJECT_ROOT/queue/inbox/${agent_id}.yaml" 2>/dev/null || echo "0")

    # settings.yaml から ntfy_topic と machine.role を読む
    local ntfy_topic machine_role
    ntfy_topic=$(awk '/^ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' \
        "$PROJECT_ROOT/config/settings.yaml")
    machine_role=$(awk '/^  role:/ {print $2; exit}' \
        "$PROJECT_ROOT/config/settings.yaml")

    # legacy role name normalization (ryzen→kyoto, mbp→neosaitama)
    case "$machine_role" in
        mbp)   machine_role="neosaitama" ;;
        ryzen) machine_role="kyoto" ;;
    esac

    # machine.role に基づいてpeer topicを決定
    local peer_topic
    case "$machine_role" in
        kyoto|ryzen)     peer_topic="${ntfy_topic}-neosaitama" ;;
        neosaitama|mbp)  peer_topic="${ntfy_topic}-kyoto" ;;
        *)
            echo "[suriken] ntfy fallback: unknown machine role: $machine_role" >&2
            return 1
            ;;
    esac

    # lib/ntfy_auth.sh を source して認証引数取得
    # shellcheck source=lib/ntfy_auth.sh
    source "$PROJECT_ROOT/lib/ntfy_auth.sh"
    local auth_args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && auth_args+=("$line")
    done < <(ntfy_get_auth_args "$PROJECT_ROOT/config/ntfy_auth.env")

    # curl で POST
    local response_code
    response_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "${auth_args[@]}" \
        -H 'Title: suriken' \
        -d "suriken:${agent_id}:${unread_count}" \
        "https://ntfy.sh/${peer_topic}")

    if [[ "$response_code" =~ ^2 ]]; then
        echo "[suriken] ntfy fallback → ${peer_topic}: suriken:${agent_id}:${unread_count} (HTTP ${response_code})"
        return 0
    else
        echo "[suriken] ntfy fallback FAILED: HTTP ${response_code}" >&2
        return 1
    fi
}

# ─── helper: SSH tier2 fallback for suriken (cross-machine) ───
# ntfy tier1失敗時にSSH経由でリモートマシンにスリケンを送る
# 引数: agent_id (必須)
_cmd_suriken_ssh_fallback() {
    local agent_id="$1"
    if [[ "$(_get_operation_mode)" == "standalone" ]]; then
        return 1  # fallback skip → local-only
    fi
    # shellcheck source=lib/ssh_fallback.sh
    source "$PROJECT_ROOT/lib/ssh_fallback.sh"
    echo "[suriken] SSH tier2 → $agent_id" >&2
    if ssh_send_suriken "$agent_id"; then
        echo "[suriken] SSH tier2 success → $agent_id"
        return 0
    else
        echo "[suriken] SSH tier2 FAILED → $agent_id" >&2
        return 1
    fi
}

# ─── A-1: suriken — エージェントにnudgeを送る ───
# 設計書 Section A-1 準拠
# 引数: agent_id (必須), message (任意), type (任意), priority (任意)
cmd_suriken() {
    # FIX-LBUG-001: SSH再帰防止ガード（ローカル変数定義より前に配置）
    # リモートSSH経由で呼ばれた場合、再度クロスマシン配信しない（無限ループ防止）
    if [[ "${NJSLYR_SSH_DEPTH:-0}" -ge 1 ]]; then
        echo "[suriken] SSH depth limit reached (depth=${NJSLYR_SSH_DEPTH}), aborting to prevent infinite loop" >&2
        return 1
    fi

    local agent_id="${1:?ERROR: suriken requires agent_id}"

    # FIX-SEC-M001: agent_idバリデーション（全下流関数を保護）
    if [[ ! "$agent_id" =~ ^[a-z0-9_]+$ ]]; then
        echo "[suriken] ERROR: invalid agent_id: '$agent_id'" >&2
        return 1
    fi

    local message="${2:-}"
    local type="${3:-system_notice}"
    local priority="${4:-}"

    # 動的ペイン探索（全セッション横断: yakuzatengu対応）
    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$agent_id")

    if [[ -z "$pane_id" ]]; then
        # FIX-LBUG-002: message付きsurikenのリモートinbox_write（nudge前に実行）
        if [[ -n "$message" ]]; then
            if [[ -f "$PROJECT_ROOT/lib/ssh_fallback.sh" ]]; then
                # shellcheck source=lib/ssh_fallback.sh
                source "$PROJECT_ROOT/lib/ssh_fallback.sh"
                local peer_host peer_project escaped_message
                peer_host=$(_ssh_get_peer_host)
                peer_project=$(_ssh_get_peer_project)
                escaped_message=$(printf '%q' "$message")
                if [[ -n "$peer_host" && -n "$peer_project" ]]; then
                    # shellcheck disable=SC2086
                    ssh $SSH_OPTS "$peer_host" \
                        "cd '$peer_project' && bash scripts/inbox_write.sh '$agent_id' $escaped_message '$type' 'njslyr' '' '$priority'" \
                        2>/dev/null \
                        || echo "[suriken] WARNING: remote inbox_write failed for $agent_id" >&2
                fi
            fi
        fi

        echo "[suriken] pane not found for $agent_id — trying ntfy tier1 fallback..." >&2
        if ! _cmd_suriken_ntfy_fallback "$agent_id"; then
            echo "[suriken] ntfy tier1 failed → SSH tier2..." >&2
            _cmd_suriken_ssh_fallback "$agent_id"
            return $?
        fi
        return 0
    fi

    # メッセージがある場合はinbox_write（from="njslyr"固定）
    # inbox_write失敗でnudge送信を中断しないよう || true（nudgeが主目的）
    if [[ -n "$message" ]]; then
        bash "$SCRIPT_DIR/inbox_write.sh" \
            "$agent_id" "$message" "$type" "njslyr" "" "$priority" || true
    fi

    # unread数を確認してnudgeテキストを生成
    local unread_count
    unread_count=$(grep -c 'read: false' \
        "$PROJECT_ROOT/queue/inbox/${agent_id}.yaml" 2>/dev/null || echo "0")
    local nudge_text="スリケン！inbox${unread_count}"

    # オートコンプリート回避: text→Escape→Enter（0.3秒間隔）
    tmux send-keys -t "$pane_id" "$nudge_text" 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" Escape 2>/dev/null
    sleep 0.1
    tmux send-keys -t "$pane_id" Enter 2>/dev/null

    echo "[suriken] → $agent_id ($pane_id): inbox${unread_count}"
}

# ─── A-2: chop — エージェントに /clear を送り、リカバリー後にnudgeする ───
# 設計書 Section A-2 準拠（UNIFIED-HIGH-001: Escapeクォートなし / UNIFIED-MED-009: clear_last）
# 引数: agent_id (必須)
cmd_chop() {
    local agent_id="${1:?ERROR: chop requires agent_id}"

    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$agent_id")

    [[ -z "$pane_id" ]] && { echo "ERROR: chop: pane not found for $agent_id" >&2; return 1; }

    echo "[chop] $agent_id ($pane_id) に /clear 送信..."

    # /clear 送信（UNIFIED-HIGH-001: クォートなし Escape を使用）
    tmux send-keys -t "$pane_id" Escape 2>/dev/null
    sleep 0.1
    tmux send-keys -t "$pane_id" "/clear" 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" Enter 2>/dev/null

    # clear_last タイムスタンプ更新（UNIFIED-MED-009: B-1 graceピリオドとの連携インターフェース）
    date +%s > "$STATE_DIR/clear_last_${agent_id}"

    echo "[chop] $agent_id: /clear 送信完了。30秒後にリカバリー確認..."
    sleep 30

    # リカバリー確認ループ（最大3回・30秒間隔）
    local retry=0
    while [[ $retry -lt 3 ]]; do
        local unread_count
        unread_count=$(grep -c 'read: false' "$PROJECT_ROOT/queue/inbox/${agent_id}.yaml" 2>/dev/null) || unread_count=0
        if [[ "$unread_count" -gt 0 ]]; then
            cmd_suriken "$agent_id"
            break
        fi
        # unreadなし → agent_is_busy()で確認してから再チェック
        # pane_id (%XX形式) vs get_pane_target() のN形式。機能的問題なし。
        if agent_is_busy "$pane_id"; then
            break  # 作業中ならOK
        fi
        retry=$(( retry + 1 ))
        [[ $retry -lt 3 ]] && sleep 30
    done
}

# ─── A-3: slay — エージェントをリスポーン（stage3_slay ラッパー）───
# 設計書 Section A-3 準拠
# 引数: agent_id (必須), reason (任意)
cmd_slay() {
    local agent_id="${1:?ERROR: slay requires agent_id}"
    local reason="${2:-手動slay}"

    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$agent_id")

    [[ -z "$pane_id" ]] && { echo "ERROR: slay: pane not found for $agent_id" >&2; return 1; }

    echo "[slay] $agent_id ($pane_id): $reason"

    # njslyr.sh の stage3_slay() を呼び出す（njslyr_lib.sh経由でsource済み）
    stage3_slay "$agent_id" "$reason" "$pane_id"
}

# ─── A-4: spawn_tengu — ヤクザ天狗をspawnする（idle_start非依存）───
# 設計書 Section A-4 準拠（UNIFIED-HIGH-003 + UNIFIED-HIGH-008）
# 引数: target_agent_id (必須: 天狗として使用するyakuzaNのID)
#        mission (任意: 天狗へのミッション説明)
cmd_spawn_tengu() {
    local target_agent_id="${1:?ERROR: spawn_tengu requires target_agent_id}"
    local mission="${2:-}"

    # 天狗既存チェック
    if [[ -f "$STATE_DIR/yakuzatengu_active" ]]; then
        echo "[spawn_tengu] yakuzatengu already active. skip."
        return 0
    fi

    # 指定エージェントのpane解決
    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$target_agent_id")

    [[ -z "$pane_id" ]] && { echo "ERROR: spawn_tengu: pane not found for $target_agent_id" >&2; return 1; }

    local orig_agent="$target_agent_id"

    # ─── STATEファイル書き込み（respawn-pane前に必ず完了）───
    local spawn_time; spawn_time=$(date +%s)
    touch "$STATE_DIR/yakuzatengu_active"
    echo "$orig_agent" > "$STATE_DIR/yakuzatengu_original_agent_id"
    echo "$pane_id"    > "$STATE_DIR/yakuzatengu_original_pane"
    local orig_model; orig_model=$(tmux show-options -pv -t "$pane_id" @model_name 2>/dev/null || echo "Sonnet")
    echo "$orig_model" > "$STATE_DIR/yakuzatengu_original_model"
    echo "$spawn_time" > "$STATE_DIR/yakuzatengu_spawn_time"

    # spawn前にidle/thinkingファイル削除（njslyr.sh L858-859相当）
    rm -f "$STATE_DIR/njslyr_${orig_agent}_thinking_start"
    rm -f "$STATE_DIR/njslyr_${orig_agent}_idle_start"

    # 元エージェントのタスクYAML status を suspended に変更（rollback用に元statusを保存）
    local orig_task_yaml orig_task_status
    # shellcheck disable=SC2012  # ls -t needed for mtime sort; yaml filenames have no special chars
    orig_task_yaml=$(ls -t "$PROJECT_ROOT/queue/tasks/${orig_agent}"*.yaml 2>/dev/null | head -1)
    orig_task_status="idle"
    if [[ -n "$orig_task_yaml" && -f "$orig_task_yaml" ]]; then
        orig_task_status=$(awk '/^ *status:/ {gsub(/['"'"'"]/, "", $2); print $2; exit}' "$orig_task_yaml" 2>/dev/null || echo "idle")
        sedi 's/^ *status: .*/  status: suspended/' "$orig_task_yaml" 2>/dev/null || true
    fi

    # remain-on-exit設定（恒久ルール: respawn-pane前に必須）
    tmux set-option -p -t "$pane_id" remain-on-exit on 2>/dev/null || true

    # UNIFIED-MED-003: 元bg_colorを保存（rollback + despawn時に参照）
    local orig_bg_color
    orig_bg_color=$(tmux show-options -pv -t "$pane_id" background 2>/dev/null || echo "default")
    echo "$orig_bg_color" > "$STATE_DIR/yakuzatengu_original_bg_color"

    # bg_color設定（ヤクザ天狗カラー: ダークピンク #3a0025）
    tmux select-pane -t "$pane_id" -P "bg=#3a0025" 2>/dev/null || true

    # Sonnet起動（失敗時はSTATEロールバック）
    if ! tmux respawn-pane -k -t "$pane_id" \
        "claude --model claude-sonnet-4-6 --dangerously-skip-permissions" 2>/dev/null; then
        # エラーロールバック: STATEファイル削除 + bg_color復元 + タスクYAML status復元
        tmux select-pane -t "$pane_id" -P "bg=${orig_bg_color}" 2>/dev/null || true
        if [[ -n "${orig_task_yaml:-}" && -f "${orig_task_yaml:-}" ]]; then
            sedi "s|^ *status: suspended|  status: ${orig_task_status:-assigned}|" "$orig_task_yaml" 2>/dev/null || true
        fi
        rm -f "$STATE_DIR/yakuzatengu_active" \
              "$STATE_DIR/yakuzatengu_original_agent_id" \
              "$STATE_DIR/yakuzatengu_original_pane" \
              "$STATE_DIR/yakuzatengu_original_model" \
              "$STATE_DIR/yakuzatengu_spawn_time" \
              "$STATE_DIR/yakuzatengu_original_bg_color"
        echo "ERROR: spawn_tengu: respawn-pane失敗。ロールバック完了。" >&2
        return 1
    fi
    sleep 1

    # @agent_id と @model_name を yakuzatengu に設定
    tmux set-option -p -t "$pane_id" @agent_id   "yakuzatengu" 2>/dev/null || true
    tmux set-option -p -t "$pane_id" @model_name "Sonnet"       2>/dev/null || true

    # UNIFIED-HIGH-008: spawn後 watcher 即時起動シグナル
    touch "$STATE_DIR/rescan_watchers"

    # missionがあればinboxにミッション内容を含める
    local spawn_msg="ヤクザ天狗spawn完了。instructions/yakuzatengu.mdを読み、任務を開始せよ。"
    if [[ -n "$mission" ]]; then
        spawn_msg="ヤクザ天狗spawn完了。ミッション: ${mission}。instructions/yakuzatengu.mdを読み、任務を開始せよ。"
    fi

    bash "$SCRIPT_DIR/inbox_write.sh" "yakuzatengu" "$spawn_msg" task_assigned njslyr_cmd "" P0
    echo "[spawn_tengu] ◆ヤクザ天狗召喚◆ ${orig_agent} → yakuzatengu(claude-sonnet-4-6)"
}

# ─── A-5: despawn_tengu — ヤクザ天狗をdespawnして元エージェントを復元する ───
# 設計書 Section A-5 準拠（UNIFIED-HIGH-007）
# 引数: reason (任意)
cmd_despawn_tengu() {
    local reason="${1:-手動despawn}"

    # yakuzatengu_active確認
    if [[ ! -f "$STATE_DIR/yakuzatengu_active" ]]; then
        echo "[despawn_tengu] yakuzatengu not active. skip."
        return 0
    fi

    # STATEファイル読み込み
    local orig_agent orig_pane orig_model
    orig_agent=$(cat "$STATE_DIR/yakuzatengu_original_agent_id" 2>/dev/null || echo "")
    orig_pane=$(cat "$STATE_DIR/yakuzatengu_original_pane" 2>/dev/null || echo "")
    orig_model=$(cat "$STATE_DIR/yakuzatengu_original_model" 2>/dev/null || echo "Sonnet")

    if [[ -z "$orig_agent" || -z "$orig_pane" ]]; then
        echo "ERROR: despawn_tengu: STATEファイル不完全。" >&2
        return 1
    fi

    # モデルとbg_colorを決定
    local model bg_color
    case "$orig_model" in
        Opus|opus|OPUS) model="claude-opus-4-6" ;;
        *)              model="claude-sonnet-4-6" ;;
    esac
    bg_color=$(cat "$STATE_DIR/yakuzatengu_original_bg_color" 2>/dev/null || \
        { [[ "$orig_model" =~ [Oo]pus ]] && echo "#1a002e" || echo "default"; })

    echo "[despawn_tengu] yakuzatengu → ${orig_agent}(model:${model}): $reason"

    # remain-on-exit設定（恒久ルール: respawn-pane前に必須）
    tmux set-option -p -t "$orig_pane" remain-on-exit on 2>/dev/null || true

    # 元モデルで復元（失敗時はSTATE保持・再試行可能にする）
    if ! tmux respawn-pane -k -t "$orig_pane" \
        "claude --model ${model} --dangerously-skip-permissions" 2>/dev/null; then
        echo "ERROR: despawn_tengu: respawn-pane失敗。STATE保持。手動再実行を。" >&2
        return 1
    fi
    sleep 1

    # @agent_id / @model_name / bg_color 復元
    tmux set-option -p -t "$orig_pane" @agent_id   "$orig_agent"  2>/dev/null || true
    tmux set-option -p -t "$orig_pane" @model_name "$orig_model"  2>/dev/null || true
    tmux select-pane  -t "$orig_pane" -P "bg=${bg_color}"         2>/dev/null || true

    # STATEクリーンアップ（8件）
    rm -f "$STATE_DIR/yakuzatengu_active" \
          "$STATE_DIR/yakuzatengu_original_agent_id" \
          "$STATE_DIR/yakuzatengu_original_pane" \
          "$STATE_DIR/yakuzatengu_original_model" \
          "$STATE_DIR/yakuzatengu_spawn_time" \
          "$STATE_DIR/yakuzatengu_done" \
          "$STATE_DIR/yakuzatengu_despawn_pending" \
          "$STATE_DIR/yakuzatengu_original_bg_color"

    # UNIFIED-MED-002: 元エージェントのタスクYAML status を suspended → assigned に復元
    if [[ -n "$orig_agent" ]]; then
        local orig_task_yaml
        # shellcheck disable=SC2012  # ls -t needed for mtime sort; yaml filenames have no special chars
        orig_task_yaml=$(ls -t "$PROJECT_ROOT/queue/tasks/${orig_agent}"*.yaml 2>/dev/null | head -1)
        if [[ -n "$orig_task_yaml" && -f "$orig_task_yaml" ]]; then
            sedi "s|^ *status: suspended|  status: assigned|" "$orig_task_yaml" 2>/dev/null || true
            echo "[despawn_tengu] Restored task status: $orig_task_yaml"
        fi
    fi

    # watcher_supervisor に即時再スキャン要求（orphan watcher対処）
    touch "$STATE_DIR/rescan_watchers"

    # 元エージェントにdespawn完了を通知
    bash "$SCRIPT_DIR/inbox_write.sh" "$orig_agent" \
        "ヤクザ天狗despawn完了。Session Start手順を実行し、タスクYAMLを再読せよ。" \
        task_assigned njslyr_cmd "" P0 2>/dev/null || true

    echo "[despawn_tengu] ◆ヤクザ天狗帰還◆ yakuzatengu → ${orig_agent}。任務完了。"
}

# ─── A-7: inject — バリキドリンク投与（Sonnet→Opus切替）───
# njslyr.sh inject_barikidorink() 相当のワンコマンド版
# 引数: agent_id (必須)
cmd_inject() {
    local agent_id="${1:?ERROR: inject requires agent_id}"

    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$agent_id")

    [[ -z "$pane_id" ]] && { echo "ERROR: inject: pane not found for $agent_id" >&2; return 1; }

    # 現在のモデル確認
    local current_model current_bg
    current_model=$(tmux show-options -pv -t "$pane_id" @model_name 2>/dev/null || echo "unknown")
    current_bg=$(tmux show-options -pv -t "$pane_id" background 2>/dev/null || echo "unknown")

    # 既にOpusなら skip
    if [[ "$current_model" == "Opus" && "$current_bg" == "#1a002e" ]]; then
        echo "[inject] $agent_id ($pane_id): already Opus + bg=#1a002e. skip."
        return 0
    fi

    echo "[inject] $agent_id ($pane_id): $current_model (bg=$current_bg) → Opus (bg=#1a002e)"

    # /model claude-opus-4-6 送信（オートコンプリート回避: text→Escape→Enter）
    if [[ "$current_model" != "Opus" ]]; then
        tmux send-keys -t "$pane_id" "/model claude-opus-4-6" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$pane_id" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$pane_id" Enter 2>/dev/null
        sleep 0.5
    fi

    # @model_name / bg_color は常に更新
    tmux set-option -p -t "$pane_id" @model_name "Opus" 2>/dev/null || true
    tmux select-pane -t "$pane_id" -P "bg=#1a002e" 2>/dev/null || true

    echo "[inject] $agent_id: inject complete (Opus, bg=#1a002e)"
}

# ─── A-6: detox — バリキドリンク解毒（Opus→Sonnet復帰）───
# njslyr.sh detox_barikidorink() 相当のワンコマンド版
# 引数: agent_id (必須)
cmd_detox() {
    local agent_id="${1:?ERROR: detox requires agent_id}"

    local pane_id
    pane_id=$(resolve_pane_by_agent_id "$agent_id")

    [[ -z "$pane_id" ]] && { echo "ERROR: detox: pane not found for $agent_id" >&2; return 1; }

    # 現在のモデル確認
    local current_model current_bg
    current_model=$(tmux show-options -pv -t "$pane_id" @model_name 2>/dev/null || echo "unknown")
    current_bg=$(tmux show-options -pv -t "$pane_id" background 2>/dev/null || echo "unknown")

    # @model_nameがSonnetでもbg色がdefaultでなければ修正が必要
    if [[ "$current_model" == "Sonnet" && "$current_bg" == "default" ]]; then
        echo "[detox] $agent_id ($pane_id): already Sonnet + bg=default. skip."
        return 0
    fi

    echo "[detox] $agent_id ($pane_id): $current_model (bg=$current_bg) → Sonnet (bg=default)"

    # モデルがSonnetでなければ /model sonnet 送信
    if [[ "$current_model" != "Sonnet" ]]; then
        # /model sonnet 送信（オートコンプリート回避: text→Escape→Enter）
        tmux send-keys -t "$pane_id" "/model sonnet" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$pane_id" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$pane_id" Enter 2>/dev/null
        sleep 0.5
    fi

    # @model_name / bg_color は常に更新（部分的な解毒状態を修復）
    tmux set-option -p -t "$pane_id" @model_name "Sonnet" 2>/dev/null || true
    tmux select-pane -t "$pane_id" -P "bg=default" 2>/dev/null || true

    echo "[detox] $agent_id: detox complete (Sonnet, bg=default)"
}

# ─── usage ───
usage() {
    cat <<'EOF'
Usage: bash scripts/njslyr_cmd.sh <subcommand> [args...]

Subcommands:
  suriken <agent_id> [message] [type] [priority]
      Send a suriken (nudge) to an agent.
      If message is given, writes to inbox first (from=njslyr).
      type default: system_notice
      priority default: type-based default (see inbox_write.sh)

  chop <agent_id>
      Send /clear to an agent and nudge after recovery.

  slay <agent_id> [reason]
      Respawn an agent (stage3_slay wrapper).

  spawn_tengu <target_agent_id> [mission]
      Spawn yakuzatengu using specified yakuzaN pane (idle_start independent).

  despawn_tengu [reason]
      Despawn yakuzatengu and restore original agent.

  inject <agent_id>
      Inject barikidorink (Sonnet → Opus). Sends /model claude-opus-4-6,
      updates @model_name and bg_color. Skips if already Opus.

  detox <agent_id>
      Detox barikidorink (Opus → Sonnet). Sends /model sonnet,
      updates @model_name and bg_color. Skips if already Sonnet.

Examples:
  bash scripts/njslyr_cmd.sh suriken yakuza3
  bash scripts/njslyr_cmd.sh suriken gryakuza "タスク確認せよ" system_notice P1
  bash scripts/njslyr_cmd.sh chop yakuza5
  bash scripts/njslyr_cmd.sh slay yakuza2 "コンテキスト枯渇"
  bash scripts/njslyr_cmd.sh spawn_tengu yakuza7 "cmd_999 インフラ監視"
  bash scripts/njslyr_cmd.sh despawn_tengu
  bash scripts/njslyr_cmd.sh inject yakuza5
  bash scripts/njslyr_cmd.sh detox yakuza3
EOF
}

# ─── main ───
main() {
    local subcommand="${1:-}"
    case "$subcommand" in
        suriken)
            shift
            cmd_suriken "$@"
            ;;
        chop)
            shift
            cmd_chop "$@"
            ;;
        slay)
            shift
            cmd_slay "$@"
            ;;
        spawn_tengu)
            shift
            cmd_spawn_tengu "$@"
            ;;
        despawn_tengu)
            shift
            cmd_despawn_tengu "$@"
            ;;
        inject)
            shift
            cmd_inject "$@"
            ;;
        detox)
            shift
            cmd_detox "$@"
            ;;
        help|--help|-h|"")
            usage
            ;;
        *)
            echo "ERROR: Unknown subcommand: $subcommand" >&2
            usage >&2
            return 1
            ;;
    esac
}

main "$@"
