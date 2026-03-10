#!/bin/bash
# monitor_context.sh - Context usage monitoring with auto-recovery
# Phase 1: Prevent context exhaustion accidents (Laomoto top priority)
#
# Strategy: Extract autocompact data from ~/.claude/debug/ logs
# Thresholds: 30% warn, 20% alert, 10% auto-clear

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
DASHBOARD="$PROJECT_ROOT/dashboard.md"
DEBUG_DIR="$HOME/.claude/debug"

# Thresholds (percentage remaining)
WARN_THRESHOLD=30
ALERT_THRESHOLD=20
CRITICAL_THRESHOLD=10

# Cooldown to prevent spam (5 minutes = 300 seconds)
COOLDOWN=300
STATE_DIR="$PROJECT_ROOT/.state"
CACHE_DIR="$PROJECT_ROOT/queue/.cache"
mkdir -p "$STATE_DIR" "$CACHE_DIR"

LAST_WARN_FILE="$STATE_DIR/last_warn"
LAST_ALERT_FILE="$STATE_DIR/last_alert"
LAST_CLEAR_FILE="$STATE_DIR/last_clear"

# ========================================
# Core Functions
# ========================================

# Extract latest context usage from debug logs (last 10 minutes)
# Returns: percentage remaining (e.g., "35.6")
get_context_usage() {
    local autocompact_line
    autocompact_line=$(find "$DEBUG_DIR" -name "*.txt" -mmin -10 -type f 2>/dev/null | \
        xargs grep "autocompact:" 2>/dev/null | \
        tail -1)

    if [[ -z "$autocompact_line" ]]; then
        echo "ERROR: No autocompact data found in recent debug logs" >&2
        return 1
    fi

    # Parse: autocompact: tokens=115916 threshold=167000 effectiveWindow=180000
    local tokens
    local window

    tokens="${autocompact_line#*tokens=}"; tokens="${tokens%%[^0-9]*}"
    window="${autocompact_line#*effectiveWindow=}"; window="${window%%[^0-9]*}"

    if [[ -z "$tokens" || -z "$window" || "$window" -eq 0 ]]; then
        echo "ERROR: Failed to parse autocompact data: $autocompact_line" >&2
        return 1
    fi

    # Calculate remaining percentage: (window - tokens) / window * 100
    local usage_pct
    usage_pct=$(awk "BEGIN {printf \"%.1f\", (($window - $tokens) / $window * 100)}")
    echo "$usage_pct"
}

# Check if cooldown period has passed
# Args: $1 = cooldown file path
# Returns: 0 if cooldown passed, 1 if still active
check_cooldown() {
    local cooldown_file="$1"
    local now
    now=$(date +%s)

    if [[ -f "$cooldown_file" ]]; then
        local last
        last=$(cat "$cooldown_file" 2>/dev/null || echo "0")
        [[ "$last" =~ ^[0-9]+$ ]] || last=0  # 空/非数値なら0扱い（cooldown済みと同義）
        local elapsed=$((now - last))
        if [[ $elapsed -lt $COOLDOWN ]]; then
            return 1  # Still in cooldown
        fi
    fi
    return 0  # Cooldown passed
}

# Update cooldown timestamp
# Args: $1 = cooldown file path
update_cooldown() {
    local cooldown_file="$1"
    date +%s > "$cooldown_file"
}

# Send ntfy notification if ntfy.sh is available
# Args: $1 = message, $2 = priority (optional)
send_ntfy() {
    local message="$1"
    local priority="${2:-default}"

    if [[ -x "$SCRIPT_DIR/ntfy.sh" ]]; then
        "$SCRIPT_DIR/ntfy.sh" "$message" "$priority" 2>/dev/null || true
    fi
}

# Update dashboard with alert in 🚨ヨウタイオウ section
# Args: $1 = usage percentage
update_dashboard_alert() {
    local usage_pct="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local alert_msg="⚠️ コンテキスト残量 ${usage_pct}% (閾値${ALERT_THRESHOLD}%以下) - 自動監視検知 [$timestamp]"

    if [[ ! -f "$DASHBOARD" ]]; then
        echo "Dashboard file not found: $DASHBOARD" >&2
        return 1
    fi

    if grep -q "^## 🚨ヨウタイオウ" "$DASHBOARD"; then
        # Append to existing section (insert after section header)
        local temp_file
        temp_file=$(TMPDIR="$CACHE_DIR" mktemp)
        awk -v alert="$alert_msg" '
            /^## 🚨ヨウタイオウ/ {
                print
                print ""
                print "- " alert
                skip_next_blank = 1
                next
            }
            skip_next_blank && /^$/ {
                skip_next_blank = 0
                next
            }
            {print}
        ' "$DASHBOARD" > "$temp_file"
        mv "$temp_file" "$DASHBOARD"
    else
        # Create new section at the end
        {
            echo ""
            echo "## 🚨ヨウタイオウ"
            echo ""
            echo "- $alert_msg"
        } >> "$DASHBOARD"
    fi
}

