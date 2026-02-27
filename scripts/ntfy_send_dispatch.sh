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
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://ntfy.sh/${DISPATCH_TOPIC}" \
    "${AUTH_ARGS[@]}" \
    -H 'Content-Type: text/plain' \
    -H 'Title: task_dispatch' \
    -d "dispatch:${PAYLOAD}")

if [[ "$HTTP_STATUS" =~ ^2 ]]; then
    echo "[ntfy_send_dispatch] SUCCESS: $TASK_PATH → ntfy/${TOPIC:0:8}...(masked)-neosaitama (HTTP $HTTP_STATUS)" >&2
else
    echo "[ntfy_send_dispatch] ERROR: ntfy POST failed (HTTP $HTTP_STATUS)" >&2
    exit 1
fi
