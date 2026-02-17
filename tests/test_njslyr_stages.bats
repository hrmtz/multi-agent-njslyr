#!/usr/bin/env bats
# test_njslyr_stages.bats — njslyr.sh ステージ関数ユニットテスト
#
# テスト対象: scripts/njslyr.sh のステージ関数・ヘルパー関数
#
# 実行方法:
#   bats tests/test_njslyr_stages.bats
#
# 前提条件:
#   - batsインストール済み: brew install bats-core (macOS)
#   - python3 + PyYAML: pip3 install PyYAML
#   - tmuxインストール済み（get_monitored_agents/get_pane_target以外はtmuxモック可）
#
# テストケース構成:
#   TC-S1: stage3_slay() — 再起動ループ検知時のブロック
#   TC-S2: stage3_slay() — pre-slay data preservation（タスクYAML状態更新）
#   TC-S3: generate_death_cry() — 辞世の句/爆発四散の出力確認
#   TC-S4: check_cooldown() — クールダウン期間内/期間外の判定
#   TC-S5: update_cooldown() — クールダウンタイムスタンプ書き込み
#   TC-S6: get_restart_count() — 再起動カウンタ取得
#   TC-S7: increment_restart_count() — 再起動カウンタインクリメント
#   TC-S8: reset_restart_count() — 再起動カウンタリセット
#   TC-S9: is_long_running_task() — long_runningフラグ検出
#   TC-S10: get_pane_target() — tmuxペインターゲット解決（tmux依存）
#   TC-S11: stage3_slay() — エージェントタイプ判定（model選択）
#   TC-S12: generate_farewell_haiku() — 辞世の句生成確認

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export NJSLYR_SCRIPT="$PROJECT_ROOT/scripts/njslyr.sh"

    # スクリプト存在確認
    [ -f "$NJSLYR_SCRIPT" ] || return 1

    # python3 + PyYAML存在確認
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    # テスト毎に独立したtmpディレクトリを作成
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/njslyr_stages_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    export TEST_TASKS_DIR="$TEST_TMPDIR/queue/tasks"
    export TEST_METRICS_DIR="$TEST_TMPDIR/queue/metrics"
    export TEST_LOG_DIR="$TEST_TMPDIR/queue/logs"
    export TEST_STATE_DIR="$TEST_TMPDIR/.state"

    mkdir -p "$TEST_INBOX_DIR" "$TEST_TASKS_DIR" "$TEST_METRICS_DIR" "$TEST_LOG_DIR" "$TEST_STATE_DIR"

    # テストモード有効化（njslyr.shのmain実行をスキップ）
    export __NJSLYR_TESTING__=1

    # 環境変数で上書き
    export PROJECT_ROOT="$TEST_TMPDIR"
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    # inbox_write.sh モック
    cat > "$TEST_SCRIPT_DIR/inbox_write.sh" << 'EOF_MOCK'
#!/bin/bash
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
MESSAGE_ID="msg_$(date +%s)_$$"

python3 << EOPY
import yaml, os

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

    # tmuxモック（tmux非依存テスト用）
    # 実際のtmuxコマンドをモックに差し替え
    export MOCK_TMUX_DIR="$TEST_TMPDIR/mock_bin"
    mkdir -p "$MOCK_TMUX_DIR"
    cat > "$MOCK_TMUX_DIR/tmux" << 'EOF_TMUX_MOCK'
#!/bin/bash
# tmux mock for njslyr tests
case "$1" in
    send-keys)
        # ログに記録（検証用）
        echo "tmux send-keys $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
    select-pane)
        echo "tmux select-pane $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
    set-option)
        echo "tmux set-option $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
    respawn-pane)
        echo "tmux respawn-pane $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
    capture-pane)
        echo "tmux capture-pane $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        echo ""  # empty output
        ;;
    list-panes)
        echo "tmux list-panes $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        # Return mock pane data if available
        if [ -f "${TEST_TMPDIR}/mock_panes.txt" ]; then
            cat "${TEST_TMPDIR}/mock_panes.txt"
        fi
        ;;
    *)
        echo "tmux $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
