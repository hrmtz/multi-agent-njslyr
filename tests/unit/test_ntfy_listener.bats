#!/usr/bin/env bats
# test_ntfy_listener.bats — ntfy_listener.sh heartbeat/prefix routing ユニットテスト
# cmd_275 Round3 Group B / cmd_278 T2 追加
#
# テスト構成:
#   T-NL-HB-001: 正常HBメッセージのパース（全フィールド正常値）
#   T-NL-HB-002: epoch非数値でスキップ（log_warn出力）
#   T-NL-HB-003: agents非数値でスキップ
#   T-NL-HB-004: load非数値でスキップ
#   T-NL-HB-005: ctx_summary不正値→"unknown"にサニタイズ
#   T-NL-HB-006: host不正文字（セミコロン等）でスキップ
#   T-NL-PFX-001: push:メッセージの正常ルーティング
#   T-NL-PFX-002: sync:メッセージの正常ルーティング
#   T-NL-PFX-003: 未知prefixのデフォルト処理
#   T-NL-PFX-004: prefix偽装（"push:; rm -rf /"）の安全な処理
#   T-NL-RPT-001: report: 正常処理（YAML書き込み + gryakuza inbox通知確認）
#   T-NL-RPT-002: report: 不正base64 → エラーログ・ファイル未作成
#   T-NL-RPT-003: report: worker_id/task_id バリデーション失敗 → 拒否
#   T-NL-RPT-004: report: 既存ファイル重複処理（タイムスタンプsuffix付与）

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    NTFY_LISTENER="$PROJECT_ROOT/scripts/ntfy_listener.sh"
    export NTFY_LISTENER

    # ソースファイル存在確認
    [ -f "$NTFY_LISTENER" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/ntfy_listener_test.XXXXXX")"

    # Mock project directory structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue/{heartbeat,reports},logs/ntfy_inbox_corrupt}

    # Variables needed by ntfy_listener.sh functions (used by sourced functions.sh)
    # shellcheck disable=SC2034
    SCRIPT_DIR="$MOCK_PROJECT"
    INBOX="$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    # shellcheck disable=SC2034
    LOCKFILE="${INBOX}.lock"
    # shellcheck disable=SC2034
    CORRUPT_DIR="$MOCK_PROJECT/logs/ntfy_inbox_corrupt"
    echo "inbox:" > "$INBOX"

    # Mock inbox_write.sh (records calls to log file)
    INBOX_WRITE_LOG="$TEST_TMP/inbox_write_calls.log"
    export INBOX_WRITE_LOG
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "${INBOX_WRITE_LOG}"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # Mock tmux (records calls, returns mock pane data)
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

    # Mock git (records calls, succeeds by default)
    GIT_CALL_LOG="$TEST_TMP/git_calls.log"
    export GIT_CALL_LOG
    cat > "$TEST_TMP/mock_bin/git" << 'MOCK'
#!/bin/bash
echo "$@" >> "${GIT_CALL_LOG}"
echo "Already up to date."
MOCK
    chmod +x "$TEST_TMP/mock_bin/git"

    # Mock cross_sync.sh (succeeds by default)
    cat > "$MOCK_PROJECT/scripts/cross_sync.sh" << 'MOCK'
#!/bin/bash
echo "mock cross_sync: $*"
MOCK
    chmod +x "$MOCK_PROJECT/scripts/cross_sync.sh"

    # Add mock bin to PATH (before real commands)
    export PATH="$TEST_TMP/mock_bin:$PATH"

    # Extract function definitions from ntfy_listener.sh
    # Range: from parse_message_fields() to just before 'trap cleanup' line
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
# Heartbeat validation tests
# ═══════════════════════════════════════════════════════════════

# --- T-NL-HB-001: 正常HBメッセージのパース ---

@test "T-NL-HB-001: handle_heartbeat parses valid payload (all fields normal)" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:0.42:ok"
    [ "$status" -eq 0 ]

    # Verify heartbeat YAML was created with correct content
    local hb_file="$MOCK_PROJECT/queue/heartbeat/ryzen.yaml"
    [ -f "$hb_file" ]
    grep -q "machine_id: ryzen" "$hb_file"
    grep -q "status: alive" "$hb_file"
    grep -q "agents_active: 5" "$hb_file"
    grep -q "load_avg: 0.42" "$hb_file"
    grep -q "context_summary: ok" "$hb_file"
}

