#!/usr/bin/env bats
# test_ssh_inbox_write.bats — lib/ssh_inbox_write.sh ユニットテスト
#
# テスト構成:
#   T-S01: 引数バリデーション — target_agent未指定でexit 1
#   T-S02: 引数バリデーション — message未指定でexit 1
#   T-S03: agent_idバリデーション — 不正文字でexit 1
#   T-S04: from バリデーション — 不正文字でexit 1
#   T-S05: NJSLYR_SSH_DEPTH>=1 で再帰防止 → exit 1
#   T-S06: SSH疎通OK → inbox_write成功 (mock)
#   T-S07: SSH疎通失敗 → 10秒wait → リトライ成功 (mock)
#   T-S08: SSH疎通2回失敗 → ntfyフォールバック (mock)
#   T-S09: task_yaml指定時 → scp実行 (mock)
#   T-S10: peer_host未設定でexit 1
#   T-S11: peer_project_root 不正パスでexit 1

# ─── セットアップ ─────────────────────────────────────────────────────────────

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export SSH_INBOX_WRITE_SCRIPT="$PROJECT_ROOT/lib/ssh_inbox_write.sh"
    [ -f "$SSH_INBOX_WRITE_SCRIPT" ] || { echo "MISSING: $SSH_INBOX_WRITE_SCRIPT"; return 1; }
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d)"

    # テスト用ディレクトリ構造
    mkdir -p "$TEST_TMPDIR/lib"
    mkdir -p "$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_TMPDIR/config"
    mkdir -p "$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_TMPDIR/queue/tasks"
    mkdir -p "$TEST_TMPDIR/logs"

    # ssh_fallback.sh モック (テスト用 SCRIPT_DIR を返す)
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

    # デフォルト settings.yaml
    cat > "$TEST_TMPDIR/config/settings.yaml" << EOF
machine:
  role: kyoto
  peer_host: test-peer-host
  peer_project_root: /Users/hrmtz/project/multi-agent-njslyr
EOF

    # inbox_write.sh モック (ローカル呼び出し用)
    cat > "$TEST_TMPDIR/scripts/inbox_write.sh" << 'EOF'
#!/usr/bin/env bash
echo "[mock inbox_write] args: $*" >&2
exit 0
EOF
    chmod +x "$TEST_TMPDIR/scripts/inbox_write.sh"

    # テスト対象スクリプトを SCRIPT_DIR=TEST_TMPDIR でコピー
    # SCRIPT_DIR の解決を TEST_TMPDIR にオーバーライド
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/lib/ssh_inbox_write.sh" > "$TEST_TMPDIR/lib/ssh_inbox_write.sh"
    chmod +x "$TEST_TMPDIR/lib/ssh_inbox_write.sh"

    export TEST_SCRIPT="$TEST_TMPDIR/lib/ssh_inbox_write.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ─── ヘルパー: fake ssh/scp コマンドをPATHに注入 ─────────────────────────────

# SSH成功モック
_setup_ssh_ok() {
    local mock_bin="$TEST_TMPDIR/mock_bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/ssh" << 'EOF'
#!/usr/bin/env bash
# 疎通確認(true): true引数 → 即 exit 0
for arg in "$@"; do
    if [[ "$arg" == "true" ]]; then exit 0; fi
done
# inbox_write実行: 成功
echo "[mock ssh] $*" >&2
exit 0
EOF
    cat > "$mock_bin/scp" << 'EOF'
#!/usr/bin/env bash
echo "[mock scp] $*" >&2
exit 0
EOF
    chmod +x "$mock_bin/ssh" "$mock_bin/scp"
    export PATH="$mock_bin:$PATH"
}

# SSH初回失敗・2回目成功モック
_setup_ssh_fail_then_ok() {
    local mock_bin="$TEST_TMPDIR/mock_bin_failok"
    mkdir -p "$mock_bin"
    local attempt_file="$TEST_TMPDIR/ssh_attempt_count"
    echo "0" > "$attempt_file"
    cat > "$mock_bin/ssh" << EOF
#!/usr/bin/env bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
# 疎通確認(true): 1回目失敗、2回目成功
for arg in "\$@"; do
    if [[ "\$arg" == "true" ]]; then
        if [[ \$count -le 1 ]]; then exit 1; else exit 0; fi
    fi
done
# inbox_write実行: 成功
echo "[mock ssh ok] \$*" >&2
exit 0
EOF
    cat > "$mock_bin/scp" << 'EOF'
#!/usr/bin/env bash
echo "[mock scp] $*" >&2
exit 0
EOF
    chmod +x "$mock_bin/ssh" "$mock_bin/scp"
    export PATH="$mock_bin:$PATH"
    export ATTEMPT_FILE="$attempt_file"
}