esac
exit 0
EOF_TMUX_MOCK
    chmod +x "$MOCK_TMUX_DIR/tmux"

    # テスト用inbox初期化
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # dashboard.md（update_dashboardが書き込む先）
    echo "# Dashboard" > "$TEST_TMPDIR/dashboard.md"

    # ダークニンジャinbox（notify_darkninjaが書き込む先）
    echo "messages: []" > "$TEST_INBOX_DIR/darkninja.yaml"

    # njslyr.shをsource
    export SCRIPT_DIR="$TEST_SCRIPT_DIR"
    source "$NJSLYR_SCRIPT"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# TC-S1: stage3_slay() — 再起動ループ検知時のブロック
# =============================================================================

@test "TC-S1: stage3_slay blocks when restart loop detected" {
    # 再起動カウンタを設定（3回、10分前）
    local now_epoch
    now_epoch=$(date +%s)
    local restart_ts
    restart_ts=$(date -j -f '%s' "$((now_epoch - 600))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$((now_epoch - 600))" '+%Y-%m-%dT%H:%M:%S')

    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << EOF
count: 3
last_restart: "$restart_ts"
EOF

    # tmuxモック使用（PATHの先頭に追加）
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # stage3_slayを実行 — 再起動ループのためブロックされるはず
    run stage3_slay "test_agent" "test_reason" "multiagent:1.3"
    [ "$status" -eq 1 ]

    # ダークニンジャへの通知が送られたことを確認
    python3 << EOF
import yaml
with open('$TEST_INBOX_DIR/darkninja.yaml') as f:
    data = yaml.safe_load(f)
messages = data.get('messages', [])
assert len(messages) >= 1, f'Expected notification to darkninja, got {len(messages)} messages'
msg = messages[-1]
assert '再起動ループ' in msg['content'], f'Expected restart loop warning, got: {msg["content"]}'
print('TC-S1: PASS')
EOF
}

# =============================================================================
# TC-S2: stage3_slay() — pre-slay data preservation（タスクYAML状態更新）
# =============================================================================

@test "TC-S2: stage3_slay updates task YAML status to slayed_by_njslyr" {
    # 再起動カウンタなし（ループ検知されない）
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml"

    # タスクYAML作成
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "pre_slay_test_001"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-18T01:00:00"
EOF

    # tmuxモック使用
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # stage3_slayを実行
    run stage3_slay "test_agent" "test_slay_reason" "multiagent:1.3"
    [ "$status" -eq 0 ]

    # タスクYAMLのstatusが "slayed_by_njslyr" に更新されていることを確認
    run grep 'status: slayed_by_njslyr' "$TEST_TASKS_DIR/test_agent.yaml"
    [ "$status" -eq 0 ]

    # 粛清ログが作成されていることを確認
    local slay_log_count
    slay_log_count=$(ls "$TEST_LOG_DIR"/njslyr_slay_*.yaml 2>/dev/null | wc -l)
    [ "$slay_log_count" -ge 1 ]

    # 粛清ログの内容を検証
    local slay_log
    slay_log=$(ls -t "$TEST_LOG_DIR"/njslyr_slay_*.yaml | head -1)
    grep -q 'agent_id: "test_agent"' "$slay_log"
    grep -q 'task_id: "pre_slay_test_001"' "$slay_log"
    grep -q 'slay_reason: "test_slay_reason"' "$slay_log"
}

# =============================================================================
# TC-S3: generate_death_cry() — 辞世の句/爆発四散の出力確認
# =============================================================================

@test "TC-S3: generate_death_cry returns haiku or bakuhatsu" {
    # 10回実行して、全て非空であることを確認
    local empty_count=0
    for i in $(seq 1 10); do
        result=$(generate_death_cry "test_agent")
        if [ -z "$result" ]; then
            empty_count=$((empty_count + 1))
        fi
    done
    [ "$empty_count" -eq 0 ]

    # 出力に ║ が含まれることを確認（フォーマット検証）
    result=$(generate_death_cry "test_agent")
    [[ "$result" == *"║"* ]]
}

# =============================================================================
# TC-S4: check_cooldown() — クールダウン期間内/期間外の判定
# =============================================================================

