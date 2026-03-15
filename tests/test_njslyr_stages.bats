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
    show-options)
        echo "tmux show-options $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        # Return mock model name if configured
        if [ -f "${TEST_TMPDIR}/mock_model_name.txt" ]; then
            cat "${TEST_TMPDIR}/mock_model_name.txt"
        fi
        ;;
    list-panes)
        echo "tmux list-panes $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        # Return mock pane data if available
        if [ -f "${TEST_TMPDIR}/mock_panes.txt" ]; then
            cat "${TEST_TMPDIR}/mock_panes.txt"
        fi
        ;;
    list-windows)
        echo "tmux list-windows $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        # Return mock window name for get_agents_window()
        echo "kyoto"
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
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_yakuza3.yaml"

    # タスクYAML作成（yakuza3 = 有効なエージェントタイプ）
    cat > "$TEST_TASKS_DIR/yakuza3.yaml" << 'EOF'
task:
  task_id: "pre_slay_test_001"
  description: "テストタスク"
  status: assigned
  timestamp: "2026-02-18T01:00:00"
EOF

    # tmuxモック使用
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # stage3_slayを実行
    run stage3_slay "yakuza3" "test_slay_reason" "multiagent:1.3"
    [ "$status" -eq 0 ]

    # タスクYAMLのstatusが "slayed_by_njslyr" に更新されていることを確認
    run grep 'status: slayed_by_njslyr' "$TEST_TASKS_DIR/yakuza3.yaml"
    [ "$status" -eq 0 ]

    # 粛清ログが作成されていることを確認
    local slay_log_count
    slay_log_count=$(ls "$TEST_LOG_DIR"/njslyr_slay_*.yaml 2>/dev/null | wc -l)
    [ "$slay_log_count" -ge 1 ]

    # 粛清ログの内容を検証
    local slay_log
    slay_log=$(ls -t "$TEST_LOG_DIR"/njslyr_slay_*.yaml | head -1)
    grep -q 'agent_id: "yakuza3"' "$slay_log"
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
0 smith
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

    # yakuza3のペインターゲット取得 (BUG-2 fix: multiagent:kyoto.N format)
    result=$(get_pane_target "yakuza3")
    [ "$result" = "multiagent:kyoto.3" ]

    # smithのペインターゲット取得
    result=$(get_pane_target "smith")
    [ "$result" = "multiagent:kyoto.0" ]

    # soukaiyaのペインターゲット取得
    result=$(get_pane_target "soukaiya")
    [ "$result" = "multiagent:kyoto.8" ]

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
    stage3_slay "yakuza3" "test_reason" "multiagent:kyoto.3"

    # tmux respawn-paneがsonnetモデルで呼ばれたことを確認
    grep -q 'respawn-pane.*--model sonnet' "$TEST_TMPDIR/tmux_calls.log"

    # ログクリア
    > "$TEST_TMPDIR/tmux_calls.log"

    # soukaiyaのslay → opusモデルで再起動
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_soukaiya.yaml"
    stage3_slay "soukaiya" "test_reason" "multiagent:kyoto.8"

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

# =============================================================================
# TC-B3-1: agent_is_busy() — BUG-3 expanded pattern detection
# =============================================================================

@test "TC-B3-1: agent_is_busy detects expanded patterns" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    local patterns=(
        "Thinking..."
        "(thinking)"
        "thought for 3.2s"
        "Cogitated for 5.1s"
        "Working on task"
        "Generating output"
        "Planning next steps"
        "Sending request"
        "esc to interrupt"
        "思考中"
        "処理中"
        "生成中"
        "計画中"
        "送信中"
        "実行中"
    )

    for pattern in "${patterns[@]}"; do
        # Override capture-pane mock to return this pattern
        cat > "$MOCK_TMUX_DIR/tmux" << MOCK_EOF
#!/bin/bash
case "\$1" in
    capture-pane) echo "$pattern" ;;
    *) echo "" ;;
esac
exit 0
MOCK_EOF
        chmod +x "$MOCK_TMUX_DIR/tmux"

        run agent_is_busy "multiagent:kyoto.2"
        [ "$status" -eq 0 ] || {
            echo "FAIL: pattern '$pattern' not detected by agent_is_busy"
            false
        }
    done
}

# =============================================================================
# TC-B3-2: agent_is_thinking() — BUG-3 pattern detection + negative tests
# =============================================================================

@test "TC-B3-2: agent_is_thinking detects thinking patterns and rejects non-thinking" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Positive: should detect as thinking
    local thinking_patterns=(
        "Thinking..."
        "(thinking)"
        "思考中..."
        "Planning next steps"
        "考え中"
        "計画中"
    )

    for pattern in "${thinking_patterns[@]}"; do
        cat > "$MOCK_TMUX_DIR/tmux" << MOCK_EOF
#!/bin/bash
case "\$1" in
    capture-pane) echo "$pattern" ;;
    *) echo "" ;;
esac
exit 0
MOCK_EOF
        chmod +x "$MOCK_TMUX_DIR/tmux"

        run agent_is_thinking "multiagent:kyoto.2"
        [ "$status" -eq 0 ] || {
            echo "FAIL: thinking pattern '$pattern' not detected"
            false
        }
    done

    # Negative: should NOT detect as thinking
    local non_thinking_patterns=(
        "Working on the task"
        "Sending message"
        "Generating output"
        "Cogitated for 3.2s"
        "thought for 5.1s"
        "送信中"
        "生成中"
        "処理中"
        "実行中"
    )

    for pattern in "${non_thinking_patterns[@]}"; do
        cat > "$MOCK_TMUX_DIR/tmux" << MOCK_EOF
