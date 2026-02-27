#!/usr/bin/env bats
# test_njslyr_get_agents_window.bats — get_agents_window() unit tests (FIX-002)
#
# Tests:
#   T-CMD-GAW-001: "agents" window exists → returns "agents"
#   T-CMD-GAW-002: "neosaitama" window exists → returns "neosaitama"
#   T-CMD-GAW-003: "kyoto" window exists → returns "kyoto"
#   T-CMD-GAW-004: no matching window → returns empty
#   T-CMD-GAW-005: multiple matching windows → returns first match

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NJSLYR_SH="$PROJECT_ROOT/scripts/njslyr.sh"
    export NJSLYR_SH
    [ -f "$NJSLYR_SH" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/njslyr_gaw_test.XXXXXX")"

    # Add mock bin dir to PATH
    mkdir -p "$TEST_TMP/mock_bin"
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract get_agents_window() function using awk (macOS-safe)
    awk '/^get_agents_window\(\)/{found=1} /^get_monitor_window\(\)/{found=0} found' \
        "$NJSLYR_SH" > "$TEST_TMP/functions.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# =============================================================================
# T-CMD-GAW-001: "agents" window exists → returns "agents"
# =============================================================================

@test "T-CMD-GAW-001: agents window exists returns agents" {
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
# Mock: list-windows returns "agents" as one of the windows
if [[ "$*" == *"list-windows"* ]]; then
    printf "main\nagents\nmonitors\n"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        source '$TEST_TMP/functions.sh'
        get_agents_window
    "
    [ "$status" -eq 0 ]
    [ "$output" = "agents" ]
}

# =============================================================================
# T-CMD-GAW-002: "neosaitama" window exists → returns "neosaitama"
# =============================================================================

@test "T-CMD-GAW-002: neosaitama window exists returns neosaitama" {
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
if [[ "$*" == *"list-windows"* ]]; then
    printf "main\nneosaitama\nmonitors\n"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        source '$TEST_TMP/functions.sh'
        get_agents_window
    "
    [ "$status" -eq 0 ]
    [ "$output" = "neosaitama" ]
}

# =============================================================================
# T-CMD-GAW-003: "kyoto" window exists → returns "kyoto"
# =============================================================================

@test "T-CMD-GAW-003: kyoto window exists returns kyoto" {
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
if [[ "$*" == *"list-windows"* ]]; then
    printf "main\nkyoto\nmonitors\n"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        source '$TEST_TMP/functions.sh'
        get_agents_window
    "
    [ "$status" -eq 0 ]
    [ "$output" = "kyoto" ]
}

# =============================================================================
# T-CMD-GAW-004: no matching window → returns empty string
# =============================================================================

@test "T-CMD-GAW-004: no matching window returns empty" {
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
if [[ "$*" == *"list-windows"* ]]; then
    printf "main\nmonitors\ndashboard\n"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        source '$TEST_TMP/functions.sh'
        result=\$(get_agents_window)
        echo \"result='\$result'\"
        [ -z \"\$result\" ]
    "
    [ "$status" -eq 0 ]
}

# =============================================================================
# T-CMD-GAW-005: multiple matching windows → returns first match
# =============================================================================

@test "T-CMD-GAW-005: multiple matching windows returns first" {
    cat > "$TEST_TMP/mock_bin/tmux" << 'MOCK'
#!/bin/bash
if [[ "$*" == *"list-windows"* ]]; then
    printf "agents\nkyoto\nneosaitama\n"
fi
MOCK
    chmod +x "$TEST_TMP/mock_bin/tmux"

    run bash -c "
        source '$TEST_TMP/functions.sh'
        get_agents_window
    "
    [ "$status" -eq 0 ]
    # head -1 returns first matching window: "agents"
    [ "$output" = "agents" ]
}