@test "TC-S4: check_cooldown correctly handles cooldown periods" {
    # Case 1: クールダウンファイルなし → 通過
    rm -f "$TEST_STATE_DIR/njslyr_test_agent_stage3_last"
    run check_cooldown "test_agent" "stage3"
    [ "$status" -eq 0 ]

    # Case 2: クールダウン期間内（5分前） → ブロック
    echo "$(($(date +%s) - 300))" > "$TEST_STATE_DIR/njslyr_test_agent_stage3_last"
    run check_cooldown "test_agent" "stage3"
    [ "$status" -eq 1 ]

    # Case 3: クールダウン期間外（35分前） → 通過
    echo "$(($(date +%s) - 2100))" > "$TEST_STATE_DIR/njslyr_test_agent_stage3_last"
    run check_cooldown "test_agent" "stage3"
    [ "$status" -eq 0 ]
}

# =============================================================================
# TC-S5: update_cooldown() — クールダウンタイムスタンプ書き込み
# =============================================================================

@test "TC-S5: update_cooldown writes timestamp file" {
    # クールダウン更新前はファイルなし
    rm -f "$TEST_STATE_DIR/njslyr_test_agent_stage2_last"
    [ ! -f "$TEST_STATE_DIR/njslyr_test_agent_stage2_last" ]

    # update_cooldownを実行
    update_cooldown "test_agent" "stage2"

    # ファイルが作成されていることを確認
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_stage2_last" ]

    # ファイル内容がepochタイムスタンプであることを確認
    local ts
    ts=$(cat "$TEST_STATE_DIR/njslyr_test_agent_stage2_last")
    [[ "$ts" =~ ^[0-9]+$ ]]

    # 現在時刻との差が5秒以内であることを確認
    local now
    now=$(date +%s)
    local diff=$((now - ts))
    [ "$diff" -lt 5 ]
}

# =============================================================================
# TC-S6: get_restart_count() — 再起動カウンタ取得
# =============================================================================

@test "TC-S6: get_restart_count returns correct count" {
    # Case 1: ファイルなし → 0
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml"
    result=$(get_restart_count "test_agent")
    [ "$result" = "0" ]

    # Case 2: count: 5 → 5
    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << 'EOF'
count: 5
last_restart: "2026-02-18T01:00:00"
EOF
    result=$(get_restart_count "test_agent")
    [ "$result" = "5" ]

    # Case 3: count: 0 → 0
    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << 'EOF'
count: 0
last_restart: "2026-02-18T01:00:00"
EOF
    result=$(get_restart_count "test_agent")
    [ "$result" = "0" ]
}

# =============================================================================
# TC-S7: increment_restart_count() — 再起動カウンタインクリメント
# =============================================================================

@test "TC-S7: increment_restart_count increments counter correctly" {
    # 初期状態: ファイルなし（count=0）
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml"

    # 1回目のインクリメント → 1
    increment_restart_count "test_agent"
    result=$(get_restart_count "test_agent")
    [ "$result" = "1" ]

    # 2回目のインクリメント → 2
    increment_restart_count "test_agent"
    result=$(get_restart_count "test_agent")
    [ "$result" = "2" ]

    # last_restartフィールドが存在することを確認
    grep -q 'last_restart:' "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml"
}

# =============================================================================
# TC-S8: reset_restart_count() — 再起動カウンタリセット
# =============================================================================

@test "TC-S8: reset_restart_count removes counter file" {
    # カウンタファイル作成
    cat > "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" << 'EOF'
count: 3
last_restart: "2026-02-18T01:00:00"
EOF
    [ -f "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" ]

    # リセット
    reset_restart_count "test_agent"

    # ファイルが削除されていることを確認
    [ ! -f "$TEST_METRICS_DIR/njslyr_restarts_test_agent.yaml" ]

    # get_restart_countが0を返すことを確認
    result=$(get_restart_count "test_agent")
    [ "$result" = "0" ]
}

# =============================================================================
# TC-S9: is_long_running_task() — long_runningフラグ検出
# =============================================================================

