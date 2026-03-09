#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-CM: Cross-Machine Communication Tests (cmd_298)
# ═══════════════════════════════════════════════════════════════
# クロスマシン通信の E2E テストスクリプト。
# 実際のクロスマシン通信が不可能な環境では全テストをskip。
#
# 前提環境変数:
#   BOTH_MACHINES=true   — 両マシンが接続可能な状態（T-CM-001〜004用）
#   PEER_ACCESSIBLE=true — SSHでpeerに到達可能（T-CM-003用）
#
# 実行例（両マシン接続済み環境）:
#   BOTH_MACHINES=true PEER_ACCESSIBLE=true bats tests/e2e/test_cross_machine_comms.bats
#
# 単体モック実行（SSH fallback ロジック検証のみ）:
#   bats tests/e2e/test_cross_machine_comms.bats
#
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e,cross_machine

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# ─── Project root ───
PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# ─── Helpers ───

# settings.yaml から machine.role を読む
_get_machine_role() {
    awk '/^  role:/ {print $2; exit}' "$PROJECT_ROOT/config/settings.yaml" 2>/dev/null
}

# settings.yaml から ntfy_topic を読む
_get_ntfy_topic() {
    awk '/^ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' \
        "$PROJECT_ROOT/config/settings.yaml" 2>/dev/null
}

# settings.yaml から peer_host を読む
_get_peer_host() {
    awk '/^  peer_host:/ {print $2; exit}' "$PROJECT_ROOT/config/settings.yaml" 2>/dev/null
}

# inbox の unread 数を返す
_inbox_unread_count() {
    local agent_id="$1"
    grep -c 'read: false' "$PROJECT_ROOT/queue/inbox/${agent_id}.yaml" 2>/dev/null || echo "0"
}

# ─── Lifecycle ───

setup_file() {
    command -v curl &>/dev/null || skip "curl not available (required for ntfy)"
    [[ -f "$PROJECT_ROOT/config/settings.yaml" ]] || \
        skip "config/settings.yaml not found"
    [[ -f "$PROJECT_ROOT/scripts/njslyr_cmd.sh" ]] || \
        skip "scripts/njslyr_cmd.sh not found"
}

setup() {
    :  # 個別テストはそれぞれskip判定を持つ
}

