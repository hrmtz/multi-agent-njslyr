#!/usr/bin/env bats
# test_njslyr_cmd.bats — njslyr_cmd.sh suriken コマンドのユニットテスト (cmd_297)
#
# テスト構成:
#   T-CMD-SRK-001: ローカルペインあり → tmux send-keys 3回呼ばれる（リグレッション確認）
#   T-CMD-SRK-002: ローカルペインなし → _cmd_suriken_ntfy_fallback 呼び出し確認
#   T-CMD-SRK-003: _cmd_suriken_ntfy_fallback: HTTP 200 → 成功
#   T-CMD-SRK-004: _cmd_suriken_ntfy_fallback: HTTP 500 → return 1
#   T-CMD-INJ-001: cmd_inject: pane見つからず → return 1
#   T-CMD-INJ-002: cmd_inject: 既にOpus + bg=#1a002e → スキップ
#   T-CMD-INJ-003: cmd_inject: Sonnet → /model opus + @model_name更新

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

    # Mock njslyr_lib.sh (provides resolve_pane_by_agent_id, stage3_slay, sedi, agent_is_busy)
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT
    cat > "$TEST_TMP/mock_njslyr_lib.sh" << 'MOCK'
#!/bin/bash
resolve_pane_by_agent_id() {
    echo "${RESOLVE_PANE_RESULT}"
}
stage3_slay() { echo "mock_stage3_slay: $*" >> "${STAGE3_LOG:-/dev/null}"; }
sedi() { sed -i "$@"; }
agent_is_busy() { return 1; }
cmd_suriken() { echo "mock_suriken: $*" >> "${SURIKEN_LOG:-/dev/null}"; }
MOCK

    # Add mock bin dir to PATH
    mkdir -p "$TEST_TMP/mock_bin"
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract cmd_suriken, _cmd_suriken_ntfy_fallback, _cmd_suriken_ssh_fallback from njslyr_cmd.sh
    # Range: from _cmd_suriken_ntfy_fallback() to just before cmd_chop()
    sed -n '/^_cmd_suriken_ntfy_fallback()/,/^# ─── A-2: chop/{/^# ─── A-2: chop/d;p}' \
        "$NJSLYR_CMD" > "$TEST_TMP/functions.sh"

    # Extract cmd_chop from njslyr_cmd.sh (A-2: chop → A-3: slay boundary)
    sed -n '/^cmd_chop()/,/^# ─── A-3: slay/{/^# ─── A-3: slay/d;p}' \
        "$NJSLYR_CMD" >> "$TEST_TMP/functions.sh"

    # Extract cmd_inject from njslyr_cmd.sh (A-7: inject → A-6: detox boundary)
    sed -n '/^cmd_inject()/,/^# ─── A-6: detox/{/^# ─── A-6: detox/d;p}' \
        "$NJSLYR_CMD" >> "$TEST_TMP/functions.sh"

    # Extract cmd_detox from njslyr_cmd.sh (A-6: detox → usage boundary)
    sed -n '/^cmd_detox()/,/^# ─── usage/{/^# ─── usage/d;p}' \
        "$NJSLYR_CMD" >> "$TEST_TMP/functions.sh"

    # Extract cmd_slay from njslyr_cmd.sh (A-3: slay → A-4: spawn_tengu boundary)
    sed -n '/^cmd_slay()/,/^# ─── A-4: spawn_tengu/{/^# ─── A-4: spawn_tengu/d;p}' \
        "$NJSLYR_CMD" >> "$TEST_TMP/functions.sh"

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
    [[ "$output" == *"ntfy tier2 →"* ]]
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
    [[ "$output" == *"ntfy tier2 FAILED"* ]]
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

# =============================================================================
# T-CMD-SRK-006: SSH tier1成功 → ntfyを呼ばずreturn 0
# =============================================================================

