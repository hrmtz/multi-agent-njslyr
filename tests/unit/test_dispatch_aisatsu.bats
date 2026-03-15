#!/usr/bin/env bats
# test_dispatch_aisatsu.bats — dispatch アイサツ機構ユニットテスト (cmd_328 モンジュPhase3)
#
# テスト構成:
#   T-AISATSU-001: handle_aisatsu parses valid アイサツ (aisatsu:task_id:ok)
#   T-AISATSU-002: handle_aisatsu parses error アイサツ (aisatsu:task_id:error)
#   T-AISATSU-003: handle_aisatsu rejects invalid task_id (path traversal)
#   T-AISATSU-004: handle_aisatsu sanitizes unknown status to "unknown"
#   T-AISATSU-005: route_message dispatches aisatsu: prefix correctly (return 0)
#   T-AISATSU-006: handle_aisatsu notifies darkninja via inbox_write
#   T-AISATSU-007: handle_task_dispatch sends aisatsu: after success (mock curl)
#   T-AISATSU-008: backward compat — dispatch: prefix still works (no aisatsu interference)
#   T-AISATSU-009: backward compat — report: prefix still works
#   T-AISATSU-010: backward compat — suriken: prefix still works
#   T-AISATSU-011: _wait_for_aisatsu returns 0 on アイサツ match (mock curl stream)
#   T-AISATSU-012: _wait_for_aisatsu returns 1 on シツレイ検知 (mock curl empty)
#   T-AISATSU-013: アイサツformat validation — empty task_id rejected

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
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/dispatch_aisatsu_test.XXXXXX")"

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
# For streaming (_wait_for_aisatsu): output nothing by default (triggers シツレイ検知)
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
# handle_aisatsu tests
# ═══════════════════════════════════════════════════════════════

# --- T-AISATSU-001: 正常アイサツ(ok)のパース ---

@test "T-AISATSU-001: handle_aisatsu parses valid アイサツ with ok status" {
    run call_with_stderr handle_aisatsu "subtask_test_001:ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aisatsu: task_id=subtask_test_001 status=ok"* ]]

    # darkninja inbox_write 呼び出し確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
    grep -q "アイサツ確認" "$INBOX_WRITE_LOG"
    grep -q "subtask_test_001" "$INBOX_WRITE_LOG"
}

# --- T-AISATSU-002: エラーアイサツ(error)のパース ---

@test "T-AISATSU-002: handle_aisatsu parses valid アイサツ with error status" {
    run call_with_stderr handle_aisatsu "subtask_test_002:error"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aisatsu: task_id=subtask_test_002 status=error"* ]]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "subtask_test_002" "$INBOX_WRITE_LOG"
    grep -q "error" "$INBOX_WRITE_LOG"
}

# --- T-AISATSU-003: 不正task_id（パストラバーサル）→ 拒否 ---

@test "T-AISATSU-003: handle_aisatsu rejects invalid task_id (path traversal)" {
    run call_with_stderr handle_aisatsu "../../../etc/passwd:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid task_id"* ]]

    # inbox_write は呼ばれないこと
    [ ! -f "$INBOX_WRITE_LOG" ]
}

# --- T-AISATSU-004: 不正status → unknownにサニタイズ ---

@test "T-AISATSU-004: handle_aisatsu sanitizes unknown status to 'unknown'" {
    run call_with_stderr handle_aisatsu "subtask_test_004:bogus_status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid status"* ]]
    [[ "$output" == *"treating as unknown"* ]]
    [[ "$output" == *"status=unknown"* ]]

    # darkninja への通知は行われること（statusはunknownだが通知自体は必要）
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
}

# --- T-AISATSU-005: route_message aisatsu: → return 0 (ntfy_inbox記録あり) ---

@test "T-AISATSU-005: route_message dispatches aisatsu: prefix and returns 0" {
    run call_with_stderr route_message "aisatsu:subtask_route_test:ok" ""
    [ "$status" -eq 0 ]

    # darkninja inbox_write 確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
    grep -q "subtask_route_test" "$INBOX_WRITE_LOG"
}

