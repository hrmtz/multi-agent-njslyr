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
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# settings.yaml 存在確認（スタンドアロン動作防止）
if [[ ! -f "$SETTINGS" ]]; then
    echo "[ntfy_send_dispatch] ERROR: settings.yaml not found (role=kyoto). dispatch unavailable." >&2
    exit 1
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
# ─── ntfy POST（リトライ付き: 3回・5秒間隔）───
# cmd_297 SSH fallback: context/ssh_fallback_design.md Section 3
MAX_NTFY_RETRIES=3
NTFY_RETRY_INTERVAL=5
ntfy_ok=false

for attempt in $(seq 1 $MAX_NTFY_RETRIES); do
    HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://ntfy.sh/${DISPATCH_TOPIC}" \
        "${AUTH_ARGS[@]}" \
        -H 'Content-Type: text/plain' \
        -H 'Title: task_dispatch' \
        -d "dispatch:${PAYLOAD}")

    if [[ "$HTTP_STATUS" =~ ^2 ]]; then
        echo "[ntfy_send_dispatch] SUCCESS (attempt ${attempt}): $TASK_PATH → ntfy/...-${DISPATCH_TOPIC##*-} (HTTP $HTTP_STATUS)" >&2
        ntfy_ok=true
        break
    fi
    echo "[ntfy_send_dispatch] ntfy POST failed (HTTP $HTTP_STATUS, attempt ${attempt}/${MAX_NTFY_RETRIES})" >&2
    if [[ $attempt -lt $MAX_NTFY_RETRIES ]]; then
        sleep $NTFY_RETRY_INTERVAL
    fi
done

if [[ "$ntfy_ok" == "true" ]]; then
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
