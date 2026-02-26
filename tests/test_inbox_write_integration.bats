#!/usr/bin/env bats
# test_inbox_write_integration.bats — inbox_write.sh インテグレーションテスト
#
# テスト構成:
#   TI-001~TI-003: flock競合時の挙動（ロック保持・指数バックオフ・タイムアウト）
#   TI-004~TI-009: priority引数省略時のデフォルトマッピング
#   TI-010~TI-012: 存在しないagentへの配信挙動

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"

    # スクリプト存在確認（前提条件）
    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1

    # python3 + PyYAML存在確認
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    # テスト毎に独立したtmpディレクトリを作成
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_write_integration.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # inbox_write.shのSCRIPT_DIRをテスト用に書き換えたコピーを作成
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_write.sh" > "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    export TEST_INBOX_WRITE="$TEST_SCRIPT_DIR/inbox_write.sh"
}

teardown() {
    # ロックファイルのクリーンアップ（テスト中に残る可能性あり）
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        kill "$LOCK_PID" 2>/dev/null || true
        wait "$LOCK_PID" 2>/dev/null || true
    fi
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# TI-001: flock競合 — ロック保持中でもリトライで成功する
# =============================================================================

@test "TI-001: flock contention → write succeeds after lock is released" {
    # 事前にinboxファイルを作成
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"
    local LOCKFILE="$TEST_INBOX_DIR/test_agent.yaml.lock"

    # ロックを3秒間保持するバックグラウンドプロセスを起動
    (
        exec 200>"$LOCKFILE"
        flock -x 200
        sleep 3
    ) &
    LOCK_PID=$!

    # ロック取得を確認するために少し待つ
    sleep 0.3

    # inbox_write実行（flock -w 5で待機するため、3秒後に成功するはず）
    run bash "$TEST_INBOX_WRITE" "test_agent" "ロック競合テスト" "cmd_new" "tester"
    [ "$status" -eq 0 ]

    # メッセージが正しく書き込まれたことを確認
    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 1, f'Expected 1 message, got {len(data["messages"])}'
assert data['messages'][0]['content'] == 'ロック競合テスト'

print('TI-001: PASS')
EOF

    # バックグラウンドプロセスの終了を待つ
    wait "$LOCK_PID" 2>/dev/null || true
    LOCK_PID=""
}

# =============================================================================
# TI-002: flock競合 — 複数プロセスが同時書き込みしてもデータ損失なし
# =============================================================================

@test "TI-002: heavy flock contention → 16 parallel writes, no data loss" {
    # 16個の並行書き込みプロセスを起動
    for i in $(seq 1 16); do
        bash "$TEST_INBOX_WRITE" "test_agent" "並行メッセージ_$i" "concurrent" "writer_$i" &
    done

    # 全プロセスの完了を待つ
    wait

    # 検証: 16件全てが書き込まれていること
    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg_count = len(data['messages'])
assert msg_count == 16, f'Expected 16 messages, got {msg_count}'

# 全てのIDが一意であること
ids = [msg['id'] for msg in data['messages']]
assert len(ids) == len(set(ids)), f'Duplicate IDs found: {ids}'

# 全ての並行メッセージが含まれていること
contents = sorted([msg['content'] for msg in data['messages']])
for i in range(1, 17):
    expected = f'並行メッセージ_{i}'
    assert expected in contents, f'Missing message: {expected}'

print('TI-002: PASS')
EOF
}

# =============================================================================
# TI-003: flock競合 — ロックタイムアウトからのリトライ・バックオフ確認
# =============================================================================

@test "TI-003: flock timeout with long lock → retries with backoff, eventually fails after max attempts" {
    # 事前にinboxファイルを作成
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"
    local LOCKFILE="$TEST_INBOX_DIR/test_agent.yaml.lock"

    # ロックを30秒間保持（inbox_write.shのflock -w 5を5回超過させる）
    (
        exec 200>"$LOCKFILE"
        flock -x 200
        sleep 30
    ) &
    LOCK_PID=$!

    # ロック取得を確認するために少し待つ
    sleep 0.3

    # inbox_write実行（5回のリトライ全てがタイムアウトするはず）
    run bash "$TEST_INBOX_WRITE" "test_agent" "タイムアウトテスト" "cmd_new" "tester"

    # 失敗することを確認（exit 1）
    [ "$status" -eq 1 ]

    # エラーメッセージにFAILEDが含まれること
    [[ "$output" =~ "FAILED" ]]

    # バックグラウンドプロセスを停止
    kill "$LOCK_PID" 2>/dev/null || true
    wait "$LOCK_PID" 2>/dev/null || true
    LOCK_PID=""
}

# =============================================================================
# TI-004: priority省略 — cmd_newタイプはデフォルトP0
# =============================================================================

@test "TI-004: priority default for cmd_new → P0" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "ラオモト指示" "cmd_new" "darkninja"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P0', f'Expected P0 for cmd_new, got {msg["priority"]}'

print('TI-004: PASS')
EOF
}