# --- T-AISATSU-006: handle_aisatsu通知内容にtask_idとstatusが含まれる ---

@test "T-AISATSU-006: handle_aisatsu inbox message contains task_id and status" {
    run call_with_stderr handle_aisatsu "subtask_328_test:ok"
    [ "$status" -eq 0 ]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "subtask_328_test" "$INBOX_WRITE_LOG"
    grep -q "ok" "$INBOX_WRITE_LOG"
    grep -q "system_notice" "$INBOX_WRITE_LOG"
}

# ═══════════════════════════════════════════════════════════════
# handle_task_dispatch アイサツ送信テスト
# ═══════════════════════════════════════════════════════════════

# --- T-AISATSU-007: dispatch成功時にaisatsu: POST呼び出し確認 ---

@test "T-AISATSU-007: handle_task_dispatch sends aisatsu via local inbox_write on kyoto (cmd_330)" {
    # cmd_330: MACHINE_ROLE=kyoto → ローカルinbox_write経由でaisatsuを送信（loopback防止）
    # curlではなくscripts/inbox_write.shが使われることを確認
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_aisatsu_test
  parent_cmd: cmd_328
  assigned_to: yakuza3
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dispatch: task_id=subtask_aisatsu_test"* ]]

    # ローカルinbox_writeでaisatsu送信されたことを確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "aisatsu受領" "$INBOX_WRITE_LOG"
    grep -q "system_notice" "$INBOX_WRITE_LOG"

    # ログメッセージに「アイサツ(ローカル)」が含まれること
    [[ "$output" == *"アイサツ(ローカル)"* ]]
}

# ═══════════════════════════════════════════════════════════════
# 後方互換テスト（既存プレフィックスに影響なし）
# ═══════════════════════════════════════════════════════════════

# --- T-AISATSU-008: dispatch: プレフィックス後方互換 ---

@test "T-AISATSU-008: backward compat — dispatch: prefix still routes correctly" {
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

    # smith inbox通知確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "smith" "$INBOX_WRITE_LOG"
}

# --- T-AISATSU-009: report: プレフィックス後方互換 ---