# --- T-NL-HB-002: epoch非数値でスキップ ---

@test "T-NL-HB-002: handle_heartbeat rejects non-numeric epoch with warning" {
    run call_with_stderr handle_heartbeat "ryzen:not_a_number:5:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat epoch"* ]]

    # No heartbeat file should be created
    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-003: agents非数値でスキップ ---

@test "T-NL-HB-003: handle_heartbeat rejects non-numeric agents with warning" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:abc:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat agents"* ]]

    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-004: load非数値でスキップ ---

@test "T-NL-HB-004: handle_heartbeat rejects non-numeric load with warning" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:high:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat load"* ]]

    [ ! -f "$MOCK_PROJECT/queue/heartbeat/ryzen.yaml" ]
}

# --- T-NL-HB-005: ctx_summary不正値→"unknown"にサニタイズ ---

@test "T-NL-HB-005: handle_heartbeat sanitizes invalid ctx_summary to unknown" {
    run call_with_stderr handle_heartbeat "ryzen:1709000000:5:0.42:bogus_status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sanitizing to unknown"* ]]

    local hb_file="$MOCK_PROJECT/queue/heartbeat/ryzen.yaml"
    [ -f "$hb_file" ]
    grep -q "context_summary: unknown" "$hb_file"
}

# --- T-NL-HB-006: host不正文字（セミコロン等）でスキップ ---

@test "T-NL-HB-006: handle_heartbeat rejects host with invalid characters (semicolon)" {
    run call_with_stderr handle_heartbeat "evil;host:1709000000:5:0.42:ok"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid heartbeat host"* ]]

    # Verify no file was created for the invalid host
    local count
    count=$(find "$MOCK_PROJECT/queue/heartbeat" -type f | wc -l)
    [ "$count" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# Prefix routing tests
# ═══════════════════════════════════════════════════════════════

# --- T-NL-PFX-001: push:メッセージの正常ルーティング ---

@test "T-NL-PFX-001: route_message dispatches push: prefix correctly" {
    run call_with_stderr route_message "push:cmd_100:main" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"push:"* ]]

    # Verify mock git was called with pull + correct branch
    [ -f "$GIT_CALL_LOG" ]
    grep -q "pull" "$GIT_CALL_LOG"
    grep -q "main" "$GIT_CALL_LOG"
}

# --- T-NL-PFX-002: sync:メッセージの正常ルーティング ---

@test "T-NL-PFX-002: route_message dispatches sync: prefix correctly" {
    run call_with_stderr route_message "sync:myproject:done" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"sync:"* ]]

    # Verify inbox_write was called (darkninja notified)
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
}

# --- T-NL-PFX-003: 未知prefixのデフォルト処理 ---

@test "T-NL-PFX-003: route_message returns 1 for unknown prefix (fallback)" {
    run call_with_stderr route_message "unknown_thing:data_here" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNRECOGNIZED PREFIX"* ]]
}

# --- T-NL-PFX-004: prefix偽装安全処理 ---

@test "T-NL-PFX-004: route_message handles injection payload safely (push:; rm -rf /)" {
    run call_with_stderr route_message "push:; rm -rf /" ""
    # push handler should run (prefix "push" is valid), returns 0 regardless
    [ "$status" -eq 0 ]

    # Verify mock git was NOT called (branch validation rejected the invalid payload)
    [ ! -f "$GIT_CALL_LOG" ]

    # Verify WARNING about invalid branch was logged
    [[ "$output" == *"WARNING: Invalid branch"* ]]

    # Critical: project directory must still exist (no injection executed)
    [ -d "$MOCK_PROJECT/queue" ]
    [ -d "$MOCK_PROJECT/scripts" ]
}

# ═══════════════════════════════════════════════════════════════
# ping: handler tests
# ═══════════════════════════════════════════════════════════════

# --- T-NL-PNG-001: ping: 正常メッセージ → heartbeat YAML記録 ---

@test "T-NL-PNG-001: handle_ping creates heartbeat YAML for valid payload" {
    run call_with_stderr handle_ping "mbp:1772124024:MBP calling Ryzen. respond."
    [ "$status" -eq 0 ]

    local hb_file="$MOCK_PROJECT/queue/heartbeat/mbp.yaml"
    [ -f "$hb_file" ]
    grep -q "machine_id: mbp" "$hb_file"
    grep -q "status: alive" "$hb_file"
    grep -q "last_ping:" "$hb_file"
    grep -q "ping_message:" "$hb_file"
}

