#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ntfy_send_report.sh — NeoSaitama→Kyoto レポート送信ヘルパー (cmd_363)
# Usage: bash scripts/ntfy_send_report.sh <report_yaml_path>
#
# NeoSaitama側 yakuza/soukaiya がタスク完了後にこのスクリプトを呼び出す。
# SSH(SCP)でレポートYAMLをKyotoへ転送し、inbox_writeで通知する。
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

# shellcheck source=../lib/ssh_fallback.sh
source "$SCRIPT_DIR/lib/ssh_fallback.sh"

REPORT_PATH="$1"
if [[ -z "$REPORT_PATH" ]]; then
    echo "Usage: $0 <report_yaml_path>" >&2
    exit 1
fi

if [[ ! -f "$REPORT_PATH" ]]; then
    echo "[ntfy_send_report] ERROR: report file not found: $REPORT_PATH" >&2
    exit 1
fi

# SSH report送信: SCPでレポートYAMLをpeerへ転送しinbox通知
_report_ssh_primary() {
    local report_path="$1"
    local log_file="${SCRIPT_DIR}/logs/ntfy_send_report.log"
    local peer_host peer_project report_filename remote_report_path report_id
    mkdir -p "$(dirname "$log_file")"

    peer_host=$(_ssh_get_peer_host)
    peer_project=$(_ssh_get_peer_project)
    if [[ -z "$peer_host" || -z "$peer_project" ]]; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary skipped: peer_host/peer_project_root not configured" >> "$log_file"
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
        "bash '${peer_project}/scripts/inbox_write.sh' smith \
        'SSH report受信: ${report_id} → queue/reports/${report_filename} 保存済み。' \
        report_received ntfy_listener '${remote_report_path}'" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback SUCCESS → ${peer_host}:${remote_report_path}" >> "$log_file"
        echo "[ntfy_send_report] SSH fallback SUCCESS: ${report_path} → ${peer_host}:${remote_report_path}" >&2
    else
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH fallback ERROR: inbox_write failed on ${peer_host}" >> "$log_file"
    fi
    return 0
}

# ─── SSH dispatch実行 ───
echo "[ntfy_send_report] SSH dispatch試行..." >&2
if _report_ssh_primary "$REPORT_PATH"; then
    exit 0
fi

echo "[ntfy_send_report] ERROR: SSH dispatch failed." >&2
exit 1