#!/bin/bash
case "\$1" in
    capture-pane) echo "$pattern" ;;
    *) echo "" ;;
esac
exit 0
MOCK_EOF
        chmod +x "$MOCK_TMUX_DIR/tmux"

        run agent_is_thinking "multiagent:kyoto.2"
        [ "$status" -ne 0 ] || {
            echo "FAIL: non-thinking pattern '$pattern' wrongly detected as thinking"
            false
        }
    done
}

# =============================================================================
# TC-B4-1-revised: check_agent() creates thinking state file on first detection
# =============================================================================

@test "TC-B4-1-revised: check_agent creates thinking state file on first thinking detection" {
    # Custom tmux mock: capture-pane returns "Thinking..."
    cat > "$MOCK_TMUX_DIR/tmux" << 'THINKING_MOCK'
#!/bin/bash
case "$1" in
    capture-pane)
        echo "Thinking..."
        ;;
    list-panes)
        if [ -f "${TEST_TMPDIR}/mock_panes.txt" ]; then
            cat "${TEST_TMPDIR}/mock_panes.txt"
        fi
        ;;
    show-options)
        echo ""
        ;;
    *)
        echo "tmux $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
esac
exit 0
THINKING_MOCK
    chmod +x "$MOCK_TMUX_DIR/tmux"
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Set up mock panes
    echo "3 yakuza3" > "$TEST_TMPDIR/mock_panes.txt"

    # Task YAML (assigned, not idle — needed to avoid idle detection)
    cat > "$TEST_TASKS_DIR/yakuza3.yaml" << 'EOF'
task:
  task_id: "thinking_test_001"
  status: assigned
EOF

    # Empty inbox (no unread — thinking is checked regardless)
    echo "messages: []" > "$TEST_INBOX_DIR/yakuza3.yaml"

    # Ensure thinking state file doesn't exist
    rm -f "$TEST_STATE_DIR/njslyr_yakuza3_thinking_start"

    run check_agent "yakuza3"
    [ "$status" -eq 0 ]

    # Thinking state file should be created
    [ -f "$TEST_STATE_DIR/njslyr_yakuza3_thinking_start" ]

    # Content should be a recent epoch timestamp
    local ts
    ts=$(cat "$TEST_STATE_DIR/njslyr_yakuza3_thinking_start")
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local diff=$((now - ts))
    [ "$diff" -lt 5 ]
}

# =============================================================================
# TC-B4-2-revised: thinking timeout triggers Stage 2 via check_agent
# =============================================================================

@test "TC-B4-2-revised: thinking timeout triggers Stage 2 escalation" {
    # Custom tmux mock: capture-pane returns "Thinking..."
    cat > "$MOCK_TMUX_DIR/tmux" << 'THINKING_MOCK'
#!/bin/bash
case "$1" in
    capture-pane)
        echo "Thinking..."
        ;;
    list-panes)
        if [ -f "${TEST_TMPDIR}/mock_panes.txt" ]; then
            cat "${TEST_TMPDIR}/mock_panes.txt"
        fi
        ;;
    send-keys)
        echo "tmux send-keys $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
    show-options)
        echo ""
        ;;
    *)
        echo "tmux $*" >> "${TEST_TMPDIR}/tmux_calls.log"
        ;;
esac
exit 0
THINKING_MOCK
    chmod +x "$MOCK_TMUX_DIR/tmux"
    export PATH="$MOCK_TMUX_DIR:$PATH"

    echo "5 yakuza5" > "$TEST_TMPDIR/mock_panes.txt"

    # Task YAML (assigned, not idle)
    cat > "$TEST_TASKS_DIR/yakuza5.yaml" << 'EOF'
task:
  task_id: "thinking_timeout_test"
  status: assigned
EOF

    # Empty inbox
    echo "messages: []" > "$TEST_INBOX_DIR/yakuza5.yaml"

    # Set thinking state file to 700 seconds ago (> THINKING_TIMEOUT=600)
    echo "$(($(date +%s) - 700))" > "$TEST_STATE_DIR/njslyr_yakuza5_thinking_start"

    # Clear stage2 cooldown (so stage2_chop is allowed)
    rm -f "$TEST_STATE_DIR/njslyr_yakuza5_stage2_last"

    # Initialize tmux_calls log
    > "$TEST_TMPDIR/tmux_calls.log"

    run check_agent "yakuza5"
    [ "$status" -eq 0 ]

    # Thinking state file should be deleted (timeout → cleanup)
    [ ! -f "$TEST_STATE_DIR/njslyr_yakuza5_thinking_start" ]

    # Stage 2 cooldown should have been set
    [ -f "$TEST_STATE_DIR/njslyr_yakuza5_stage2_last" ]
}

# =============================================================================
# TC-BUG5-1: idle_start file created on first idle detection
# =============================================================================

@test "TC-BUG5-1: idle_start file created on first idle detection" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # No task YAML → idle status
    rm -f "$TEST_TASKS_DIR/test_agent"*.yaml

    # No inbox unread (BUG-5 cost optimization fix allows idle through)
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # Set up mock panes
    echo "3 test_agent" > "$TEST_TMPDIR/mock_panes.txt"

    # Ensure idle state file doesn't exist
    rm -f "$TEST_STATE_DIR/njslyr_test_agent_idle_start"

    run check_agent "test_agent"
    [ "$status" -eq 0 ]

    # Idle state file should be created
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_idle_start" ]

    # Content should be a recent epoch timestamp
    local ts
    ts=$(cat "$TEST_STATE_DIR/njslyr_test_agent_idle_start")
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local diff=$((now - ts))
    [ "$diff" -lt 5 ]
}

