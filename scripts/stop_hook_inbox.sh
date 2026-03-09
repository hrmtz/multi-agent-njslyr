#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# stop_hook_inbox.sh — Claude Code Stop Hook for inbox delivery
# ═══════════════════════════════════════════════════════════════
# When a Claude Code agent finishes its turn and is about to go idle,
# this hook checks the agent's inbox for unread messages.
# If unread messages exist, the hook BLOCKs the stop and feeds
# the message summary back as the reason — the agent processes it
# as its next action without any tmux send-keys interruption.
#
# This eliminates the "思考中にinboxをぶちこまれると思考が止まる" problem
# for Claude Code agents (gryakuza, soukaiya).
#
# Usage: Registered as a Stop hook in .claude/settings.json
#   The hook receives JSON on stdin; outputs JSON to stdout.
#
# Environment:
#   TMUX_PANE — used to identify which agent is running
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

# ─── Read stdin (hook input JSON) ───
INPUT=$(cat)

# ─── Infinite loop prevention ───
# When stop_hook_active=true, the agent is already continuing from a
# previous Stop hook block. Allow it to stop this time to prevent loops.
# Use bash regex to avoid python3 fork for a simple boolean field check.
_sa_pattern='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
if [[ "$INPUT" =~ $_sa_pattern ]]; then
    exit 0
fi

# ─── Identify agent ───
AGENT_ID=""
SESSION_NAME=""
if [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
    SESSION_NAME=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}' 2>/dev/null || true)
fi

# TMUX_PANE inheritance bug workaround: TMUX_PANE may point to a different
# session's pane if darkninja was launched from within a multiagent pane.
# Reliably detect current session via $TMUX env var (session_id field),
# since tmux display-message -p without -t fails when no client is attached.
ACTUAL_SESSION=""
if [ -n "${TMUX:-}" ]; then
    # $TMUX format: socket_path,server_pid,session_id_num
    SESSION_NUM="${TMUX##*,}"
    # tmux session_id format is "$N" (dollar sign + number)
    ACTUAL_SESSION=$(tmux list-sessions -F '#{session_id} #{session_name}' 2>/dev/null \
        | awk -v n="$SESSION_NUM" '$1 == ("$" n) {print $2; exit}' || true)
fi

# If we can't identify the agent, approve (exit 0 with no output = approve)
if [ -z "$AGENT_ID" ] && [ -z "$ACTUAL_SESSION" ]; then
    exit 0
fi

# ─── Darkninja: always approve (human-controlled) ───
# Triple-check: agent_id, session from TMUX_PANE, and actual current session.
# Handles TMUX_PANE inheritance bug where darkninja session inherits TMUX_PANE
# pointing to another agent's pane (e.g. yakuza4 → SESSION_NAME="multiagent").
if [ "$AGENT_ID" = "darkninja" ] || [ "$SESSION_NAME" = "darkninja" ] || [ "$ACTUAL_SESSION" = "darkninja" ] || [ "$ACTUAL_SESSION" = "main" ]; then
    exit 0
fi

# AGENT_ID unknown (not darkninja but unidentifiable): can't locate inbox → approve
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

# ─── Check inbox for unread messages ───
INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"

if [ ! -f "$INBOX" ]; then
    exit 0
fi

# Count unread messages using grep (fast, no python dependency)
# Pattern: '^ *read: false$' to avoid false positives from message content
UNREAD_COUNT=$(grep -c '^ *read: false$' "$INBOX" 2>/dev/null || true)

if [ "${UNREAD_COUNT:-0}" -eq 0 ]; then
    exit 0
fi

# ─── Block the stop — extract summaries and feed inbox info back to agent ───
# Single python3 invocation: summary extraction + JSON output merged.
python3 -c "
import yaml, sys, json
count = $UNREAD_COUNT
inbox_path = '$INBOX'
try:
    with open(inbox_path, 'r') as f:
        data = yaml.safe_load(f)
    msgs = data.get('messages', []) if data else []
    unread = [m for m in msgs if not m.get('read', True)]
    parts = []
    for m in unread[:5]:  # Max 5 messages in summary
        frm = m.get('from', '?')
        typ = m.get('type', '?')
        content = str(m.get('content', ''))[:80]
        parts.append(f'[{frm}/{typ}] {content}')
    summary = ' | '.join(parts)
except Exception:
    summary = f'inbox未読{count}件あり'
reason = f'inbox未読{count}件あり。queue/inbox/${AGENT_ID}.yamlを読んで処理せよ。内容: {summary}'
print(json.dumps({'decision': 'block', 'reason': reason}))
" 2>/dev/null || echo "{\"decision\":\"block\",\"reason\":\"inbox未読${UNREAD_COUNT}件あり。queue/inbox/${AGENT_ID}.yamlを読んで処理せよ。\"}"
