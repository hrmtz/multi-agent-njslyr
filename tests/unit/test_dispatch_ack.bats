#!/usr/bin/env bats
# test_dispatch_ack.bats — dispatch ACK機構ユニットテスト (cmd_328 モンジュPhase1-C)
#
# テスト構成:
#   T-ACK-001: handle_ack parses valid ACK (ack:task_id:ok)
#   T-ACK-002: handle_ack parses error ACK (ack:task_id:error)
#   T-ACK-003: handle_ack rejects invalid task_id (path traversal)
#   T-ACK-004: handle_ack sanitizes unknown status to "unknown"
#   T-ACK-005: route_message dispatches ack: prefix correctly (return 0)
#   T-ACK-006: handle_ack notifies darkninja via inbox_write
#   T-ACK-007: handle_task_dispatch sends ACK after success (mock curl)
#   T-ACK-008: backward compat — dispatch: prefix still works (no ACK interference)
#   T-ACK-009: backward compat — report: prefix still works
#   T-ACK-010: backward compat — suriken: prefix still works
#   T-ACK-011: wait_for_ack returns 0 on ACK match (mock curl stream)
#   T-ACK-012: wait_for_ack returns 1 on timeout (mock curl empty)
#   T-ACK-013: ACK format validation — empty task_id rejected

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NTFY_LISTENER="$PROJECT_ROOT/scripts/ntfy_listener.sh"
    NTFY_SEND_DISPATCH="$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh"
    export NTFY_LISTENER NTFY_SEND_DISPATCH

    [ -f "$NTFY_LISTENER" ] || return 1
    [ -f "$NTFY_SEND_DISPATCH" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/dispatch_ack_test.XXXXXX")"

    # Mock project directory structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue/{heartbeat,reports,tasks},logs/ntfy_inbox_corrupt}

    # Variables needed by ntfy_listener.sh functions
    # shellcheck disable=SC2034
    SCRIPT_DIR="$MOCK_PROJECT"
    INBOX="$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    # shellcheck disable=SC2034
    LOCKFILE="${INBOX}.lock"
    # shellcheck disable=SC2034
    CORRUPT_DIR="$MOCK_PROJECT/logs/ntfy_inbox_corrupt"
    echo "inbox:" > "$INBOX"

    # ntfy_listener.sh global variables
    TOPIC="test-topic-abc"
    MACHINE_ROLE="kyoto"
    TOPIC_LAOMOTO=""
    AUTH_ARGS=()

    # Mock inbox_write.sh (records calls)
    INBOX_WRITE_LOG="$TEST_TMP/inbox_write_calls.log"
    export INBOX_WRITE_LOG
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${INBOX_WRITE_LOG}"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # Mock tmux (records calls)
    mkdir -p "$TEST_TMP/mock_bin"
    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
case "$1" in
    list-panes)
        if [ -f "${MOCK_PANES_FILE:-/dev/null}" ]; then
            cat "$MOCK_PANES_FILE"
        fi
        ;;
esac
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    # Mock git
    GIT_CALL_LOG="$TEST_TMP/git_calls.log"
    export GIT_CALL_LOG
    cat > "$TEST_TMP/mock_bin/git" << 'MOCK'
#!/bin/bash
echo "$@" >> "${GIT_CALL_LOG}"
echo "Already up to date."
MOCK
    chmod +x "$TEST_TMP/mock_bin/git"

    # Mock curl (default: succeed with empty response)
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
# Default: success for POST, empty for GET (streaming)
if [[ "$*" == *"-X POST"* ]]; then
    echo '{"id":"mock123"}'
    exit 0
fi
# For streaming (wait_for_ack): output nothing by default (triggers timeout)
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # Mock cross_sync.sh
    cat > "$MOCK_PROJECT/scripts/cross_sync.sh" << 'MOCK'
#!/bin/bash
echo "mock cross_sync: $*"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/cross_sync.sh"

    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract function definitions from ntfy_listener.sh
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
# handle_ack tests
# ═══════════════════════════════════════════════════════════════

