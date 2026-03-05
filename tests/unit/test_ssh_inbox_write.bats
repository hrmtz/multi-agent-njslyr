#!/usr/bin/env bats
# test_ssh_inbox_write.bats — lib/ssh_inbox_write.sh unit tests (NeoSaitama)
# cmd_307 subtask_307f: NeoSaitama E2E coverage expansion
#
# Test cases:
#   T-SSH-IW-006: NJSLYR_SSH_DEPTH=1 blocks recursive SSH call (depth guard) -> exit 1
#   T-SSH-IW-007: PEER_HOST not set -> exit 1 with error message
#   T-SSH-IW-008: invalid agent_id chars (space/injection) -> validation fail
#   T-SSH-IW-009: invalid FROM chars -> validation fail  [PRIMARY NEW TEST]
#   T-SSH-IW-010: task_yaml SCP transfer + remote inbox_write (mock SSH)
#
# Note: Tests T-S01..T-S11 in tests/test_ssh_inbox_write.bats cover overlapping
# functionality but with Japanese test names (macOS bats UTF-8 issue). These use
# ASCII-only names and live in tests/unit/ for CI compatibility.

# ─── Setup ───────────────────────────────────────────────────────────────────

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SSH_INBOX_WRITE_SRC="$PROJECT_ROOT/lib/ssh_inbox_write.sh"
    [ -f "$SSH_INBOX_WRITE_SRC" ] || { echo "MISSING: $SSH_INBOX_WRITE_SRC" >&2; return 1; }
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d)"

    mkdir -p "$TEST_TMPDIR/lib"
    mkdir -p "$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_TMPDIR/config"
    mkdir -p "$TEST_TMPDIR/logs"
    mkdir -p "$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_TMPDIR/queue/tasks"

    # Mock ssh_fallback.sh: provides peer_host/peer_project from TEST_TMPDIR settings
    cat > "$TEST_TMPDIR/lib/ssh_fallback.sh" << 'EOF'
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
_ssh_settings_yaml() { echo "${TEST_TMPDIR}/config/settings.yaml"; }
_ssh_get_peer_host() {
    awk '/^  peer_host:/ {print $2; exit}' "${TEST_TMPDIR}/config/settings.yaml" 2>/dev/null
}
_ssh_get_peer_project() {
    awk '/^  peer_project_root:/ {print $2; exit}' "${TEST_TMPDIR}/config/settings.yaml" 2>/dev/null
}
ssh_send_suriken() { return 1; }
EOF

    # Default settings.yaml: neosaitama with valid peer
    cat > "$TEST_TMPDIR/config/settings.yaml" << EOF
machine:
  role: neosaitama
  peer_host: peer-hostname
  peer_project_root: /Users/hrmtz/project/multi-agent-njslyr
EOF

    # Mock inbox_write.sh for local notification calls
    cat > "$TEST_TMPDIR/scripts/inbox_write.sh" << 'EOF'
#!/usr/bin/env bash
echo "[mock inbox_write] args: $*" >&2
exit 0
EOF
    chmod +x "$TEST_TMPDIR/scripts/inbox_write.sh"

    # Patch SCRIPT_DIR in the script to point at TEST_TMPDIR
    # Original: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$SSH_INBOX_WRITE_SRC" > "$TEST_TMPDIR/lib/ssh_inbox_write.sh"
    chmod +x "$TEST_TMPDIR/lib/ssh_inbox_write.sh"

    export TEST_SCRIPT="$TEST_TMPDIR/lib/ssh_inbox_write.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Helper: inject mock SSH/SCP that always succeed into PATH
_inject_ssh_ok() {
    local mock_bin="$TEST_TMPDIR/mock_bin_ok"
    mkdir -p "$mock_bin"
    # ssh mock: if arg is "true" (ping check), return 0; otherwise echo and return 0
    cat > "$mock_bin/ssh" << 'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == "true" ]] && exit 0; done
echo "[mock-ssh-ok] $*" >&2
exit 0
EOF
    cat > "$mock_bin/scp" << 'EOF'
#!/usr/bin/env bash
echo "[mock-scp-ok] $*" >&2
exit 0
EOF
    chmod +x "$mock_bin/ssh" "$mock_bin/scp"
    export PATH="$mock_bin:$PATH"
}

# ─── T-SSH-IW-006: Recursive SSH depth guard ─────────────────────────────────

@test "T-SSH-IW-006: NJSLYR_SSH_DEPTH=1 blocks recursive SSH (depth guard)" {
    run env NJSLYR_SSH_DEPTH=1 bash "$TEST_SCRIPT" \
        gryakuza "test message" task_assigned yakuza3
    [ "$status" -eq 1 ]
    [[ "$output" =~ "recursive SSH" ]]
}

# ─── T-SSH-IW-007: Missing PEER_HOST ─────────────────────────────────────────

@test "T-SSH-IW-007: missing peer_host causes exit 1 with error" {
    # settings.yaml without peer_host
    cat > "$TEST_TMPDIR/config/settings.yaml" << 'EOF'
machine:
  role: neosaitama
  peer_project_root: /Users/hrmtz/project/multi-agent-njslyr
EOF
    run bash "$TEST_SCRIPT" gryakuza "test" task_assigned yakuza3
    [ "$status" -eq 1 ]
    [[ "$output" =~ "peer_host or peer_project_root not configured" ]]
}

# ─── T-SSH-IW-008: Invalid agent_id validation ───────────────────────────────

@test "T-SSH-IW-008: agent_id with space fails validation" {
    run bash "$TEST_SCRIPT" "foo bar" "test message" task_assigned yakuza3
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
    [[ "$output" =~ "invalid target_agent" ]]
}

@test "T-SSH-IW-008b: agent_id with semicolon injection fails validation" {
    run bash "$TEST_SCRIPT" "yakuza;rm -rf /" "test message" task_assigned yakuza3
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
}

# ─── T-SSH-IW-009: Invalid FROM validation (primary new test) ────────────────
# This was missing from tests/test_ssh_inbox_write.bats (T-S01..S11 only tested
# target_agent validation, not FROM validation).

@test "T-SSH-IW-009: FROM with space fails validation (exit 1)" {
    run bash "$TEST_SCRIPT" gryakuza "test message" task_assigned "foo bar"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
    [[ "$output" =~ "invalid from" ]]
}

@test "T-SSH-IW-009b: FROM with semicolon injection fails validation" {
    run bash "$TEST_SCRIPT" gryakuza "test message" task_assigned "bad;agent"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
}

@test "T-SSH-IW-009c: FROM with @ sign is accepted (gryakuza@neo pattern)" {
    _inject_ssh_ok
    # ^[a-z0-9_@]+$ allows @ — gryakuza@neo is valid
    run bash "$TEST_SCRIPT" yakuza3 "test message" task_assigned "gryakuza@neo"
    # Must NOT fail at FROM validation
    [[ "$output" != *"invalid from"* ]]
}

# ─── T-SSH-IW-010: SCP transfer + remote inbox_write via mock SSH ─────────────

@test "T-SSH-IW-010: task_yaml SCP transfer and remote inbox_write succeed (mock SSH)" {
    _inject_ssh_ok
    local yaml_file="$TEST_TMPDIR/queue/tasks/test_iw010.yaml"
    echo "task_id: test_iw010" > "$yaml_file"
    run bash "$TEST_SCRIPT" gryakuza "task assignment" task_assigned yakuza3 "$yaml_file"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "scp OK" ]]
    [[ "$output" =~ "inbox_write OK" ]]
}
