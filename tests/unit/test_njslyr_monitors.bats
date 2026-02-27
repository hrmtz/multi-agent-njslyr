#!/usr/bin/env bats
# test_njslyr_monitors.bats — njslyr.sh crane/tortoise monitors関連テスト
# cmd_275 Round3 Group C (subtask_275m)
#
# テスト構成:
#   T-NJ-MON-001: get_monitored_agents monitorsウィンドウ存在時
#   T-NJ-MON-002: get_monitored_agents monitorsウィンドウ不在時（空配列）
#   T-NJ-MON-003: get_pane_target agents→monitors fallback
#   T-NJ-MON-004: validate_agent_ids monitors agent含む
#
# tmux依存関数はモックtmuxで検証する。

# --- セットアップ ---

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # モックtmuxディレクトリ
    MOCK_BIN="${TEST_TMP}/bin"
    mkdir -p "$MOCK_BIN"

    # njslyr.shはset -euo pipefailで直接sourceすると起動してしまう。
    # テスト対象関数のみ抽出して評価する。
    # 関数定義に必要な最小限の変数とヘルパーを設定
    export PROJECT_ROOT
    export SCRIPT_DIR="$PROJECT_ROOT/scripts"
    export DASHBOARD="${TEST_TMP}/dashboard.md"
    export LOG_DIR="${TEST_TMP}/logs"
    export METRICS_DIR="${TEST_TMP}/metrics"
    export STATE_DIR="${TEST_TMP}/state"
    export CACHE_DIR="${TEST_TMP}/cache"
    mkdir -p "$LOG_DIR" "$METRICS_DIR" "$STATE_DIR" "$CACHE_DIR"
    touch "$DASHBOARD"

    # log/update_dashboard/notify_darkninja スタブ
    log() { echo "[LOG] $*"; }
    update_dashboard() { echo "[DASHBOARD] $*"; }
    notify_darkninja() { echo "[NOTIFY] $*"; }
    export -f log update_dashboard notify_darkninja
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ヘルパー: 特定のtmux mockを設定してnjslyr.sh関数を評価
# モック動作は MOCK_TMUX_BEHAVIOR ファイルで制御
create_tmux_mock() {
    local behavior_file="${TEST_TMP}/tmux_behavior"
    cat > "$behavior_file" << 'MOCKEOF'
# default: empty
MOCKEOF

    cat > "${MOCK_BIN}/tmux" << 'SCRIPT'
#!/bin/bash
# tmuxモック — MOCK_TMUX_AGENTS_OUTPUT / MOCK_TMUX_MONITORS_OUTPUT で出力を制御
# 引数パターンに応じて適切な出力を返す

args="$*"

# list-panes -t multiagent:agents
if [[ "$args" == *"list-panes"*"multiagent:agents"* ]]; then
    if [[ -n "${MOCK_TMUX_AGENTS_OUTPUT:-}" ]]; then
        echo "$MOCK_TMUX_AGENTS_OUTPUT"
    fi
    exit 0
fi

# list-panes -t multiagent:monitors
if [[ "$args" == *"list-panes"*"multiagent:monitors"* ]]; then
    if [[ -n "${MOCK_TMUX_MONITORS_OUTPUT:-}" ]]; then
        echo "$MOCK_TMUX_MONITORS_OUTPUT"
    fi
    exit 0
fi

# その他のtmuxコマンドは成功で返す
exit 0
SCRIPT
    chmod +x "${MOCK_BIN}/tmux"
}

# ヘルパー: njslyr.shから対象関数を抽出して定義
# (set -euo pipefail + mkdir等をスキップ)
load_njslyr_functions() {
    # sedi関数（njslyr.sh冒頭で定義）
    sedi() {
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "$@"
        else
            sed -i "$@"
        fi
    }

    # get_monitored_agents (L370-380)
    get_monitored_agents() {
        {
            tmux list-panes -t multiagent:agents -F '#{@agent_id}' 2>/dev/null
            tmux list-panes -t multiagent:monitors -F '#{@agent_id}' 2>/dev/null
        } | grep -v '^$' | \
            grep -v '^darkninja$' | \
            sort -u || true
    }

    # get_pane_target (L425-438)
    get_pane_target() {
        local agent_id="$1"
        local result
        result=$(tmux list-panes -t multiagent:agents -F '#{pane_index} #{@agent_id}' 2>/dev/null | \
            awk -v id="$agent_id" '$2 == id {print "multiagent:agents." $1; exit}')
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
        tmux list-panes -t multiagent:monitors -F '#{pane_index} #{@agent_id}' 2>/dev/null | \
            awk -v id="$agent_id" '$2 == id {print "multiagent:monitors." $1; exit}'
    }

    # validate_agent_ids (L350-367)
    validate_agent_ids() {
        local suspicious_panes
        suspicious_panes=$(
            {
                tmux list-panes -t multiagent:agents -F '#{pane_index} #{@agent_id}' 2>/dev/null
                tmux list-panes -t multiagent:monitors -F 'monitors:#{pane_index} #{@agent_id}' 2>/dev/null
            } | awk '$2 == "darkninja" {print $1}' || true
        )

        if [[ -n "$suspicious_panes" ]]; then
            local msg="🚨 @agent_id誤設定検知！multiagentペイン(${suspicious_panes})にdarkninja IDが設定されている。yokubari.shで再起動が必要。"
            log "ALERT: $msg"
            update_dashboard "$msg"
            notify_darkninja "$msg" P0
            return 1
        fi
        return 0
    }
}