# =============================================================================
# TC-BUG5-2: idle timeout triggers Stage 1 suriken
# =============================================================================

@test "TC-BUG5-2: idle timeout triggers Stage 1 suriken" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # No task YAML → idle status
    rm -f "$TEST_TASKS_DIR/test_agent"*.yaml

    # No inbox unread
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # Set up mock panes
    echo "3 test_agent" > "$TEST_TMPDIR/mock_panes.txt"

    # Set idle_start to 360 seconds ago (> IDLE_TIMEOUT=300)
    local old_ts=$(($(date +%s) - 360))
    echo "$old_ts" > "$TEST_STATE_DIR/njslyr_test_agent_idle_start"

    run check_agent "test_agent"
    [ "$status" -eq 0 ]

    # idle_start should be reset to approximately now (not the old value)
    local new_ts
    new_ts=$(cat "$TEST_STATE_DIR/njslyr_test_agent_idle_start")
    [ "$new_ts" -gt "$old_ts" ]

    # Stage 1 cooldown should have been set
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_stage1_last" ]

    # Suriken should have been sent via inbox_write.sh (creates inbox entry)
    grep -q 'read: [Ff]alse' "$TEST_INBOX_DIR/test_agent.yaml"
}

# =============================================================================
# TC-BUG5-3: idle tracking cleared when agent gets a task
# =============================================================================

@test "TC-BUG5-3: idle tracking cleared when agent gets a task" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Create task YAML (not idle)
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'YAMLEOF'
task:
  task_id: active_task_001
  status: assigned
YAMLEOF

    # Create stale idle_start file
    echo "$(($(date +%s) - 100))" > "$TEST_STATE_DIR/njslyr_test_agent_idle_start"
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_idle_start" ]

    # Set up mock panes
    echo "3 test_agent" > "$TEST_TMPDIR/mock_panes.txt"
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    run check_agent "test_agent"

    # idle_start file should be removed
    [ ! -f "$TEST_STATE_DIR/njslyr_test_agent_idle_start" ]
}

# =============================================================================
# TC-S13: stage3_slay respects @model_name=Opus (BUG-1 fix)
# =============================================================================

@test "TC-S13: stage3_slay respects @model_name=Opus" {
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_yakuza3.yaml"

    cat > "$TEST_TASKS_DIR/yakuza3.yaml" << 'EOF'
task:
  task_id: "model_name_opus_test"
  status: assigned
EOF

    # Mock tmux: show-options returns "Opus" for @model_name
    echo "Opus" > "$TEST_TMPDIR/mock_model_name.txt"

    # Set up mock panes
    echo "3 yakuza3" > "$TEST_TMPDIR/mock_panes.txt"

    export PATH="$MOCK_TMUX_DIR:$PATH"
    > "$TEST_TMPDIR/tmux_calls.log"

    run stage3_slay "yakuza3" "test_reason" "multiagent:kyoto.3"
    [ "$status" -eq 0 ]

    # respawn-pane should use opus model
    grep -q 'respawn-pane.*--model opus' "$TEST_TMPDIR/tmux_calls.log"

    # select-pane should restore bg=#1a002e (barikidorink purple)
    grep -q 'select-pane.*bg=#1a002e' "$TEST_TMPDIR/tmux_calls.log"
}

# =============================================================================
# TC-S14: stage3_slay falls back to default when @model_name is empty (BUG-1)
# =============================================================================

@test "TC-S14: stage3_slay falls back to default when @model_name is empty" {
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_yakuza3.yaml"
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_soukaiya.yaml"

    for agent in yakuza3 soukaiya; do
        cat > "$TEST_TASKS_DIR/${agent}.yaml" << EOF
task:
  task_id: "fallback_test_${agent}"
  status: assigned
EOF
    done

    # Mock tmux: show-options returns empty (no @model_name)
    rm -f "$TEST_TMPDIR/mock_model_name.txt"

    export PATH="$MOCK_TMUX_DIR:$PATH"

    # yakuza3: should default to sonnet
    > "$TEST_TMPDIR/tmux_calls.log"
    run stage3_slay "yakuza3" "test_reason" "multiagent:kyoto.3"
    [ "$status" -eq 0 ]
    grep -q 'respawn-pane.*--model sonnet' "$TEST_TMPDIR/tmux_calls.log"
    grep -q 'select-pane.*bg=default' "$TEST_TMPDIR/tmux_calls.log"

    # soukaiya: should default to opus
    > "$TEST_TMPDIR/tmux_calls.log"
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_soukaiya.yaml"
    run stage3_slay "soukaiya" "test_reason" "multiagent:kyoto.8"
    [ "$status" -eq 0 ]
    grep -q 'respawn-pane.*--model opus' "$TEST_TMPDIR/tmux_calls.log"
}

# =============================================================================
# TC-S15: get_pane_target returns multiagent:kyoto.N format (BUG-2 fix)
# =============================================================================

@test "TC-S15: get_pane_target returns multiagent:kyoto.N format" {
    # Mock panes with various agents
    cat > "$TEST_TMPDIR/mock_panes.txt" << 'EOF'
0 smith
1 yakuza1
5 yakuza5
8 soukaiya
EOF

    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Verify multiagent:kyoto.N format (not multiagent:1.N)
    result=$(get_pane_target "yakuza1")
    [ "$result" = "multiagent:kyoto.1" ]
    [[ "$result" != *"multiagent:1."* ]]

    result=$(get_pane_target "yakuza5")
    [ "$result" = "multiagent:kyoto.5" ]

    result=$(get_pane_target "smith")
    [ "$result" = "multiagent:kyoto.0" ]

    result=$(get_pane_target "soukaiya")
    [ "$result" = "multiagent:kyoto.8" ]
}