# =============================================================================
# TI-005: priority省略 — report_receivedタイプはデフォルトP1
# =============================================================================

@test "TI-005: priority default for report_received → P1" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "タスク完了報告" "report_received" "yakuza3"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P1', f'Expected P1 for report_received, got {msg["priority"]}'

print('TI-005: PASS')
EOF
}

# =============================================================================
# TI-006: priority省略 — report_receivedでBLOCKINGキーワードありはP0
# =============================================================================

@test "TI-006: priority default for report_received with BLOCKING → P0" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "BLOCKING: 依存ファイルが見つからない" "report_received" "yakuza5"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P0', f'Expected P0 for BLOCKING report, got {msg["priority"]}'

print('TI-006: PASS')
EOF
}

# =============================================================================
# TI-007: priority省略 — task_assignedタイプはデフォルトP2
# =============================================================================

@test "TI-007: priority default for task_assigned → P2" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "タスク割り当て" "task_assigned" "gryakuza"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P2', f'Expected P2 for task_assigned, got {msg["priority"]}'

print('TI-007: PASS')
EOF
}

# =============================================================================
# TI-008: priority省略 — 不明typeはデフォルトP3
# =============================================================================

@test "TI-008: priority default for unknown type → P3" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "情報共有" "info_share" "yakuza1"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P3', f'Expected P3 for unknown type, got {msg["priority"]}'

print('TI-008: PASS')
EOF
}

# =============================================================================
# TI-009: priority明示指定 — デフォルトを上書き
# =============================================================================

@test "TI-009: explicit priority overrides default → P1 overrides task_assigned default P2" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "緊急タスク" "task_assigned" "gryakuza" "" "P1"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]
assert msg['priority'] == 'P1', f'Expected P1 (explicit override), got {msg["priority"]}'

print('TI-009: PASS')
EOF
}

# =============================================================================
# TI-010: 存在しないagent — 新規inboxファイルが自動作成される
# =============================================================================

@test "TI-010: nonexistent agent → inbox file auto-created" {
    # 事前にファイルが存在しないことを確認
    [ ! -f "$TEST_INBOX_DIR/phantom_agent.yaml" ]

    run bash "$TEST_INBOX_WRITE" "phantom_agent" "存在しないエージェントへ" "task_assigned" "gryakuza"
    [ "$status" -eq 0 ]

    # ファイルが作成されていること
    [ -f "$TEST_INBOX_DIR/phantom_agent.yaml" ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/phantom_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 1, f'Expected 1 message, got {len(data["messages"])}'
assert data['messages'][0]['content'] == '存在しないエージェントへ'

print('TI-010: PASS')
EOF
}

# =============================================================================
# TI-011: 存在しないagent — 複数回書き込みで正常に追記
# =============================================================================

@test "TI-011: nonexistent agent → multiple writes accumulate correctly" {
    # 3回連続で書き込み
    bash "$TEST_INBOX_WRITE" "new_agent" "メッセージ1" "cmd_new" "darkninja"
    bash "$TEST_INBOX_WRITE" "new_agent" "メッセージ2" "task_assigned" "gryakuza"
    run bash "$TEST_INBOX_WRITE" "new_agent" "メッセージ3" "report_received" "yakuza1"
    [ "$status" -eq 0 ]

    python3 <<EOF
import yaml

with open('$TEST_INBOX_DIR/new_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 3, f'Expected 3 messages, got {len(data["messages"])}'

# 順序検証
assert data['messages'][0]['content'] == 'メッセージ1'
assert data['messages'][1]['content'] == 'メッセージ2'
assert data['messages'][2]['content'] == 'メッセージ3'

# 各メッセージのpriorityも正しいこと
assert data['messages'][0]['priority'] == 'P0', 'cmd_new should be P0'
assert data['messages'][1]['priority'] == 'P2', 'task_assigned should be P2'
assert data['messages'][2]['priority'] == 'P1', 'report_received should be P1'

print('TI-011: PASS')
EOF
}

# =============================================================================
# TI-012: 不正priority — バリデーションエラーで exit 1
# =============================================================================

@test "TI-012: invalid priority → exit 1 with error message" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "テスト" "cmd_new" "tester" "" "P5"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid priority" ]]
}
