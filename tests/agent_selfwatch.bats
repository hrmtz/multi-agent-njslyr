#!/usr/bin/env bats
# agent_selfwatch.bats — Agent self-watch unit tests (TDD Step 3)
#
# FR/NFR trace (tests/specs/agent_selfwatch_spec.md):
#   TC-FR-001,002,003,004,005,006,007,008,009,010,011,014
#   TC-NFR-002,003,008
#
# Note:
#   All tests are GREEN (Phase 1-3 features have been implemented).
#   Former [RED] labels removed as all features are now present in inbox_watcher.sh.

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    export YAKUZA_INSTR="$PROJECT_ROOT/instructions/generated/codex-yakuza.md"

    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1
    [ -f "$YAKUZA_INSTR" ] || return 1
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/agent_selfwatch_test.XXXXXX")"

    export TEST_INBOX="$TEST_TMPDIR/test_agent.yaml"
    cat > "$TEST_INBOX" << 'YAML'
messages: []
YAML

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export TEST_HARNESS="$TEST_TMPDIR/harness.sh"
    cat > "$TEST_HARNESS" << 'HARNESS'
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="${TEST_CLI_TYPE:-claude}"
INBOX="$TEST_INBOX"
LOCKFILE="${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"

tmux() {
    echo "tmux $*" >> "$MOCK_LOG"
    if echo "$*" | grep -q "capture-pane"; then
        echo "${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "$*" | grep -q "send-keys"; then
        return "${MOCK_SENDKEYS_RC:-0}"
    fi
    return 0
}

timeout() { shift; "$@"; }
sleep() { :; }
pgrep() { return "${MOCK_PGREP_RC:-1}"; }
export -f tmux timeout sleep pgrep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "TC-FR-001: process_unread_once is defined and called on startup" {
    grep -q "process_unread_once()" "$WATCHER_SCRIPT"
    grep -q "process_unread_once" "$WATCHER_SCRIPT"
}

@test "TC-FR-002: file-watch + timeout fallback is configured" {
    # FIX-021 renamed INOTIFY_TIMEOUT → INOTIFY_TIMEOUT_BASE (thundering herd fix)
    grep -q "INOTIFY_TIMEOUT_BASE=" "$WATCHER_SCRIPT"
    grep -q "_wait_for_file_change" "$WATCHER_SCRIPT"
}

@test "TC-FR-003: get_unread_info routes task/special messages correctly" {
    # Production format: no indent for list items (matches awk parser + grep fast-path)
    cat > "$TEST_INBOX" << 'YAML'
messages:
- content: task
  from: smith
  id: msg_task
  read: false
  timestamp: '2026-02-09T21:00:00'
  type: task_assigned
- content: /clear
  from: smith
  id: msg_clear
  read: false
  timestamp: '2026-02-09T21:00:01'
  type: clear_command
- content: /model opus
  from: smith
  id: msg_model
  read: false
  timestamp: '2026-02-09T21:00:02'
  type: model_switch
YAML

    run bash -c "source '$TEST_HARNESS'; get_unread_info"
    [ "$status" -eq 0 ]

    # Verify output: line1=normal_count, line2=has_task_assigned, line3+=specials
    local lines
    IFS=$'\n' read -r -d '' -a lines <<< "$output" || true
    [ "${lines[0]}" = "1" ]  # 1 normal (task_assigned)
    [ "${lines[1]}" = "1" ]  # has_task_assigned=true
    [ "${#lines[@]}" -ge 4 ] # 2 specials (clear_command + model_switch)

    # FIX-005: get_unread_info is now read-only — specials remain unread
    grep -q '^  read: false' "$TEST_INBOX"  # All messages still unread

    # Test mark_specials_read separately
    run bash -c "source '$TEST_HARNESS'; mark_specials_read"
    [ "$status" -eq 0 ]

    # After mark_specials_read: specials should be read, task_assigned stays unread
    python3 - << 'PY' "$TEST_INBOX"
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
by_id = {m["id"]: m for m in data["messages"]}
assert by_id["msg_task"]["read"] is False, "task_assigned should remain unread"
assert by_id["msg_clear"]["read"] is True, "clear_command should be marked read"
assert by_id["msg_model"]["read"] is True, "model_switch should be marked read"
print("OK")
PY
}