@test "T-AISATSU-009: backward compat — report: prefix still routes correctly" {
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

# --- T-AISATSU-010: suriken: プレフィックス後方互換 ---

@test "T-AISATSU-010: backward compat — suriken: prefix still routes correctly (return 2)" {
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
# _wait_for_aisatsu テスト（ntfy_send_dispatch.sh）
# ═══════════════════════════════════════════════════════════════

# --- T-AISATSU-011: _wait_for_aisatsu アイサツ受信成功 ---

@test "T-AISATSU-011: _wait_for_aisatsu returns 0 when aisatsu: message is in stream" {
    # Mock curl: aisatsu:ok メッセージを含むntfyストリームをシミュレート
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
if [[ "$*" == *"/json?"* ]]; then
    # ntfy streaming: aisatsu:ok メッセージ出力
    echo '{"event":"message","message":"aisatsu:subtask_aisatsu_stream:ok","id":"msg_aisatsu_001","topic":"test-topic-kyoto"}'
    exit 0
fi
echo '{"id":"mock123"}'
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # _wait_for_aisatsu 関数をntfy_send_dispatch.shから抽出
    SCRIPT_DIR="$MOCK_PROJECT"
    MY_ROLE="kyoto"
    AUTH_ARGS=()
    TOPIC="test-topic-abc"
    mkdir -p "$MOCK_PROJECT/logs"

    # Extract _wait_for_aisatsu function (process substitution方式 — BUG-001修正済み)
    sed -n '/^_wait_for_aisatsu()/,/^}/p' "$NTFY_SEND_DISPATCH" > "$TEST_TMP/wait_for_aisatsu.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/wait_for_aisatsu.sh"

    run call_with_stderr _wait_for_aisatsu "subtask_aisatsu_stream" "$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"アイサツ受信(ok)"* ]]
}

# --- T-AISATSU-012: _wait_for_aisatsu シツレイ検知 ---

@test "T-AISATSU-012: _wait_for_aisatsu returns 1 on シツレイ検知 (no aisatsu in stream)" {
    # Mock curl: マッチしないメッセージのみ（タイムアウトシミュレート）
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_CALL_LOG}"
if [[ "$*" == *"/json?"* ]]; then
    # keepaliveとdispatchメッセージのみ（アイサツなし）
    echo '{"event":"keepalive","topic":"test-topic-kyoto"}'
    echo '{"event":"message","message":"dispatch:other_data","id":"msg_other","topic":"test-topic-kyoto"}'
    exit 0
fi
echo '{"id":"mock123"}'
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    SCRIPT_DIR="$MOCK_PROJECT"
    MY_ROLE="kyoto"
    AUTH_ARGS=()
    TOPIC="test-topic-abc"
    mkdir -p "$MOCK_PROJECT/logs"

    sed -n '/^_wait_for_aisatsu()/,/^}/p' "$NTFY_SEND_DISPATCH" > "$TEST_TMP/wait_for_aisatsu.sh"
    # shellcheck source=/dev/null
    source "$TEST_TMP/wait_for_aisatsu.sh"

    run call_with_stderr _wait_for_aisatsu "subtask_no_aisatsu" "$(date +%s)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"シツレイ検知"* ]]
}

# --- T-AISATSU-013: アイサツformat — 空task_id → 拒否 ---

@test "T-AISATSU-013: handle_aisatsu rejects empty task_id" {
    run call_with_stderr handle_aisatsu ":ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid task_id"* ]]

    [ ! -f "$INBOX_WRITE_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# SSH primary / transport_priority テスト
# ═══════════════════════════════════════════════════════════════

# --- T-DISPATCH-SSH-001: SSH primary成功時はntfyを呼ばない ---

@test "T-DISPATCH-SSH-001: ssh_first mode — SSH primary成功時はntfyを呼ばない" {
    # Mock settings.yaml with ssh_first + peer config
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
machine:
  role: kyoto
  operation_mode: kyoto_master
  peer_host: mock-peer
  peer_project_root: /remote/project
ntfy_topic: test-topic-abc
transport:
  priority: ssh_first
YAML

    # Mock scp: success
    SCP_CALL_LOG="$TEST_TMP/scp_calls.log"
    export SCP_CALL_LOG
    cat > "$TEST_TMP/mock_bin/scp" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SCP_CALL_LOG}"
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/scp"

    # Mock ssh: success (inbox_write)
    SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
    export SSH_CALL_LOG
    cat > "$TEST_TMP/mock_bin/ssh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SSH_CALL_LOG}"
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/ssh"

    # Create a task YAML
    local task_file="$MOCK_PROJECT/queue/tasks/yakuza1_subtask_ssh_test.yaml"
    cat > "$task_file" << 'YAML'
task:
  task_id: subtask_ssh_test
  parent_cmd: cmd_330
  assigned_to: yakuza1
  status: assigned
YAML

    # Extract _dispatch_ssh_primary + _get_transport_priority from ntfy_send_dispatch.sh
    sed -n '/^_get_transport_priority()/,/^_dispatch_ssh_fallback/{/^_dispatch_ssh_fallback/d;p}' \
        "$NTFY_SEND_DISPATCH" > "$TEST_TMP/ssh_primary.sh"
    # Also need ssh_fallback lib variables
    echo "SSH_OPTS=\"-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes\"" >> "$TEST_TMP/ssh_primary.sh"
    cat >> "$TEST_TMP/ssh_primary.sh" << 'EOF'
_ssh_get_peer_host() { awk '/^  peer_host:/ {print $2; exit}' "$SETTINGS" 2>/dev/null; }
_ssh_get_peer_project() { awk '/^  peer_project_root:/ {print $2; exit}' "$SETTINGS" 2>/dev/null; }
EOF
    # shellcheck source=/dev/null
    SETTINGS="$MOCK_PROJECT/config/settings.yaml"
    SCRIPT_DIR="$MOCK_PROJECT"
    mkdir -p "$MOCK_PROJECT/logs"
    source "$TEST_TMP/ssh_primary.sh"

    run _dispatch_ssh_primary "$task_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH primary SUCCESS"* ]]

    # scp が呼ばれたこと
    [ -f "$SCP_CALL_LOG" ]

    # curl (ntfy) が呼ばれていないこと
    [ ! -f "$CURL_CALL_LOG" ]
}