# --- T-ACK-001: 正常ACK(ok)のパース ---

@test "T-ACK-001: handle_ack parses valid ACK with ok status" {
    run call_with_stderr handle_ack "subtask_test_001:ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ack: task_id=subtask_test_001 status=ok"* ]]

    # darkninja inbox_write 呼び出し確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
    grep -q "dispatch ACK" "$INBOX_WRITE_LOG"
    grep -q "subtask_test_001" "$INBOX_WRITE_LOG"
}

# --- T-ACK-002: エラーACK(error)のパース ---

@test "T-ACK-002: handle_ack parses valid ACK with error status" {
    run call_with_stderr handle_ack "subtask_test_002:error"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ack: task_id=subtask_test_002 status=error"* ]]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "subtask_test_002" "$INBOX_WRITE_LOG"
    grep -q "error" "$INBOX_WRITE_LOG"
}

# --- T-ACK-003: 不正task_id（パストラバーサル）→ 拒否 ---

@test "T-ACK-003: handle_ack rejects invalid task_id (path traversal)" {
    run call_with_stderr handle_ack "../../../etc/passwd:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid task_id"* ]]

    # inbox_write は呼ばれないこと
    [ ! -f "$INBOX_WRITE_LOG" ]
}

# --- T-ACK-004: 不正status → unknownにサニタイズ ---

@test "T-ACK-004: handle_ack sanitizes unknown status to 'unknown'" {
    run call_with_stderr handle_ack "subtask_test_004:bogus_status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid status"* ]]
    [[ "$output" == *"treating as unknown"* ]]
    [[ "$output" == *"status=unknown"* ]]

    # darkninja への通知は行われること（statusはunknownだが通知自体は必要）
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
}

# --- T-ACK-005: route_message ack: → return 0 (ntfy_inbox記録あり) ---

@test "T-ACK-005: route_message dispatches ack: prefix and returns 0" {
    run call_with_stderr route_message "ack:subtask_route_test:ok" ""
    [ "$status" -eq 0 ]

    # darkninja inbox_write 確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
    grep -q "subtask_route_test" "$INBOX_WRITE_LOG"
}

# --- T-ACK-006: handle_ack通知内容にtask_idとstatusが含まれる ---

@test "T-ACK-006: handle_ack inbox message contains task_id and status" {
    run call_with_stderr handle_ack "subtask_328_test:ok"
    [ "$status" -eq 0 ]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "subtask_328_test" "$INBOX_WRITE_LOG"
    grep -q "ok" "$INBOX_WRITE_LOG"
    grep -q "system_notice" "$INBOX_WRITE_LOG"
}

# ═══════════════════════════════════════════════════════════════
# handle_task_dispatch ACK送信テスト
# ═══════════════════════════════════════════════════════════════

# --- T-ACK-007: dispatch成功時にACK POST呼び出し確認 ---

@test "T-ACK-007: handle_task_dispatch calls curl POST for ACK after success" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_ack_test
  parent_cmd: cmd_328
  assigned_to: yakuza3
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dispatch: task_id=subtask_ack_test"* ]]

    # ACK送信のcurlが呼ばれたことを確認
    [ -f "$CURL_CALL_LOG" ]
    grep -q "ack:subtask_ack_test:ok" "$CURL_CALL_LOG"

    # ACKトピックが正しいこと（kyotoマシン→neosaitamaトピックへACK）
    # MACHINE_ROLE=kyoto → ack_topic = test-topic-abc-neosaitama
    grep -q "test-topic-abc-neosaitama" "$CURL_CALL_LOG"
}

# ═══════════════════════════════════════════════════════════════
# 後方互換テスト（既存プレフィックスに影響なし）
# ═══════════════════════════════════════════════════════════════

# --- T-ACK-008: dispatch: プレフィックス後方互換 ---