# --- T-NL-PNG-002: ping: 不正source → return 1, ファイル未作成 ---

@test "T-NL-PNG-002: handle_ping rejects invalid source with warning" {
    run call_with_stderr handle_ping "evil;host:1772124024:hello"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid ping source"* ]]

    local count
    count=$(find "$MOCK_PROJECT/queue/heartbeat" -type f | wc -l)
    [ "$count" -eq 0 ]
}

# --- T-NL-PNG-003: ping: 非数値epoch → return 1, ファイル未作成 ---

@test "T-NL-PNG-003: handle_ping rejects non-numeric epoch with warning" {
    run call_with_stderr handle_ping "mbp:not_a_number:hello"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid ping epoch"* ]]

    [ ! -f "$MOCK_PROJECT/queue/heartbeat/mbp.yaml" ]
}

# --- T-NL-PNG-004: route_message ping: → return 2 (ntfy_inbox skip) ---

@test "T-NL-PNG-004: route_message dispatches ping: and returns 2 (skip ntfy_inbox)" {
    run call_with_stderr route_message "ping:mbp:1772124024:hello" ""
    # return 2 = handled, skip ntfy_inbox
    [ "$status" -eq 2 ]

    # Verify heartbeat file was created
    [ -f "$MOCK_PROJECT/queue/heartbeat/mbp.yaml" ]
}

# ═══════════════════════════════════════════════════════════════
# ntfy_inbox.yaml status update test
# ═══════════════════════════════════════════════════════════════

# --- T-NL-INBOX-001: append_ntfy_inbox "processed" → status:processed ---

@test "T-NL-INBOX-001: append_ntfy_inbox writes status:processed when status arg provided" {
    run call_with_stderr append_ntfy_inbox "msg_test_001" "2026-02-27T01:00:00+09:00" \
        "cmd:test_001:hello" "processed"
    [ "$status" -eq 0 ]

    [ -f "$INBOX" ]
    grep -q "status: processed" "$INBOX"
    grep -q "msg_test_001" "$INBOX"
}

# --- T-NL-INBOX-002: append_ntfy_inbox デフォルト → status:pending ---

@test "T-NL-INBOX-002: append_ntfy_inbox defaults to status:pending when no status arg" {
    run call_with_stderr append_ntfy_inbox "msg_test_002" "2026-02-27T01:00:00+09:00" \
        "unknown:data"
    [ "$status" -eq 0 ]

    grep -q "status: pending" "$INBOX"
    grep -q "msg_test_002" "$INBOX"
}

# ═══════════════════════════════════════════════════════════════
# report: handler tests (cmd_278 T2)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-RPT-001: report: 正常処理 ---

@test "T-NL-RPT-001: handle_report saves YAML and notifies gryakuza inbox" {
    # 正常なレポートYAMLをbase64エンコード
    local valid_yaml="worker_id: yakuza3
task_id: subtask_278c
status: completed
result: success
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_report "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"report: saved"* ]]

    # レポートファイルが正しいパスに作成されているか確認
    local report_file="$MOCK_PROJECT/queue/reports/yakuza3_report_subtask_278c.yaml"
    [ -f "$report_file" ]
    grep -q "worker_id: yakuza3" "$report_file"
    grep -q "task_id: subtask_278c" "$report_file"

    # gryakuza inbox_write が呼ばれたか確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
    grep -q "report_received" "$INBOX_WRITE_LOG"
    grep -q "subtask_278c" "$INBOX_WRITE_LOG"
}

# --- T-NL-RPT-002: report: 不正base64 → エラーログ・ファイル未作成 ---

@test "T-NL-RPT-002: handle_report rejects invalid base64, no file created" {
    # !!! は base64 デコード不可または空worker_id/task_idとなりバリデーション失敗
    run call_with_stderr handle_report "!!!invalid_base64!!!"
    [ "$status" -ne 0 ]

    # queue/reports/ にファイルが作成されていないこと
    local count
    count=$(find "$MOCK_PROJECT/queue/reports" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]

    # gryakuza inbox_write が呼ばれていないこと
    [ ! -f "$INBOX_WRITE_LOG" ] || ! grep -q "gryakuza" "$INBOX_WRITE_LOG"
}

# --- T-NL-RPT-003: report: worker_id/task_id バリデーション失敗 → 拒否 ---

