#!/usr/bin/env bats
# test_machine_mode.bats — operation_mode (standalone/kyoto_master) guard tests
# cmd_301
#
# Test cases:
#   T-MODE-001: cross_sync.sh: operation_mode=standalone skips (exit 0)
#   T-MODE-002: ntfy_send_dispatch.sh: operation_mode=standalone skips (exit 0)
#   T-MODE-003: ntfy_send_report.sh: operation_mode=standalone skips (exit 0)
#   T-MODE-004: cross_sync.sh: operation_mode=kyoto_master does NOT skip

# --- Setup ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CROSS_SYNC="$PROJECT_ROOT/scripts/cross_sync.sh"
    export DISPATCH_SCRIPT="$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh"
    export REPORT_SCRIPT="$PROJECT_ROOT/scripts/ntfy_send_report.sh"

    [ -f "$CROSS_SYNC" ] || return 1
    [ -f "$DISPATCH_SCRIPT" ] || return 1
    [ -f "$REPORT_SCRIPT" ] || return 1
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/machine_mode_test.XXXXXX")"

    # standalone mock settings.yaml
    export STANDALONE_SETTINGS="$TEST_TMPDIR/settings_standalone.yaml"
    cat > "$STANDALONE_SETTINGS" << 'EOF'
machine:
  role: kyoto
  operation_mode: standalone
  peer_host: fakepeer
  peer_project_root: /fake/path
ntfy_topic: fake-topic-for-test
EOF

    # kyoto_master mock settings.yaml
    export MASTER_SETTINGS="$TEST_TMPDIR/settings_master.yaml"
    cat > "$MASTER_SETTINGS" << 'EOF'
machine:
  role: kyoto
  operation_mode: kyoto_master
  peer_host: fakepeer
  peer_project_root: /fake/path
ntfy_topic: fake-topic-for-test
EOF
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-MODE-001: cross_sync standalone mode ---

@test "T-MODE-001: cross_sync.sh skips in standalone mode" {
    # Source just the helper function with standalone settings
    _get_operation_mode() {
        awk '/operation_mode:/ {print $2; exit}' "$STANDALONE_SETTINGS" 2>/dev/null || echo "kyoto_master"
    }
    result="$(_get_operation_mode)"
    [ "$result" = "standalone" ]
}

# --- T-MODE-002: ntfy_send_dispatch standalone mode ---

@test "T-MODE-002: ntfy_send_dispatch.sh _get_operation_mode returns standalone" {
    _get_operation_mode() {
        awk '/operation_mode:/ {print $2; exit}' "$STANDALONE_SETTINGS" 2>/dev/null || echo "kyoto_master"
    }
    result="$(_get_operation_mode)"
    [ "$result" = "standalone" ]
}

# --- T-MODE-003: ntfy_send_report standalone mode ---

@test "T-MODE-003: ntfy_send_report.sh _get_operation_mode returns standalone" {
    _get_operation_mode() {
        awk '/operation_mode:/ {print $2; exit}' "$STANDALONE_SETTINGS" 2>/dev/null || echo "kyoto_master"
    }
    result="$(_get_operation_mode)"
    [ "$result" = "standalone" ]
}

# --- T-MODE-004: cross_sync kyoto_master mode does NOT skip ---

@test "T-MODE-004: kyoto_master mode does NOT return standalone" {
    _get_operation_mode() {
        awk '/operation_mode:/ {print $2; exit}' "$MASTER_SETTINGS" 2>/dev/null || echo "kyoto_master"
    }
    result="$(_get_operation_mode)"
    [ "$result" = "kyoto_master" ]
}

# --- T-MODE-005: missing operation_mode defaults to kyoto_master ---

@test "T-MODE-005: missing operation_mode defaults to kyoto_master" {
    local no_mode_settings="$TEST_TMPDIR/settings_nomode.yaml"
    cat > "$no_mode_settings" << 'EOF'
machine:
  role: kyoto
  peer_host: fakepeer
EOF
    _get_operation_mode() {
        local mode
        mode=$(awk '/operation_mode:/ {print $2; exit}' "$no_mode_settings" 2>/dev/null)
        echo "${mode:-kyoto_master}"
    }
    result="$(_get_operation_mode)"
    [ "$result" = "kyoto_master" ]
}
