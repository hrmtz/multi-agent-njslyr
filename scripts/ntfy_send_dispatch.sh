#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ntfy_send_dispatch.sh — Ryzen→MBP タスクディスパッチ送信ヘルパー (cmd_278 FIX-001)
# Usage: bash scripts/ntfy_send_dispatch.sh <task_yaml_path>
#
# Ryzen側 gryakuza/darkninja がタスクをMBPへ転送する際に呼び出す。
# タスクYAMLをbase64エンコードし、ntfy経由で ネオサイタマ(MBP) へ送信する。
# MBP側 ntfy_listener.sh の handle_task_dispatch() が受信・保存する。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${SETTINGS_FILE:-$SCRIPT_DIR/config/settings.yaml}"

# settings.yaml 存在確認（スタンドアロン動作防止）
if [[ ! -f "$SETTINGS" ]]; then
    echo "[ntfy_send_dispatch] ERROR: settings.yaml not found (role=kyoto). dispatch unavailable." >&2
    exit 1
fi

_get_operation_mode() {
    local mode
    mode=$(awk '/operation_mode:/ {print $2; exit}' "$SETTINGS" 2>/dev/null)
    echo "${mode:-kyoto_master}"
}

if [[ "$(_get_operation_mode)" == "standalone" ]]; then
    echo "[dispatch] standalone mode: skipping" >&2
    exit 0
fi

TOPIC=$(awk '/ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' "$SETTINGS")

# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

# shellcheck source=../lib/ssh_fallback.sh
source "$SCRIPT_DIR/lib/ssh_fallback.sh"

if [[ -z "$TOPIC" ]]; then
    echo "[ntfy_send_dispatch] ERROR: ntfy_topic not configured in settings.yaml" >&2
    exit 1
fi

TASK_PATH="${1:-}"
if [[ -z "$TASK_PATH" ]]; then
    echo "Usage: $0 <task_yaml_path>" >&2
    exit 1
fi

# path traversal防止: realpathで解決し、プロジェクトルート内であることを確認
TASK_REALPATH=$(realpath "$TASK_PATH" 2>/dev/null) || true
if [[ -z "$TASK_REALPATH" ]]; then
    echo "[ntfy_send_dispatch] ERROR: Cannot resolve path: $TASK_PATH" >&2
    exit 1
fi