# =============================================================================
# TC-S16: stage3_slay restores bg=default for Sonnet agents (BUG-1 fix)
# =============================================================================

@test "TC-S16: stage3_slay restores bg=default for Sonnet agents" {
    rm -f "$TEST_METRICS_DIR/njslyr_restarts_yakuza2.yaml"

    cat > "$TEST_TASKS_DIR/yakuza2.yaml" << 'EOF'
task:
  task_id: "sonnet_bg_test"
  status: assigned
EOF

    # Mock tmux: show-options returns "Sonnet"
    echo "Sonnet" > "$TEST_TMPDIR/mock_model_name.txt"

    export PATH="$MOCK_TMUX_DIR:$PATH"
    > "$TEST_TMPDIR/tmux_calls.log"

    run stage3_slay "yakuza2" "test_reason" "multiagent:kyoto.2"
    [ "$status" -eq 0 ]

    # respawn-pane should use sonnet model
    grep -q 'respawn-pane.*--model sonnet' "$TEST_TMPDIR/tmux_calls.log"

    # select-pane should restore bg=default (not purple)
    grep -q 'select-pane.*bg=default' "$TEST_TMPDIR/tmux_calls.log"

    # bg=#1a002e should NOT appear (it's for Opus only)
    ! grep -q 'bg=#1a002e' "$TEST_TMPDIR/tmux_calls.log"
}

# =============================================================================
# TC-BUG6-1: inbox_watcher_recently_cleared detects shared clear lock
# =============================================================================

@test "TC-BUG6-1: inbox_watcher_recently_cleared detects shared clear lock" {
    # Case 1: No lock file → not recently cleared (return 1)
    rm -f "$TEST_STATE_DIR/clear_last_test_agent"
    run inbox_watcher_recently_cleared "test_agent"
    [ "$status" -eq 1 ]

    # Case 2: Lock file with recent timestamp (60s ago) → recently cleared (return 0)
    echo "$(($(date +%s) - 60))" > "$TEST_STATE_DIR/clear_last_test_agent"
    run inbox_watcher_recently_cleared "test_agent"
    [ "$status" -eq 0 ]

    # Case 3: Lock file with old timestamp (600s ago, > 300s threshold) → not recent (return 1)
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/clear_last_test_agent"
    run inbox_watcher_recently_cleared "test_agent"
    [ "$status" -eq 1 ]
}

# =============================================================================
# TC-BUG6-2: stage2_chop writes shared clear lock
# =============================================================================

