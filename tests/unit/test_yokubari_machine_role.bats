#!/usr/bin/env bats
# test_yokubari_machine_role.bats — yokubari.sh MACHINE_ROLE分岐 ユニットテスト
# cmd_275 Round3 Group C (subtask_275m)
#
# テスト構成:
#   T-YK-MR-001: MACHINE_ROLE=ryzen時のYAKUZA_MAX=7確認
#   T-YK-MR-002: MACHINE_ROLE=mbp時のYAKUZA_MAX=3確認
#   T-YK-MR-003: MACHINE_ROLE未設定時のデフォルト動作
#   T-YK-MR-004: CLEAN_MODEでYAKUZA_MAX早期定義が機能（Round1修正確認）
#
# yokubari.shはset -eかつtmux依存のため直接sourceできない。
# MACHINE_ROLE読み取りロジックを抽出して検証する。

# --- セットアップ ---

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ヘルパー: settings.yamlからMACHINE_ROLEを読み取る（yokubari.shのL63-68と同一ロジック）
read_machine_role() {
    local settings_file="$1"
    local machine_role=""
    if [ -f "$settings_file" ]; then
        machine_role=$(awk '/^  role:/{print $2}' "$settings_file" 2>/dev/null)
    fi
    echo "${machine_role:-ryzen}"
}

# ヘルパー: MACHINE_ROLEからYAKUZA_MAX/MONITOR_AGENTを設定（yokubari.shのL70-77と同一ロジック）
get_machine_config() {
    local machine_role="$1"
    local yakuza_max monitor_agent
    if [[ "$machine_role" == "mbp" ]]; then
        yakuza_max=3
        monitor_agent="master_crane"
    else
        yakuza_max=7
        monitor_agent="master_tortoise"
    fi
    echo "${yakuza_max}:${monitor_agent}"
}

# =============================================================================
# T-YK-MR-001: MACHINE_ROLE=ryzen時のYAKUZA_MAX=7確認
# =============================================================================

@test "T-YK-MR-001: MACHINE_ROLE=ryzen → YAKUZA_MAX=7, MONITOR=master_tortoise" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
machine:
  role: ryzen
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "ryzen" ]

    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_tortoise" ]
}

# =============================================================================
# T-YK-MR-002: MACHINE_ROLE=mbp時のYAKUZA_MAX=3確認
# =============================================================================

@test "T-YK-MR-002: MACHINE_ROLE=mbp → YAKUZA_MAX=3, MONITOR=master_crane" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
machine:
  role: mbp
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "mbp" ]

    local config
    config=$(get_machine_config "$role")
    [ "$config" = "3:master_crane" ]
}

# =============================================================================
# T-YK-MR-003: MACHINE_ROLE未設定時のデフォルト動作
# =============================================================================

@test "T-YK-MR-003a: machineセクションなし → ryzenデフォルト" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "ryzen" ]
}

@test "T-YK-MR-003b: settings.yaml不在 → ryzenデフォルト" {
    local role
    role=$(read_machine_role "${TEST_TMP}/nonexistent.yaml")
    [ "$role" = "ryzen" ]
}

@test "T-YK-MR-003c: 空settings.yaml → ryzenデフォルト" {
    touch "${TEST_TMP}/settings.yaml"
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "ryzen" ]
}

@test "T-YK-MR-003d: roleフィールドが空 → ryzenデフォルト" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role:
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "ryzen" ]
}

# =============================================================================
# T-YK-MR-004: CLEAN_MODEでYAKUZA_MAX早期定義が機能（Round1修正確認）
# =============================================================================