if [[ "$TASK_REALPATH" != "$SCRIPT_DIR"/* ]]; then
    echo "[ntfy_send_dispatch] ERROR: path traversal detected: $TASK_PATH is outside project root" >&2
    exit 1
fi

if [[ ! -f "$TASK_REALPATH" ]]; then
    echo "[ntfy_send_dispatch] ERROR: task file not found: $TASK_PATH" >&2
    exit 1
fi

# cmd_328: task_id取得（ACK照合用）
DISPATCH_TASK_ID=$(python3 -c "
import yaml, sys
try:
    with open('$TASK_REALPATH') as f:
        d = yaml.safe_load(f)
    task_data = d.get('task', d) if isinstance(d, dict) else {}
    print(task_data.get('task_id', '') if isinstance(task_data, dict) else '')
except Exception:
    print('')
" 2>/dev/null)

# base64エンコード（改行除去: tr -d '\n'）
PAYLOAD=$(base64 < "$TASK_REALPATH" | tr -d '\n')

# 認証引数取得
AUTH_ARGS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/api_keys.env")

# FIX-010: dispatch送信先をmachine.roleに基づいて動的決定（双方向対応）
MY_ROLE=$(awk '/^  role:/ {print $2; exit}' "$SETTINGS")
MY_ROLE="${MY_ROLE:-kyoto}"
case "$MY_ROLE" in
  kyoto|ryzen)    DISPATCH_TOPIC="${TOPIC}-neosaitama" ;;
  neosaitama|mbp) DISPATCH_TOPIC="${TOPIC}-kyoto" ;;
  *)              DISPATCH_TOPIC="${TOPIC}-neosaitama" ;;  # fallback
esac

# NTFY-002: payload size check
# NOTE: gzip圧縮(dispatch_gz)は受信側(ntfy_listener.sh route_message)にハンドラが
# 未実装のため一時無効化。dispatch_gzで送信するとサイレント消失する (LBUG-003)。
# 受信側ハンドラ実装後に有効化すること。
PREFIX="dispatch"
if [[ ${#PAYLOAD} -gt 4096 ]]; then
    echo "[ntfy_send_dispatch] WARNING: payload ${#PAYLOAD}B > 4096B (large, but sending uncompressed — dispatch_gz receiver not yet implemented)" >&2
    # 旧コード（受信側実装後に有効化）:
    # PAYLOAD=$(gzip -c "$TASK_REALPATH" | base64 | tr -d '\n')
    # PREFIX="dispatch_gz"
fi

# cmd_328: アイサツ待機関数 — dispatch送信成功後に受信側からのアイサツを待つ
# 引数: task_id, since_epoch
# 設計判断: 同期ブロッキング方式を採用
#   理由1: ntfy_send_dispatch.shは短命スクリプト（送信→確認→終了）
#   理由2: バックグラウンドだと孤立プロセス管理が複雑（PID追跡・状態ファイル等）
#   理由3: SSH fallbackとの連携がシンプル（タイムアウト後に直接呼び出せる）
#   理由4: send_with_retry自体も最大13秒ブロッキング。60秒は一貫性あり
# BUG-001修正: process substitution方式（< <(curl)）採用 — break後curlを即kill
# DESIGN-001: aisatsu:error受信も return 0（到達確認済み）。シツレイ検知(タイムアウト)のみreturn 1
# 戻り値: 0=アイサツ受信（ok/error問わず）, 1=シツレイ検知（→SSH fallback発動）
_wait_for_aisatsu() {
    local task_id="$1"
    local since_epoch="$2"
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_dispatch.log"
    mkdir -p "$(dirname "$log_file")"
    local own_topic="${TOPIC}-${MY_ROLE}"
    local aisatsu_url="https://ntfy.sh/${own_topic}/json?since=${since_epoch}"
    local aisatsu_received=0

    echo "[ntfy_send_dispatch] アイサツ待機中: task_id=$task_id on $own_topic (60s)..." >&2
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] アイサツ待機開始: task_id=$task_id topic=$own_topic" >> "$log_file"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # event=message のみ処理（open/keepalive skip）
        [[ "$line" != *'"event":"message"'* ]] && continue
        # task_idを含む行のみ詳細parse（高速フィルタ）
        [[ "$line" != *"aisatsu:${task_id}"* ]] && continue
        local msg
        msg=$(printf '%s' "$line" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('message', ''))
except Exception:
    print('')
" 2>/dev/null)
        if [[ "$msg" == "aisatsu:${task_id}:ok" ]]; then
            echo "[$(date '+%Y-%m-%dT%H:%M:%S')] アイサツ受信(ok): $msg" >> "$log_file"
            echo "[ntfy_send_dispatch] アイサツ受信(ok): $task_id" >&2
            aisatsu_received=1
            break
        elif [[ "$msg" == "aisatsu:${task_id}:error" ]]; then
            # DESIGN-001: error=到達確認済み（処理失敗）→ return 0、SSH fallbackなし
            echo "[$(date '+%Y-%m-%dT%H:%M:%S')] アイサツ受信(error): $msg (dispatch到達済み・処理失敗)" >> "$log_file"
            echo "[ntfy_send_dispatch] アイサツ受信(error, dispatch到達済み): $task_id" >&2
            aisatsu_received=1
            break
        fi
    done < <(curl -s --max-time 60 "${AUTH_ARGS[@]}" "$aisatsu_url" 2>/dev/null)

    if [[ "$aisatsu_received" -eq 1 ]]; then
        return 0
    else
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] シツレイ検知: $task_id — 60秒以内にアイサツなし" >> "$log_file"
        echo "[ntfy_send_dispatch] WARNING: シツレイ検知 (タイムアウト) for $task_id" >&2
        return 1
    fi
}

# transport_priority読み込み（settings.yaml transport.priority）
# 戻り値: ssh_first (デフォルト) | ntfy_first
_get_transport_priority() {
    awk '/^transport:/{found=1} found && /priority:/{print $2; found=0; exit}' "$SETTINGS" 2>/dev/null
}

# SSH primary dispatch: ssh_firstモードでの第一優先転送
# 引数: task_realpath (必須)
# 戻り値: 0=成功(SCP+inbox_write両方OK), 1=失敗(→ntfy fallbackへ)
_dispatch_ssh_primary() {
    local task_realpath="$1"
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_dispatch.log"
    local peer_host peer_project task_filename remote_task_path task_id
    mkdir -p "$(dirname "$log_file")"

    peer_host=$(_ssh_get_peer_host)
    peer_project=$(_ssh_get_peer_project)
    if [[ -z "$peer_host" || -z "$peer_project" ]]; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary skipped: peer_host/peer_project_root not configured" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH primary skipped: peer not configured → ntfy fallback" >&2
        return 1
    fi

    task_filename=$(basename "$task_realpath")
    remote_task_path="${peer_project}/queue/tasks/${task_filename}"
    task_id="${task_filename%.yaml}"

    # 1. SCP でタスクYAMLをpeerへ転送
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "$task_realpath" "${peer_host}:${remote_task_path}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary ERROR: scp failed → ${peer_host}:${remote_task_path}" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH primary FAILED: scp failed → ntfy fallback" >&2
        return 1
    fi

    # 2. SSH でリモートinbox_write実行（task_assigned通知）
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "$peer_host" \
        "bash '${peer_project}/scripts/inbox_write.sh' gryakuza \
        'SSH dispatch受信: ${task_id} → queue/tasks/${task_filename} 保存済み。確認して割り当てよ。' \
        task_assigned gryakuza '${remote_task_path}'" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary SUCCESS → ${peer_host}:${remote_task_path}" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH primary SUCCESS: ${task_realpath} → ${peer_host}:${remote_task_path}" >&2
        return 0
    else
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary ERROR: inbox_write failed on ${peer_host}" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH primary FAILED: inbox_write failed → ntfy fallback" >&2
        return 1
    fi
}

# SSH tier2 fallback: ntfy全失敗時にSCPでタスクYAMLをpeerへ転送しinbox通知
# 引数: task_realpath (必須)
# 戻り値: 0=実行済み(成功/失敗ともにログのみ), 1=peer未設定(スキップ)
_dispatch_ssh_fallback() {
    local task_realpath="$1"
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_dispatch.log"
    local peer_host peer_project task_filename remote_task_path task_id
    mkdir -p "$(dirname "$log_file")"

    peer_host=$(_ssh_get_peer_host)
    peer_project=$(_ssh_get_peer_project)
    if [[ -z "$peer_host" || -z "$peer_project" ]]; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback skipped: peer_host/peer_project_root not configured" >> "$log_file"
        return 1
    fi

    task_filename=$(basename "$task_realpath")
    remote_task_path="${peer_project}/queue/tasks/${task_filename}"
    task_id="${task_filename%.yaml}"

    # 1. SCP でタスクYAMLをpeerへ転送
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "$task_realpath" "${peer_host}:${remote_task_path}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback ERROR: scp failed → ${peer_host}:${remote_task_path}" >> "$log_file"
        return 0
    fi

    # 2. SSH でリモートinbox_write実行（task_assigned通知）
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "$peer_host" \
        "bash '${peer_project}/scripts/inbox_write.sh' gryakuza \
        'SSH dispatch受信: ${task_id} → queue/tasks/${task_filename} 保存済み。確認して割り当てよ。' \
        task_assigned gryakuza '${remote_task_path}'" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback SUCCESS → ${peer_host}:${remote_task_path}" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH fallback SUCCESS: ${task_realpath} → ${peer_host}:${remote_task_path}" >&2
    else
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback ERROR: inbox_write failed on ${peer_host}" >> "$log_file"
    fi
    return 0
}

# NTFY-003: send_with_retry — 3回リトライ（指数バックオフ: 1s / 3s / 9s）
send_with_retry() {
    local url="$1" data="$2"
    local max_attempts=3
    local wait_times=(1 3 9)
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_dispatch.log"
    mkdir -p "$(dirname "$log_file")"
    for i in "${!wait_times[@]}"; do
        local attempt=$((i + 1))
        local resp
        resp=$(curl -s -w "\n%{http_code}" -X POST "$url" \
            "${AUTH_ARGS[@]}" \
            -H 'Content-Type: text/plain' \
            -H 'Title: task_dispatch' \
            -d "$data")
        local code="${resp##*$'\n'}"
        local body="${resp%$'\n'*}"
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] attempt $attempt: HTTP $code | body: ${body:0:200}" >> "$log_file"
        if [[ "$code" =~ ^2 ]]; then
            echo "[ntfy_send_dispatch] POST success (attempt $attempt): HTTP $code" >&2
            return 0
        fi
        echo "[ntfy_send_dispatch] POST failed (attempt $attempt/$max_attempts): HTTP $code" >&2
        [[ $attempt -lt $max_attempts ]] && sleep "${wait_times[$i]}"
    done
    echo "[ntfy_send_dispatch] All $max_attempts attempts failed" >&2
    return 1
}

# ─── transport_priority 判定 ───
TRANSPORT_PRIORITY=$(_get_transport_priority)
TRANSPORT_PRIORITY="${TRANSPORT_PRIORITY:-ssh_first}"

if [[ "$TRANSPORT_PRIORITY" == "ssh_first" ]]; then
    # ─── SSH primary試行（ssh_firstモード）───
    echo "[ntfy_send_dispatch] transport=ssh_first: SSH primary試行..." >&2
    if _dispatch_ssh_primary "$TASK_REALPATH"; then
        exit 0
    fi

    # SSH primary失敗 → ntfy fallback
    echo "[ntfy_send_dispatch] SSH primary失敗。ntfy fallback試行..." >&2
    SEND_EPOCH=$(date +%s)
    if send_with_retry "https://ntfy.sh/${DISPATCH_TOPIC}" "${PREFIX}:${PAYLOAD}"; then
        echo "[ntfy_send_dispatch] ntfy SUCCESS: $TASK_PATH → ntfy/...-${DISPATCH_TOPIC##*-}" >&2
        if [[ -n "$DISPATCH_TASK_ID" ]]; then
            if _wait_for_aisatsu "$DISPATCH_TASK_ID" "$SEND_EPOCH"; then
                echo "[ntfy_send_dispatch] dispatch アイサツ確認: $DISPATCH_TASK_ID" >&2
            else
                echo "[ntfy_send_dispatch] WARNING: ntfy送信済みだがアイサツなし (シツレイ検知)" >&2
            fi
        fi
        exit 0
    fi

    # SSH + ntfy 両方失敗
    echo "[ntfy_send_dispatch] ERROR: SSH primary and ntfy both failed." >&2
    exit 1

else
    # ─── ntfy_firstモード（旧動作・後方互換）───
    # DESIGN-002: DISPATCH_TASK_ID (python3 yaml.safe_load方式) を使用
    # SEND_EPOCH: アイサツ since= パラメータ用、送信直前に記録（取りこぼし防止）
    SEND_EPOCH=$(date +%s)

    if send_with_retry "https://ntfy.sh/${DISPATCH_TOPIC}" "${PREFIX}:${PAYLOAD}"; then
        echo "[ntfy_send_dispatch] SUCCESS: $TASK_PATH → ntfy/...-${DISPATCH_TOPIC##*-}" >&2

        # cmd_328: アイサツ待機（DISPATCH_TASK_ID使用 — python3 yaml.safe_load方式）
        if [[ -n "$DISPATCH_TASK_ID" ]]; then
            if _wait_for_aisatsu "$DISPATCH_TASK_ID" "$SEND_EPOCH"; then
                echo "[ntfy_send_dispatch] dispatch アイサツ確認: $DISPATCH_TASK_ID" >&2
                exit 0
            else
                # シツレイ検知 → SSH fallback自動実行
                echo "[ntfy_send_dispatch] シツレイ検知。SSH fallback実行..." >&2
                _dispatch_ssh_fallback "$TASK_REALPATH" || true
                exit 0
            fi
        else
            echo "[ntfy_send_dispatch] WARNING: task_id取得失敗 — アイサツ待機スキップ" >&2
            exit 0
        fi
    fi

    # ─── SSH tier2 fallback（ntfy 全リトライ失敗時）───
    echo "[ntfy_send_dispatch] All ntfy attempts failed. Trying SSH fallback..." >&2
    if ! _dispatch_ssh_fallback "$TASK_REALPATH"; then
        echo "[ntfy_send_dispatch] ERROR: SSH fallback unavailable (no peer configured)" >&2
        exit 1
    fi
    exit 0
fi
