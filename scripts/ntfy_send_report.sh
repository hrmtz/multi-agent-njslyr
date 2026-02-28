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

_get_operation_mode() {
    local mode
    mode=$(awk '/operation_mode:/ {print $2; exit}' "$SETTINGS" 2>/dev/null)
    echo "${mode:-kyoto_master}"
}

if [[ "$(_get_operation_mode)" == "standalone" ]]; then
    echo "[ntfy_send_report] standalone mode: skipping" >&2
    exit 0
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

# NTFY-003: send_with_retry — 3回リトライ（指数バックオフ: 1s / 3s / 9s）
send_with_retry() {
    local url="$1" data="$2"
    local max_attempts=3
    local wait_times=(1 3 9)
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_report.log"
    mkdir -p "$(dirname "$log_file")"
    for i in "${!wait_times[@]}"; do
        local attempt=$((i + 1))
        local resp
        resp=$(curl -s -w "\n%{http_code}" -X POST "$url" \
            "${AUTH_ARGS[@]}" \
            -H 'Content-Type: text/plain' \
            -d "$data")
        local code="${resp##*$'\n'}"
        local body="${resp%$'\n'*}"
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] attempt $attempt: HTTP $code | body: ${body:0:200}" >> "$log_file"
        if [[ "$code" =~ ^2 ]]; then
            echo "[ntfy_send_report] POST success (attempt $attempt): HTTP $code" >&2
            return 0
        fi
        echo "[ntfy_send_report] POST failed (attempt $attempt/$max_attempts): HTTP $code" >&2
        [[ $attempt -lt $max_attempts ]] && sleep "${wait_times[$i]}"
    done
    echo "[ntfy_send_report] All $max_attempts attempts failed" >&2
    return 1
}

# FIX-010: HTTP status検証 / FIX-011: ${TOPIC}-kyoto送信でトピック分離
if send_with_retry "https://ntfy.sh/${TOPIC}-kyoto" "report:${PAYLOAD}"; then
    echo "[ntfy_send_report] Sent: $REPORT_PATH → ntfy/${TOPIC:0:8}...(masked)" >&2
else
    echo "[ntfy_send_report] ERROR: report send failed after retries" >&2
    exit 1
fi
