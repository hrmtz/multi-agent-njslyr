#!/usr/bin/env bats
# test_inbox_watcher.bats — inbox_watcher.sh FIX-001/003/004/008 unit tests
# cmd_289 Phase3 Task Gamma
#
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1
# to test actual production functions with mocked externals.
#
# テスト構成:
#   T-TIMEOUT-001: INOTIFY_TIMEOUT default is 5 (not 30)
#   T-TIMEOUT-002: Main loop contains mtime before/after recheck (FIX-001)
#   T-TIMEOUT-003: No sleep 0.3 between process_unread and inotifywait
#   T-FIX-001-001: mtime recheck handles Darwin/Linux stat syntax
#   T-FIX-003-001: send_context_reset does not call agent_is_busy (no polling)
#   T-FIX-003-002: send_context_reset sends /clear for claude
#   T-FIX-003-003: send_context_reset skips darkninja
#   T-FIX-003-004: send_context_reset uses fixed sleep, no polling loop
#   T-FIX-004-001: darkninja Phase3 does NOT reset FIRST_UNREAD_SEEN
#   T-FIX-004-002: darkninja Phase3 does NOT reset LAST_CLEAR_TS
#   T-FIX-004-003: darkninja Phase3 writes alert to .state/alerts/
#   T-FIX-004-004: darkninja Phase3 continues with Phase2 nudge
#   T-FIX-004-005: darkninja Phase3 suppression code exists
#   T-FIX-004-006: darkninja Phase3 block has no FIRST_UNREAD_SEEN=0
#   T-FIX-008-001: unread=0 does NOT call agent_is_busy
#   T-FIX-008-002: unread=0 sends C-u only on transition
#   T-FIX-008-003: unread=0 does NOT send C-u when FIRST_UNREAD_SEEN=0
#   T-FIX-008-004: darkninja unread=0 skips C-u when pane active
#   T-FIX-008-005: fast_count=0 path has early return
#   T-INT-001: process_unread sends nudge for normal unread
#   T-INT-002: process_unread handles clear_command
#   T-INT-003: process_unread handles model_switch

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_watcher_test.XXXXXX")"

    # Log files
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"
    export FUNC_LOG="$TEST_TMPDIR/func_calls.log"
    > "$FUNC_LOG"

    # Create mock pgrep (default: no self-watch found)
    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    # Create test inbox directory
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Default mock control variables
    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""

    # --- Main test harness (test_agent) ---
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
CACHE_DIR="$TEST_TMPDIR/.cache"
STATE_DIR="$TEST_TMPDIR/.state"
METRICS_FILE="$TEST_TMPDIR/metrics/test_agent_selfwatch.yaml"
mkdir -p "\$CACHE_DIR" "\$STATE_DIR" "\${METRICS_FILE%/*}"
if [ ! -f "\$INBOX" ]; then
    echo "messages: []" > "\$INBOX"
fi
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then echo "\${MOCK_CAPTURE_PANE:-}"; return 0; fi
    if echo "\$*" | grep -q "send-keys"; then return \${MOCK_SENDKEYS_RC:-0}; fi
    if echo "\$*" | grep -q "show-options"; then echo "\${MOCK_PANE_CLI:-}"; return 0; fi
    if echo "\$*" | grep -q "list-panes"; then echo "\$AGENT_ID \$PANE_TARGET"; return 0; fi
    if echo "\$*" | grep -q "display-message.*pane_active"; then echo "0"; return 0; fi
    if echo "\$*" | grep -q "display-message"; then echo "mock_pane"; return 0; fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # --- Darkninja test harness (pane_active=0) ---
    export DN_HARNESS="$TEST_TMPDIR/darkninja_harness.sh"
    cat > "$DN_HARNESS" << DNHARNESS