@test "T-ACK-008: backward compat — dispatch: prefix still routes correctly" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_compat_test
  parent_cmd: cmd_328
  assigned_to: yakuza4
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr route_message "dispatch:${payload}" ""
    [ "$status" -eq 0 ]

    # タスクファイル作成確認
    [ -f "$MOCK_PROJECT/queue/tasks/yakuza4_subtask_compat_test.yaml" ]

    # gryakuza inbox通知確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
}

# --- T-ACK-009: report: プレフィックス後方互換 ---

@test "T-ACK-009: backward compat — report: prefix still routes correctly" {
    local valid_yaml="worker_id: yakuza3
task_id: subtask_compat_rpt
status: completed
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr route_message "report:${payload}" ""
    [ "$status" -eq 0 ]

    [ -f "$MOCK_PROJECT/queue/reports/yakuza3_report_subtask_compat_rpt.yaml" ]
}

# --- T-ACK-010: suriken: プレフィックス後方互換 ---

@test "T-ACK-010: backward compat — suriken: prefix still routes correctly (return 2)" {
    MOCK_PANES_FILE="$TEST_TMP/mock_panes.txt"
    export MOCK_PANES_FILE
    cat > "$MOCK_PANES_FILE" << 'EOF'
%3 yakuza5
EOF

    run call_with_stderr route_message "suriken:yakuza5:1" ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"nudge sent to yakuza5"* ]]
}

# ═══════════════════════════════════════════════════════════════
# wait_for_ack テスト（ntfy_send_dispatch.sh）
# ═══════════════════════════════════════════════════════════════

# --- T-ACK-011: wait_for_ack ACK受信成功 ---

@test "T-ACK-011: wait_for_ack returns 0 when ACK message is in stream" {
    # Mock curl to output a matching ACK JSON message
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
if [[ "$*" == *"/json?"* ]]; then
    # Simulate ntfy streaming: output one JSON message with ACK
    echo '{"event":"message","message":"ack:subtask_ack_stream:ok","id":"msg_ack_001","topic":"test-topic"}'
    exit 0
fi
echo '{"id":"mock123"}'
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # Extract wait_for_ack from ntfy_send_dispatch.sh
    # We need the function definition + required variables
    SCRIPT_DIR="$MOCK_PROJECT"
    AUTH_ARGS=()
    local log_file="$MOCK_PROJECT/logs/ntfy_send_dispatch.log"
    mkdir -p "$(dirname "$log_file")"

    # Extract wait_for_ack function
    sed -n '/^wait_for_ack()/,/^}/p' "$NTFY_SEND_DISPATCH" > "$TEST_TMP/wait_for_ack.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/wait_for_ack.sh"

    run call_with_stderr wait_for_ack "subtask_ack_stream" "test-topic-kyoto" 5 "$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACK received"* ]]
}

# --- T-ACK-012: wait_for_ack タイムアウト ---

@test "T-ACK-012: wait_for_ack returns 1 on timeout (no ACK in stream)" {
    # Mock curl to output non-matching messages then exit (simulating timeout)
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
if [[ "$*" == *"/json?"* ]]; then
    # Simulate: only a keepalive, no matching ACK
    echo '{"event":"keepalive","topic":"test-topic"}'
    echo '{"event":"message","message":"dispatch:other_data","id":"msg_other","topic":"test-topic"}'
    exit 0
fi
echo '{"id":"mock123"}'
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    SCRIPT_DIR="$MOCK_PROJECT"
    AUTH_ARGS=()
    mkdir -p "$MOCK_PROJECT/logs"

    sed -n '/^wait_for_ack()/,/^}/p' "$NTFY_SEND_DISPATCH" > "$TEST_TMP/wait_for_ack.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/wait_for_ack.sh"

    run call_with_stderr wait_for_ack "subtask_no_ack" "test-topic-kyoto" 2 "$(date +%s)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ACK timeout"* ]]
}

# --- T-ACK-013: ACKフォーマット — 空task_id → 拒否 ---

@test "T-ACK-013: handle_ack rejects empty task_id" {
    run call_with_stderr handle_ack ":ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid task_id"* ]]

    [ ! -f "$INBOX_WRITE_LOG" ]
}
