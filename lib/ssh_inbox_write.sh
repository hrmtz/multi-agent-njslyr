#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# ssh_inbox_write.sh — SSH-first cross-machine inbox_write
# cmd_306 C1実装: SSHファーストアーキテクチャの中核スクリプト
#
# Usage: bash lib/ssh_inbox_write.sh <target_agent> <message> <type> <from> [task_yaml_path] [priority]
#
# 制御フロー:
#   1. lib/ssh_fallback.sh source (peer_host, peer_project取得)
#   2. agent_idバリデーション [a-z0-9_]+ (インジェクション防御)
#   3. SSH疎通確認 (ConnectTimeout=5)
#   4a. 成功: task_yaml scp + SSH経由inbox_write実行 → return 0
#   4b. 初回失敗: 10秒wait + 1回リトライ (MBPスリープ復帰考慮)
#   5. リトライ失敗: ntfyフォールバック
#   6. 全結果ローカルログ記録
#   7. SSH失敗時: gryakuza inboxに通知 (障害可視化)
#
# macOS PATH対策: SSH経由コマンドに Homebrew PATH を明示付加
# 再帰防止: NJSLYR_SSH_DEPTH ガード (ssh_fallback.sh 準拠)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# macOS SSH non-interactive shell PATH fix
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

# ─── スクリプトのルートディレクトリ解決 ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── ライブラリ読み込み ─────────────────────────────────────────────────────
# shellcheck source=lib/ssh_fallback.sh
source "$SCRIPT_DIR/lib/ssh_fallback.sh"

# ─── 引数パース ────────────────────────────────────────────────────────────
TARGET_AGENT="${1:-}"
MESSAGE="${2:-}"
TYPE="${3:-task_assigned}"
FROM="${4:-unknown}"
TASK_YAML_PATH="${5:-}"
PRIORITY="${6:-}"

# ─── ログ設定 ───────────────────────────────────────────────────────────────
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/ssh_inbox_write.log"
LOG_TAG="[ssh_inbox_write]"

_log() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $LOG_TAG $*" | tee -a "$LOG_FILE" >&2
}

_log_error() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $LOG_TAG ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# ─── 引数バリデーション ─────────────────────────────────────────────────────
if [[ -z "$TARGET_AGENT" || -z "$MESSAGE" ]]; then
    echo "Usage: $(basename "$0") <target_agent> <message> <type> <from> [task_yaml_path] [priority]" >&2
    exit 1
fi

# agent_id validation: リモートコマンドインジェクション防御
# 許可パターン: [a-z0-9_]+ のみ (例: yakuza3, gryakuza, master_tortoise)
if [[ ! "$TARGET_AGENT" =~ ^[a-z0-9_]+$ ]]; then
    _log_error "REJECTED: invalid target_agent '$TARGET_AGENT' (must match [a-z0-9_]+)"
    exit 1
fi

# from も同様にバリデーション (@ を許可: "gryakuza@neo" 等)
if [[ ! "$FROM" =~ ^[a-z0-9_@]+$ ]]; then
    _log_error "REJECTED: invalid from '$FROM' (must match [a-z0-9_@]+)"
    exit 1
fi

# ─── NJSLYR_SSH_DEPTH 再帰防止ガード ──────────────────────────────────────────
# ssh_fallback.sh の ssh_send_suriken と同様のパターン
if [[ "${NJSLYR_SSH_DEPTH:-0}" -ge 1 ]]; then
    _log_error "NJSLYR_SSH_DEPTH=${NJSLYR_SSH_DEPTH}: recursive SSH detected, aborting"
    exit 1
fi

# ─── peer情報取得 ───────────────────────────────────────────────────────────
PEER_HOST=$(_ssh_get_peer_host)
PEER_PROJECT=$(_ssh_get_peer_project)

if [[ -z "$PEER_HOST" || -z "$PEER_PROJECT" ]]; then
    _log_error "peer_host or peer_project_root not configured in config/settings.yaml"
    exit 1
fi