@test "T-NL-RPT-003: handle_report rejects YAML with missing worker_id field" {
    # worker_id フィールドなし（task_id のみ）
    local invalid_yaml="task_id: subtask_278c
status: completed
"
    local payload
    payload=$(printf '%s' "$invalid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_report "$payload"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or missing worker_id"* ]]

    # ファイル未作成
    local count
    count=$(find "$MOCK_PROJECT/queue/reports" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]
}

@test "T-NL-RPT-003b: handle_report rejects YAML with path-traversal worker_id" {
    # worker_id にパストラバーサル文字（スラッシュ）を含む
    local bad_yaml="worker_id: ../../../etc/passwd
task_id: subtask_278c
status: completed
"
    local payload
    payload=$(printf '%s' "$bad_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_report "$payload"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or missing worker_id"* ]]

    local count
    count=$(find "$MOCK_PROJECT/queue/reports" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]
}

# --- T-NL-RPT-004: report: 既存ファイル重複処理（タイムスタンプsuffix付与） ---

@test "T-NL-RPT-004: handle_report adds timestamp suffix when report file already exists" {
    local valid_yaml="worker_id: yakuza3
task_id: subtask_278c
status: completed
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    # 1回目: 通常ファイル作成
    run call_with_stderr handle_report "$payload"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_PROJECT/queue/reports/yakuza3_report_subtask_278c.yaml" ]

    # 2回目: 既存ファイルあり → タイムスタンプsuffix付きで作成
    run call_with_stderr handle_report "$payload"
    [ "$status" -eq 0 ]

    # queue/reports/ に2ファイル存在（元 + suffix付き）
    local count
    count=$(find "$MOCK_PROJECT/queue/reports" -type f -name "yakuza3_report_subtask_278c*.yaml" | wc -l)
    [ "$count" -eq 2 ]
}

# --- T-NL-RPT-005: route_message report: → return 0 (ntfy_inbox処理) ---

@test "T-NL-RPT-005: route_message dispatches report: prefix and returns 0" {
    local valid_yaml="worker_id: yakuza3
task_id: subtask_test
status: completed
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr route_message "report:${payload}" ""
    [ "$status" -eq 0 ]

    # レポートファイルが作成されているか確認
    [ -f "$MOCK_PROJECT/queue/reports/yakuza3_report_subtask_test.yaml" ]
}

# ═══════════════════════════════════════════════════════════════
# dispatch: handler tests (cmd_278 T1)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-DSP-001: dispatch: 正常処理 ---

@test "T-NL-DSP-001: handle_task_dispatch writes YAML and notifies gryakuza inbox (FIX-004)" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_test_dsp
  parent_cmd: cmd_278
  assigned_to: yakuza3
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dispatch: task_id=subtask_test_dsp"* ]]

    # queue/tasks/ にYAMLが作成されているか確認
    local task_file="$MOCK_PROJECT/queue/tasks/yakuza3_subtask_test_dsp.yaml"
    [ -f "$task_file" ]
    grep -q "task_id: subtask_test_dsp" "$task_file"
    grep -q "parent_cmd: cmd_278" "$task_file"

    # FIX-004: gryakuza inbox_write が呼ばれたか確認（workerへの直接通知ではない）
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
    grep -q "report_received" "$INBOX_WRITE_LOG"
}

# --- T-NL-DSP-002: dispatch: 不正base64 → エラーログ・ファイル未作成 ---

@test "T-NL-DSP-002: handle_task_dispatch rejects invalid base64, no file created" {
    run call_with_stderr handle_task_dispatch "!!!invalid_base64!!!"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base64 decode failed"* ]]

    # queue/tasks/ にファイルが作成されていないこと
    mkdir -p "$MOCK_PROJECT/queue/tasks"
    local count
    count=$(find "$MOCK_PROJECT/queue/tasks" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]
}

# --- T-NL-DSP-003: dispatch: task_id/parent_cmd欠如 → バリデーション失敗 ---

@test "T-NL-DSP-003: handle_task_dispatch rejects YAML missing required fields" {
    # task_id のみ、parent_cmd なし
    local incomplete_yaml
    incomplete_yaml="task:
  task_id: subtask_test_dsp
  assigned_to: yakuza3
"
    local payload
    payload=$(printf '%s' "$incomplete_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing task_id or parent_cmd"* ]]

    # ファイル未作成
    mkdir -p "$MOCK_PROJECT/queue/tasks"
    local count
    count=$(find "$MOCK_PROJECT/queue/tasks" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]
}