# SSH常時失敗モック
_setup_ssh_always_fail() {
    local mock_bin="$TEST_TMPDIR/mock_bin_fail"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/ssh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    cat > "$mock_bin/scp" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$mock_bin/ssh" "$mock_bin/scp"
    export PATH="$mock_bin:$PATH"
}

# ntfyフォールバックモック
_setup_ntfy_mocks() {
    cat > "$TEST_TMPDIR/scripts/ntfy_send_dispatch.sh" << 'EOF'
#!/usr/bin/env bash
echo "[mock ntfy_send_dispatch] $*" >&2
touch "${TEST_TMPDIR}/ntfy_dispatch_called" 2>/dev/null || true
exit 0
EOF
    cat > "$TEST_TMPDIR/scripts/ntfy_send_report.sh" << 'EOF'
#!/usr/bin/env bash
echo "[mock ntfy_send_report] $*" >&2
touch "${TEST_TMPDIR}/ntfy_report_called" 2>/dev/null || true
exit 0
EOF
    chmod +x "$TEST_TMPDIR/scripts/ntfy_send_dispatch.sh"
    chmod +x "$TEST_TMPDIR/scripts/ntfy_send_report.sh"
}

# ─── テストケース ─────────────────────────────────────────────────────────────

@test "T-S01: target_agent未指定でexit 1" {
    run bash "$TEST_SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

@test "T-S02: message未指定でexit 1" {
    run bash "$TEST_SCRIPT" "gryakuza"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

@test "T-S03: agent_id不正文字でexit 1" {
    run bash "$TEST_SCRIPT" "gryakuza;rm -rf /" "test message" "task_assigned" "yakuza3"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
}

@test "T-S04: agent_id スペース含みでexit 1" {
    run bash "$TEST_SCRIPT" "gryakuza neo" "test message" "task_assigned" "yakuza3"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
}

@test "T-S05: NJSLYR_SSH_DEPTH=1 で再帰防止 → exit 1" {
    run env NJSLYR_SSH_DEPTH=1 bash "$TEST_SCRIPT" "gryakuza" "test" "task_assigned" "yakuza3"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "recursive SSH" ]]
}

@test "T-S06: SSH疎通OK → inbox_write成功 (mock)" {
    _setup_ssh_ok
    # sleep を無効化（テスト高速化）
    run bash "$TEST_SCRIPT" "gryakuza" "テストメッセージ" "task_assigned" "yakuza3"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "inbox_write OK" ]]
}

@test "T-S07: SSH初回失敗 → リトライ後成功 (mock)" {
    _setup_ssh_fail_then_ok
    # sleep 10 を skipping するため sleep をモック
    local mock_bin="$TEST_TMPDIR/mock_bin_failok"
    cat > "$mock_bin/sleep" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$mock_bin/sleep"
    run bash "$TEST_SCRIPT" "gryakuza" "リトライテスト" "task_assigned" "yakuza3"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "sleep recovery" ]]
}

@test "T-S08: SSH 2回失敗 → ntfyフォールバック (mock)" {
    _setup_ssh_always_fail
    _setup_ntfy_mocks
    # sleep をモック
    local mock_bin="$TEST_TMPDIR/mock_bin_fail"
    cat > "$mock_bin/sleep" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$mock_bin/sleep"
    # ntfyスクリプトのTEST_TMPDIR参照のため環境変数エクスポート
    export TEST_TMPDIR
    run bash "$TEST_SCRIPT" "gryakuza" "フォールバックテスト" "task_assigned" "yakuza3"
    # SSH失敗 → ntfyフォールバック → exit 1 (SSH失敗扱い)
    [ "$status" -eq 1 ]
    [[ "$output" =~ "ntfy fallback" ]]
}

@test "T-S09: task_yaml指定時 → scpが呼ばれる (mock)" {
    _setup_ssh_ok
    local yaml_file="$TEST_TMPDIR/queue/tasks/test_task.yaml"
    echo "task_id: test" > "$yaml_file"
    run bash "$TEST_SCRIPT" "yakuza3" "タスク割り当て" "task_assigned" "gryakuza" "$yaml_file"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "scp OK" ]]
}

@test "T-S10: peer_host未設定でexit 1" {
    # peer_host を空にする
    cat > "$TEST_TMPDIR/config/settings.yaml" << 'EOF'
machine:
  role: kyoto
  peer_project_root: /Users/hrmtz/project/multi-agent-njslyr
EOF
    run bash "$TEST_SCRIPT" "gryakuza" "test" "task_assigned" "yakuza3"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "peer_host or peer_project_root not configured" ]]
}

@test "T-S11: peer_project_root 不正パス (.. 含む) でexit 1" {
    cat > "$TEST_TMPDIR/config/settings.yaml" << 'EOF'
machine:
  role: kyoto
  peer_host: test-peer-host
  peer_project_root: /Users/../etc/passwd
EOF
    run bash "$TEST_SCRIPT" "gryakuza" "test" "task_assigned" "yakuza3"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid PEER_PROJECT" ]]
}
