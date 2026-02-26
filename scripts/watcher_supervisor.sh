#!/bin/bash
set -euo pipefail

# macOS (Darwin): GNU coreutils + util-linux (flock) via Homebrew
if [[ "$(uname -s)" == "Darwin" ]]; then
    _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
    export PATH="${_HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
fi

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

PROJECT_ROOT="$SCRIPT_DIR"
STATE_DIR="$PROJECT_ROOT/.state"
RESCAN_FILE="$STATE_DIR/rescan_watchers"

mkdir -p logs queue/inbox "$STATE_DIR"

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

# Check if a pane with session:window.index format exists.
# Used only for darkninja (fixed session target).
pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

# For darkninja only: static session target (darkninja:main.0).
# Kept separate because darkninja runs in a dedicated session, not multiagent:agents.
start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        return 0
    fi

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null); cli=${cli:-claude}
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

# For all agents except darkninja: dynamically resolve pane_id from @agent_id.
# UNIFIED-MED-005: pgrep uses [%] to match %pane_id format (avoids trailing-space ambiguity).
# C-ISSUE-1: pane_exists() is not used here; empty pane_id check replaces it.
# pane_map: cached output of "tmux list-panes -a -F '#{@agent_id} #{pane_id}'" (passed from scan_all_agents)
start_watcher_for_agent() {
    local agent="$1"
    local log_file="$2"
    local pane_map="$3"

    ensure_inbox_file "$agent"

    # Dynamic pane lookup by @agent_id (uses caller-cached tmux output — no extra fork)
    local pane_id
    pane_id=$(awk -v id="$agent" '$1 == id {print $2; exit}' <<< "$pane_map")

    if [[ -z "$pane_id" ]]; then
        # Pane not found: skip (expected after yakuzatengu despawn or pane not yet spawned)
        return 0
    fi

    # UNIFIED-MED-005: [%] matches the literal % prefix of pane_id (e.g. %42)
    if pgrep -f "scripts/inbox_watcher.sh ${agent} [%]" >/dev/null 2>&1; then
        return 0
    fi

    local cli
    cli=$(tmux show-options -p -t "$pane_id" -v @agent_cli 2>/dev/null); cli=${cli:-claude}
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane_id" "$cli" >> "$log_file" 2>&1 &
    echo "[watcher_supervisor] started inbox_watcher for $agent → $pane_id"
}

# Scan all agents and ensure their inbox_watchers are running.
# Called from main loop (periodic) and on RESCAN_FILE signal (immediate).
scan_all_agents() {
    # darkninja: fixed session target (separate dedicated session)
    start_watcher_if_missing "darkninja" "darkninja:main.0" "logs/inbox_watcher_darkninja.log"

    # Cache full pane map once to avoid N tmux calls per agent (N+1 → 1).
    local pane_map
    pane_map=$(tmux list-panes -a -F '#{@agent_id} #{pane_id}' 2>/dev/null)

    # All agents in multiagent:agents window: detect dynamically by @agent_id.
    # Handles yakuzatengu spawn/despawn transparently.
    # awk replaces grep -v '^$' | sort -u (one process instead of two).
    while IFS= read -r agent; do
        [[ -z "$agent" || "$agent" == "darkninja" ]] && continue
        start_watcher_for_agent "$agent" "logs/inbox_watcher_${agent}.log" "$pane_map"
    done < <(tmux list-panes -t multiagent:agents -F '#{@agent_id}' 2>/dev/null \
        | awk 'NF && !seen[$0]++')
}

# Graceful shutdown: log and exit cleanly on SIGTERM/SIGINT
cleanup() {
    echo "[watcher_supervisor] shutting down (signal received)" >&2
    exit 0
}
trap cleanup SIGTERM SIGINT

while true; do
    # UNIFIED-HIGH-008: rescan_watchers signal
    # spawn_tengu() / despawn_tengu() touch this file to trigger immediate rescanning.
    # macOS has no inotifywait, so we use polling (checked once per loop iteration).
    if [[ -f "$RESCAN_FILE" ]]; then
        # LOW-002: mv方式（アトミック操作）でrm後・scan前の新シグナル消失を防止
        # mv失敗（同時実行等）はtrueで無視。その場合次ループで再検知される
        mv "$RESCAN_FILE" "${RESCAN_FILE}.processing" 2>/dev/null || true
        echo "[watcher_supervisor] rescan_watchers signal detected. Running immediate scan."
        scan_all_agents
        sleep 5
        continue  # LOW-001: rescan後は通常スキャンをスキップ（2重スキャン防止）
    fi

    scan_all_agents
    sleep 5
done
