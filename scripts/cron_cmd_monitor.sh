#!/bin/bash
# cron_cmd_monitor.sh — 30分間隔でdarkninjaにcmd進捗確認を促すinboxを投入
# Usage: */30 * * * * bash /home/hrmtz/projects/multi-agent-njslyr/scripts/cron_cmd_monitor.sh
#
# Flow:
#   1. pending/in_progress の cmd_*.yaml が存在するか確認
#   2. 存在しなければスキップ（全cmd完了時は無駄に起こさない）
#   3. inbox_write.sh で cron_cmd_monitor タスク投入
#   4. njslyr_cmd.sh suriken darkninja でnudge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
LOGFILE="$PROJECT_ROOT/queue/logs/cron_cmd_monitor.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# 1. tmuxセッション存在確認
if ! tmux has-session -t multiagent 2>/dev/null; then
    log "SKIP: tmux session 'multiagent' not found"
    exit 0
fi

# 2. darkninja pane存在確認
# shellcheck source=scripts/njslyr_lib.sh
source "$SCRIPT_DIR/njslyr_lib.sh"
DARKNINJA_PANE=$(resolve_pane_by_agent_id "darkninja" 2>/dev/null || echo "")

if [[ -z "$DARKNINJA_PANE" ]]; then
    log "SKIP: darkninja pane not found"
    exit 0
fi

# 3. pending/in_progress の cmd が存在するか確認
ACTIVE_CMDS=$(grep -rl 'status:\s*\(pending\|in_progress\)' "$PROJECT_ROOT/queue/tasks/cmd_"*.yaml 2>/dev/null | wc -l)

if [[ "$ACTIVE_CMDS" -eq 0 ]]; then
    log "SKIP: no active cmds (all done/cancelled)"
    exit 0
fi

log "Active cmds found: $ACTIVE_CMDS"

# 4. inbox_write で cron_cmd_monitor 投入
TASK_CONTENT="cmd進捗確認タイマー発火。pending/in_progressのcmdを確認し、smithの状態をチェックせよ。報告が滞っていれば催促スリケンを投げろ。"

bash "$SCRIPT_DIR/inbox_write.sh" \
    darkninja \
    "$TASK_CONTENT" \
    cron_cmd_monitor \
    cron \
    "" \
    P2

log "inbox_write: cron_cmd_monitor sent to darkninja"

# 5. suriken でnudge
bash "$SCRIPT_DIR/njslyr_cmd.sh" suriken darkninja >> "$LOGFILE" 2>&1 || {
    log "WARNING: suriken to darkninja failed (non-fatal)"
}

log "cron_cmd_monitor completed"