# PEER_HOST バリデーション (パストラバーサル・インジェクション防御)
if [[ ! "$PEER_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    _log_error "Invalid PEER_HOST: '$PEER_HOST'"
    exit 1
fi

# PEER_PROJECT バリデーション
if [[ ! "$PEER_PROJECT" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || [[ "$PEER_PROJECT" == *..* ]]; then
    _log_error "Invalid PEER_PROJECT: '$PEER_PROJECT'"
    exit 1
fi

# ─── SSH疎通確認関数 ─────────────────────────────────────────────────────────
_ssh_ping() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -o ConnectTimeout=5 "$PEER_HOST" true 2>/dev/null
}

# ─── task_yaml SCP転送関数 ───────────────────────────────────────────────────
_scp_task_yaml() {
    if [[ -z "$TASK_YAML_PATH" ]]; then
        return 0
    fi
    if [[ ! -f "$TASK_YAML_PATH" ]]; then
        _log_error "task_yaml not found: $TASK_YAML_PATH"
        return 1
    fi
    _log "scp: $TASK_YAML_PATH → $PEER_HOST:$PEER_PROJECT/queue/tasks/"
    # shellcheck disable=SC2086
    scp $SSH_OPTS "$TASK_YAML_PATH" "${PEER_HOST}:${PEER_PROJECT}/queue/tasks/" 2>>"$LOG_FILE"
}

# ─── SSH経由 remote inbox_write 実行関数 ────────────────────────────────────
# printf '%q' でBash安全クォート: シェルインジェクション防御
_ssh_run_inbox_write() {
    local q_target q_message q_type q_from q_yaml q_priority q_project

    q_target=$(printf '%q' "$TARGET_AGENT")
    q_message=$(printf '%q' "$MESSAGE")
    q_type=$(printf '%q' "$TYPE")
    q_from=$(printf '%q' "$FROM")
    q_project=$(printf '%q' "$PEER_PROJECT")

    # remote_yaml: SCP転送後のリモート側相対パス
    local remote_yaml=""
    if [[ -n "$TASK_YAML_PATH" ]]; then
        remote_yaml="queue/tasks/$(basename "$TASK_YAML_PATH")"
    fi
    q_yaml=$(printf '%q' "$remote_yaml")
    q_priority=$(printf '%q' "${PRIORITY:-}")

    _log "SSH exec: inbox_write $TARGET_AGENT (type=$TYPE) @ $PEER_HOST"

    # macOS PATH明示: Homebrew flock等がSSH非インタラクティブシェルで動作するよう設定
    # NJSLYR_SSH_DEPTH=1: リモート側での再帰SSH防止
    # SC2086: $SSH_OPTS は意図的にワード分割させる（複数オプション）
    # SC2029: $q_project/$q_target等はクライアント側で意図的に展開（printf '%q'済み）
    # shellcheck disable=SC2086,SC2029
    NJSLYR_SSH_DEPTH=1 ssh $SSH_OPTS "$PEER_HOST" \
        "export PATH=/opt/homebrew/bin:/opt/homebrew/opt/util-linux/bin:/usr/local/bin:/usr/bin:/bin; \
         cd $q_project && \
         NJSLYR_SSH_DEPTH=1 bash scripts/inbox_write.sh \
           $q_target $q_message $q_type $q_from $q_yaml $q_priority" \
        2>>"$LOG_FILE"
}

# ─── gryakuza障害通知 ────────────────────────────────────────────────────────
_notify_gryakuza_ssh_failure() {
    local reason="$1"
    # 無限ループ防止: gryakuza宛てのSSH送信失敗 or gryakuza自身からの送信は通知しない
    if [[ "$TARGET_AGENT" == "gryakuza" || "$FROM" == "gryakuza" ]]; then
        return 0
    fi
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "[ssh_inbox_write] SSH失敗: $PEER_HOST → inbox_write to $TARGET_AGENT (type=$TYPE, from=$FROM, reason=$reason). ntfyフォールバック試行済。" \
        "system_notice" "ssh_inbox_write" "" "P1" 2>>"$LOG_FILE" || true
}

# ─── ntfyフォールバック ─────────────────────────────────────────────────────
_ntfy_fallback() {
    local reason="$1"
    _log "SSH failed ($reason) → attempting ntfy fallback"

    local ntfy_dispatch="$SCRIPT_DIR/scripts/ntfy_send_dispatch.sh"
    local ntfy_report="$SCRIPT_DIR/scripts/ntfy_send_report.sh"

    case "$TYPE" in
        task_assigned|cmd_new|clear_command|model_switch)
            # dispatch系: ntfy_send_dispatch.sh
            if [[ -x "$ntfy_dispatch" ]]; then
                bash "$ntfy_dispatch" \
                    "$TARGET_AGENT" "$MESSAGE" "$TYPE" "$FROM" \
                    "${TASK_YAML_PATH:-}" "${PRIORITY:-}" 2>>"$LOG_FILE" || true
                _log "ntfy dispatch fallback sent → $TARGET_AGENT"
            else
                _log_error "ntfy_send_dispatch.sh not found: $ntfy_dispatch"
            fi
            ;;
        report_received)
            # report系: ntfy_send_report.sh
            if [[ -x "$ntfy_report" ]]; then
                bash "$ntfy_report" \
                    "$TARGET_AGENT" "$MESSAGE" "$TYPE" "$FROM" \
                    "${TASK_YAML_PATH:-}" "${PRIORITY:-}" 2>>"$LOG_FILE" || true
                _log "ntfy report fallback sent → $TARGET_AGENT"
            else
                _log_error "ntfy_send_report.sh not found: $ntfy_report"
            fi
            ;;
        wake_up|system_notice)
            # wake_up/system_notice系: ログのみ (njslyr_cmd.sh側で制御)
            _log "type=$TYPE: ntfy fallback not applicable. SSH failure logged only."
            ;;
        *)
            # その他: dispatch fallback試行
            if [[ -x "$ntfy_dispatch" ]]; then
                bash "$ntfy_dispatch" \
                    "$TARGET_AGENT" "$MESSAGE" "$TYPE" "$FROM" \
                    "${TASK_YAML_PATH:-}" "${PRIORITY:-}" 2>>"$LOG_FILE" || true
                _log "ntfy dispatch fallback (generic) sent → $TARGET_AGENT"
            else
                _log_error "ntfy_send_dispatch.sh not found for type=$TYPE"
            fi
            ;;
    esac

    # gryakuzaに障害通知 (可視化)
    _notify_gryakuza_ssh_failure "$reason"
}

