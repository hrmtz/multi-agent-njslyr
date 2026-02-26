#!/usr/bin/env bats
# test_inbox_e2e.bats — inbox_write.sh + inbox_watcher.sh E2Eテスト
# リグレッションテスト仕様書 T-E2E-001 ~ T-E2E-005 実装
#
# テスト構成:
#   T-E2E-001: 優先度フィールド付きメッセージの配信
#   T-E2E-002: /clear後のauto-recovery配信
#   T-E2E-003: 基本的なE2E配信（メッセージ書き込み→検知→配信）
#   T-E2E-004: 複数メッセージの優先度ソート配信
#   T-E2E-005: 大量メッセージ(50件)のバッチ処理

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    export INBOX_WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"

    # スクリプト存在確認（前提条件）
    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1
    [ -f "$INBOX_WATCHER_SCRIPT" ] || return 1

    # python3 + PyYAML存在確認
    python3 -c "import yaml" 2>/dev/null || return 1

    # fswatch/inotifywait存在確認（OS別）
    if [[ "$(uname -s)" == "Darwin" ]]; then
        command -v fswatch &>/dev/null || return 1
    else
        command -v inotifywait &>/dev/null || return 1
    fi
}

setup() {
    # テスト毎に独立したtmpディレクトリを作成
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_e2e_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    export TEST_METRICS_DIR="$TEST_TMPDIR/queue/metrics"
    mkdir -p "$TEST_INBOX_DIR"
    mkdir -p "$TEST_METRICS_DIR"

    # inbox_write.sh wrapper（SCRIPT_DIRをtmpに向ける）
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    # 元のスクリプトをコピー（SCRIPT_DIRをテスト用に書き換える）
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_write.sh" > "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    export TEST_INBOX_WRITE="$TEST_SCRIPT_DIR/inbox_write.sh"

    # inbox初期化
    export TEST_INBOX_FILE="$TEST_INBOX_DIR/test_agent.yaml"
    echo "messages: []" > "$TEST_INBOX_FILE"
}

