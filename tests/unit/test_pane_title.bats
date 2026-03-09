#!/usr/bin/env bats
# test_pane_title.bats — pane_title.sh ペインタイトル更新ヘルパーテスト (cmd_338)
#
# テスト対象: scripts/pane_title.sh
# 実行方法: bats tests/unit/test_pane_title.bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/scripts/pane_title.sh"

    # tmux select-paneをモック化（引数をファイルに記録）
    MOCK_LOG="$BATS_TEST_TMPDIR/tmux_calls.log"
    tmux() {
        echo "tmux $*" >> "$MOCK_LOG"
    }
    export -f tmux
}

# TC1: DS判定テスト（ANTHROPIC_BASE_URL含む extra_env → [DS]）
@test "TC1: get_model_badge returns [DS] when extra_env contains ANTHROPIC_BASE_URL" {
    result=$(get_model_badge "sonnet" "ANTHROPIC_BASE_URL=https://example.com")
    [ "$result" = "[DS]" ]
}

# TC2: Opus判定テスト（model=opus → [Opus]）
@test "TC2: get_model_badge returns [Opus] for opus model" {
    result=$(get_model_badge "opus")
    [ "$result" = "[Opus]" ]

    result2=$(get_model_badge "claude-opus-4-6")
    [ "$result2" = "[Opus]" ]
}

# TC3: Haiku判定テスト（model=haiku → [Hku]）
@test "TC3: get_model_badge returns [Hku] for haiku model" {
    result=$(get_model_badge "haiku")
    [ "$result" = "[Hku]" ]

    result2=$(get_model_badge "claude-haiku-4-5-20251001")
    [ "$result2" = "[Hku]" ]
}

# TC4: Sonnet判定テスト（model=sonnet → [Snt]）
@test "TC4: get_model_badge returns [Snt] for sonnet model" {
    result=$(get_model_badge "sonnet")
    [ "$result" = "[Snt]" ]

    result2=$(get_model_badge "claude-sonnet-4-6")
    [ "$result2" = "[Snt]" ]
}

# TC5: デフォルト判定テスト（model="" → [Snt]）
@test "TC5: get_model_badge returns [Snt] for empty model string" {
    result=$(get_model_badge "")
    [ "$result" = "[Snt]" ]

    result2=$(get_model_badge)
    [ "$result2" = "[Snt]" ]
}

# TC6: 不明モデル → [?]
@test "TC6: get_model_badge returns [?] for unknown model" {
    result=$(get_model_badge "gpt-4")
    [ "$result" = "[?]" ]
}

# TC7: update_pane_title calls tmux with correct title
@test "TC7: update_pane_title sets correct pane title for opus" {
    update_pane_title "multiagent:agents.1" "yakuza1" "opus" ""
    run grep "select-pane" "$MOCK_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"yakuza1[Opus]"* ]]
}

# TC8: update_pane_title DS overrides model
@test "TC8: update_pane_title DS overrides model string" {
    update_pane_title "multiagent:agents.5" "yakuza5" "sonnet" "ANTHROPIC_BASE_URL=https://x.com"
    run grep "select-pane" "$MOCK_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"yakuza5[DS]"* ]]
}

# TC9: update_pane_title with empty model defaults to [Snt]
@test "TC9: update_pane_title defaults to [Snt] for empty model" {
    update_pane_title "multiagent:agents.0" "gryakuza" "" ""
    run grep "select-pane" "$MOCK_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gryakuza[Snt]"* ]]
}