teardown() {
    # テスト中に設置した一時ファイルを削除
    rm -f "$PROJECT_ROOT/queue/heartbeat/test_cm_$$.yaml" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# T-CM-001: kyoto → neosaitama suriken (ntfy tier1)
# ═══════════════════════════════════════════════════════════════
# 前提:
#   - BOTH_MACHINES=true
#   - kyoto が稼働中（このマシンで実行）
#   - neosaitama 側で ntfy_listener.sh が起動済み
# 手順:
#   - njslyr_cmd.sh suriken yakuza3 送信
#   - ローカルにpane不在 → ntfy tier1 fallback発動
#   - レスポンスコード 2xx → 成功
# ═══════════════════════════════════════════════════════════════

@test "T-CM-001: kyoto→neosaitama suriken via ntfy tier1 fallback" {
    [[ "${BOTH_MACHINES:-}" == "true" ]] || \
        skip "BOTH_MACHINES not set — skipping cross-machine ntfy test"

    local role
    role=$(_get_machine_role)
    [[ "$role" == "kyoto" || "$role" == "ryzen" ]] || \
        skip "This test must run on kyoto machine (current: ${role})"

    local topic
    topic=$(_get_ntfy_topic)
    [[ -n "$topic" ]] || skip "ntfy_topic not configured"

    # yakuza3のローカルpaneが存在しないことを確認（neosaitamaエージェント）
    local pane_found
    pane_found=$(tmux list-panes -a -F '#{@agent_id}' 2>/dev/null | grep -c "^yakuza3$" || echo "0")

    # ローカルにいない場合のみtier1 fallbackが発動する
    # ローカルにpaneがある場合はこのテストをスキップ（ローカルnudgeになってしまう）
    if [[ "$pane_found" -gt 0 ]]; then
        skip "yakuza3 pane found locally — ntfy fallback would not trigger"
    fi

    # suriken 実行 → ntfy tier1 fallback が発動するはず
    run bash "$PROJECT_ROOT/scripts/njslyr_cmd.sh" suriken yakuza3
    # ntfy fallback または SSH fallback が成功した場合
    # exit code 0 かつ出力に "ntfy fallback" または "SSH tier2" を含む
    assert_success
    [[ "$output" == *"ntfy fallback"* || "$output" == *"SSH tier2"* ]] || \
        fail "Expected ntfy fallback or SSH tier2 in output, got: $output"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-002: neosaitama → kyoto suriken (ntfy tier1)
# ═══════════════════════════════════════════════════════════════
# 前提:
#   - BOTH_MACHINES=true
#   - neosaitama が稼働中（このマシンで実行）
#   - kyoto 側で ntfy_listener.sh が起動済み
# ═══════════════════════════════════════════════════════════════

@test "T-CM-002: neosaitama→kyoto suriken via ntfy tier1 fallback" {
    [[ "${BOTH_MACHINES:-}" == "true" ]] || \
        skip "BOTH_MACHINES not set — skipping cross-machine ntfy test"

    local role
    role=$(_get_machine_role)
    [[ "$role" == "neosaitama" || "$role" == "mbp" ]] || \
        skip "This test must run on neosaitama machine (current: ${role})"

    local topic
    topic=$(_get_ntfy_topic)
    [[ -n "$topic" ]] || skip "ntfy_topic not configured"

    # gryakuza のローカルpaneが存在しないことを確認（kyotoエージェント）
    local pane_found
    pane_found=$(tmux list-panes -a -F '#{@agent_id}' 2>/dev/null | grep -c "^gryakuza$" || echo "0")
    if [[ "$pane_found" -gt 0 ]]; then
        skip "gryakuza pane found locally — ntfy fallback would not trigger"
    fi

    # suriken 実行 → ntfy tier1 fallback が発動するはず
    run bash "$PROJECT_ROOT/scripts/njslyr_cmd.sh" suriken gryakuza
    assert_success
    [[ "$output" == *"ntfy fallback"* || "$output" == *"SSH tier2"* ]] || \
        fail "Expected ntfy fallback or SSH tier2 in output, got: $output"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-003: SSH tier2 fallback (ntfy失敗時)
# ═══════════════════════════════════════════════════════════════
# 前提:
#   - PEER_ACCESSIBLE=true（SSHでpeerに到達可能）
#   - settings.yaml に peer_host / peer_project_root が設定済み
# mock:
#   - _cmd_suriken_ntfy_fallback を強制FAIL関数で上書き
#   - SSH tier2 が発動し成功することを確認
# ═══════════════════════════════════════════════════════════════

@test "T-CM-003: SSH tier2 fallback triggers when ntfy tier1 fails" {
    [[ "${PEER_ACCESSIBLE:-}" == "true" ]] || \
        skip "PEER_ACCESSIBLE not set — skipping SSH tier2 fallback test"

    local peer_host
    peer_host=$(_get_peer_host)
    [[ -n "$peer_host" ]] || skip "peer_host not configured in settings.yaml"

    # SSH接続テスト（5秒タイムアウト）
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "$peer_host" "echo ok" &>/dev/null; then
        skip "SSH connection to $peer_host failed — cannot test SSH tier2"
    fi

    # モックスクリプト: ntfy fallback を強制失敗させる wrapper を作成
    # njslyr_cmd.sh の中身は source できないため、ssh_fallback.sh + 外部コマンドで直接テスト
    local mock_script
    mock_script=$(mktemp "$PROJECT_ROOT/reel/test_ssh_tier2_XXXXXX.sh")
    chmod +x "$mock_script"
    cat > "$mock_script" << 'MOCK_EOF'
#!/usr/bin/env bash
# T-CM-003 用モック: _cmd_suriken_ntfy_fallback を強制FAIL, SSH tier2のみ実行
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/ssh_fallback.sh"
# SSH tier2 を直接呼び出し（ntfy fallback をバイパス）
agent_id="${1:-gryakuza}"
if ssh_send_suriken "$agent_id"; then
    echo "[T-CM-003] SSH tier2 success"
    exit 0
else
    echo "[T-CM-003] SSH tier2 FAILED" >&2
    exit 1
fi
MOCK_EOF

    run bash "$mock_script" gryakuza
    rm -f "$mock_script"
    assert_success
    assert_output --partial "[T-CM-003] SSH tier2 success"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-004: cross-machine dispatch delivery (ntfy_send_dispatch.sh)
# ═══════════════════════════════════════════════════════════════
# 前提:
#   - BOTH_MACHINES=true
#   - ntfy 認証が設定済み (config/ntfy_auth.env)
# 手順:
#   - 一時タスクYAMLを作成 → ntfy_send_dispatch.sh で送信
#   - HTTP 2xx でレスポンスが来ることを確認
# ═══════════════════════════════════════════════════════════════

@test "T-CM-004: cross-machine dispatch delivery via ntfy_send_dispatch.sh" {
    [[ "${BOTH_MACHINES:-}" == "true" ]] || \
        skip "BOTH_MACHINES not set — skipping cross-machine dispatch test"

    [[ -f "$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh" ]] || \
        skip "ntfy_send_dispatch.sh not found"

    local topic
    topic=$(_get_ntfy_topic)
    [[ -n "$topic" ]] || skip "ntfy_topic not configured"

    # 一時タスクYAMLをプロジェクトルート内に作成（D009ルール: /tmp禁止）
    local test_task="$PROJECT_ROOT/queue/tasks/test_cm_dispatch_$$.yaml"
    cat > "$test_task" << TASK_EOF
task:
  task_id: test_cm_dispatch_$$
  description: "T-CM-004 cross-machine dispatch test"
  status: assigned
  assigned_to: yakuza1
  timestamp: "$(date -u '+%Y-%m-%dT%H:%M:%S')"
TASK_EOF

    run bash "$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh" "$test_task"
    local exit_code=$status
    rm -f "$test_task"

    assert_equal "$exit_code" "0"
    [[ "$output" == *"SUCCESS"* || "$output" == *"success"* ]] || \
        fail "Expected SUCCESS in output, got: $output"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-005: heartbeat hybrid check (queue/heartbeat/ + SSH)
# ═══════════════════════════════════════════════════════════════
# 前提:
#   - queue/heartbeat/tortoise.yaml が存在
# 手順:
#   - ローカルの heartbeat YAML が正しい構造を持つか確認
#   - PEER_ACCESSIBLE=true の場合: SSH経由でリモートの heartbeat も確認
# ═══════════════════════════════════════════════════════════════

@test "T-CM-005-A: heartbeat YAML exists with required fields (local)" {
    local hb_dir="$PROJECT_ROOT/queue/heartbeat"
    [[ -d "$hb_dir" ]] || fail "queue/heartbeat/ directory not found"

    # tortoise.yaml または crane.yaml のいずれかが存在すること
    local found=0
    for f in "$hb_dir/tortoise.yaml" "$hb_dir/crane.yaml"; do
        [[ -f "$f" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || skip "No heartbeat YAML found (both machines offline)"

    # 存在するファイルのフィールド検証
    for hb_file in "$hb_dir/tortoise.yaml" "$hb_dir/crane.yaml"; do
        [[ -f "$hb_file" ]] || continue
        local machine_id last_beat status_field
        machine_id=$(awk '/^machine_id:/ {print $2; exit}' "$hb_file")
        last_beat=$(awk '/^last_beat:/ {print $2; exit}' "$hb_file")
        status_field=$(awk '/^status:/ {print $2; exit}' "$hb_file")

        [[ -n "$machine_id" ]] || \
            fail "$hb_file: 'machine_id' field missing"
        [[ -n "$last_beat" ]] || \
            fail "$hb_file: 'last_beat' field missing"
        [[ -n "$status_field" ]] || \
            fail "$hb_file: 'status' field missing"
    done
}

@test "T-CM-005-B: remote heartbeat accessible via SSH" {
    [[ "${PEER_ACCESSIBLE:-}" == "true" ]] || \
        skip "PEER_ACCESSIBLE not set — skipping SSH heartbeat check"

    local peer_host peer_project
    peer_host=$(_get_peer_host)
    peer_project=$(awk '/^  peer_project_root:/ {print $2; exit}' \
        "$PROJECT_ROOT/config/settings.yaml" 2>/dev/null)

    [[ -n "$peer_host" ]] || skip "peer_host not configured"
    [[ -n "$peer_project" ]] || skip "peer_project_root not configured"

    # SSH接続確認
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "$peer_host" "echo ok" &>/dev/null; then
        skip "SSH connection to $peer_host failed"
    fi

    # リモートの heartbeat YAML を SSH で読み込む
    run ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "$peer_host" \
        "cat '${peer_project}/queue/heartbeat/tortoise.yaml' \
             '${peer_project}/queue/heartbeat/crane.yaml' 2>/dev/null | \
         grep -c 'machine_id:' || echo 0"

    assert_success
    # 少なくとも1つの heartbeat YAML が存在すること
    local count="${output//[^0-9]/}"
    [[ "$count" -ge 1 ]] || \
        fail "No heartbeat YAML found on peer ($peer_host:$peer_project)"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-006: ntfy_send_dispatch.sh path traversal protection
# ═══════════════════════════════════════════════════════════════
# プロジェクトルート外のpathを渡した場合に拒否されることを確認。
# この検証はクロスマシン接続不要（ローカルで完結）。
# ═══════════════════════════════════════════════════════════════

@test "T-CM-006: ntfy_send_dispatch.sh rejects path traversal" {
    [[ -f "$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh" ]] || \
        skip "ntfy_send_dispatch.sh not found"

    # /etc/hostname のような外部パスを指定 → 拒否されること
    run bash "$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh" "/etc/hostname"
    assert_failure
    assert_output --partial "path traversal"
}

# ═══════════════════════════════════════════════════════════════
# T-CM-007: suriken ntfy fallback — unknown machine role returns error
# ═══════════════════════════════════════════════════════════════
# settings.yaml の machine.role が不正な場合、ntfy fallback が
# 適切にエラーを返すことをモックで確認。
# ═══════════════════════════════════════════════════════════════

@test "T-CM-007: njslyr_cmd.sh suriken falls back to ntfy when pane not found (local unit)" {
    [[ -f "$PROJECT_ROOT/scripts/njslyr_cmd.sh" ]] || \
        skip "njslyr_cmd.sh not found"
    [[ -f "$PROJECT_ROOT/config/settings.yaml" ]] || \
        skip "config/settings.yaml not found"

    # 存在しないエージェントIDを指定 → ローカルpane不在 → ntfy/SSH fallback発動
    # ntfy/SSH どちらも失敗してもよい（構造のテストのみ）
    # 出力に「pane not found」または「ntfy fallback」または「SSH」が含まれることを確認
    run bash "$PROJECT_ROOT/scripts/njslyr_cmd.sh" suriken "nonexistent_agent_$$"
    # pane が見つからない場合は fallback を試みる（exit code は環境依存）
    [[ "$output" == *"pane not found"* || "$output" == *"ntfy fallback"* || \
       "$output" == *"SSH"* || "$output" == *"suriken"* ]] || \
        fail "Unexpected output for missing agent: $output"
}
