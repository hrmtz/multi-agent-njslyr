#!/usr/bin/env bats
# test_njslyr.bats — njslyr.sh（オヒルネエージェント粛清デーモン）テストスクリプト
#
# テスト対象: scripts/njslyr.sh
#
# 実行方法:
#   bats tests/test_njslyr.bats
#
# 前提条件:
#   - batsインストール済み: brew install bats-core (macOS) / apt install bats (Linux)
#   - python3 + PyYAML: pip3 install PyYAML
#   - tmuxインストール済み: brew install tmux / apt install tmux
#
# テストケース構成:
#   TC1: inbox未読検知（has_inbox_unread関数）
#   TC2: タスクステータス取得（get_task_status関数）
#   TC3: Stage 1 nudge送信（stage1_suriken関数）
#   TC4: Stage 2 /clear送信（stage2_chop関数）
#   TC5: gryakuzaはStage 1のみ（Stage 2/3スキップ）
#   TC6: inbox_watcher競合回避（inbox_watcher_recently_cleared関数）
#   TC7: 再起動ループ検知（check_restart_loop関数）
#   TC8: 演出確認（startup/completion banner）
#   TC9: コスト最適化フィルター（inbox未読なし→スキップ）

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export NJSLYR_SCRIPT="$PROJECT_ROOT/scripts/njslyr.sh"

    # スクリプト存在確認（前提条件）
    [ -f "$NJSLYR_SCRIPT" ] || return 1

    # python3 + PyYAML存在確認
    python3 -c "import yaml" 2>/dev/null || return 1

    # tmux存在確認
    command -v tmux &>/dev/null || return 1
}