# --- T-NL-DSP-004: dispatch: task_id バリデーション失敗（パストラバーサル）→ 拒否 ---

@test "T-NL-DSP-004: handle_task_dispatch rejects path-traversal task_id" {
    local bad_yaml
    bad_yaml="task:
  task_id: ../../../etc/cron.d/evil
  parent_cmd: cmd_278
  assigned_to: yakuza3
"
    local payload
    payload=$(printf '%s' "$bad_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid task_id"* ]]

    mkdir -p "$MOCK_PROJECT/queue/tasks"
    local count
    count=$(find "$MOCK_PROJECT/queue/tasks" -type f -name "*.yaml" | wc -l)
    [ "$count" -eq 0 ]
}

# --- T-NL-DSP-005: route_message dispatch: → return 0 (ntfy_inbox記録) ---

@test "T-NL-DSP-005: route_message dispatches dispatch: prefix and returns 0" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_route_test
  parent_cmd: cmd_278
  assigned_to: yakuza4
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr route_message "dispatch:${payload}" ""
    [ "$status" -eq 0 ]

    # タスクファイルが作成されているか確認
    [ -f "$MOCK_PROJECT/queue/tasks/yakuza4_subtask_route_test.yaml" ]
}

# ═══════════════════════════════════════════════════════════════
# FIX-006: dispatch: 既存ファイル上書き保護テスト (cmd_278i)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-DSP-006: dispatch: 既存ファイル上書き保護 → return 1, ファイル不変 ---

@test "T-NL-DSP-006: handle_task_dispatch skips when task file already exists" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_overwrite_test
  parent_cmd: cmd_278
  assigned_to: yakuza5
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    # 1回目: 正常作成
    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]
    local task_file="$MOCK_PROJECT/queue/tasks/yakuza5_subtask_overwrite_test.yaml"
    [ -f "$task_file" ]

    # 元ファイルのmd5を記録
    local original_md5
    original_md5=$(md5sum "$task_file" | awk '{print $1}')

    # 2回目: 上書き保護 → return 1, WARNING出力
    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Task file already exists"* ]]
    [[ "$output" == *"skipping to prevent overwrite"* ]]

    # ファイル内容が変わっていないこと
    local new_md5
    new_md5=$(md5sum "$task_file" | awk '{print $1}')
    [ "$original_md5" = "$new_md5" ]
}

# --- T-NL-DSP-007: dispatch: 上書き保護時 inbox_write が呼ばれないこと ---

@test "T-NL-DSP-007: handle_task_dispatch does not notify worker when file exists" {
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_nonotify_test
  parent_cmd: cmd_278
  assigned_to: yakuza6
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    # 1回目: 正常
    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]

    # inbox_write ログをリセット
    rm -f "$INBOX_WRITE_LOG"

    # 2回目: 上書き保護 → inbox_write 呼ばれない
    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 1 ]

    # inbox_write が呼ばれていないこと
    [ ! -f "$INBOX_WRITE_LOG" ]
}

# =============================================================================
# FIX-004: dispatch通知先 → gryakuza (cmd_278 subtask_278j)
# =============================================================================

@test "T-NL-FIX004-001: handle_task_dispatch notifies gryakuza not worker directly" {
    # FIX-004: dispatch受信時はgryakuzaに通知（§2.3アーキテクチャ準拠）
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_fix004_test
  parent_cmd: cmd_278
  assigned_to: yakuza3
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]

    # gryakuzaへの通知確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
    grep -q "report_received" "$INBOX_WRITE_LOG"

    # workerへの直接通知がないこと
    ! grep -q "yakuza3" "$INBOX_WRITE_LOG"
    ! grep -q "task_assigned" "$INBOX_WRITE_LOG"
}

@test "T-NL-FIX004-002: handle_task_dispatch inbox message contains task_id and path" {
    # FIX-004: gryakuzaへの通知メッセージにtask_idとファイルパスが含まれること
    local valid_yaml
    valid_yaml="task:
  task_id: subtask_fix004_msg
  parent_cmd: cmd_278
  assigned_to: yakuza4
  status: assigned
"
    local payload
    payload=$(printf '%s' "$valid_yaml" | base64 | tr -d '\n')

    run call_with_stderr handle_task_dispatch "$payload"
    [ "$status" -eq 0 ]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "subtask_fix004_msg" "$INBOX_WRITE_LOG"
}

