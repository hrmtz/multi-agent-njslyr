#!/usr/bin/env bats
# test_njslyr_cmd.bats — njslyr_cmd.sh suriken コマンドのユニットテスト (cmd_297)
#
# テスト構成:
#   T-CMD-SRK-001: ローカルペインあり → tmux send-keys 3回呼ばれる（リグレッション確認）
#   T-CMD-SRK-002: ローカルペインなし → _cmd_suriken_ntfy_fallback 呼び出し確認
#   T-CMD-SRK-003: _cmd_suriken_ntfy_fallback: HTTP 200 → 成功
#   T-CMD-SRK-004: _cmd_suriken_ntfy_fallback: HTTP 500 → return 1

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NJSLYR_CMD="$PROJECT_ROOT/scripts/njslyr_cmd.sh"
    export NJSLYR_CMD

    [ -f "$NJSLYR_CMD" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/njslyr_cmd_test.XXXXXX")"

    # Mock project directory structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue/inbox,.state}

    # Mock settings.yaml
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
language: ja
machine:
  role: kyoto
ntfy_topic: test-topic-abc123xyz
YAML

    # Mock ntfy_auth.env (no auth = empty args)
    touch "$MOCK_PROJECT/config/ntfy_auth.env"

    # Mock ntfy_auth.sh
    cat > "$MOCK_PROJECT/lib/ntfy_auth.sh" << 'MOCK'
#!/bin/bash
ntfy_get_auth_args() { return 0; }
ntfy_validate_topic() { return 0; }
MOCK

    # Mock inbox_write.sh
    INBOX_WRITE_LOG="$TEST_TMP/inbox_write_calls.log"
    export INBOX_WRITE_LOG
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${INBOX_WRITE_LOG}"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # Mock inbox YAML (0 unread)
    cat > "$MOCK_PROJECT/queue/inbox/yakuza3.yaml" << 'YAML'
messages:
- content: test
  read: true
YAML

    # Mock njslyr_lib.sh (provides resolve_pane_by_agent_id, stage3_slay, sedi, agent_is_busy)
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT
    cat > "$TEST_TMP/mock_njslyr_lib.sh" << 'MOCK'
#!/bin/bash
resolve_pane_by_agent_id() {
    echo "${RESOLVE_PANE_RESULT}"
}
stage3_slay() { echo "mock stage3_slay: $*"; }
sedi() { sed -i "$@"; }
agent_is_busy() { return 1; }
MOCK

    # Add mock bin dir to PATH
    mkdir -p "$TEST_TMP/mock_bin"
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract cmd_suriken and _cmd_suriken_ntfy_fallback from njslyr_cmd.sh
    # Range: from _cmd_suriken_ntfy_fallback() to just before cmd_chop()
    sed -n '/^_cmd_suriken_ntfy_fallback()/,/^# ─── A-2: chop/{/^# ─── A-2: chop/d;p}' \
        "$NJSLYR_CMD" > "$TEST_TMP/functions.sh"

    # Set SCRIPT_DIR and PROJECT_ROOT for sourced functions
    # shellcheck source=/dev/null
    (
        SCRIPT_DIR="$MOCK_PROJECT/scripts"
        PROJECT_ROOT="$MOCK_PROJECT"
        # shellcheck source=/dev/null
        source "$TEST_TMP/mock_njslyr_lib.sh"
        # shellcheck source=/dev/null
        source "$TEST_TMP/functions.sh"
    ) 2>/dev/null || true
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: source functions with given environment
source_functions() {
    SCRIPT_DIR="$MOCK_PROJECT/scripts"
    PROJECT_ROOT="$MOCK_PROJECT"
    # shellcheck source=/dev/null
    source "$TEST_TMP/mock_njslyr_lib.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/functions.sh"
}

# Helper: run function capturing stdout+stderr
call_with_stderr() {
    "$@" 2>&1
}

# =============================================================================
# T-CMD-SRK-001: ローカルペインあり → tmux send-keys 3回（リグレッション確認）
# =============================================================================

@test "T-CMD-SRK-001: cmd_suriken sends 3x tmux send-keys when pane found locally" {
    # Mock tmux: list-panes returns %1, send-keys logged
    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    # resolve_pane_by_agent_id returns %1 (pane found)
    RESOLVE_PANE_RESULT="%1"
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # tmux send-keys 3回確認（nudge text + Escape + Enter）
    [ -f "$TMUX_CALL_LOG" ]
    local send_keys_count
    send_keys_count=$(grep -c "send-keys" "$TMUX_CALL_LOG")
    [ "$send_keys_count" -eq 3 ]
}

# =============================================================================
# T-CMD-SRK-002: ローカルペインなし → _cmd_suriken_ntfy_fallback 呼び出し
# =============================================================================

@test "T-CMD-SRK-002: cmd_suriken calls ntfy fallback when pane not found" {
    # Mock curl (HTTP 200)
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # resolve_pane_by_agent_id returns empty (pane not found)
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1

    # curl was called (ntfy fallback executed)
    [ -f "$CURL_CALL_LOG" ]
    grep -q "ntfy.sh" "$CURL_CALL_LOG"
    # Message format: suriken:agent_id:unread_count
    grep -q "suriken:yakuza3" "$CURL_CALL_LOG"
}

# =============================================================================
# T-CMD-SRK-003: _cmd_suriken_ntfy_fallback HTTP 200 → 成功
# =============================================================================

@test "T-CMD-SRK-003: _cmd_suriken_ntfy_fallback succeeds on HTTP 200" {
    # Mock curl: returns 200
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        _cmd_suriken_ntfy_fallback yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"ntfy fallback →"* ]]
    [[ "$output" == *"HTTP 200"* ]]
}

# =============================================================================
# T-CMD-SRK-004: _cmd_suriken_ntfy_fallback HTTP 500 → return 1
# =============================================================================

@test "T-CMD-SRK-004: _cmd_suriken_ntfy_fallback returns 1 on HTTP 500" {
    # Mock curl: returns 500
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "500"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        _cmd_suriken_ntfy_fallback yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"ntfy fallback FAILED"* ]]
    [[ "$output" == *"HTTP 500"* ]]
}

# =============================================================================
# T-CMD-SRK-005: _cmd_suriken_ntfy_fallback peer_topic decision (kyoto → neosaitama)
# =============================================================================

@test "T-CMD-SRK-005: _cmd_suriken_ntfy_fallback sends to neosaitama topic when role is kyoto" {
    # Mock curl: capture full args
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        _cmd_suriken_ntfy_fallback yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # ntfy.sh/{topic}-neosaitama に送信されているか確認
    [ -f "$CURL_CALL_LOG" ]
    grep -q "neosaitama" "$CURL_CALL_LOG"
}
