#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ntfy_send_report.sh — MBP側レポート送信ヘルパー (cmd_278 T2)
# Usage: bash scripts/ntfy_send_report.sh <report_yaml_path>
#
# MBP側 yakuza/soukaiya がタスク完了後にこのスクリプトを呼び出す。
# レポートYAMLをbase64エンコードし、ntfy経由で Ryzen へ送信する。
# Ryzen側 ntfy_listener.sh の handle_report() が受信・保存する。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# FIX-012: settings.yaml存在チェック（ntfy_send_dispatch.shと統一）
if [[ ! -f "$SETTINGS" ]]; then
    echo "[ntfy_send_report] ERROR: settings.yaml not found: $SETTINGS" >&2
    exit 1
fi

TOPIC=$(awk '/ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' "$SETTINGS")

# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

if [[ -z "$TOPIC" ]]; then
    echo "[ntfy_send_report] ERROR: ntfy_topic not configured in settings.yaml" >&2
    exit 1
fi

REPORT_PATH="$1"
if [[ -z "$REPORT_PATH" ]]; then
    echo "Usage: $0 <report_yaml_path>" >&2
    exit 1
fi

if [[ ! -f "$REPORT_PATH" ]]; then
    echo "[ntfy_send_report] ERROR: report file not found: $REPORT_PATH" >&2
    exit 1
fi

# base64エンコード（改行除去: tr -d '\n'）
PAYLOAD=$(base64 < "$REPORT_PATH" | tr -d '\n')

# 認証引数取得
AUTH_ARGS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

# ntfy送信（FIX-010: HTTP status検証 / FIX-011: ${TOPIC}-kyoto送信でトピック分離）
# shellcheck disable=SC2215
HTTP_STATUS=$(curl -s -w '%{http_code}' -o /dev/null -X POST "https://ntfy.sh/${TOPIC}-kyoto" \
    "${AUTH_ARGS[@]}" \
    -H 'Content-Type: text/plain' \
    -d "report:${PAYLOAD}")
CURL_EXIT=$?

if [[ "$CURL_EXIT" -ne 0 ]]; then
    echo "[ntfy_send_report] ERROR: curl failed (exit code: $CURL_EXIT)" >&2
    exit 1
fi

if [[ "${HTTP_STATUS}" != 2* ]]; then
    echo "[ntfy_send_report] ERROR: ntfy POST failed: HTTP ${HTTP_STATUS}" >&2
    exit 1
fi

echo "[ntfy_send_report] Sent: $REPORT_PATH → ntfy/${TOPIC:0:8}...(masked) (HTTP $HTTP_STATUS)" >&2