# =============================================================================
# FIX-009: handover simultaneous mode拒否 (cmd_278 subtask_278j)
# =============================================================================

@test "T-NL-FIX009-001: handle_handover rejects when mode is simultaneous" {
    # FIX-009: simultaneous mode中はhandoverを拒否してlog_warnを出す
    cat > "$MOCK_PROJECT/queue/active_machine.yaml" << 'YAML'
mode: simultaneous
primary: kyoto
secondary: neosaitama
since: "2026-02-27T00:00:00+09:00"
activated_by: laomoto
YAML
    run call_with_stderr handle_handover "kyoto"
    [ "$status" -eq 1 ]
    [[ "$output" == *"handover rejected"* ]]
    [[ "$output" == *"simultaneous mode"* ]]

    # active_machine.yaml が変更されていないこと（primary: kyoto のまま）
    grep -q "mode: simultaneous" "$MOCK_PROJECT/queue/active_machine.yaml"
}

@test "T-NL-FIX009-002: handle_handover succeeds when mode is exclusive" {
    # FIX-009: exclusive mode中はhandover可能
    cat > "$MOCK_PROJECT/queue/active_machine.yaml" << 'YAML'
mode: exclusive
active_machine: kyoto
since: "2026-02-27T00:00:00+09:00"
handover_by: laomoto
YAML
    run call_with_stderr handle_handover "neosaitama"
    [ "$status" -eq 0 ]

    # active_machine.yaml が更新されているか確認（C4-B修正後: primary: フォーマット）
    grep -q "primary: neosaitama" "$MOCK_PROJECT/queue/active_machine.yaml"

    # gryakuza inbox通知が送られているか確認
    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
    grep -q "handover受信" "$INBOX_WRITE_LOG"
}

@test "T-NL-FIX009-003: handle_handover succeeds when active_machine.yaml has no mode field" {
    # FIX-009: mode フィールドなし（legacy形式）→ exclusive扱いでhandover許可
    cat > "$MOCK_PROJECT/queue/active_machine.yaml" << 'YAML'
active_machine: kyoto
since: "2026-02-27T00:00:00+09:00"
YAML
    run call_with_stderr handle_handover "neosaitama"
    [ "$status" -eq 0 ]

    # active_machine.yaml が更新されているか確認（C4-B修正後: primary: フォーマット）
    grep -q "primary: neosaitama" "$MOCK_PROJECT/queue/active_machine.yaml"
}

# ═══════════════════════════════════════════════════════════════
# suriken: handler tests (cmd_298 NTFY-001)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-SRK-001: suriken: 正常処理（ペイン発見→nudge送信） ---

@test "T-NL-SRK-001: handle_suriken sends nudge to found pane" {
    # Mock pane data: yakuza3 is at %5
    MOCK_PANES_FILE="$TEST_TMP/mock_panes.txt"
    export MOCK_PANES_FILE
    cat > "$MOCK_PANES_FILE" << 'EOF'
%0 gryakuza
%1 yakuza1
%5 yakuza3
%8 soukaiya
EOF

    run call_with_stderr handle_suriken "yakuza3:2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nudge sent to yakuza3"* ]]
    [[ "$output" == *"count=2"* ]]

    # tmux send-keys が呼ばれたことを確認
    [ -f "$TMUX_CALL_LOG" ]
    grep -q "send-keys" "$TMUX_CALL_LOG"
    grep -q "%5" "$TMUX_CALL_LOG"
}

# --- T-NL-SRK-002: suriken: 不正agent_id → エラー ---

@test "T-NL-SRK-002: handle_suriken rejects invalid agent_id (injection attempt)" {
    run call_with_stderr handle_suriken "invalid!agent:1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid agent_id"* ]]

    # tmux send-keys が呼ばれていないこと
    [ ! -f "$TMUX_CALL_LOG" ] || ! grep -q "send-keys" "$TMUX_CALL_LOG"
}

# --- T-NL-SRK-003: suriken: ペイン未発見 → エラー ---

@test "T-NL-SRK-003: handle_suriken returns error when pane not found" {
    # Mock pane data: noexist は存在しない
    MOCK_PANES_FILE="$TEST_TMP/mock_panes.txt"
    export MOCK_PANES_FILE
    cat > "$MOCK_PANES_FILE" << 'EOF'
%0 gryakuza
%1 yakuza1
EOF

    run call_with_stderr handle_suriken "noexist:0"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pane not found"* ]]

    # tmux send-keys が呼ばれていないこと
    ! grep -q "send-keys" "$TMUX_CALL_LOG" 2>/dev/null
}

