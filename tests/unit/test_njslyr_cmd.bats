#!/usr/bin/env bats
# test_njslyr_cmd.bats — njslyr_cmd.sh suriken/inject コマンドのユニットテスト
#
# テスト構成:
#   T-CMD-SRK-001: ローカルペインあり → tmux send-keys 3回（リグレッション確認）
#   T-CMD-SRK-002: ローカルペインなし → ntfy fallback呼び出し確認
#   T-CMD-SRK-003: cmd_suriken ntfy Stage 2: HTTP 200 → 成功
#   T-CMD-SRK-004: cmd_suriken ntfy Stage 2: HTTP 500 + SSH設定なし → return 1
#   T-CMD-SRK-005: cmd_suriken (kyoto role) → neosaitama topicに送信
#   T-CMD-INJ-001: cmd_inject: pane見つからず → return 1 (FIX-008)
#   T-CMD-INJ-002: cmd_inject: 既にOpus → スキップ (FIX-008)
#   T-CMD-INJ-003: cmd_inject: Sonnet → /model opus + @model_name更新 (FIX-008)

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

    # Mock settings.yaml (kyoto role, ntfy_topic, no peer_host → SSH stage fails gracefully)
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

    # Mock njslyr_lib.sh (provides resolve_pane_by_agent_id, resolve_agent_machine,
    # get_my_machine_role, stage3_slay, sedi, agent_is_busy)
    RESOLVE_PANE_RESULT=""
    RESOLVE_AGENT_MACHINE="active"
    MY_MACHINE_ROLE="kyoto"
    export RESOLVE_PANE_RESULT RESOLVE_AGENT_MACHINE MY_MACHINE_ROLE
    cat > "$TEST_TMP/mock_njslyr_lib.sh" << 'MOCK'
#!/bin/bash
resolve_pane_by_agent_id() {
    echo "${RESOLVE_PANE_RESULT}"
}
resolve_agent_machine() {
    echo "${RESOLVE_AGENT_MACHINE:-active}"
}
get_my_machine_role() {
    echo "${MY_MACHINE_ROLE:-kyoto}"
}
stage3_slay() { echo "mock stage3_slay: $*"; }
sedi() { sed -i "$@"; }
agent_is_busy() { return 1; }
MOCK

    # Add mock bin dir to PATH
    mkdir -p "$TEST_TMP/mock_bin"
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Mock sleep (no-op for test speed)
    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

    # Extract cmd_suriken and cmd_inject functions from njslyr_cmd.sh
    # Uses awk with ASCII-only function name boundaries (macOS sed multibyte workaround)
    awk '/^cmd_suriken\(\)/{found=1} /^cmd_chop\(\)/{found=0} found' \
        "$NJSLYR_CMD" > "$TEST_TMP/functions.sh"

    # Append cmd_inject function (FIX-008)
    awk '/^cmd_inject\(\)/{found=1} /^cmd_detox\(\)/{found=0} found' \
        "$NJSLYR_CMD" >> "$TEST_TMP/functions.sh"
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
# T-CMD-SRK-002: ローカルペインなし → ntfy fallback呼び出し確認
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
# T-CMD-SRK-003: cmd_suriken ntfy Stage 2 HTTP 200 → 成功
# =============================================================================

@test "T-CMD-SRK-003: cmd_suriken ntfy stage succeeds on HTTP 200" {
    # Mock curl: returns 200
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    RESOLVE_PANE_RESULT=""
    RESOLVE_AGENT_MACHINE="active"
    MY_MACHINE_ROLE="kyoto"
    export RESOLVE_PANE_RESULT RESOLVE_AGENT_MACHINE MY_MACHINE_ROLE

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"ntfy/"* ]]
}

# =============================================================================
# T-CMD-SRK-004: cmd_suriken ntfy Stage 2 HTTP 500 + SSH設定なし → return 1
# =============================================================================

@test "T-CMD-SRK-004: cmd_suriken returns 1 when ntfy fails and no peer_host" {
    # Mock curl: returns 500
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "500"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    RESOLVE_PANE_RESULT=""
    RESOLVE_AGENT_MACHINE="active"
    MY_MACHINE_ROLE="kyoto"
    export RESOLVE_PANE_RESULT RESOLVE_AGENT_MACHINE MY_MACHINE_ROLE

    # settings.yaml with ntfy_topic but NO peer_host (SSH stage cannot proceed)
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
language: ja
machine:
  role: kyoto
ntfy_topic: test-topic-abc123xyz
YAML

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"all stages failed"* ]]
}

# =============================================================================
# T-CMD-SRK-005: cmd_suriken (kyoto role) → neosaitama topicに送信
# =============================================================================

@test "T-CMD-SRK-005: cmd_suriken (kyoto role) sends to neosaitama ntfy topic" {
    # Mock curl: capture full args
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    RESOLVE_PANE_RESULT=""
    RESOLVE_AGENT_MACHINE="active"
    MY_MACHINE_ROLE="kyoto"
    export RESOLVE_PANE_RESULT RESOLVE_AGENT_MACHINE MY_MACHINE_ROLE

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_suriken yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # ntfy.sh/{topic}-neosaitama に送信されているか確認
    [ -f "$CURL_CALL_LOG" ]
    grep -q "neosaitama" "$CURL_CALL_LOG"
}

# =============================================================================
# T-CMD-INJ-001: cmd_inject: pane見つからず → return 1 (FIX-008)
# =============================================================================

@test "T-CMD-INJ-001: cmd_inject returns 1 when pane not found" {
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "mock tmux: $*" >&2
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_inject yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"pane not found"* ]]
}

# =============================================================================
# T-CMD-INJ-002: cmd_inject: 既にOpus + bg=#1a002e → スキップ (FIX-008)
# =============================================================================

@test "T-CMD-INJ-002: cmd_inject skips when already Opus" {
    RESOLVE_PANE_RESULT="%2"
    export RESOLVE_PANE_RESULT

    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
# show-options -pv @model_name → Opus
# show-options -pv background  → #1a002e
if [[ "$*" == *"@model_name"* ]]; then
    echo "Opus"
elif [[ "$*" == *"background"* ]]; then
    echo "#1a002e"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_inject yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip"* ]]

    # send-keys should NOT be called (no model switch needed)
    if [ -f "$TMUX_CALL_LOG" ]; then
        ! grep -q "send-keys" "$TMUX_CALL_LOG"
    fi
}

# =============================================================================
# T-CMD-INJ-003: cmd_inject: Sonnet → /model opus + @model_name更新 (FIX-008)
# =============================================================================

@test "T-CMD-INJ-003: cmd_inject switches Sonnet to Opus and updates model_name" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
# show-options @model_name → Sonnet (not yet Opus)
# show-options background  → default
if [[ "$*" == *"@model_name"* && "$*" == *"show-options"* ]]; then
    echo "Sonnet"
elif [[ "$*" == *"background"* && "$*" == *"show-options"* ]]; then
    echo "default"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_inject yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"inject complete"* ]]

    # /model claude-opus-4-6 が send-keys で送信されたか確認
    [ -f "$TMUX_CALL_LOG" ]
    grep -q "send-keys" "$TMUX_CALL_LOG"
    grep -q "claude-opus-4-6\|Opus" "$TMUX_CALL_LOG"
}