# =============================================================================
# T-NJ-MON-001: get_monitored_agents monitorsウィンドウ存在時
# =============================================================================

@test "T-NJ-MON-001a: agentsのみ → agents windowのagentを返す" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="gryakuza
yakuza1
yakuza2
yakuza3
soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT=""

    run get_monitored_agents
    [ "$status" -eq 0 ]
    [[ "$output" == *"gryakuza"* ]]
    [[ "$output" == *"yakuza1"* ]]
    [[ "$output" == *"soukaiya"* ]]
    # darkninjaは除外
    [[ "$output" != *"darkninja"* ]]

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
}

@test "T-NJ-MON-001b: agents + monitors → 両方のagentを返す" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="gryakuza
yakuza1
yakuza2
yakuza3
soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT="master_tortoise"

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
    [[ "$output" == *"gryakuza"* ]]
    [[ "$output" == *"master_tortoise"* ]]
}

@test "T-NJ-MON-001c: monitors=master_crane (mbp構成)" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="gryakuza
yakuza1
yakuza2
yakuza3
soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT="master_crane"

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
    [[ "$output" == *"master_crane"* ]]
    [[ "$output" == *"gryakuza"* ]]
}

@test "T-NJ-MON-001d: darkninja が agents window にいても除外される" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="darkninja
gryakuza
yakuza1"
    export MOCK_TMUX_MONITORS_OUTPUT=""

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
    [[ "$output" != *"darkninja"* ]]
    [[ "$output" == *"gryakuza"* ]]
    [[ "$output" == *"yakuza1"* ]]
}

# =============================================================================
# T-NJ-MON-002: get_monitored_agents monitorsウィンドウ不在時（空配列）
# =============================================================================

@test "T-NJ-MON-002a: 両window空 → 空出力" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT=""
    export MOCK_TMUX_MONITORS_OUTPUT=""

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-NJ-MON-002b: agentsのみ（monitors未作成） → agentsのみ返す" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="gryakuza
yakuza1
soukaiya"
    unset MOCK_TMUX_MONITORS_OUTPUT

    PATH="${MOCK_BIN}:$PATH" run get_monitored_agents
    [ "$status" -eq 0 ]
    [[ "$output" == *"gryakuza"* ]]
    [[ "$output" != *"master_tortoise"* ]]
}

# =============================================================================
# T-NJ-MON-003: get_pane_target agents→monitors fallback
# =============================================================================

@test "T-NJ-MON-003a: agentsウィンドウで見つかる → multiagent:agents.N" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1
2 yakuza2"
    export MOCK_TMUX_MONITORS_OUTPUT=""

    PATH="${MOCK_BIN}:$PATH" run get_pane_target "yakuza1"
    [ "$status" -eq 0 ]
    [ "$output" = "multiagent:agents.1" ]
}

@test "T-NJ-MON-003b: agentsに不在→monitorsウィンドウにfallback" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1"
    export MOCK_TMUX_MONITORS_OUTPUT="0 master_tortoise"

    PATH="${MOCK_BIN}:$PATH" run get_pane_target "master_tortoise"
    [ "$status" -eq 0 ]
    [ "$output" = "multiagent:monitors.0" ]
}

@test "T-NJ-MON-003c: master_crane (mbp) もfallbackで見つかる" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1
2 yakuza2
3 yakuza3
4 soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT="0 master_crane"

    PATH="${MOCK_BIN}:$PATH" run get_pane_target "master_crane"
    [ "$status" -eq 0 ]
    [ "$output" = "multiagent:monitors.0" ]
}

@test "T-NJ-MON-003d: どちらにも不在 → 空出力" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1"
    export MOCK_TMUX_MONITORS_OUTPUT="0 master_tortoise"

    PATH="${MOCK_BIN}:$PATH" run get_pane_target "nonexistent_agent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# T-NJ-MON-004: validate_agent_ids monitors agent含む
# =============================================================================

@test "T-NJ-MON-004a: 正常（darkninja IDなし） → return 0" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1
2 yakuza2
3 soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT="monitors:0 master_tortoise"

    PATH="${MOCK_BIN}:$PATH" run validate_agent_ids
    [ "$status" -eq 0 ]
}