# Trigger auto /clear for smith via inbox
# Args: $1 = usage percentage
trigger_auto_clear() {
    local usage_pct="$1"
    local message="🚨コンテキスト残量${usage_pct}% → 自動/clear発動（monitor_context.sh）"

    # Send clear_command type to smith
    bash "$SCRIPT_DIR/inbox_write.sh" smith "$message" clear_command monitor_context

    echo "[AUTO-CLEAR] Triggered /clear for smith (usage: ${usage_pct}%)" >&2
}

# ========================================
# Main Monitoring Logic
# ========================================

main() {
    local mode="${1:-continuous}"

    if [[ "$mode" == "once" ]]; then
        # One-shot mode (for testing)
        run_once
    else
        # Continuous monitoring mode
        run_continuous
    fi
}

# One-shot execution (test mode)
run_once() {
    local usage_pct
    usage_pct=$(get_context_usage) || {
        echo "Failed to get context usage" >&2
        exit 1
    }

    echo "Context remaining: ${usage_pct}%"

    # Export to tmux environment for other agents
    if [[ -n "${TMUX:-}" ]]; then
        tmux set-environment -g CONTEXT_REMAINING "$usage_pct"
        tmux set-environment -g CONTEXT_LAST_CHECK "$(date '+%Y-%m-%d %H:%M:%S')"
    fi

    exit 0
}

# Continuous monitoring loop (5-minute intervals)
run_continuous() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting context monitoring (5-minute intervals)" >&2

    while true; do
        local usage_pct
        usage_pct=$(get_context_usage) || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to get context usage, retrying in 5 minutes" >&2
            sleep 300
            continue
        }

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context remaining: ${usage_pct}%"

        # Export to tmux environment
        if [[ -n "${TMUX:-}" ]]; then
            tmux set-environment -g CONTEXT_REMAINING "$usage_pct"
            tmux set-environment -g CONTEXT_LAST_CHECK "$(date '+%Y-%m-%d %H:%M:%S')"
        fi

        # Threshold checks (reverse order: critical first)
        if (( $(echo "$usage_pct < $CRITICAL_THRESHOLD" | bc -l) )); then
            # CRITICAL: Auto /clear
            if check_cooldown "$LAST_CLEAR_FILE"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚨 CRITICAL: ${usage_pct}% < ${CRITICAL_THRESHOLD}% - Triggering auto /clear"
                trigger_auto_clear "$usage_pct"
                update_cooldown "$LAST_CLEAR_FILE"
                send_ntfy "🚨 コンテキスト枯渇寸前(${usage_pct}%) - 自動/clear発動" "urgent"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ Auto /clear cooldown active, skipping"
            fi

        elif (( $(echo "$usage_pct < $ALERT_THRESHOLD" | bc -l) )); then
            # ALERT: Dashboard warning
            if check_cooldown "$LAST_ALERT_FILE"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  ALERT: ${usage_pct}% < ${ALERT_THRESHOLD}% - Updating dashboard"
                update_dashboard_alert "$usage_pct"
                update_cooldown "$LAST_ALERT_FILE"
                send_ntfy "⚠️ コンテキスト残量${usage_pct}% (閾値${ALERT_THRESHOLD}%)" "high"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ Alert cooldown active, skipping"
            fi

        elif (( $(echo "$usage_pct < $WARN_THRESHOLD" | bc -l) )); then
            # WARN: ntfy notification only
            if check_cooldown "$LAST_WARN_FILE"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📢 WARN: ${usage_pct}% < ${WARN_THRESHOLD}% - Sending notification"
                send_ntfy "📢 コンテキスト残量${usage_pct}% (要注意)" "default"
                update_cooldown "$LAST_WARN_FILE"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ Warning cooldown active, skipping"
            fi
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Context usage healthy"
        fi

        # Sleep 5 minutes
        sleep 300
    done
}

# ========================================
# Entry Point
# ========================================

main "$@"
