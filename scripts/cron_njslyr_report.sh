#!/bin/bash
# cron_njslyr_report.sh — 毎日22:00に忍殺語日報タスクをdarkninjaに投入する
# Usage: 0 22 * * * bash /home/hrmtz/projects/multi-agent-njslyr/scripts/cron_njslyr_report.sh
#
# Flow:
#   1. tmuxセッション(multiagent)存在確認
#   2. darkninja pane存在確認
#   3. inbox_write.sh で cron_daily_report タスク投入
#   4. njslyr_cmd.sh suriken darkninja でnudge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
LOGFILE="$PROJECT_ROOT/queue/logs/cron_njslyr_report.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# 1. tmuxセッション存在確認
if ! tmux has-session -t multiagent 2>/dev/null; then
    log "SKIP: tmux session 'multiagent' not found"
    exit 0
fi

# 2. darkninja pane存在確認（@agent_id=darkninjaのペインを探す）
# shellcheck source=scripts/njslyr_lib.sh
source "$SCRIPT_DIR/njslyr_lib.sh"
DARKNINJA_PANE=$(resolve_pane_by_agent_id "darkninja" 2>/dev/null || echo "")

if [[ -z "$DARKNINJA_PANE" ]]; then
    log "SKIP: darkninja pane not found in any tmux session"
    exit 0
fi

log "darkninja pane found: $DARKNINJA_PANE"

# 3. inbox_write で cron_daily_report タスク投入
TASK_CONTENT="本日の忍殺語日報を作成しLINEで送信せよ。git log --since=\"today 00:00\"とメモリから素材を抽出し、TEMPLATE_NJSLYR.mdに基づいて10投稿に分けてline_push.shで送信。完了後reports/daily/にアーカイブ保存。"

bash "$SCRIPT_DIR/inbox_write.sh" \
    darkninja \
    "$TASK_CONTENT" \
    cron_daily_report \
    cron \
    "" \
    P1

log "inbox_write: cron_daily_report sent to darkninja"

# 4. suriken でnudge
bash "$SCRIPT_DIR/njslyr_cmd.sh" suriken darkninja >> "$LOGFILE" 2>&1 || {
    log "WARNING: suriken to darkninja failed (non-fatal)"
}

log "cron_njslyr_report completed"