# ─── SSH成功時の処理 ─────────────────────────────────────────────────────────
_do_ssh_inbox_write() {
    # 1. task_yaml SCP転送
    if [[ -n "$TASK_YAML_PATH" ]]; then
        if ! _scp_task_yaml; then
            _log_error "scp failed: $TASK_YAML_PATH"
            _ntfy_fallback "scp failed"
            return 1
        fi
        _log "scp OK: $(basename "$TASK_YAML_PATH")"
    fi

    # 2. SSH経由 inbox_write 実行
    if _ssh_run_inbox_write; then
        _log "✓ inbox_write OK → $TARGET_AGENT@$PEER_HOST (type=$TYPE)"
        return 0
    else
        _log_error "SSH inbox_write exec failed"
        _ntfy_fallback "inbox_write exec failed"
        return 1
    fi
}

# ─── メイン処理 ─────────────────────────────────────────────────────────────
_log "→ $TARGET_AGENT (type=$TYPE, from=$FROM, peer=$PEER_HOST)"

# SSH疎通確認 (1回目)
if _ssh_ping; then
    _log "SSH ping OK (attempt 1)"
    _do_ssh_inbox_write
    exit $?
fi

# 初回SSH失敗 → MBPスリープ復帰考慮: 10秒wait + 1回リトライ
_log "SSH ping failed (attempt 1/2) — waiting 10s for MBP sleep recovery..."
sleep 10

if _ssh_ping; then
    _log "SSH ping OK (attempt 2 — after sleep recovery wait)"
    _do_ssh_inbox_write
    exit $?
fi

# リトライも失敗 → ntfyフォールバック確定
_log_error "SSH ping failed (attempt 2/2) → ntfy fallback"
_ntfy_fallback "SSH unreachable after 2 attempts"
exit 1