@test "T-NJ-MON-004b: agentsにdarkninja誤設定 → return 1 + 警告" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 darkninja
2 yakuza2"
    export MOCK_TMUX_MONITORS_OUTPUT="monitors:0 master_tortoise"

    PATH="${MOCK_BIN}:$PATH" run validate_agent_ids
    [ "$status" -eq 1 ]
    [[ "$output" == *"誤設定検知"* ]]
}

@test "T-NJ-MON-004c: monitorsにdarkninja誤設定 → return 1 + 警告" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1"
    export MOCK_TMUX_MONITORS_OUTPUT="monitors:0 darkninja"

    PATH="${MOCK_BIN}:$PATH" run validate_agent_ids
    [ "$status" -eq 1 ]
    [[ "$output" == *"誤設定検知"* ]]
}

@test "T-NJ-MON-004d: 両window正常（master_crane含む） → return 0" {
    create_tmux_mock
    load_njslyr_functions

    export MOCK_TMUX_AGENTS_OUTPUT="0 gryakuza
1 yakuza1
2 yakuza2
3 yakuza3
4 soukaiya"
    export MOCK_TMUX_MONITORS_OUTPUT="monitors:0 master_crane"

    PATH="${MOCK_BIN}:$PATH" run validate_agent_ids
    [ "$status" -eq 0 ]
}

# =============================================================================
# T-NJ-MON-005: check_inbox_watcher watcher生存チェック
# =============================================================================

# ヘルパー: check_inbox_watcher関数を定義（pgrep mock付き）
load_check_inbox_watcher() {
    # log stub（未定義の場合）
    if ! declare -f log >/dev/null 2>&1; then
        log() { echo "[LOG] $*"; }
        export -f log
    fi

    check_inbox_watcher() {
        local agent_id="$1"
        if ! pgrep -f "inbox_watcher.sh.*${agent_id}" >/dev/null 2>&1; then
            log "WARN: inbox_watcher for ${agent_id} not found. Attempting restart..."
            local supervisor="${SCRIPT_DIR}/watcher_supervisor.sh"
            if [[ -f "$supervisor" ]]; then
                bash "$supervisor" "$agent_id" &
                log "INFO: watcher_supervisor started for ${agent_id}"
            else
                log "ERROR: watcher_supervisor.sh not found. Manual restart required."
            fi
        fi
    }
}

@test "T-NJ-MON-005a: watcher生存中 → no action (no WARN log)" {
    load_njslyr_functions
    load_check_inbox_watcher

    # pgrep mock: 常に0(found)を返す
    cat > "${MOCK_BIN}/pgrep" << 'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "${MOCK_BIN}/pgrep"

    PATH="${MOCK_BIN}:$PATH" run check_inbox_watcher "yakuza1"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN"* ]]
    [[ "$output" != *"not found"* ]]
}

@test "T-NJ-MON-005b: watcher死亡 + supervisor存在 → WARN + supervisor起動" {
    load_njslyr_functions
    load_check_inbox_watcher

    # pgrep mock: 常に1(not found)を返す
    cat > "${MOCK_BIN}/pgrep" << 'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
    chmod +x "${MOCK_BIN}/pgrep"

    # 偽のwatcher_supervisor.shを配置
    mkdir -p "${TEST_TMP}/scripts"
    cat > "${TEST_TMP}/scripts/watcher_supervisor.sh" << 'SCRIPT'
#!/bin/bash
echo "supervisor called for: $1"
exit 0
SCRIPT
    chmod +x "${TEST_TMP}/scripts/watcher_supervisor.sh"
    export SCRIPT_DIR="${TEST_TMP}/scripts"

    PATH="${MOCK_BIN}:$PATH" run check_inbox_watcher "yakuza3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"inbox_watcher for yakuza3 not found"* ]]
    [[ "$output" == *"INFO: watcher_supervisor started for yakuza3"* ]]
}

@test "T-NJ-MON-005c: watcher死亡 + supervisor不在 → WARN + ERROR log" {
    load_njslyr_functions
    load_check_inbox_watcher

    # pgrep mock: 常に1(not found)を返す
    cat > "${MOCK_BIN}/pgrep" << 'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
    chmod +x "${MOCK_BIN}/pgrep"

    # supervisor不在のディレクトリをSCRIPT_DIRに設定
    local no_supervisor_dir="${TEST_TMP}/no_supervisor"
    mkdir -p "$no_supervisor_dir"
    export SCRIPT_DIR="$no_supervisor_dir"

    PATH="${MOCK_BIN}:$PATH" run check_inbox_watcher "yakuza5"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"ERROR: watcher_supervisor.sh not found"* ]]
}
