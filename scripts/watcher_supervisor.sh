#!/bin/bash
set -euo pipefail

# macOS (Darwin): GNU coreutils via Homebrew gnubin
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
fi

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs queue/inbox

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

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

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

while true; do
    start_watcher_if_missing "darkninja" "darkninja:main.0" "logs/inbox_watcher_darkninja.log"
    start_watcher_if_missing "gryakuza" "multiagent:agents.0" "logs/inbox_watcher_gryakuza.log"
    start_watcher_if_missing "yakuza1" "multiagent:agents.1" "logs/inbox_watcher_yakuza1.log"
    start_watcher_if_missing "yakuza2" "multiagent:agents.2" "logs/inbox_watcher_yakuza2.log"
    start_watcher_if_missing "yakuza3" "multiagent:agents.3" "logs/inbox_watcher_yakuza3.log"
    start_watcher_if_missing "yakuza4" "multiagent:agents.4" "logs/inbox_watcher_yakuza4.log"
    start_watcher_if_missing "yakuza5" "multiagent:agents.5" "logs/inbox_watcher_yakuza5.log"
    start_watcher_if_missing "yakuza6" "multiagent:agents.6" "logs/inbox_watcher_yakuza6.log"
    start_watcher_if_missing "yakuza7" "multiagent:agents.7" "logs/inbox_watcher_yakuza7.log"
    start_watcher_if_missing "soukaiya" "multiagent:agents.8" "logs/inbox_watcher_soukaiya.log"
    sleep 5
done