@test "TC-BUG6-2: stage2_chop writes shared clear lock" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Ensure lock file doesn't exist
    rm -f "$TEST_STATE_DIR/clear_last_test_agent"

    # Run stage2_chop
    run stage2_chop "test_agent" "test_chop_reason"
    [ "$status" -eq 0 ]

    # Shared clear lock file should exist
    [ -f "$TEST_STATE_DIR/clear_last_test_agent" ]

    # Content should be a recent epoch timestamp
    local ts
    ts=$(cat "$TEST_STATE_DIR/clear_last_test_agent")
    [[ "$ts" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    local diff=$((now - ts))
    [ "$diff" -lt 5 ]

    # Stage 2 timestamp file should also exist
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_stage2_last" ]
}

# =============================================================================
# TC-01: should_spawn_yakuzatengu: inbox未読>=5でtrue（P0）
# =============================================================================

@test "TC-01: should_spawn_yakuzatengu returns true when inbox unread >= 5" {
    # yakuzatengu不活性
    rm -f "$TEST_STATE_DIR/yakuzatengu_active"

    # smith inbox: 5件未読（本番形式: 行頭アンカー付きread: false）
    cat > "$TEST_INBOX_DIR/smith.yaml" << 'EOF'
messages:
- id: m1
  read: false
  content: msg1
  from: a
  type: t
  timestamp: t1
- id: m2
  read: false
  content: msg2
  from: a
  type: t
  timestamp: t2
- id: m3
  read: false
  content: msg3
  from: a
  type: t
  timestamp: t3
- id: m4
  read: false
  content: msg4
  from: a
  type: t
  timestamp: t4
- id: m5
  read: false
  content: msg5
  from: a
  type: t
  timestamp: t5
EOF

    # アイドルyakuza存在（spawn実行に必要）
    echo "$(date +%s)" > "$TEST_STATE_DIR/njslyr_yakuza1_idle_start"

    # BUG-B2対応: get_monitored_agentsをoverride（yakuza1を返す）
    get_monitored_agents() { printf 'yakuza1\n'; }

    should_spawn_yakuzatengu "smith"
    [ $? -eq 0 ]
}

# =============================================================================
# TC-02: should_spawn_yakuzatengu: アイドルyakuza>=3体×300秒でtrue（P0）
# =============================================================================

@test "TC-02: should_spawn_yakuzatengu returns true when 3+ yakuza idle for 300s" {
    # yakuzatengu不活性
    rm -f "$TEST_STATE_DIR/yakuzatengu_active"

    # smith inbox: 未読なし（条件2のみで判定）
    echo "messages: []" > "$TEST_INBOX_DIR/smith.yaml"

    # get_monitored_agentsをoverride（yakuza1/2/3を返す）
    get_monitored_agents() { printf 'yakuza1\nyakuza2\nyakuza3\n'; }

    # 3体のidle_startファイルを400秒前に設定（>300秒）
    local old_ts=$(($(date +%s) - 400))
    for yid in yakuza1 yakuza2 yakuza3; do
        echo "$old_ts" > "$TEST_STATE_DIR/njslyr_${yid}_idle_start"
    done

    should_spawn_yakuzatengu "smith"
    [ $? -eq 0 ]
}

# =============================================================================
# TC-03: should_spawn_yakuzatengu: 二重spawn防止（P0）
# =============================================================================

@test "TC-03: should_spawn_yakuzatengu returns false when yakuzatengu already active" {
    # yakuzatengu既にactive
    touch "$TEST_STATE_DIR/yakuzatengu_active"

    # smith inbox: 5件未読（条件は満たす）
    cat > "$TEST_INBOX_DIR/smith.yaml" << 'EOF'
messages:
- {id: m1, read: false, content: msg1, from: a, type: t, timestamp: t1}
- {id: m2, read: false, content: msg2, from: a, type: t, timestamp: t2}
- {id: m3, read: false, content: msg3, from: a, type: t, timestamp: t3}
- {id: m4, read: false, content: msg4, from: a, type: t, timestamp: t4}
- {id: m5, read: false, content: msg5, from: a, type: t, timestamp: t5}
EOF

    # 二重spawn防止 → return 1 (run使用でset -eを回避)
    run should_spawn_yakuzatengu "smith"
    [ "$status" -ne 0 ]
}

# =============================================================================
# TC-04: should_spawn_yakuzatengu: 条件未達でfalse（P0）
# =============================================================================

@test "TC-04: should_spawn_yakuzatengu returns false when no conditions met" {
    # yakuzatengu不活性
    rm -f "$TEST_STATE_DIR/yakuzatengu_active"

    # smith inbox: 未読なし
    echo "messages: []" > "$TEST_INBOX_DIR/smith.yaml"

    # get_monitored_agentsをoverride（idle yakuzaなし）
    get_monitored_agents() { printf 'yakuza1\nyakuza2\n'; }

    # idle_startファイルなし
    rm -f "$TEST_STATE_DIR/njslyr_yakuza1_idle_start"
    rm -f "$TEST_STATE_DIR/njslyr_yakuza2_idle_start"

    # 条件未達 → return 1 (run使用でset -eを回避)
    run should_spawn_yakuzatengu "smith"
    [ "$status" -ne 0 ]
}

# =============================================================================
# TC-05: should_despawn_yakuzatengu: 2サイクル確認（1→pending、2→despawn）（P0）
# =============================================================================

@test "TC-05: should_despawn_yakuzatengu: 2-cycle confirmation for despawn" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # smith pane設定
    echo "0 smith" > "$TEST_TMPDIR/mock_panes.txt"

    # smith inbox: 未読なし（復帰条件満足）
    echo "messages: []" > "$TEST_INBOX_DIR/smith.yaml"

    # spawn_time: 600秒前（Guard時間超過）
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    # pending_fileなし（1サイクル目）
    rm -f "$TEST_STATE_DIR/yakuzatengu_despawn_pending"

    # 1サイクル目: pending記録 → return 1 (run使用でset -eを回避)
    run should_despawn_yakuzatengu
    [ "$status" -ne 0 ]

    # pending_fileが作成されているはず
    [ -f "$TEST_STATE_DIR/yakuzatengu_despawn_pending" ]

    # 2サイクル目: pending存在 → return 0（despawn実行）
    run should_despawn_yakuzatengu
    [ "$status" -eq 0 ]
}

# =============================================================================
# TC-06: should_despawn_yakuzatengu: Guard時間（spawn後300秒未満はdespawn禁止）（P0）
# =============================================================================

@test "TC-06: should_despawn_yakuzatengu blocks despawn within 300s guard period" {
    # spawn_time: 100秒前（Guard時間内）
    echo "$(($(date +%s) - 100))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    # Guard時間内 → return 1 (run使用でset -eを回避)
    run should_despawn_yakuzatengu
    [ "$status" -ne 0 ]
}

# =============================================================================
# TC-07: cleanup_yakuzatengu_state: 全STATEファイル+clear_last削除（P1）
# =============================================================================

@test "TC-07: cleanup_yakuzatengu_state deletes all STATE files including clear_last" {
    # 全STATEファイルを作成
    touch "$TEST_STATE_DIR/yakuzatengu_active"
    echo "yakuza1" > "$TEST_STATE_DIR/yakuzatengu_original_agent_id"
    echo "multiagent:kyoto.1" > "$TEST_STATE_DIR/yakuzatengu_original_pane"
    echo "Sonnet" > "$TEST_STATE_DIR/yakuzatengu_original_model"
    echo "12345" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"
    touch "$TEST_STATE_DIR/yakuzatengu_despawn_pending"
    touch "$TEST_STATE_DIR/yakuzatengu_done"
    touch "$TEST_STATE_DIR/clear_last_yakuzatengu"
    touch "$TEST_STATE_DIR/njslyr_yakuzatengu_thinking_start"
    touch "$TEST_STATE_DIR/njslyr_yakuzatengu_idle_start"

    # cleanup実行
    cleanup_yakuzatengu_state

    # 全ファイルが削除されているはず
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_active" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_agent_id" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_pane" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_model" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_spawn_time" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_despawn_pending" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_done" ]
    [ ! -f "$TEST_STATE_DIR/clear_last_yakuzatengu" ]
    [ ! -f "$TEST_STATE_DIR/njslyr_yakuzatengu_thinking_start" ]
    [ ! -f "$TEST_STATE_DIR/njslyr_yakuzatengu_idle_start" ]
}

# =============================================================================
# TC-08: yakuzatengu_done自己despawnシグナル: 即座despawn（P1）
# =============================================================================