# --- T-NL-SRK-004: route_message suriken: → return 0 ---

@test "T-NL-SRK-004: route_message dispatches suriken: prefix and returns 2 (skip ntfy_inbox)" {
    MOCK_PANES_FILE="$TEST_TMP/mock_panes.txt"
    export MOCK_PANES_FILE
    cat > "$MOCK_PANES_FILE" << 'EOF'
%3 yakuza5
EOF

    run call_with_stderr route_message "suriken:yakuza5:3" ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"nudge sent to yakuza5"* ]]
}

# --- T-NL-SRK-005: suriken: count未指定 → デフォルト1 ---

@test "T-NL-SRK-005: handle_suriken defaults count to 1 when not specified" {
    MOCK_PANES_FILE="$TEST_TMP/mock_panes.txt"
    export MOCK_PANES_FILE
    cat > "$MOCK_PANES_FILE" << 'EOF'
%2 yakuza2
EOF

    run call_with_stderr handle_suriken "yakuza2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]]

    # nudge text にinbox1が含まれるか確認
    grep -q "inbox1" "$TMUX_CALL_LOG"
}

# ═══════════════════════════════════════════════════════════════
# activate:simultaneous handler tests (cmd_306 C6)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-ACT-001: handle_activate_simultaneous 正常ケース ---

@test "T-NL-ACT-001: handle_activate_simultaneous writes mode:simultaneous to active_machine.yaml" {
    run call_with_stderr handle_activate_simultaneous
    [ "$status" -eq 0 ]

    local am_file="$MOCK_PROJECT/queue/active_machine.yaml"
    [ -f "$am_file" ]
    grep -q "mode: simultaneous" "$am_file"
    grep -q "primary: kyoto" "$am_file"
    grep -q "secondary: neosaitama" "$am_file"
    grep -q "activated_by: laomoto_ntfy" "$am_file"
}

# --- T-NL-ACT-002: handle_activate_simultaneous gryakuza P0通知確認 ---

@test "T-NL-ACT-002: handle_activate_simultaneous notifies gryakuza with P0 priority" {
    run call_with_stderr handle_activate_simultaneous
    [ "$status" -eq 0 ]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
    grep -q "P0" "$INBOX_WRITE_LOG"
}

# --- T-NL-ACT-003: route_message activate:simultaneous ルーティング確認 ---

@test "T-NL-ACT-003: route_message dispatches activate:simultaneous to handle_activate_simultaneous" {
    run call_with_stderr route_message "activate:simultaneous" "test-topic"
    [ "$status" -eq 0 ]

    local am_file="$MOCK_PROJECT/queue/active_machine.yaml"
    [ -f "$am_file" ]
    grep -q "mode: simultaneous" "$am_file"
    grep -q "gryakuza" "$INBOX_WRITE_LOG"
}

# --- T-NL-ACT-004: 未知payload → WARNING + return 0 ---

@test "T-NL-ACT-004: route_message activate:unknown logs WARNING and returns 0" {
    run call_with_stderr route_message "activate:unknown_payload" "test-topic"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"unknown activate subcommand"* ]]

    # active_machine.yaml は書き込まれないこと
    [ ! -f "$MOCK_PROJECT/queue/active_machine.yaml" ]
}

# ═══════════════════════════════════════════════════════════════
# free text forwarding tests (cmd_306 C4-A)
# ═══════════════════════════════════════════════════════════════

# --- T-NL-FT-001: free text → darkninja inbox_write 呼び出し確認 ---

@test "T-NL-FT-001: route_message free text forwards to darkninja via inbox_write" {
    run call_with_stderr route_message "hello from laomoto" "test-topic"
    [ "$status" -eq 0 ]

    [ -f "$INBOX_WRITE_LOG" ]
    grep -q "darkninja" "$INBOX_WRITE_LOG"
    grep -q "ntfy free text" "$INBOX_WRITE_LOG"
}

# --- T-NL-FT-002: free text → return 0 確認 ---

@test "T-NL-FT-002: route_message free text returns 0" {
    run call_with_stderr route_message "another free text message" "test-topic"
    [ "$status" -eq 0 ]
}