#!/bin/bash
AGENT_ID="darkninja"
PANE_TARGET="main:darkninja.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/darkninja.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
CACHE_DIR="$TEST_TMPDIR/.cache"
STATE_DIR="$TEST_TMPDIR/.state"
METRICS_FILE="$TEST_TMPDIR/metrics/darkninja_selfwatch.yaml"
mkdir -p "\$CACHE_DIR" "\$STATE_DIR" "\${METRICS_FILE%/*}"
if [ ! -f "\$INBOX" ]; then
    echo "messages: []" > "\$INBOX"
fi
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then echo "\${MOCK_CAPTURE_PANE:-}"; return 0; fi
    if echo "\$*" | grep -q "send-keys"; then return \${MOCK_SENDKEYS_RC:-0}; fi
    if echo "\$*" | grep -q "show-options"; then echo "\${MOCK_PANE_CLI:-}"; return 0; fi
    if echo "\$*" | grep -q "list-panes"; then echo "darkninja main:darkninja.0"; return 0; fi
    if echo "\$*" | grep -q "display-message.*pane_active"; then echo "0"; return 0; fi
    if echo "\$*" | grep -q "display-message"; then echo "mock_pane"; return 0; fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
DNHARNESS
    chmod +x "$DN_HARNESS"

    # --- Darkninja harness with pane_active=1 ---
    export DN_ACTIVE_HARNESS="$TEST_TMPDIR/darkninja_active_harness.sh"
    cat > "$DN_ACTIVE_HARNESS" << DNAHARNESS
#!/bin/bash
AGENT_ID="darkninja"
PANE_TARGET="main:darkninja.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/darkninja.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
CACHE_DIR="$TEST_TMPDIR/.cache"
STATE_DIR="$TEST_TMPDIR/.state"
METRICS_FILE="$TEST_TMPDIR/metrics/darkninja_selfwatch.yaml"
mkdir -p "\$CACHE_DIR" "\$STATE_DIR" "\${METRICS_FILE%/*}"
if [ ! -f "\$INBOX" ]; then
    echo "messages: []" > "\$INBOX"
fi
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then echo ""; return 0; fi
    if echo "\$*" | grep -q "send-keys"; then return 0; fi
    if echo "\$*" | grep -q "show-options"; then echo ""; return 0; fi
    if echo "\$*" | grep -q "list-panes"; then echo "darkninja main:darkninja.0"; return 0; fi
    if echo "\$*" | grep -q "display-message.*pane_active"; then echo "1"; return 0; fi
    if echo "\$*" | grep -q "display-message"; then echo "mock_pane"; return 0; fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
DNAHARNESS
    chmod +x "$DN_ACTIVE_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════
# Section 1: Timeout & Main Loop Code Structure (FIX-001)
# ═══════════════════════════════════════════════════════════════

@test "T-TIMEOUT-001: INOTIFY_TIMEOUT defaults to 5 (not 30)" {
    grep -q 'INOTIFY_TIMEOUT=.*5' "$WATCHER_SCRIPT"
    ! grep -q 'INOTIFY_TIMEOUT=.*30' "$WATCHER_SCRIPT"
}

@test "T-TIMEOUT-002: Main loop contains mtime before/after recheck (FIX-001)" {
    grep -q '_mtime_before=' "$WATCHER_SCRIPT"
    grep -q '_mtime_after=' "$WATCHER_SCRIPT"
    grep -q '_mtime_before.*!=.*_mtime_after.*&&.*continue' "$WATCHER_SCRIPT"
}

@test "T-TIMEOUT-003: No sleep 0.3 in main loop between process_unread and inotifywait" {
    local main_loop
    main_loop=$(sed -n '/^while true/,/^done$/p' "$WATCHER_SCRIPT")
    ! echo "$main_loop" | grep -q 'sleep 0\.3'
}

@test "T-FIX-001-001: mtime recheck handles both Darwin and Linux stat syntax" {
    grep -q 'stat -f %m' "$WATCHER_SCRIPT"
    grep -q 'stat -c %Y' "$WATCHER_SCRIPT"
}

