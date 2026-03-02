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

# shellcheck source=../lib/ssh_fallback.sh
source "$SCRIPT_DIR/lib/ssh_fallback.sh"

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
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/api_keys.env")

# SSH tier2 fallback: ntfy全失敗時にSCPでレポートYAMLをpeerへ転送しinbox通知
# 引数: report_path (必須)
# 戻り値: 0=実行済み(成功/失敗ともにログのみ), 1=peer未設定(スキップ)
_report_ssh_fallback() {
    local report_path="$1"
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_report.log"
    local peer_host peer_project report_filename remote_report_path report_id
    mkdir -p "$(dirname "$log_file")"

    peer_host=$(_ssh_get_peer_host)
    peer_project=$(_ssh_get_peer_project)
    if [[ -z "$peer_host" || -z "$peer_project" ]]; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback skipped: peer_host/peer_project_root not configured" >> "$log_file"
        return 1
    fi

    report_filename=$(basename "$report_path")
    remote_report_path="${peer_project}/queue/reports/${report_filename}"
    report_id="${report_filename%.yaml}"

    # 1. SCP でレポートYAMLをpeerへ転送
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "$report_path" "${peer_host}:${remote_report_path}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback ERROR: scp failed → ${peer_host}:${remote_report_path}" >> "$log_file"
        return 0
    fi

    # 2. SSH でリモートinbox_write実行（report_received通知）
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "$peer_host" \
        "bash '${peer_project}/scripts/inbox_write.sh' gryakuza \
        'SSH report受信: ${report_id} → queue/reports/${report_filename} 保存済み。' \
        report_received ntfy_listener '${remote_report_path}'" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback SUCCESS → ${peer_host}:${remote_report_path}" >> "$log_file"
        echo "[ntfy_send_report] SSH fallback SUCCESS: ${report_path} → ${peer_host}:${remote_report_path}" >&2
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
    # ─── SSH tier2 fallback（ntfy 全リトライ失敗時）───
    echo "[ntfy_send_report] All ntfy attempts failed. Trying SSH fallback..." >&2
    if ! _report_ssh_fallback "$REPORT_PATH"; then
        echo "[ntfy_send_report] ERROR: report send failed after retries" >&2
        exit 1
    fi
fi
