#!/usr/bin/env bats
# test_barikidorink.bats — バリキドリンク投与・解除ヘルパー関数ユニットテスト
# 自己研鑽タスク: yakuza2
#
# テスト構成:
#   T-BK-001: inject_barikidorink — 関数定義がyokubari.shに存在
#   T-BK-002: inject_barikidorink — 関数定義がnjslyr.shに存在
#   T-BK-003: detox_barikidorink — 関数定義がyokubari.shに存在
#   T-BK-004: detox_barikidorink — 関数定義がnjslyr.shに存在
#   T-BK-005: inject_barikidorink — /model opus を送信
#   T-BK-006: inject_barikidorink — @model_name を Opus に設定
#   T-BK-007: inject_barikidorink — 背景色を #1a002e に変更
#   T-BK-008: inject_barikidorink — /clear を送信
#   T-BK-009: detox_barikidorink — /model sonnet を送信
#   T-BK-010: detox_barikidorink — @model_name を Sonnet に設定
#   T-BK-011: detox_barikidorink — 背景色を default に戻す
#   T-BK-012: detox_barikidorink — /clear を送信
#   T-BK-013: inject_barikidorink — コマンド実行順序が正しい
#   T-BK-014: detox_barikidorink — コマンド実行順序が正しい
#   T-BK-015: inject_barikidorink — 引数なし呼び出しで空paneを使用
#   T-BK-016: detox_barikidorink — 引数なし呼び出しで空paneを使用
#   T-BK-017: yokubari.sh と njslyr.sh の関数定義が一致

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export YOKUBARI_SCRIPT="$PROJECT_ROOT/yokubari.sh"
    export NJSLYR_SCRIPT="$PROJECT_ROOT/scripts/njslyr.sh"
    [ -f "$YOKUBARI_SCRIPT" ] || return 1
    [ -f "$NJSLYR_SCRIPT" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/barikidorink_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    # Test harness: extract barikidorink functions from yokubari.sh with mocked externals
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash

# Mock tmux — record all calls
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    return 0
}

# Mock sleep — no-op for speed
sleep() { :; }

export -f tmux sleep

# Extract and define the barikidorink functions from yokubari.sh
# Using sed to extract function bodies
eval "\$(sed -n '/^inject_barikidorink()/,/^}/p' "$YOKUBARI_SCRIPT")"
eval "\$(sed -n '/^detox_barikidorink()/,/^}/p' "$YOKUBARI_SCRIPT")"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# 関数定義存在テスト (static analysis)
# =============================================================================

@test "T-BK-001: inject_barikidorink is defined in yokubari.sh" {
    grep -q '^inject_barikidorink()' "$YOKUBARI_SCRIPT"
}

@test "T-BK-002: inject_barikidorink is defined in njslyr.sh" {
    grep -q '^inject_barikidorink()' "$NJSLYR_SCRIPT"
}

@test "T-BK-003: detox_barikidorink is defined in yokubari.sh" {
    grep -q '^detox_barikidorink()' "$YOKUBARI_SCRIPT"
}

@test "T-BK-004: detox_barikidorink is defined in njslyr.sh" {
    grep -q '^detox_barikidorink()' "$NJSLYR_SCRIPT"
}

# =============================================================================
# inject_barikidorink tmuxコマンド列テスト
# =============================================================================

@test "T-BK-005: inject_barikidorink sends /model opus" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t multiagent:0.1 /model opus$' "$MOCK_LOG"
    grep -q 'send-keys -t multiagent:0.1 Escape' "$MOCK_LOG"
    grep -q 'send-keys -t multiagent:0.1 Enter' "$MOCK_LOG"
}

@test "T-BK-006: inject_barikidorink sets @model_name to Opus" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    grep -q 'set-option -p -t multiagent:0.1 @model_name Opus' "$MOCK_LOG"
}

@test "T-BK-007: inject_barikidorink changes background to #1a002e" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    grep -q 'select-pane -t multiagent:0.1 -P bg=#1a002e' "$MOCK_LOG"
}

@test "T-BK-008: inject_barikidorink sends /clear" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t multiagent:0.1 /clear$' "$MOCK_LOG"
}

# =============================================================================
# detox_barikidorink tmuxコマンド列テスト
# =============================================================================