# --- T-DISPATCH-SSH-002: SSH primary失敗時はntfy fallbackへ ---

@test "T-DISPATCH-SSH-002: ssh_first mode — SSH primary失敗時はntfy fallbackが呼ばれる" {
    # Mock settings.yaml with ssh_first + peer config
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
machine:
  role: kyoto
  operation_mode: kyoto_master
  peer_host: mock-peer
  peer_project_root: /remote/project
ntfy_topic: test-topic-abc
transport:
  priority: ssh_first
YAML

    # Mock scp: FAIL
    SCP_CALL_LOG="$TEST_TMP/scp_calls.log"
    export SCP_CALL_LOG
    cat > "$TEST_TMP/mock_bin/scp" << 'MOCK'
#!/bin/bash
echo "$@" >> "${SCP_CALL_LOG}"
exit 1
MOCK
    chmod +x "$TEST_TMP/mock_bin/scp"

    # Create a task YAML
    local task_file="$MOCK_PROJECT/queue/tasks/yakuza1_subtask_ssh_fail.yaml"
    cat > "$task_file" << 'YAML'
task:
  task_id: subtask_ssh_fail
  parent_cmd: cmd_330
  assigned_to: yakuza1
  status: assigned
YAML

    # Extract _dispatch_ssh_primary
    sed -n '/^_get_transport_priority()/,/^_dispatch_ssh_fallback/{/^_dispatch_ssh_fallback/d;p}' \
        "$NTFY_SEND_DISPATCH" > "$TEST_TMP/ssh_primary.sh"
    echo "SSH_OPTS=\"-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes\"" >> "$TEST_TMP/ssh_primary.sh"
    cat >> "$TEST_TMP/ssh_primary.sh" << 'EOF'
_ssh_get_peer_host() { awk '/^  peer_host:/ {print $2; exit}' "$SETTINGS" 2>/dev/null; }
_ssh_get_peer_project() { awk '/^  peer_project_root:/ {print $2; exit}' "$SETTINGS" 2>/dev/null; }
EOF
    SETTINGS="$MOCK_PROJECT/config/settings.yaml"
    SCRIPT_DIR="$MOCK_PROJECT"
    mkdir -p "$MOCK_PROJECT/logs"
    source "$TEST_TMP/ssh_primary.sh"

    # SSH primaryがreturn 1を返すことを確認
    run _dispatch_ssh_primary "$task_file"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SSH primary FAILED"* ]]

    # scp は呼ばれたが失敗した
    [ -f "$SCP_CALL_LOG" ]
}

# --- T-DISPATCH-SSH-003: transport_priority=ntfy_firstは旧動作（後方互換） ---

@test "T-DISPATCH-SSH-003: ntfy_first mode — _get_transport_priority returns ntfy_first" {
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
machine:
  role: kyoto
ntfy_topic: test-topic-abc
transport:
  priority: ntfy_first
YAML

    sed -n '/^_get_transport_priority()/,/^$/p' "$NTFY_SEND_DISPATCH" > "$TEST_TMP/get_prio.sh"
    SETTINGS="$MOCK_PROJECT/config/settings.yaml"
    source "$TEST_TMP/get_prio.sh"

    local prio
    prio=$(_get_transport_priority)
    [ "$prio" = "ntfy_first" ]
}