@test "T-CMD-SRK-006: cmd_suriken succeeds via SSH tier1 without calling ntfy" {
    # Mock ssh: success (logs call)
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
echo "[mock ssh] suriken sent"
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    # Mock curl: should NOT be called (ntfy not invoked when SSH succeeds)
    CURL_CALL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_CALL_LOG
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
echo "200"
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # resolve_pane_by_agent_id returns empty (pane not found → triggers fallback chain)
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

    # SSH tier1 was called
    [ -f "$SSH_CALL_LOG" ]
    grep -q "mock-peer" "$SSH_CALL_LOG"
    grep -q "suriken" "$SSH_CALL_LOG"

    # Output indicates SSH tier1 was used
    [[ "$output" == *"SSH tier1"* ]]

    # ntfy (curl) was NOT called
    [ ! -f "$CURL_CALL_LOG" ]
}

# =============================================================================
# T-CMD-SRK-007: _cmd_suriken_ssh_fallback SSH成功 → return 0
# =============================================================================

@test "T-CMD-SRK-007: _cmd_suriken_ssh_fallback returns 0 on SSH success" {
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

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        _cmd_suriken_ssh_fallback yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH tier1 success"* ]]

    # SSH called with correct peer host
    [ -f "$SSH_CALL_LOG" ]
    grep -q "mock-peer" "$SSH_CALL_LOG"
}

# =============================================================================
# T-CMD-SRK-008: _cmd_suriken_ssh_fallback SSH失敗 → return 1
# =============================================================================

@test "T-CMD-SRK-008: _cmd_suriken_ssh_fallback returns 1 on SSH failure" {
    # Mock ssh: failure
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "ssh: connect to host mock-peer: Connection refused" >&2
exit 255
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        _cmd_suriken_ssh_fallback yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"SSH tier1 FAILED"* ]]
}

# =============================================================================
# T-CMD-INJ-001: cmd_inject: pane見つからず → return 1
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
# T-CMD-INJ-002: cmd_inject: 既にOpus + bg=#1a002e → スキップ
# =============================================================================

@test "T-CMD-INJ-002: cmd_inject skips when already Opus with correct bg" {
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
# T-CMD-INJ-003: cmd_inject: Sonnet → /model opus + @model_name更新
# =============================================================================

@test "T-CMD-INJ-003: cmd_inject switches Sonnet to Opus and updates model_name" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    # Mock sleep (no-op for test speed)
    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

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

# =============================================================================
# T-CMD-DTX-001: cmd_detox: pane見つからず → return 1
# =============================================================================

@test "T-CMD-DTX-001: cmd_detox returns 1 when pane not found" {
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
        cmd_detox yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"pane not found"* ]]
}

# =============================================================================
# T-CMD-DTX-002: cmd_detox: 既にSonnet + bg=default → スキップ
# =============================================================================

@test "T-CMD-DTX-002: cmd_detox skips when already Sonnet and bg=default" {
    RESOLVE_PANE_RESULT="%2"
    export RESOLVE_PANE_RESULT

    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
if [[ "$*" == *"@model_name"* ]]; then
    echo "Sonnet"
elif [[ "$*" == *"background"* ]]; then
    echo "default"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_detox yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip"* ]]

    # send-keys が呼ばれないこと
    if [ -f "$TMUX_CALL_LOG" ]; then
        ! grep -q "send-keys" "$TMUX_CALL_LOG"
    fi
}

# =============================================================================
# T-CMD-DTX-003: cmd_detox: Opus → Sonnet切替
# =============================================================================

@test "T-CMD-DTX-003: cmd_detox switches Opus to Sonnet and updates bg" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    TMUX_CALL_LOG="$TEST_TMP/tmux_calls.log"
    export TMUX_CALL_LOG

    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TMUX_CALL_LOG}"
if [[ "$*" == *"@model_name"* && "$*" == *"show-options"* ]]; then
    echo "Opus"
elif [[ "$*" == *"background"* && "$*" == *"show-options"* ]]; then
    echo "#1a002e"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_detox yakuza3
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"detox complete"* ]]

    [ -f "$TMUX_CALL_LOG" ]
    grep -q "send-keys" "$TMUX_CALL_LOG"
    grep -q "/model sonnet" "$TMUX_CALL_LOG"
    grep -q "set-option" "$TMUX_CALL_LOG"
    grep -q "@model_name" "$TMUX_CALL_LOG"
    grep -q "Sonnet" "$TMUX_CALL_LOG"
    grep -q "select-pane" "$TMUX_CALL_LOG"
    grep -q "bg=default" "$TMUX_CALL_LOG"
}

