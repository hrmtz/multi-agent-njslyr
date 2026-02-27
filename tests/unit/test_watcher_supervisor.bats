#!/usr/bin/env bats
# test_watcher_supervisor.bats — watcher_supervisor.sh ユニットテスト
# cmd_289 Phase3 Task Beta (subtask_289i)
#
# テスト構成:
#   T-WS-001: backoff_seconds count=1 → 5s
#   T-WS-002: backoff_seconds count=2 → 10s
#   T-WS-003: backoff_seconds count=3 → 30s
#   T-WS-004: backoff_seconds count=4 → 60s (cap)
#   T-WS-005: backoff_seconds count=10 → 60s (cap, upper bound)
#   T-WS-006: log_restart がRESTART_LOGにエントリを追記する
#   T-WS-007: log_restart のフォーマット検証 (agent=, attempt=)
#   T-WS-008: SIGTERM でgraceful shutdown (exit 0)
#   T-WS-009: ShellCheck 0 warning

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    SUPERVISOR="$PROJECT_ROOT/scripts/watcher_supervisor.sh"
    export SUPERVISOR
    [ -f "$SUPERVISOR" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/ws_test.XXXXXX")"
    export TEST_TMP
    mkdir -p "$TEST_TMP/.state"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ─── backoff_seconds ──────────────────────────────────────────────────────────

@test "T-WS-001: backoff_seconds count=1 → 5s" {
    FUNC="$(awk '/^backoff_seconds\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; backoff_seconds 1"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "T-WS-002: backoff_seconds count=2 → 10s" {
    FUNC="$(awk '/^backoff_seconds\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; backoff_seconds 2"
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "T-WS-003: backoff_seconds count=3 → 30s" {
    FUNC="$(awk '/^backoff_seconds\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; backoff_seconds 3"
    [ "$status" -eq 0 ]
    [ "$output" = "30" ]
}

@test "T-WS-004: backoff_seconds count=4 → 60s (cap)" {
    FUNC="$(awk '/^backoff_seconds\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; backoff_seconds 4"
    [ "$status" -eq 0 ]
    [ "$output" = "60" ]
}

@test "T-WS-005: backoff_seconds count=10 → 60s (cap, upper bound)" {
    FUNC="$(awk '/^backoff_seconds\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; backoff_seconds 10"
    [ "$status" -eq 0 ]
    [ "$output" = "60" ]
}

# ─── log_restart ──────────────────────────────────────────────────────────────

@test "T-WS-006: log_restart がRESTART_LOGにエントリを追記する" {
    local test_log="$TEST_TMP/.state/watcher_restart.log"
    FUNC="$(awk '/^log_restart\(\)/,/^\}/' "$SUPERVISOR")"
    run bash -c "$FUNC; RESTART_LOG='$test_log'; log_restart 'yakuza1' 2"
    [ "$status" -eq 0 ]
    [ -f "$test_log" ]
}

@test "T-WS-007: log_restart のフォーマット検証 (agent=, attempt=)" {
    local test_log="$TEST_TMP/.state/watcher_restart.log"
    FUNC="$(awk '/^log_restart\(\)/,/^\}/' "$SUPERVISOR")"
    bash -c "$FUNC; RESTART_LOG='$test_log'; log_restart 'soukaiya' 3"
    run grep -E "agent=soukaiya attempt=3" "$test_log"
    [ "$status" -eq 0 ]
}

# ─── SIGTERM graceful shutdown ────────────────────────────────────────────────

@test "T-WS-008: SIGTERM でgraceful shutdown (exit 0)" {
    # Start supervisor in background (tmux unavailable → scan_all_agents is no-op)
    bash "$SUPERVISOR" >/dev/null 2>&1 &
    local sup_pid=$!

    # Wait for the main loop to start
    sleep 0.5

    # Send SIGTERM
    kill -TERM "$sup_pid" 2>/dev/null || true

    # Wait and capture exit code (trap calls exit 0)
    wait "$sup_pid" 2>/dev/null
    local exit_code=$?
    [ "$exit_code" -eq 0 ]
}

# ─── ShellCheck ───────────────────────────────────────────────────────────────

@test "T-WS-009: ShellCheck 0 warning" {
    run shellcheck -S warning "$SUPERVISOR"
    [ "$status" -eq 0 ]
}