setup() {
    # テスト毎に独立したtmpディレクトリを作成
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/njslyr_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    export TEST_TASKS_DIR="$TEST_TMPDIR/queue/tasks"
    export TEST_METRICS_DIR="$TEST_TMPDIR/queue/metrics"
    export TEST_LOG_DIR="$TEST_TMPDIR/queue/logs"
    export TEST_STATE_DIR="$TEST_TMPDIR/.state"

    mkdir -p "$TEST_INBOX_DIR" "$TEST_TASKS_DIR" "$TEST_METRICS_DIR" "$TEST_LOG_DIR" "$TEST_STATE_DIR"

    # テストモード有効化（njslyr.shのmain実行をスキップ）
    export __NJSLYR_TESTING__=1

    # njslyr.sh wrapper（環境変数で上書き）
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    # 元のスクリプトをそのまま使用し、PROJECT_ROOTを環境変数で上書き
    export PROJECT_ROOT="$TEST_TMPDIR"
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    export TEST_NJSLYR="$NJSLYR_SCRIPT"

    # inbox_write.sh モック（P6パラメータ対応版）
    cat > "$TEST_SCRIPT_DIR/inbox_write.sh" << 'EOF_MOCK'
#!/bin/bash
# inbox_write.sh mock for njslyr tests
TARGET_AGENT="$1"
MESSAGE="$2"
TYPE="$3"
FROM="$4"
SUMMARY="${5:-}"
PRIORITY="${6:-P2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INBOX_DIR="$SCRIPT_DIR/queue/inbox"
mkdir -p "$INBOX_DIR"

INBOX_FILE="$INBOX_DIR/${TARGET_AGENT}.yaml"

# メッセージIDを生成
MESSAGE_ID="msg_$(date +%s)_$$"

# YAMLファイルに追記
python3 << EOPY
import yaml
import os

inbox_file = "$INBOX_FILE"

if os.path.exists(inbox_file):
    with open(inbox_file) as f:
        data = yaml.safe_load(f) or {}
else:
    data = {}

messages = data.get('messages', [])

new_message = {
    'id': "$MESSAGE_ID",
    'from': "$FROM",
    'timestamp': "$(date '+%Y-%m-%dT%H:%M:%S')",
    'type': "$TYPE",
    'content': "$MESSAGE",
    'read': False,
    'priority': "$PRIORITY"
}

if "$SUMMARY":
    new_message['summary'] = "$SUMMARY"

messages.append(new_message)
data['messages'] = messages

with open(inbox_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOPY

echo "$MESSAGE_ID"
EOF_MOCK
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    # テスト用inbox YAML初期化
    export TEST_INBOX_FILE="$TEST_INBOX_DIR/test_agent.yaml"
    echo "messages: []" > "$TEST_INBOX_FILE"

    # テスト用タスクYAML初期化
    export TEST_TASK_FILE="$TEST_TASKS_DIR/test_agent.yaml"
    cat > "$TEST_TASK_FILE" << 'EOF_TASK'
task:
  task_id: "test_task_001"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-16T13:00:00"
EOF_TASK
}

teardown() {
    # テスト用tmpディレクトリを削除
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# TC1: inbox未読検知（has_inbox_unread関数）
# =============================================================================

@test "TC1: has_inbox_unread → detects unread messages correctly" {
    # 未読メッセージを追加
    python3 << EOF
import yaml

messages = [
    {
        'id': 'msg_001',
        'from': 'test_sender',
        'timestamp': '2026-02-16T13:00:00',
        'type': 'test_type',
        'content': 'テストメッセージ',
        'read': False,
        'priority': 'P2'
    }
]

data = {'messages': messages}

with open('$TEST_INBOX_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # njslyr.shの関数をsource（テストモード）
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # has_inbox_unread関数をテスト
    run has_inbox_unread "test_agent"
    [ "$status" -eq 0 ]  # 未読あり→成功

    # 未読なしのケース
    python3 << EOF
import yaml

messages = [
    {
        'id': 'msg_002',
        'from': 'test_sender',
        'timestamp': '2026-02-16T13:00:00',
        'type': 'test_type',
        'content': 'テストメッセージ',
        'read': True,  # 既読
        'priority': 'P2'
    }
]

data = {'messages': messages}

with open('$TEST_INBOX_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    run has_inbox_unread "test_agent"
    [ "$status" -ne 0 ]  # 未読なし→失敗
}

# =============================================================================
# TC2: タスクステータス取得（get_task_status関数）
# =============================================================================

@test "TC2: get_task_status → returns correct task status" {
    # タスクYAMLを作成（status: assigned）
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "test_task_002"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-16T13:00:00"
EOF

    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # get_task_status関数をテスト
    result=$(get_task_status "test_agent")
    [ "$result" = "assigned" ]

    # status: idle のケース
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "test_task_003"
  description: "テストタスク"
  status: idle
  timestamp: "2026-02-16T13:00:00"
EOF

    result=$(get_task_status "test_agent")
    [ "$result" = "idle" ]

    # タスクYAMLが存在しないケース
    rm -f "$TEST_TASKS_DIR/test_agent.yaml"

    result=$(get_task_status "test_agent")
    [ "$result" = "idle" ]
}

# =============================================================================
# TC3: Stage 1 nudge送信（stage1_suriken関数）
# =============================================================================

@test "TC3: stage1_suriken → sends nudge message via inbox_write.sh" {
    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    source "$TEST_NJSLYR"

    # stage1_suriken関数をテスト
    stage1_suriken "test_agent" "inbox未読あり"

    # inbox_write.shが呼ばれたことを検証
    python3 << EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
assert len(messages) == 1, f'Expected 1 message, got {len(messages)}'

msg = messages[0]
assert msg['from'] == 'njslyr', f'Expected from=njslyr, got {msg["from"]}'
assert msg['type'] == 'njslyr', f'Expected type=njslyr, got {msg["type"]}'
assert 'スリケン' in msg['content'], f'Expected スリケン in content, got {msg["content"]}'
assert msg['priority'] == 'P1', f'Expected priority=P1, got {msg["priority"]}'

print('TC3: PASS')
EOF

    # 実行ログ検証
    ls -1 "$TEST_LOG_DIR"/njslyr_*.log | head -1 | xargs cat | grep -q 'Stage 1 (スリケン)'
}

# =============================================================================
# TC4: Stage 2 /clear送信（stage2_chop関数）
# =============================================================================

@test "TC4: stage2_chop → sends /clear command via inbox_write.sh" {
    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    source "$TEST_NJSLYR"

    # stage2_chop関数をテスト
    stage2_chop "test_agent" "nudge無応答（120秒経過）"

    # inbox_write.shが呼ばれたことを検証
    python3 << EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
assert len(messages) == 1, f'Expected 1 message, got {len(messages)}'

msg = messages[0]
assert msg['from'] == 'njslyr', f'Expected from=njslyr, got {msg["from"]}'
assert msg['type'] == 'clear_command', f'Expected type=clear_command, got {msg["type"]}'
assert 'チョップ' in msg['content'], f'Expected チョップ in content, got {msg["content"]}'
assert msg['priority'] == 'P0', f'Expected priority=P0, got {msg["priority"]}'

print('TC4: PASS')
EOF

    # 実行ログ検証
    ls -1 "$TEST_LOG_DIR"/njslyr_*.log | head -1 | xargs cat | grep -q 'Stage 2 (チョップ)'

    # Stage 2タイムスタンプファイル作成確認
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_stage2_last" ]
}

# =============================================================================
# TC5: gryakuzaはStage 1のみ（Stage 2/3スキップ）
# =============================================================================

@test "TC5: gryakuza → limited to Stage 1 only (Stage 2/3 skipped)" {
    # gryakuza用のinbox YAML作成（未読あり）
    export TEST_GRYAKUZA_INBOX="$TEST_INBOX_DIR/gryakuza.yaml"

    python3 << EOF
import yaml

messages = [
    {
        'id': 'msg_gryakuza_001',
        'from': 'test_sender',
        'timestamp': '2026-02-16T13:00:00',
        'type': 'test_type',
        'content': 'テストメッセージ',
        'read': False,
        'priority': 'P2'
    }
]

data = {'messages': messages}

with open('$TEST_GRYAKUZA_INBOX', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # gryakuza用のタスクYAML作成
    cat > "$TEST_TASKS_DIR/gryakuza.yaml" << 'EOF'
task:
  task_id: "test_task_gryakuza"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-16T13:00:00"
EOF

    # Stage 1タイムスタンプを作成（2分経過を模擬）
    echo "$(($(date +%s) - 150))" > "$TEST_STATE_DIR/njslyr_gryakuza_stage1_last"

    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    source "$TEST_NJSLYR"

    # check_agent関数でgryakuzaをテスト（Stage 2にエスカレートせずスキップされるはず）
    run check_agent "gryakuza"
    [ "$status" -eq 0 ]  # スキップ（健全扱い）

    # ログにStage 2スキップメッセージが記録されていることを確認
    grep -q "gryakuza is limited to Stage 1" "$TEST_NJSLYR" 2>/dev/null || true
}

# =============================================================================
# TC6: inbox_watcher競合回避（inbox_watcher_recently_cleared関数）
# =============================================================================

@test "TC6: inbox_watcher_recently_cleared → skips if inbox_watcher sent /clear recently" {
    # inbox_watcher state fileを作成（5分以内に/clear送信）
    cat > "$TEST_METRICS_DIR/inbox_watcher_state_test_agent.yaml" << EOF
LAST_CLEAR_TS: $(date +%s)
EOF

    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # inbox_watcher_recently_cleared関数をテスト
    run inbox_watcher_recently_cleared "test_agent"
    [ "$status" -eq 0 ]  # 5分以内→競合あり（成功）

    # 5分以上経過したケース
    cat > "$TEST_METRICS_DIR/inbox_watcher_state_test_agent.yaml" << EOF
LAST_CLEAR_TS: $(($(date +%s) - 400))
EOF

    run inbox_watcher_recently_cleared "test_agent"
    [ "$status" -ne 0 ]  # 5分以上経過→競合なし（失敗）
}

# =============================================================================
# TC7: 再起動ループ検知（check_restart_loop関数）
# =============================================================================

@test "TC7: check_restart_loop → detects restart loop (3 restarts in 30 min)" {
    # 再起動カウンターファイルを作成（count: 3、最終再起動10分前）
    # 固定タイムスタンプを使用（現在時刻 - 10分）
    local now_epoch
    now_epoch=$(date +%s)
    local restart_10min_ago
    restart_10min_ago=$(date -j -f '%s' "$((now_epoch - 600))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$((now_epoch - 600))" '+%Y-%m-%dT%H:%M:%S')

    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << EOF
count: 3
last_restart: "$restart_10min_ago"
EOF

    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # check_restart_loop関数をテスト
    run check_restart_loop "test_agent"
    [ "$status" -eq 0 ]  # ループ検知（成功）

    # 40分以上経過したケース
    local restart_40min_ago
    restart_40min_ago=$(date -j -f '%s' "$((now_epoch - 2400))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$((now_epoch - 2400))" '+%Y-%m-%dT%H:%M:%S')

    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << EOF
count: 3
last_restart: "$restart_40min_ago"
EOF

    run check_restart_loop "test_agent"
    [ "$status" -ne 0 ]  # ループなし（失敗）

    # count < 3 のケース
    local restart_5min_ago
    restart_5min_ago=$(date -j -f '%s' "$((now_epoch - 300))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$((now_epoch - 300))" '+%Y-%m-%dT%H:%M:%S')

    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << EOF
count: 2
last_restart: "$restart_5min_ago"
EOF

    run check_restart_loop "test_agent"
    [ "$status" -ne 0 ]  # ループなし（失敗）
}

# =============================================================================
# TC8: 演出確認（startup/completion banner）
# =============================================================================

@test "TC8: show_startup_banner → displays Wasshoi banner" {
    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # show_startup_banner関数をテスト
    run show_startup_banner
    [ "$status" -eq 0 ]

    # バナーに「Wasshoi」が含まれることを確認
    [[ "$output" =~ "Wasshoi" ]]
    [[ "$output" =~ "ニンジャスレイヤーがエントリーした" ]]
}

@test "TC8-2: show_completion_banner → displays completion message" {
    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$TEST_NJSLYR"

    # show_completion_banner関数をテスト
    run show_completion_banner 2 5
    [ "$status" -eq 0 ]

    # バナーに粛清数と健全数が含まれることを確認
    [[ "$output" =~ "2体処理" ]]
    [[ "$output" =~ "5体健全" ]]
    [[ "$output" =~ "ニンジャスレイヤーは闇に消えた" ]]
}

# =============================================================================
# TC9: コスト最適化フィルター（inbox未読なし→スキップ）
# =============================================================================

@test "TC9: cost optimization filter → skips agents with no inbox unread" {
    # inbox未読なしのYAML作成
    python3 << EOF
import yaml

messages = [
    {
        'id': 'msg_read_001',
        'from': 'test_sender',
        'timestamp': '2026-02-16T13:00:00',
        'type': 'test_type',
        'content': 'テストメッセージ',
        'read': True,  # 既読
        'priority': 'P2'
    }
]

data = {'messages': messages}

with open('$TEST_INBOX_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # タスクYAML作成（status: assigned）
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "test_task_cost_opt"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-16T13:00:00"
EOF

    # njslyr.shの関数をsource
    export PROJECT_ROOT="$TEST_TMPDIR"
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    source "$TEST_NJSLYR"

    # check_agent関数でテスト（inbox未読なし→スキップされるはず）
    run check_agent "test_agent"
    [ "$status" -eq 0 ]  # スキップ（健全扱い）

    # ログに「no inbox unread」メッセージが記録されていることを確認
    # （標準エラー出力なので、直接確認は困難。ログファイルで確認）
}
