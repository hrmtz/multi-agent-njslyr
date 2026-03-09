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

# shellcheck source=../lib/ssh_fallback.sh
source "$SCRIPT_DIR/lib/ssh_fallback.sh"

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

# SSH primary dispatch: SSHでタスクYAMLをpeerへ転送
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
        echo "[ntfy_send_dispatch] SSH primary skipped: peer not configured." >&2
        return 1
    fi

    task_filename=$(basename "$task_realpath")
    remote_task_path="${peer_project}/queue/tasks/${task_filename}"
    task_id="${task_filename%.yaml}"

    # 1. SCP でタスクYAMLをpeerへ転送
    # shellcheck disable=SC2086
    if ! scp ${SSH_OPTS} "$task_realpath" "${peer_host}:${remote_task_path}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] SSH primary ERROR: scp failed → ${peer_host}:${remote_task_path}" >> "$log_file"
        echo "[ntfy_send_dispatch] SSH primary FAILED: scp failed." >&2
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
        echo "[ntfy_send_dispatch] SSH primary FAILED: inbox_write failed." >&2
        return 1
    fi
}

# ─── SSH dispatch実行 ───
echo "[ntfy_send_dispatch] SSH dispatch試行..." >&2
if _dispatch_ssh_primary "$TASK_REALPATH"; then
    exit 0
fi

echo "[ntfy_send_dispatch] ERROR: SSH dispatch failed." >&2
exit 1