@test "TC-S9: is_long_running_task detects long_running flag" {
    # Case 1: long_running: true → 検出
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "long_task_001"
  description: "長時間タスク"
  status: assigned
  long_running: true
EOF

    run is_long_running_task "test_agent"
    [ "$status" -eq 0 ]

    # Case 2: long_running: false → 未検出
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "normal_task_001"
  description: "通常タスク"
  status: assigned
  long_running: false
EOF

    run is_long_running_task "test_agent"
    [ "$status" -ne 0 ]

    # Case 3: long_runningフィールドなし → 未検出
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: "no_flag_task_001"
  description: "フラグなしタスク"
  status: assigned
EOF

    run is_long_running_task "test_agent"
    [ "$status" -ne 0 ]

    # Case 4: タスクYAMLなし → 未検出
    rm -f "$TEST_TASKS_DIR/test_agent.yaml"

    run is_long_running_task "test_agent"
    [ "$status" -ne 0 ]
}

# =============================================================================
# TC-S10: get_pane_target() — tmuxペインターゲット解決
# =============================================================================

@test "TC-S10: get_pane_target resolves pane target from tmux" {
    # tmuxモックのlist-panes出力を設定
    cat > "$TEST_TMPDIR/mock_panes.txt" << 'EOF'
0 gryakuza
1 yakuza1
2 yakuza2
3 yakuza3
4 yakuza4
5 yakuza5
6 yakuza6
7 yakuza7
8 soukaiya
EOF

    # tmuxモック使用
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # yakuza3のペインターゲット取得
    result=$(get_pane_target "yakuza3")
    [ "$result" = "multiagent:1.3" ]

    # gryakuzaのペインターゲット取得
    result=$(get_pane_target "gryakuza")
    [ "$result" = "multiagent:1.0" ]

    # soukaiyaのペインターゲット取得
    result=$(get_pane_target "soukaiya")
    [ "$result" = "multiagent:1.8" ]

    # 存在しないエージェント → 空文字
    result=$(get_pane_target "nonexistent_agent")
    [ -z "$result" ]
}

# =============================================================================
# TC-S11: stage3_slay() — エージェントタイプ判定（model選択）
# =============================================================================

@test "TC-S11: stage3_slay uses correct model for agent types" {
    # 再起動カウンタなし
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_yakuza3.yaml"
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_soukaiya.yaml"

    # タスクYAML作成
    for agent in yakuza3 soukaiya; do
        cat > "$TEST_TASKS_DIR/${agent}.yaml" << EOF
task:
  task_id: "model_test_${agent}"
  description: "モデル判定テスト"
  status: assigned
EOF
    done

    # tmuxモック使用
    export PATH="$MOCK_TMUX_DIR:$PATH"
    > "$TEST_TMPDIR/tmux_calls.log"

    # yakuza3のslay → sonnetモデルで再起動
    stage3_slay "yakuza3" "test_reason" "multiagent:1.3"

    # tmux respawn-paneがsonnetモデルで呼ばれたことを確認
    grep -q 'respawn-pane.*--model sonnet' "$TEST_TMPDIR/tmux_calls.log"

    # ログクリア
    > "$TEST_TMPDIR/tmux_calls.log"

    # soukaiyaのslay → opusモデルで再起動
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_soukaiya.yaml"
    stage3_slay "soukaiya" "test_reason" "multiagent:1.8"

    # tmux respawn-paneがopusモデルで呼ばれたことを確認
    grep -q 'respawn-pane.*--model opus' "$TEST_TMPDIR/tmux_calls.log"
}

# =============================================================================
# TC-S12: generate_farewell_haiku() — 辞世の句生成確認
# =============================================================================

@test "TC-S12: generate_farewell_haiku returns valid haiku" {
    # 10回実行して全て非空であることを確認
    local empty_count=0
    for i in $(seq 1 10); do
        result=$(generate_farewell_haiku)
        if [ -z "$result" ]; then
            empty_count=$((empty_count + 1))
        fi
    done
    [ "$empty_count" -eq 0 ]

    # 出力が空でないことを確認
    result=$(generate_farewell_haiku)
    [ -n "$result" ]
}
