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

# base64エンコード（改行除去: tr -d '\n'）
PAYLOAD=$(base64 < "$TASK_REALPATH" | tr -d '\n')

# 認証引数取得
AUTH_ARGS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

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

# ─── ntfy POST（send_with_retryで3回・指数バックオフ 1s/3s/9s）───
# cmd_297 SSH fallback: context/ssh_fallback_design.md Section 3
if send_with_retry "https://ntfy.sh/${DISPATCH_TOPIC}" "${PREFIX}:${PAYLOAD}"; then
    echo "[ntfy_send_dispatch] SUCCESS: $TASK_PATH → ntfy/...-${DISPATCH_TOPIC##*-}" >&2
    exit 0
fi

# ─── SSH fallback（ntfy 全リトライ失敗時）───
echo "[ntfy_send_dispatch] All ntfy attempts failed. Trying SSH fallback..." >&2

PEER_HOST=$(awk '/^  peer_host:/ {print $2; exit}' "$SETTINGS" 2>/dev/null || echo "")
PEER_PROJECT_ROOT=$(awk '/^  peer_project_root:/ {print $2; exit}' "$SETTINGS" 2>/dev/null || echo "")

if [[ -z "$PEER_HOST" || -z "$PEER_PROJECT_ROOT" ]]; then
    echo "[ntfy_send_dispatch] ERROR: SSH fallback unavailable (no peer_host in settings.yaml)" >&2
    exit 1
fi

TASK_FILENAME=$(basename "$TASK_REALPATH")
REMOTE_TASK_PATH="${PEER_PROJECT_ROOT}/queue/tasks/${TASK_FILENAME}"

# 1. scp でタスク YAML をリモートに転送
if ! scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "$TASK_REALPATH" "${PEER_HOST}:${REMOTE_TASK_PATH}" 2>/dev/null; then
    echo "[ntfy_send_dispatch] ERROR: SSH fallback: scp failed ($PEER_HOST:$REMOTE_TASK_PATH)" >&2
    exit 1
fi

# 2. SSH でリモート inbox_write を実行（gryakuza に dispatch 到着を通知）
TASK_ID="${TASK_FILENAME%.yaml}"
if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$PEER_HOST" \
    "bash '${PEER_PROJECT_ROOT}/scripts/inbox_write.sh' gryakuza \
    'SSH dispatch受信: ${TASK_ID} → queue/tasks/${TASK_FILENAME} 保存済み。確認して割り当てよ。' \
    report_received ntfy_listener '${REMOTE_TASK_PATH}'" 2>/dev/null; then
    echo "[ntfy_send_dispatch] SSH fallback SUCCESS: $TASK_PATH → ${PEER_HOST}:${REMOTE_TASK_PATH}" >&2
else
    echo "[ntfy_send_dispatch] ERROR: SSH fallback: inbox_write failed on $PEER_HOST" >&2
    exit 1
fi