@test "TC-08: should_despawn_yakuzatengu triggers immediately on yakuzatengu_done signal" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # spawn_time: 600秒前（Guard時間超過）
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    # 自己despawnシグナル: yakuzatengu_done作成
    touch "$TEST_STATE_DIR/yakuzatengu_done"

    # smith inbox: 未読多い（復帰条件を満たさない状態でもdoneシグナルで即座despawn）
    cat > "$TEST_INBOX_DIR/smith.yaml" << 'EOF'
messages:
- {id: m1, read: false, content: msg1, from: a, type: t, timestamp: t1}
- {id: m2, read: false, content: msg2, from: a, type: t, timestamp: t2}
- {id: m3, read: false, content: msg3, from: a, type: t, timestamp: t3}
- {id: m4, read: false, content: msg4, from: a, type: t, timestamp: t4}
- {id: m5, read: false, content: msg5, from: a, type: t, timestamp: t5}
EOF

    # yakuzatengu_doneシグナルで即座despawn
    should_despawn_yakuzatengu
    [ $? -eq 0 ]
}

# =============================================================================
# TC-09: idle_threshold判定: idle_count<3時にpendingリセット（P1）
# =============================================================================

@test "TC-09: should_despawn_yakuzatengu resets pending when conditions not met" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # テスト分離: TC-08が残したyakuzatengu_doneを確実にクリア（即座despawnシグナルを排除）
    rm -f "$TEST_STATE_DIR/yakuzatengu_done"

    # spawn_time: 600秒前（Guard時間超過）
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    # smith inbox: 未読多い（復帰条件未満・BUG-B3/B4対応: multi-line形式）
    cat > "$TEST_INBOX_DIR/smith.yaml" << 'EOF'
messages:
- id: m1
  read: false
  content: msg1
  from: a
  type: t
  timestamp: t1
- id: m2
  read: false
  content: msg2
  from: a
  type: t
  timestamp: t2
- id: m3
  read: false
  content: msg3
  from: a
  type: t
  timestamp: t3
EOF

    # pending_file存在（前サイクルで1サイクル目を通過した想定）
    touch "$TEST_STATE_DIR/yakuzatengu_despawn_pending"

    # 条件不充足 → pendingをリセット → return 1 (run使用でset -eを回避)
    run should_despawn_yakuzatengu
    [ "$status" -ne 0 ]

    # pending_fileが削除されているはず
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_despawn_pending" ]
}

# =============================================================================
# TC-10: 4時間上限: spawn_time+14400秒超過で強制despawn（P1）
# =============================================================================

@test "TC-10: should_despawn_yakuzatengu forces despawn after 4-hour limit" {
    # spawn_time: 14401秒前（4時間超過）
    echo "$(($(date +%s) - 14401))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    should_despawn_yakuzatengu
    [ $? -eq 0 ]
}

# =============================================================================
# TC-11: spawn respawn失敗時のSTATEロールバック（P2）
# =============================================================================

@test "TC-11: spawn_yakuzatengu rolls back STATE files on respawn failure" {
    # respawn-pane（--model付き）のみ失敗するtmuxモック
    export PATH="$MOCK_TMUX_DIR:$PATH"
    local bg_log="$TEST_TMPDIR/select_pane_bg.log"
    cat > "$MOCK_TMUX_DIR/tmux" << ALWAYSFAIL_MOCK
#!/bin/bash
case "\$1" in
    respawn-pane)
        # 2回目（claude --model）は失敗
        if echo "\$*" | grep -q -- "--model"; then
            exit 1
        fi
        exit 0
        ;;
    list-panes)
        if [ -f "${TEST_TMPDIR}/mock_panes.txt" ]; then cat "${TEST_TMPDIR}/mock_panes.txt"; fi
        ;;
    show-options) echo "Sonnet" ;;
    select-pane)
        # BUG-T3: bg_color復元コールを記録
        echo "\$*" >> "${bg_log}"
        ;;
    *) ;;
esac
exit 0
ALWAYSFAIL_MOCK
    chmod +x "$MOCK_TMUX_DIR/tmux"

    # アイドルyakuza設定（get_pane_target用: INDEX agent_id形式）
    echo "3 yakuza3" > "$TEST_TMPDIR/mock_panes.txt"
    echo "$(($(date +%s) - 400))" > "$TEST_STATE_DIR/njslyr_yakuza3_idle_start"

    # smith inbox（spawn判定用）
    echo "messages: []" > "$TEST_INBOX_DIR/smith.yaml"

    # yakuzatengu不活性
    rm -f "$TEST_STATE_DIR/yakuzatengu_active"

    # BUG-T3: yakuza3のタスクYAML（status: assigned）を準備
    local task_yaml="$TEST_TASKS_DIR/yakuza3_test_task.yaml"
    printf 'task:\n  task_id: test_t3\n  status: assigned\n' > "$task_yaml"

    # get_monitored_agentsをoverride（mock_panes.txtの2フィールド問題を回避）
    get_monitored_agents() { printf 'yakuza3\n'; }

    # spawn実行 → respawn失敗 → ロールバック
    spawn_yakuzatengu "smith" || true

    # STATEファイルがロールバックされているはず
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_active" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_agent_id" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_pane" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_model" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_spawn_time" ]

    # BUG-T3: bg_colorが元に戻っているはず（Sonnet → default）
    grep -q 'bg=default' "$bg_log"

    # BUG-T3: task YAML statusがassignedに戻っているはず（done/suspendedではない）
    grep -q 'status: assigned' "$task_yaml"
    ! grep -q 'status: suspended' "$task_yaml"
    ! grep -q 'status: done' "$task_yaml"
}

# =============================================================================
# TC-12: despawn respawn失敗時STATE保持（次サイクル再試行）（P2）
# =============================================================================