# ═══════════════════════════════════════════════════════════════
# Section 2: send_context_reset (FIX-003)
# ═══════════════════════════════════════════════════════════════

@test "T-FIX-003-001: send_context_reset has no agent_is_busy polling (FIX-003)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        agent_is_busy() {
            echo "AGENT_IS_BUSY_CALLED" >> "'"$FUNC_LOG"'"
            return 1
        }
        export -f agent_is_busy
        send_context_reset
    '
    [ "$status" -eq 0 ]
    ! grep -q "AGENT_IS_BUSY_CALLED" "$FUNC_LOG"
}

@test "T-FIX-003-002: send_context_reset sends /clear for claude CLI" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_context_reset
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

@test "T-FIX-003-003: send_context_reset skips for darkninja agent" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="darkninja"
        send_context_reset
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
    echo "$output" | grep -q "SKIP.*darkninja"
}

@test "T-FIX-003-004: send_context_reset uses fixed sleep, no while/for polling loop" {
    local func_body
    func_body=$(sed -n '/^send_context_reset()/,/^}/p' "$WATCHER_SCRIPT")
    ! echo "$func_body" | grep -q 'while\b'
    ! echo "$func_body" | grep -q 'for\b.*agent_is_busy'
    echo "$func_body" | grep -q 'sleep 2'
}

# ═══════════════════════════════════════════════════════════════
# Section 3: darkninja Phase3 Escalation (FIX-004)
# ═══════════════════════════════════════════════════════════════

@test "T-FIX-004-001: darkninja Phase3 preserves FIRST_UNREAD_SEEN (no reset to 0)" {
    cat > "$TEST_INBOX_DIR/darkninja.yaml" << 'YAML'
messages:
- id: msg_test_004
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: report_received
  content: "test report"
  read: false
YAML

    run bash -c '
        source "'"$DN_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))
        LAST_CLEAR_TS=$((now - 600))
        saved_first=$FIRST_UNREAD_SEEN
        process_unread "timeout"
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "FIRST_UNREAD_SEEN_NOT_RESET"
        fi
        if [ "$FIRST_UNREAD_SEEN" -eq "$saved_first" ]; then
            echo "FIRST_UNREAD_SEEN_PRESERVED"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FIRST_UNREAD_SEEN_NOT_RESET"
    echo "$output" | grep -q "FIRST_UNREAD_SEEN_PRESERVED"
}

@test "T-FIX-004-002: darkninja Phase3 preserves LAST_CLEAR_TS" {
    cat > "$TEST_INBOX_DIR/darkninja.yaml" << 'YAML'
messages:
- id: msg_test_004b
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: report_received
  content: "test report"
  read: false
YAML

    run bash -c '
        source "'"$DN_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))
        LAST_CLEAR_TS=$((now - 600))
        saved_clear=$LAST_CLEAR_TS
        process_unread "timeout"
        if [ "$LAST_CLEAR_TS" -eq "$saved_clear" ]; then
            echo "LAST_CLEAR_TS_PRESERVED"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "LAST_CLEAR_TS_PRESERVED"
}

@test "T-FIX-004-003: darkninja Phase3 creates alert file in .state/alerts/" {
    cat > "$TEST_INBOX_DIR/darkninja.yaml" << 'YAML'
messages:
- id: msg_test_004c
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: report_received
  content: "test report"
  read: false
YAML

    run bash -c '
        source "'"$DN_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))
        LAST_CLEAR_TS=$((now - 600))
        process_unread "timeout"
        if [ -f "'"$TEST_TMPDIR"'/.state/alerts/darkninja_undeliverable.yaml" ]; then
            echo "ALERT_FILE_CREATED"
            cat "'"$TEST_TMPDIR"'/.state/alerts/darkninja_undeliverable.yaml"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ALERT_FILE_CREATED"
    echo "$output" | grep -q "phase3_suppressed"
}

