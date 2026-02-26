#!/usr/bin/env bats
# test_ntfy_listener.bats — ntfy_listener.sh heartbeat/prefix routing ユニットテスト
# cmd_275 Round3 Group B
#
# テスト構成:
#   T-NL-HB-001: 正常HBメッセージのパース（全フィールド正常値）
#   T-NL-HB-002: epoch非数値でスキップ（log_warn出力）
#   T-NL-HB-003: agents非数値でスキップ
#   T-NL-HB-004: load非数値でスキップ
#   T-NL-HB-005: ctx_summary不正値→"unknown"にサニタイズ
#   T-NL-HB-006: host不正文字（セミコロン等）でスキップ
#   T-NL-PFX-001: push:メッセージの正常ルーティング
#   T-NL-PFX-002: sync:メッセージの正常ルーティング
#   T-NL-PFX-003: 未知prefixのデフォルト処理
#   T-NL-PFX-004: prefix偽装（"push:; rm -rf /"）の安全な処理

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NTFY_LISTENER="$PROJECT_ROOT/scripts/ntfy_listener.sh"
    export NTFY_LISTENER

    # ソースファイル存在確認
    [ -f "$NTFY_LISTENER" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/ntfy_listener_test.XXXXXX")"

    # Mock project directory structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue/heartbeat,logs/ntfy_inbox_corrupt}

    # Variables needed by ntfy_listener.sh functions (used by sourced functions.sh)
    # shellcheck disable=SC2034
    SCRIPT_DIR="$MOCK_PROJECT"
    INBOX="$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    # shellcheck disable=SC2034
    LOCKFILE="${INBOX}.lock"
    # shellcheck disable=SC2034
    CORRUPT_DIR="$MOCK_PROJECT/logs/ntfy_inbox_corrupt"
    echo "inbox:" > "$INBOX"

    # Mock inbox_write.sh (records calls to log file)
    INBOX_WRITE_LOG="$TEST_TMP/inbox_write_calls.log"
    export INBOX_WRITE_LOG
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${INBOX_WRITE_LOG}"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # Mock git (records calls, succeeds by default)
    mkdir -p "$TEST_TMP/mock_bin"
    GIT_CALL_LOG="$TEST_TMP/git_calls.log"
    export GIT_CALL_LOG
    cat > "$TEST_TMP/mock_bin/git" << 'MOCK'
#!/bin/bash
echo "$@" >> "${GIT_CALL_LOG}"
echo "Already up to date."
MOCK
    chmod +x "$TEST_TMP/mock_bin/git"

    # Mock cross_sync.sh (succeeds by default)
    cat > "$MOCK_PROJECT/scripts/cross_sync.sh" << 'MOCK'
#!/bin/bash
echo "mock cross_sync: $*"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/cross_sync.sh"

    # Add mock bin to PATH (before real commands)
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract function definitions from ntfy_listener.sh
    # Range: from parse_message_fields() to just before 'trap cleanup' line
    sed -n '/^parse_message_fields()/,/^trap cleanup/{/^trap cleanup/d;p}' \
        "$NTFY_LISTENER" > "$TEST_TMP/functions.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/functions.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: call function capturing both stdout and stderr in $output
call_with_stderr() {
    "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════
# Heartbeat validation tests
# ═══════════════════════════════════════════════════════════════

# --- T-NL-HB-001: 正常HBメッセージのパース ---

@test "T-NL-HB-001: handle_heartbeat parses valid payload (all fields normal)" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:0.42:ok"
    [ "$status" -eq 0 ]

    # Verify heartbeat YAML was created with correct content
    local hb_file="$MOCK_PROJECT/queue/heartbeat/ryzen.yaml"
    [ -f "$hb_file" ]
    grep -q "machine_id: ryzen" "$hb_file"
    grep -q "status: alive" "$hb_file"
    grep -q "agents_active: 5" "$hb_file"
    grep -q "load_avg: 0.42" "$hb_file"
    grep -q "context_summary: ok" "$hb_file"
}

# --- T-NL-HB-002: epoch非数値でスキップ ---

@test "T-NL-HB-002: handle_heartbeat rejects non-numeric epoch with warning" {
    run call_with_stderr handle_heartbeat "ryzen:not_a_number:5:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat epoch"* ]]

    # No heartbeat file should be created
    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-003: agents非数値でスキップ ---

@test "T-NL-HB-003: handle_heartbeat rejects non-numeric agents with warning" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:abc:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat agents"* ]]

    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-004: load非数値でスキップ ---

@test "T-NL-HB-004: handle_heartbeat rejects non-numeric load with warning" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:high:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat load"* ]]

    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-005: ctx_summary不正値→"unknown"にサニタイズ ---

@test "T-NL-HB-005: handle_heartbeat sanitizes invalid ctx_summary to unknown" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:0.42:bogus_status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sanitizing to unknown"* ]]

    local hb_file="$MOCK_PROJECT/queue/heartbeat/ryzen.yaml"
    [ -f "$hb_file" ]
    grep -q "context_summary: unknown" "$hb_file"
}

# --- T-NL-HB-006: host不正文字（セミコロン等）でスキップ ---

@test "T-NL-HB-006: handle_heartbeat rejects host with invalid characters (semicolon)" {
    run call_with_stderr handle_heartbeat "evil;host:1709000000:5:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat host"* ]]

    # Verify no file was created for the invalid host
    local count
    count=$(find "$MOCK_PROJECT/queue/heartbeat" -type f | wc -l)
    [ "$count" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# Prefix routing tests
# ═══════════════════════════════════════════════════════════════

# --- T-NL-PFX-001: push:メッセージの正常ルーティング ---

@test "T-NL-PFX-001: route_message dispatches push: prefix correctly" {
    run call_with_stderr route_message "push:cmd_100:main" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"push:"* ]]

    # Verify mock git was called with pull + correct branch
    [ -f "$GIT_CALL_LOG" ]
    grep -q "pull" "$GIT_CALL_LOG"
    grep -q "main" "$GIT_CALL_LOG"
}

# --- T-NL-PFX-002: sync:メッセージの正常ルーティング ---

@test "T-NL-PFX-002: route_message dispatches sync: prefix correctly" {
    run call_with_stderr route_message "sync:myproject:done" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"sync:"* ]]

    # Verify inbox_write was called (darkninja notified)
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
}

# --- T-NL-PFX-003: 未知prefixのデフォルト処理 ---

@test "T-NL-PFX-003: route_message returns 1 for unknown prefix (fallback)" {
    run call_with_stderr route_message "unknown_thing:data_here" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"unrecognized prefix"* ]]
}

# --- T-NL-PFX-004: prefix偽装安全処理 ---

@test "T-NL-PFX-004: route_message handles injection payload safely (push:; rm -rf /)" {
    run call_with_stderr route_message "push:; rm -rf /" ""
    # push handler should run (prefix "push" is valid)
    [ "$status" -eq 0 ]

    # Verify mock git was called (not actual rm -rf)
    [ -f "$GIT_CALL_LOG" ]
    grep -q "pull" "$GIT_CALL_LOG"

    # Critical: project directory must still exist (no injection executed)
    [ -d "$MOCK_PROJECT/queue" ]
    [ -d "$MOCK_PROJECT/scripts" ]
}