@test "TC-12: despawn_yakuzatengu keeps STATE when respawn fails" {
    # respawn-pane失敗モック
    cat > "$MOCK_TMUX_DIR/tmux" << 'FAIL_MOCK'
#!/bin/bash
case "$1" in
    respawn-pane) exit 1 ;;
    *) ;;
esac
exit 0
FAIL_MOCK
    chmod +x "$MOCK_TMUX_DIR/tmux"
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # STATE設定
    touch "$TEST_STATE_DIR/yakuzatengu_active"
    echo "yakuza3" > "$TEST_STATE_DIR/yakuzatengu_original_agent_id"
    echo "multiagent:kyoto.3" > "$TEST_STATE_DIR/yakuzatengu_original_pane"
    echo "Sonnet" > "$TEST_STATE_DIR/yakuzatengu_original_model"
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/yakuzatengu_spawn_time"

    # despawn実行 → respawn失敗 → STATE保持
    run despawn_yakuzatengu
    [ "$status" -ne 0 ]

    # STATEファイルが保持されているはず
    [ -f "$TEST_STATE_DIR/yakuzatengu_active" ]
    [ -f "$TEST_STATE_DIR/yakuzatengu_original_agent_id" ]
}

# =============================================================================
# TC-13: spawn→despawnライフサイクル統合テスト（P2）
# =============================================================================

@test "TC-13: spawn_yakuzatengu and despawn_yakuzatengu full lifecycle" {
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # Mock panes
    echo "1 yakuza1" > "$TEST_TMPDIR/mock_panes.txt"

    # アイドルyakuza1: 400秒前からアイドル
    echo "$(($(date +%s) - 400))" > "$TEST_STATE_DIR/njslyr_yakuza1_idle_start"

    # タスクYAML
    cat > "$TEST_TASKS_DIR/yakuza1.yaml" << 'EOF'
task:
  task_id: lifecycle_test_001
  status: assigned
EOF

    # smith inbox
    echo "messages: []" > "$TEST_INBOX_DIR/smith.yaml"

    # yakuzatengu inbox初期化
    echo "messages: []" > "$TEST_INBOX_DIR/yakuzatengu.yaml"

    # yakuzatengu不活性
    rm -f "$TEST_STATE_DIR/yakuzatengu_active"

    # get_monitored_agentsをoverride
    get_monitored_agents() { printf 'yakuza1\n'; }

    > "$TEST_TMPDIR/tmux_calls.log"

    # === spawn実行 ===
    spawn_yakuzatengu "smith"
    [ $? -eq 0 ]

    # STATEファイルが作成されているはず
    [ -f "$TEST_STATE_DIR/yakuzatengu_active" ]
    [ -f "$TEST_STATE_DIR/yakuzatengu_original_agent_id" ]
    [ -f "$TEST_STATE_DIR/yakuzatengu_original_pane" ]
    [ -f "$TEST_STATE_DIR/yakuzatengu_original_model" ]
    [ -f "$TEST_STATE_DIR/yakuzatengu_spawn_time" ]

    # 元yakuza1のidle_startが削除されているはず（M-8）
    [ ! -f "$TEST_STATE_DIR/njslyr_yakuza1_idle_start" ]

    # @agent_idがyakuzatenguに設定されているはず
    grep -q 'set-option.*@agent_id.*yakuzatengu' "$TEST_TMPDIR/tmux_calls.log"

    # bg_color=#3a0025が設定されているはず（M-9）
    grep -q 'select-pane.*bg=#3a0025' "$TEST_TMPDIR/tmux_calls.log"

    # タスクYAMLがsuspendedに変更されているはず（S-3）
    grep -q 'status: suspended' "$TEST_TASKS_DIR/yakuza1.yaml"

    # === despawn実行 ===
    > "$TEST_TMPDIR/tmux_calls.log"
    despawn_yakuzatengu
    [ $? -eq 0 ]

    # STATEファイルがcleanupされているはず
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_active" ]
    [ ! -f "$TEST_STATE_DIR/yakuzatengu_original_agent_id" ]

    # @agent_idがyakuza1に復元されているはず
    grep -q 'set-option.*@agent_id.*yakuza1' "$TEST_TMPDIR/tmux_calls.log"
}

# =============================================================================
# BUG-IDLE-1〜4: check_agent_idle_v2() — idle判定ロジック
# =============================================================================

@test "BUG-IDLE-1: check_agent_idle_v2 does not idle during grace period" {
    # モックtmuxをPATHに追加（get_pane_targetがtest_agentペインを返さないようにする）
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # clear_last = 現在時刻（grace期間内: 60秒前）
    echo "$(($(date +%s) - 60))" > "$TEST_STATE_DIR/clear_last_test_agent"

    # タスクYAML: status=idle
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: idle_test_001
  status: idle
EOF

    # inbox: unreadなし
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # check_agent_idle_v2は1（not idle）を返すはず（grace期間内）
    run check_agent_idle_v2 "test_agent"
    [ "$status" -eq 1 ]
}

@test "BUG-IDLE-2: check_agent_idle_v2 returns idle after grace period with task status idle" {
    # モックtmuxをPATHに追加
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # clear_last = 1000秒前（grace期間180秒を超過）
    echo "$(($(date +%s) - 1000))" > "$TEST_STATE_DIR/clear_last_test_agent"

    # タスクYAML: status=idle
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: idle_test_002
  status: idle
EOF

    # inbox: unreadなし
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # check_agent_idle_v2は0（idle）を返すはず
    run check_agent_idle_v2 "test_agent"
    [ "$status" -eq 0 ]
}