@test "T-FIX-004-004: darkninja Phase3 sends Phase2 Escape+nudge (not /clear)" {
    cat > "$TEST_INBOX_DIR/darkninja.yaml" << 'YAML'
messages:
- id: msg_test_004d
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: report_received
  content: "test report"
  read: false
YAML

    run bash -c '
        source "'"$DN_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))
        LAST_CLEAR_TS=$((now - 600))
        process_unread "timeout"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*inbox" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    grep -q "display-message.*ALERT.*inbox.*unread.*darkninja" "$MOCK_LOG"
}

@test "T-FIX-004-005: darkninja Phase3 suppression code block exists in script" {
    grep -q 'phase3_suppressed' "$WATCHER_SCRIPT"
    grep -q '/clear suppressed' "$WATCHER_SCRIPT"
}

@test "T-FIX-004-006: darkninja Phase3 block has no FIRST_UNREAD_SEEN=0 assignment" {
    local dn_block
    dn_block=$(sed -n '/if \[ "\$AGENT_ID" = "darkninja" \]/,/elif/p' "$WATCHER_SCRIPT" | head -15)
    ! echo "$dn_block" | grep -q 'FIRST_UNREAD_SEEN=0'
    ! echo "$dn_block" | grep -q 'LAST_CLEAR_TS='
}

# ═══════════════════════════════════════════════════════════════
# Section 4: unread=0 Early Return (FIX-008)
# ═══════════════════════════════════════════════════════════════

@test "T-FIX-008-001: process_unread with unread=0 does NOT call agent_is_busy" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
- id: msg_old
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: task_assigned
  content: "old task"
  read: true
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        agent_is_busy() {
            echo "AGENT_IS_BUSY_CALLED" >> "'"$FUNC_LOG"'"
            return 1
        }
        export -f agent_is_busy
        FIRST_UNREAD_SEEN=0
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    ! grep -q "AGENT_IS_BUSY_CALLED" "$FUNC_LOG"
}

@test "T-FIX-008-002: process_unread sends C-u when transitioning from unread>0 to unread=0" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
- id: msg_read
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: task_assigned
  content: "done task"
  read: true
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        process_unread "event"
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

@test "T-FIX-008-003: process_unread does NOT send C-u when FIRST_UNREAD_SEEN already 0" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages: []
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=0
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys.*C-u" "$MOCK_LOG"
}

@test "T-FIX-008-004: darkninja unread=0 transition skips C-u when pane is active" {
    cat > "$TEST_INBOX_DIR/darkninja.yaml" << 'YAML'
messages:
- id: msg_dn_read
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: task_assigned
  content: "done"
  read: true
YAML

    run bash -c '
        source "'"$DN_ACTIVE_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    ! grep -q "send-keys.*C-u" "$MOCK_LOG"
}

@test "T-FIX-008-005: process_unread fast_count=0 path returns before get_unread_info" {
    local func_body
    func_body=$(sed -n '/^process_unread()/,/^[a-z_]*().*{$/p' "$WATCHER_SCRIPT" | head -40)
    echo "$func_body" | grep -q 'fast_count.*-eq 0'
    echo "$func_body" | grep -q 'return 0'
}

# ═══════════════════════════════════════════════════════════════
# Section 5: Integration — process_unread with real inbox YAML
# ═══════════════════════════════════════════════════════════════

@test "T-INT-001: process_unread sends nudge for normal unread messages" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
- id: msg_int_001
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: task_assigned
  content: "新規タスク"
  read: false
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=0
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*inbox" "$MOCK_LOG"
}

@test "T-INT-002: process_unread handles clear_command special message" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
- id: msg_int_002
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: clear_command
  content: "redo"
  read: false
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=0
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*/clear" "$MOCK_LOG"
}

@test "T-INT-003: process_unread handles model_switch special message" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
- id: msg_int_003
  from: gryakuza
  timestamp: "2026-02-27T10:00:00"
  type: model_switch
  content: "/model opus"
  read: false
YAML

    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=0
        process_unread "event"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*/model opus" "$MOCK_LOG"
}
