#!/usr/bin/env bats
# test_njslyr_cmd_suriken_ssh_first.bats — suriken SSH-firstの動作確認 (cmd_330)
#
# テスト構成:
#   T-SSH-FIRST-001: ローカルペイン未発見時にSSH tier1を先に試みること
#   T-SSH-FIRST-002: SSH tier1成功時 → ntfyを呼ばずreturn 0
#   T-SSH-FIRST-003: SSH tier1失敗時 → ntfy tier2 fallbackを呼ぶこと
#   T-SSH-FIRST-004: NJSLYR_SSH_DEPTH >= 1 → return 1（無限ループ防止ガード維持）

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NJSLYR_CMD="$PROJECT_ROOT/scripts/njslyr_cmd.sh"
    export NJSLYR_CMD

    [ -f "$NJSLYR_CMD" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/ssh_first_test.XXXXXX")"

    # Mock project directory structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue/inbox,.state}

    # Mock settings.yaml (kyoto → peer is neosaitama)
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
language: ja
machine:
  role: kyoto
  peer_host: mock-peer
  peer_project_root: /mock/peer/project
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

    # Mock ssh_fallback.sh (real lib — uses mock ssh binary via PATH)
    cp "$PROJECT_ROOT/lib/ssh_fallback.sh" "$MOCK_PROJECT/lib/ssh_fallback.sh"

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

    # Mock njslyr_lib.sh
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

    # Extract suriken functions from njslyr_cmd.sh
    sed -n '/^_cmd_suriken_ntfy_fallback()/,/^# ─── A-2: chop/{/^# ─── A-2: chop/d;p}' \
        "$NJSLYR_CMD" > "$TEST_TMP/functions.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# =============================================================================
# T-SSH-FIRST-001: ローカルペイン未発見時にSSH tier1を先に試みること
# =============================================================================

@test "T-SSH-FIRST-001: cmd_suriken attempts SSH tier1 first when pane not found" {
    # Mock ssh: fail (so we can observe SSH was attempted before ntfy)
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
exit 255
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    # Mock curl: HTTP 200 (ntfy tier2 fallback succeeds)
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # Pane not found
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1

    # SSH was attempted first (SSH_CALL_LOG exists)
    [ -f "$SSH_CALL_LOG" ]
    grep -q "mock-peer" "$SSH_CALL_LOG"

    # Output shows SSH tier1 was attempted
    [[ "$output" == *"SSH tier1"* ]]
}

# =============================================================================
# T-SSH-FIRST-002: SSH tier1成功時 → ntfyを呼ばずreturn 0
# =============================================================================

@test "T-SSH-FIRST-002: cmd_suriken returns 0 via SSH tier1 without calling ntfy" {
    # Mock ssh: success
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
echo "[mock ssh] suriken delivered"
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    # Mock curl: should NOT be called
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # Pane not found
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # SSH tier1 was called and succeeded
    [ -f "$SSH_CALL_LOG" ]
    [[ "$output" == *"SSH tier1 success"* ]]

    # ntfy (curl) was NOT called
    [ ! -f "$CURL_CALL_LOG" ]
}

# =============================================================================
# T-SSH-FIRST-003: SSH tier1失敗時 → ntfy tier2 fallbackを呼ぶこと
# =============================================================================

@test "T-SSH-FIRST-003: cmd_suriken falls back to ntfy tier2 when SSH tier1 fails" {
    # Mock ssh: fail
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
echo "ssh: connect to host mock-peer: Connection refused" >&2
exit 255
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    # Mock curl: HTTP 200 (ntfy tier2 succeeds)
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # Pane not found
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # SSH tier1 was attempted and failed
    [ -f "$SSH_CALL_LOG" ]
    [[ "$output" == *"SSH tier1 failed"* ]]

    # ntfy tier2 was called as fallback
    [ -f "$CURL_CALL_LOG" ]
    grep -q "ntfy.sh" "$CURL_CALL_LOG"
    grep -q "suriken:yakuza3" "$CURL_CALL_LOG"
    [[ "$output" == *"ntfy tier2"* ]]
}

# =============================================================================
# T-SSH-FIRST-004: NJSLYR_SSH_DEPTH >= 1 → return 1（無限ループ防止ガード維持）
# =============================================================================

@test "T-SSH-FIRST-004: cmd_suriken aborts when NJSLYR_SSH_DEPTH >= 1 (infinite loop guard)" {
    # Pane not found (would trigger cross-machine if guard not working)
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    # Mock ssh: should NOT be called
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        NJSLYR_SSH_DEPTH=1
        export NJSLYR_SSH_DEPTH
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 1 ]

    # SSH was NOT called (guard triggered before any fallback)
    [ ! -f "$SSH_CALL_LOG" ]

    # Output shows depth limit message
    [[ "$output" == *"SSH depth limit reached"* ]]
}