@test "BUG-IDLE-3: check_agent_idle_v2 does not idle when inbox has unread messages" {
    # モックtmuxをPATHに追加
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # clear_last = 1000秒前（grace期間超過）
    echo "$(($(date +%s) - 1000))" > "$TEST_STATE_DIR/clear_last_test_agent"

    # タスクYAML: status=idle
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: idle_test_003
  status: idle
EOF

    # inbox: 'read: false' のメッセージあり（has_inbox_unread()がtrueを返す）
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'EOF'
messages:
- content: test message
  from: smith
  id: msg_test_001
  priority: P2
  read: false
  timestamp: '2026-02-26T10:00:00'
  type: task_assigned
EOF

    # check_agent_idle_v2は1（not idle）を返すはず（inbox unreadあり）
    run check_agent_idle_v2 "test_agent"
    [ "$status" -eq 1 ]
}

@test "BUG-IDLE-4: check_agent_idle_v2 does not idle when task status is assigned" {
    # モックtmuxをPATHに追加
    export PATH="$MOCK_TMUX_DIR:$PATH"

    # clear_last = 1000秒前（grace期間超過）
    echo "$(($(date +%s) - 1000))" > "$TEST_STATE_DIR/clear_last_test_agent"

    # タスクYAML: status=assigned（作業中）
    cat > "$TEST_TASKS_DIR/test_agent.yaml" << 'EOF'
task:
  task_id: idle_test_004
  status: assigned
EOF

    # inbox: unreadなし
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # check_agent_idle_v2は1（not idle）を返すはず（task_status≠idle）
    run check_agent_idle_v2 "test_agent"
    [ "$status" -eq 1 ]
}

# =============================================================================
# BUG-STALE-1〜2: check_stale_state() — staleタイムスタンプファイル削除
# =============================================================================

@test "BUG-STALE-1: check_stale_state deletes stale stage_last file" {
    # stage1_lastに2時間前のタイムスタンプを設定（STALE_THRESHOLD=3600秒を超過）
    echo "$(($(date +%s) - 7200))" > "$TEST_STATE_DIR/njslyr_test_agent_stage1_last"

    # check_stale_stateを実行（ファイル削除が行われる）
    run check_stale_state "test_agent"
    [ "$status" -eq 0 ]

    # staleなstage1_lastが削除されているはず
    [ ! -f "$TEST_STATE_DIR/njslyr_test_agent_stage1_last" ]
}

@test "BUG-STALE-2: check_stale_state keeps fresh stage_last file" {
    # stage1_lastに10分前のタイムスタンプを設定（STALE_THRESHOLD=3600秒以内）
    echo "$(($(date +%s) - 600))" > "$TEST_STATE_DIR/njslyr_test_agent_stage1_last"

    # check_stale_stateを実行
    run check_stale_state "test_agent"
    [ "$status" -eq 0 ]

    # 新しいstage1_lastは削除されずに残っているはず
    [ -f "$TEST_STATE_DIR/njslyr_test_agent_stage1_last" ]
}

# =============================================================================
# TC-B4-1: check_long_running_refresh — REFRESH_INTERVAL経過後にidle_startが削除される
# =============================================================================

@test "TC-B4-1: check_long_running_refresh deletes idle_start after REFRESH_INTERVAL" {
    # Setup: njslyr_last_refresh = epoch 0（遠い過去 → elapsed >> REFRESH_INTERVAL=14400）
    echo "0" > "$TEST_STATE_DIR/njslyr_last_refresh"

    # idle_startファイルを作成し、mtimeを31分前に設定（find -mmin +30 の対象にする）
    local idle_file="$TEST_STATE_DIR/njslyr_test_agent_idle_start"
    touch "$idle_file"
    local past_epoch=$(( $(date +%s) - 1860 ))  # 31分前
    local past_time
    past_time=$(date -j -f '%s' "$past_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d "@$past_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)
    [ -n "$past_time" ] && touch -t "$past_time" "$idle_file"

    # check_long_running_refresh実行
    run check_long_running_refresh
    [ "$status" -eq 0 ]

    # idle_startファイルが削除されているはず（>30分経過かつREFRESH_INTERVAL超過）
    [ ! -f "$idle_file" ]

    # njslyr_last_refreshが現在時刻で更新されているはず
    local new_refresh
    new_refresh=$(cat "$TEST_STATE_DIR/njslyr_last_refresh")
    [[ "$new_refresh" =~ ^[0-9]+$ ]]
    local now
    now=$(date +%s)
    [ "$new_refresh" -gt "$((now - 5))" ]
}

# =============================================================================
# TC-B4-2: check_long_running_refresh — REFRESH_INTERVAL未経過時はリフレッシュしない
# =============================================================================

@test "TC-B4-2: check_long_running_refresh does not refresh when REFRESH_INTERVAL not elapsed" {
    # Setup: njslyr_last_refresh = 現在時刻（elapsed ≈ 0 << REFRESH_INTERVAL=14400）
    local now
    now=$(date +%s)
    echo "$now" > "$TEST_STATE_DIR/njslyr_last_refresh"

    # idle_startファイルを作成（リフレッシュが走らないので削除されないはず）
    local idle_file="$TEST_STATE_DIR/njslyr_test_agent_idle_start"
    touch "$idle_file"

    # check_long_running_refresh実行
    run check_long_running_refresh
    [ "$status" -eq 0 ]

    # idle_startファイルが残っているはず（REFRESH_INTERVAL未経過 → リフレッシュなし）
    [ -f "$idle_file" ]

    # njslyr_last_refreshが更新されていないはず（セットした値のまま）
    local current_refresh
    current_refresh=$(cat "$TEST_STATE_DIR/njslyr_last_refresh")
    [ "$current_refresh" -eq "$now" ]
}