@test "T-BK-009: detox_barikidorink sends /model sonnet" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t multiagent:0.1 /model sonnet$' "$MOCK_LOG"
    grep -q 'send-keys -t multiagent:0.1 Escape' "$MOCK_LOG"
    grep -q 'send-keys -t multiagent:0.1 Enter' "$MOCK_LOG"
}

@test "T-BK-010: detox_barikidorink sets @model_name to Sonnet" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    grep -q 'set-option -p -t multiagent:0.1 @model_name Sonnet' "$MOCK_LOG"
}

@test "T-BK-011: detox_barikidorink resets background to default" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    grep -q 'select-pane -t multiagent:0.1 -P bg=default' "$MOCK_LOG"
}

@test "T-BK-012: detox_barikidorink sends /clear" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink 'multiagent:0.1'"
    [ "$status" -eq 0 ]

    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t multiagent:0.1 /clear$' "$MOCK_LOG"
}

# =============================================================================
# コマンド実行順序テスト
# =============================================================================

@test "T-BK-013: inject_barikidorink executes commands in correct order" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink 'multiagent:0.3'"
    [ "$status" -eq 0 ]

    # Expected order: /model opus → set-option @model_name → select-pane bg → /clear
    local line_model line_setopt line_bg line_clear
    line_model=$(grep -n '/model opus' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_setopt=$(grep -n '@model_name Opus' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_bg=$(grep -n 'bg=#1a002e' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_clear=$(grep -n '/clear' "$MOCK_LOG" | head -1 | cut -d: -f1)

    [ "$line_model" -lt "$line_setopt" ]
    [ "$line_setopt" -lt "$line_bg" ]
    [ "$line_bg" -lt "$line_clear" ]
}

@test "T-BK-014: detox_barikidorink executes commands in correct order" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink 'multiagent:0.3'"
    [ "$status" -eq 0 ]

    # Expected order: /model sonnet → set-option @model_name → select-pane bg → /clear
    local line_model line_setopt line_bg line_clear
    line_model=$(grep -n '/model sonnet' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_setopt=$(grep -n '@model_name Sonnet' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_bg=$(grep -n 'bg=default' "$MOCK_LOG" | head -1 | cut -d: -f1)
    line_clear=$(grep -n '/clear' "$MOCK_LOG" | head -1 | cut -d: -f1)

    [ "$line_model" -lt "$line_setopt" ]
    [ "$line_setopt" -lt "$line_bg" ]
    [ "$line_bg" -lt "$line_clear" ]
}

# =============================================================================
# 引数バリデーションテスト
# =============================================================================

@test "T-BK-015: inject_barikidorink with no argument uses empty pane target" {
    run bash -c "source '$TEST_HARNESS' && inject_barikidorink"
    [ "$status" -eq 0 ]

    # Function runs with empty $1 — tmux commands get empty -t target
    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t  /model opus$' "$MOCK_LOG"
}

@test "T-BK-016: detox_barikidorink with no argument uses empty pane target" {
    run bash -c "source '$TEST_HARNESS' && detox_barikidorink"
    [ "$status" -eq 0 ]

    # Function runs with empty $1 — tmux commands get empty -t target
    # オートコンプリート回避: text→Escape→Enter（3ステップ）
    grep -q 'send-keys -t  /model sonnet$' "$MOCK_LOG"
}

# =============================================================================
# 関数定義一致テスト
# =============================================================================

@test "T-BK-017: yokubari.sh and njslyr.sh barikidorink functions are identical" {
    local yokubari_inject njslyr_inject yokubari_detox njslyr_detox

    yokubari_inject=$(sed -n '/^inject_barikidorink()/,/^}/p' "$YOKUBARI_SCRIPT")
    njslyr_inject=$(sed -n '/^inject_barikidorink()/,/^}/p' "$NJSLYR_SCRIPT")

    yokubari_detox=$(sed -n '/^detox_barikidorink()/,/^}/p' "$YOKUBARI_SCRIPT")
    njslyr_detox=$(sed -n '/^detox_barikidorink()/,/^}/p' "$NJSLYR_SCRIPT")

    [ "$yokubari_inject" = "$njslyr_inject" ]
    [ "$yokubari_detox" = "$njslyr_detox" ]
}