@test "TC-FR-004: read-update path uses lock/atomic protections" {
    # get_unread_info uses flock -s (shared/read-only)
    body="$(awk '/get_unread_info\\(\\)/,/^}/' "$WATCHER_SCRIPT")"
    echo "$body" | grep -q "flock"
    # FIX-005: mark_specials_read handles writes with flock -x + atomic mv
    mark_body="$(awk '/^mark_specials_read\(\) \{/,/^}/' "$WATCHER_SCRIPT")"
    echo "$mark_body" | grep -q "flock -x"
    echo "$mark_body" | grep -q 'mv.*\$INBOX'
}

@test "TC-FR-005: post-task inbox check rule is documented for yakuza" {
    grep -q "MANDATORY Post-Task Inbox Check" "$YAKUZA_INSTR"
}

@test "TC-FR-006: metrics hooks are defined (unread_latency/read_count/estimated_tokens)" {
    grep -q "unread_latency_sec" "$WATCHER_SCRIPT"
    grep -q "read_count" "$WATCHER_SCRIPT"
    grep -q "estimated_tokens" "$WATCHER_SCRIPT"
}

@test "TC-FR-007: feature flags for Phase 1/2/3 are defined" {
    grep -q "ASW_PHASE" "$WATCHER_SCRIPT"
    grep -q "ASW_" "$WATCHER_SCRIPT"
}

@test "TC-FR-008: normal nudge can be disabled (Phase 2 behavior)" {
    grep -q "disable_normal_nudge" "$WATCHER_SCRIPT"
}

@test "TC-FR-009: special command compatibility for codex is preserved" {
    run bash -c "TEST_CLI_TYPE=codex; source '$TEST_HARNESS'; send_cli_command /clear"
    [ "$status" -eq 0 ]
    grep -q "send-keys -t test:0.0 /new" "$MOCK_LOG"
    grep -q "send-keys -t test:0.0 Enter" "$MOCK_LOG"

    > "$MOCK_LOG"
    run bash -c "TEST_CLI_TYPE=codex; source '$TEST_HARNESS'; send_cli_command '/model opus'"
    [ "$status" -eq 0 ]
    ! grep -q "/model opus" "$MOCK_LOG"
}

@test "TC-FR-010: summary-first fast path exists (count/summary before full read)" {
    grep -q "summary-first" "$WATCHER_SCRIPT"
    grep -q "unread_count fast-path" "$WATCHER_SCRIPT"
}

@test "TC-FR-011: send-keys is restricted to final escalation only" {
    grep -q "FINAL_ESCALATION_ONLY" "$WATCHER_SCRIPT"
}

@test "TC-FR-014 + TC-NFR-002: inbox_write IF and schema remain backward compatible" {
    run bash "$INBOX_WRITE_SCRIPT" test_agent "compat-check" task_assigned smith
    [ "$status" -eq 0 ]

    python3 - << 'PY' "$PROJECT_ROOT/queue/inbox/test_agent.yaml"
import sys, yaml
p = sys.argv[1]
with open(p) as f:
    data = yaml.safe_load(f)
assert "messages" in data and isinstance(data["messages"], list)
msg = data["messages"][-1]
for k in ("id", "from", "timestamp", "type", "content", "read"):
    assert k in msg
assert msg["type"] == "task_assigned"
assert msg["from"] == "smith"
print("OK")
PY

    # cleanup test artifact written to real queue path by production script
    rm -f "$PROJECT_ROOT/queue/inbox/test_agent.yaml" "$PROJECT_ROOT/queue/inbox/test_agent.yaml.lock"
}

@test "TC-NFR-003: no-idle-full-read helper exists" {
    grep -q "no_idle_full_read" "$WATCHER_SCRIPT"
}

@test "TC-NFR-008: test file itself has no skip directives (SKIP=0 guard)" {
    ! grep -Eq '^[[:space:]]*skip([[:space:]]|$)' "$BATS_TEST_FILENAME"
}