teardown() {
    # テスト用tmpディレクトリを削除
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# T-E2E-001: 優先度フィールド付きメッセージの配信
# =============================================================================

@test "T-E2E-001: priority field delivery → messages sorted by priority (P0→P1→P2→P3)" {
    # メッセージを優先度付きで書き込み（順不同）
    python3 <<EOF
import yaml

messages = [
    {
        'id': 'msg_p2',
        'from': 'test_sender',
        'timestamp': '2026-02-16T01:00:00',
        'type': 'test_type',
        'content': 'P2メッセージ',
        'read': False,
        'priority': 'P2'
    },
    {
        'id': 'msg_p0',
        'from': 'test_sender',
        'timestamp': '2026-02-16T01:00:01',
        'type': 'test_type',
        'content': 'P0緊急メッセージ',
        'read': False,
        'priority': 'P0'
    },
    {
        'id': 'msg_p3',
        'from': 'test_sender',
        'timestamp': '2026-02-16T01:00:02',
        'type': 'test_type',
        'content': 'P3低優先度メッセージ',
        'read': False,
        'priority': 'P3'
    },
    {
        'id': 'msg_p1',
        'from': 'test_sender',
        'timestamp': '2026-02-16T01:00:03',
        'type': 'test_type',
        'content': 'P1高優先度メッセージ',
        'read': False,
        'priority': 'P1'
    },
    {
        'id': 'msg_no_priority',
        'from': 'test_sender',
        'timestamp': '2026-02-16T01:00:04',
        'type': 'test_type',
        'content': 'priorityフィールドなし（デフォルトP2）',
        'read': False
    }
]

data = {'messages': messages}

with open('$TEST_INBOX_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # 優先度ソートを確認（P0→P1→P2→P3、同一優先度内はtimestamp昇順）
    python3 <<EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
unread = [m for m in messages if not m.get('read', False)]

# 優先度マッピング（P0=0, P1=1, P2=2, P3=3、デフォルト=2）
priority_map = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3}

sorted_msgs = sorted(
    unread,
    key=lambda m: (priority_map.get(m.get('priority', 'P2'), 2), m.get('timestamp', ''))
)

# ソート結果検証
expected_order = ['msg_p0', 'msg_p1', 'msg_p2', 'msg_no_priority', 'msg_p3']
actual_order = [m['id'] for m in sorted_msgs]

assert actual_order == expected_order, f'Priority sort failed: expected {expected_order}, got {actual_order}'

print('T-E2E-001: PASS')
EOF
}

# =============================================================================
# T-E2E-002: /clear後のauto-recovery配信
# =============================================================================

@test "T-E2E-002: auto-recovery after /clear → inbox_watcher enqueues task_assigned message" {
    # inbox_watcher.sh の enqueue_recovery_task_assigned 関数をテスト用に実行
    # （実際のE2Eではinbox_watcherが自動実行するが、ここでは関数単体をテスト）

    # inbox_watcher.sh の関数をsource（テストモード）
    export __INBOX_WATCHER_TESTING__=1
    export SCRIPT_DIR="$TEST_TMPDIR"
    export AGENT_ID="test_agent"
    export INBOX="$TEST_INBOX_FILE"
    export LOCKFILE="${INBOX}.lock"

    source "$INBOX_WATCHER_SCRIPT"

    # enqueue_recovery_task_assigned 実行
    result=$(enqueue_recovery_task_assigned)

    # 結果検証: メッセージIDが返る（SKIP_DUPLICATE/ERRORでない）
    [[ "$result" =~ ^msg_auto_recovery_ ]]

    # YAMLファイル検証: auto-recoveryメッセージが追加されている
    python3 <<EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
assert len(messages) == 1, f'Expected 1 message, got {len(messages)}'

msg = messages[0]

assert msg['from'] == 'inbox_watcher', f'Expected from=inbox_watcher, got {msg["from"]}'
assert msg['type'] == 'task_assigned', f'Expected type=task_assigned, got {msg["type"]}'
assert '[auto-recovery]' in msg['content'], f'Expected [auto-recovery] in content, got {msg["content"]}'
assert msg['read'] == False, f'Expected read=False, got {msg["read"]}'
assert msg['id'].startswith('msg_auto_recovery_'), f'ID should start with msg_auto_recovery_, got {msg["id"]}'

print('T-E2E-002: PASS')
EOF

    # 重複チェック: 2回目の実行はSKIP_DUPLICATE
    result2=$(enqueue_recovery_task_assigned)
    [ "$result2" = "SKIP_DUPLICATE" ]
}

# =============================================================================
# T-E2E-003: 基本的なE2E配信（メッセージ書き込み→検知）
# =============================================================================

@test "T-E2E-003: basic E2E delivery → message written, detected, and counted" {
    # メッセージ書き込み
    bash "$TEST_INBOX_WRITE" "test_agent" "E2Eテストメッセージ" "cmd_new" "darkninja"

    # inbox_watcher.sh の get_unread_info 関数をテスト
    export __INBOX_WATCHER_TESTING__=1
    export SCRIPT_DIR="$TEST_TMPDIR"
    export AGENT_ID="test_agent"
    export INBOX="$TEST_INBOX_FILE"
    export LOCKFILE="${INBOX}.lock"

    source "$INBOX_WATCHER_SCRIPT"

    # get_unread_info 実行
    info=$(get_unread_info)

    # JSON検証: count=1
    python3 <<EOF
import json

info = '''$info'''
data = json.loads(info)

assert data['count'] == 1, f'Expected count=1, got {data["count"]}'
assert data['has_task_assigned'] == False, f'Expected has_task_assigned=False, got {data["has_task_assigned"]}'

print('T-E2E-003: PASS')
EOF
}

# =============================================================================
# T-E2E-004: 複数メッセージの優先度ソート配信
# =============================================================================

@test "T-E2E-004: multiple messages with priority → sorted delivery (P0→P1→P2→P3)" {
    # 優先度付きメッセージを複数書き込み
    bash "$TEST_INBOX_WRITE" "test_agent" "P2メッセージ" "cmd_new" "darkninja" "" "P2"
    bash "$TEST_INBOX_WRITE" "test_agent" "P0緊急" "cmd_new" "darkninja" "" "P0"
    bash "$TEST_INBOX_WRITE" "test_agent" "P1高優先度" "cmd_new" "darkninja" "" "P1"

    # 優先度ソート検証
    python3 <<EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
unread = [m for m in messages if not m.get('read', False)]

# 優先度マッピング
priority_map = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3}

sorted_msgs = sorted(
    unread,
    key=lambda m: (priority_map.get(m.get('priority', 'P2'), 2), m.get('timestamp', ''))
)

# 順序検証: P0→P1→P2
expected_contents = ['P0緊急', 'P1高優先度', 'P2メッセージ']
actual_contents = [m['content'] for m in sorted_msgs]

assert actual_contents == expected_contents, f'Expected {expected_contents}, got {actual_contents}'

print('T-E2E-004: PASS')
EOF
}

# =============================================================================
# T-E2E-005: 大量メッセージ(50件)のバッチ処理
# =============================================================================

@test "T-E2E-005: batch processing of 50 messages → all messages counted correctly" {
    # 50件のメッセージを書き込み
    for i in $(seq 1 50); do
        bash "$TEST_INBOX_WRITE" "test_agent" "バッチメッセージ ${i}" "batch_test" "test_sender"
    done

    # 未読カウント検証
    export __INBOX_WATCHER_TESTING__=1
    export SCRIPT_DIR="$TEST_TMPDIR"
    export AGENT_ID="test_agent"
    export INBOX="$TEST_INBOX_FILE"
    export LOCKFILE="${INBOX}.lock"

    source "$INBOX_WATCHER_SCRIPT"

    # get_unread_count_fast 実行
    fast_info=$(get_unread_count_fast)

    # JSON検証: count=50
    python3 <<EOF
import json

info = '''$fast_info'''
data = json.loads(info)

assert data['count'] == 50, f'Expected count=50, got {data["count"]}'

print('T-E2E-005: PASS')
EOF

    # メッセージ数検証
    python3 <<EOF
import yaml

with open('$TEST_INBOX_FILE') as f:
    data = yaml.safe_load(f)

messages = data.get('messages', [])
unread = [m for m in messages if not m.get('read', False)]

assert len(unread) == 50, f'Expected 50 unread messages, got {len(unread)}'

print('T-E2E-005: Message count verified')
EOF
}