# =============================================================================
# T-CMD-CHP-001: cmd_chop: pane見つからず → return 1
# =============================================================================

@test "T-CMD-CHP-001: cmd_chop returns 1 when pane not found" {
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        STATE_DIR='$MOCK_PROJECT/.state'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_chop yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"pane not found"* ]]
}

# =============================================================================
# T-CMD-CHP-002: cmd_chop: clear_last タイムスタンプファイルが生成される
# =============================================================================

@test "T-CMD-CHP-002: cmd_chop writes clear_last timestamp file" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    # Mock sleep (no-op)
    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

    # Mock tmux (no-op for send-keys)
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        STATE_DIR='$MOCK_PROJECT/.state'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_chop yakuza3
    " 2>&1

    # clear_last ファイルが生成されているか確認（exit statusは問わない: retryループ末尾の&&で1を返す正常動作）
    [ -f "$MOCK_PROJECT/.state/clear_last_yakuza3" ]

    # ファイルの中身が数字（epoch timestamp）か確認
    local ts
    ts=$(cat "$MOCK_PROJECT/.state/clear_last_yakuza3")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

# =============================================================================
# T-CMD-CHP-003: cmd_chop: 未読inboxあり → cmd_surikenが呼ばれる
# =============================================================================

@test "T-CMD-CHP-003: cmd_chop calls cmd_suriken when unread inbox exists" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    SURIKEN_LOG="$TEST_TMP/suriken_calls.log"
    export SURIKEN_LOG

    # Mock sleep (no-op)
    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

    # Mock tmux (no-op for send-keys)
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    # Mock inbox: 未読メッセージ1件
    cat > "$MOCK_PROJECT/queue/inbox/yakuza3.yaml" << 'YAML'
messages:
- content: test
  read: false
YAML

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        STATE_DIR='$MOCK_PROJECT/.state'
        SURIKEN_LOG='$SURIKEN_LOG'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        # cmd_suriken をモックで上書き（ログ記録用）
        cmd_suriken() { echo \"mock_suriken: \$*\" >> \"\${SURIKEN_LOG:-/dev/null}\"; }
        cmd_chop yakuza3
    " 2>&1
    [ "$status" -eq 0 ]

    # suriken が yakuza3 に対して呼ばれたか確認
    [ -f "$SURIKEN_LOG" ]
    grep -q "yakuza3" "$SURIKEN_LOG"
}

# =============================================================================
# T-CMD-SLY-001: cmd_slay returns 1 when pane not found
# =============================================================================

@test "T-CMD-SLY-001: cmd_slay returns 1 when pane not found" {
    RESOLVE_PANE_RESULT=""
    export RESOLVE_PANE_RESULT

    # Mock tmux (no-op)
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
        cmd_slay yakuza3
    " 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"pane not found"* ]]
}

# =============================================================================
# T-CMD-SLY-002: cmd_slay delegates to stage3_slay with correct args
# =============================================================================

@test "T-CMD-SLY-002: cmd_slay delegates to stage3_slay with correct args" {
    RESOLVE_PANE_RESULT="%3"
    export RESOLVE_PANE_RESULT

    # Mock tmux (no-op)
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    # STAGE3_LOG for capturing stage3_slay calls
    STAGE3_LOG="$TEST_TMP/stage3_calls.log"
    export STAGE3_LOG

    run bash -c "
        SCRIPT_DIR='$MOCK_PROJECT/scripts'
        PROJECT_ROOT='$MOCK_PROJECT'
        source '$TEST_TMP/mock_njslyr_lib.sh'
        source '$TEST_TMP/functions.sh'
        cmd_slay yakuza3 'テスト理由'
    " 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"slay"* ]]

    # stage3_slay was called with correct arguments
    [ -f "$STAGE3_LOG" ]
    grep -q "mock_stage3_slay: yakuza3 テスト理由 %3" "$STAGE3_LOG"
}