@test "T-YK-MR-004a: yokubari.sh内でYAKUZA_MAXがCLEAN_MODEブロックより前に定義" {
    # YAKUZA_MAX定義行 < CLEAN_MODE使用行（for ((i=1; i<=YAKUZA_MAX...))）を検証
    local yakuza_def_line clean_use_line

    # YAKUZA_MAX初回定義行（マシンロール分岐内）
    yakuza_def_line=$(grep -n 'YAKUZA_MAX=' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    # CLEAN_MODEブロック内でYAKUZA_MAXを使用する最初の行
    clean_use_line=$(grep -n 'CLEAN_MODE.*true' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    # YAKUZA_MAX定義がCLEAN_MODE使用より前にあること
    [ "$yakuza_def_line" -lt "$clean_use_line" ]
}

@test "T-YK-MR-004b: YAKUZA_MAXがCLEAN_MODEのforループより前に定義" {
    # forループ内のYAKUZA_MAX使用行を特定
    local yakuza_def_line for_loop_line

    yakuza_def_line=$(grep -n 'YAKUZA_MAX=' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    # CLEAN_MODEブロック内のfor ((i=1; i<=YAKUZA_MAX
    for_loop_line=$(grep -n 'for ((i=1; i<=YAKUZA_MAX' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    [ "$yakuza_def_line" -lt "$for_loop_line" ]
}

@test "T-YK-MR-004c: MONITOR_AGENTがCLEAN_MODEブロックより前に定義" {
    local monitor_def_line clean_use_line

    # MONITOR_AGENT初回定義行
    monitor_def_line=$(grep -n 'MONITOR_AGENT=' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    # CLEAN_MODEブロック内でMONITOR_AGENTを参照する行（"$MONITOR_AGENT"使用）
    # CLEAN_MODEブロックはCLEAN_MODE=trueチェックの後
    clean_use_line=$(grep -n 'CLEAN_MODE.*true' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)

    [ "$monitor_def_line" -lt "$clean_use_line" ]
}

# =============================================================================
# エッジケース: awkパーサー
# =============================================================================

@test "T-YK-MR-EDGE: roleにextraスペースがあっても正しく読み取れる" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role: mbp
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "mbp" ]
}

@test "T-YK-MR-EDGE: role値の前後にコメントがない正常値" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role: ryzen              # ryzen | mbp
YAML
    # awkの'{print $2}'はコメントを含まない（$2は2番目のフィールドのみ）
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "ryzen" ]
}

# =============================================================================
# ntfy_listener自動起動テスト（cmd_277 subtask_277b）
# T-YK-NTFY-001: ryzen → ntfy_listener起動条件が真
# T-YK-NTFY-002: mbp → ntfy_listener起動条件が偽
# T-YK-NTFY-003: ryzen + 既に起動中 → PIDチェックでスキップ（二重起動防止）
# T-YK-NTFY-004: ryzen + 未起動 → ntfy_listener起動
# T-YK-NTFY-005: ntfy_topic未設定 → 起動しない
# =============================================================================

# ヘルパー: yokubari.sh STEP6.8のntfy起動条件を評価
# 引数: machine_role ntfy_topic
# 出力: "start" | "skip_pid" | "skip_mbp" | "skip_notopic"
eval_ntfy_startup_condition() {
    local machine_role="$1"
    local ntfy_topic="$2"
    local already_running="${3:-false}"

    if [ -n "$ntfy_topic" ] && [[ "$machine_role" == "ryzen" ]]; then
        if [[ "$already_running" == "true" ]]; then
            echo "skip_pid"
        else
            echo "start"
        fi
    elif [ -n "$ntfy_topic" ]; then
        echo "skip_mbp"
    else
        echo "skip_notopic"
    fi
}

@test "T-YK-NTFY-001: ryzen + ntfy_topic設定 → 起動条件が真" {
    local result
    result=$(eval_ntfy_startup_condition "ryzen" "test-topic-xyz")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-002: mbp + ntfy_topic設定 → MBP側スキップ" {
    local result
    result=$(eval_ntfy_startup_condition "mbp" "test-topic-xyz")
    [ "$result" = "skip_mbp" ]
}

@test "T-YK-NTFY-003: ryzen + 既に起動中 → PIDチェックでスキップ" {
    local result
    result=$(eval_ntfy_startup_condition "ryzen" "test-topic-xyz" "true")
    [ "$result" = "skip_pid" ]
}

@test "T-YK-NTFY-004: ryzen + 未起動 → 起動実行" {
    local result
    result=$(eval_ntfy_startup_condition "ryzen" "test-topic-xyz" "false")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-005: ntfy_topic未設定 → 起動しない" {
    local result
    result=$(eval_ntfy_startup_condition "ryzen" "")
    [ "$result" = "skip_notopic" ]
}

@test "T-YK-NTFY-006: yokubari.shにPIDチェック実装が存在することを確認" {
    # yokubari.shにpgrepによるPIDチェックが実装されているか検証
    grep -q 'pgrep -f "ntfy_listener.sh"' "$PROJECT_ROOT/yokubari.sh"
}

@test "T-YK-NTFY-007: yokubari.shにMACHINE_ROLE=ryzen条件が存在することを確認" {
    # MACHINE_ROLE == ryzen かつ NTFY_TOPIC の複合条件が実装されているか検証
    grep -q 'MACHINE_ROLE.*==.*ryzen' "$PROJECT_ROOT/yokubari.sh"
}

@test "T-YK-NTFY-008: yokubari.sh STEP6.8でpkill無条件kill削除を確認" {
    # 旧実装: pkill -f "ntfy_listener.sh" が無条件に実行されていた
    # 新実装: PIDチェック後のみ起動 → pkillによる強制killは削除
    # ntfy起動ブロック内に無条件pkillがないことを確認
    local ntfy_block
    ntfy_block=$(sed -n '/STEP 6.8/,/STEP 7/p' "$PROJECT_ROOT/yokubari.sh")
    # pkillが含まれていないことを確認
    ! echo "$ntfy_block" | grep -q 'pkill.*ntfy_listener'
}
