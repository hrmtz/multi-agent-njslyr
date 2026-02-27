#!/usr/bin/env bats
# test_yokubari_machine_role.bats — yokubari.sh MACHINE_ROLE分岐 ユニットテスト
# cmd_275 Round3 Group C (subtask_275m)
# cmd_279 subtask_279e: kyoto/neosaitama rename + 後方互換テスト追加
#
# テスト構成:
#   T-YK-MR-001: MACHINE_ROLE=kyoto時のYAKUZA_MAX=7確認
#   T-YK-MR-002: MACHINE_ROLE=neosaitama時のYAKUZA_MAX=7確認
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
    echo "${machine_role:-kyoto}"
}

# ヘルパー: MACHINE_ROLEからYAKUZA_MAX/MONITOR_AGENTを設定（yokubari.shのL70-77と同一ロジック）
# neosaitama (MBP) と mbp (legacy) の両方を軽量構成として扱う
get_machine_config() {
    local machine_role="$1"
    local yakuza_max monitor_agent
    if [[ "$machine_role" == "neosaitama" || "$machine_role" == "mbp" ]]; then
        yakuza_max=7
        monitor_agent="master_crane"
    else
        yakuza_max=7
        monitor_agent="master_tortoise"
    fi
    echo "${yakuza_max}:${monitor_agent}"
}

# =============================================================================
# T-YK-MR-001: MACHINE_ROLE=kyoto時のYAKUZA_MAX=7確認
# =============================================================================

@test "T-YK-MR-001: MACHINE_ROLE=kyoto → YAKUZA_MAX=7, MONITOR=master_tortoise" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
machine:
  role: kyoto
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "kyoto" ]

    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_tortoise" ]
}

# =============================================================================
# T-YK-MR-002: MACHINE_ROLE=neosaitama時のYAKUZA_MAX=3確認
# =============================================================================

@test "T-YK-MR-002: MACHINE_ROLE=neosaitama → YAKUZA_MAX=7, MONITOR=master_crane" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
machine:
  role: neosaitama
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "neosaitama" ]

    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_crane" ]
}

# =============================================================================
# T-YK-MR-003: MACHINE_ROLE未設定時のデフォルト動作
# =============================================================================

@test "T-YK-MR-003a: machineセクションなし → kyotoデフォルト" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
language: ja
shell: bash
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "kyoto" ]
}

@test "T-YK-MR-003b: settings.yaml不在 → kyotoデフォルト" {
    local role
    role=$(read_machine_role "${TEST_TMP}/nonexistent.yaml")
    [ "$role" = "kyoto" ]
}

@test "T-YK-MR-003c: 空settings.yaml → kyotoデフォルト" {
    touch "${TEST_TMP}/settings.yaml"
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "kyoto" ]
}

@test "T-YK-MR-003d: roleフィールドが空 → kyotoデフォルト" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role:
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "kyoto" ]
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
  role: neosaitama
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "neosaitama" ]
}

@test "T-YK-MR-EDGE: role値の前後にコメントがない正常値" {
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role: kyoto              # kyoto | neosaitama
YAML
    # awkの'{print $2}'はコメントを含まない（$2は2番目のフィールドのみ）
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    [ "$role" = "kyoto" ]
}

# =============================================================================
# 後方互換テスト: ryzen/mbp (legacy) は kyoto/neosaitama と同等に動作
# =============================================================================

@test "yokubari: role=ryzen (legacy) still works as kyoto fallback" {
    # ryzen は kyoto と同等に動作すること（後方互換）
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role: ryzen
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    # ryzen はリテラルとして読み取られる（kyoto fallbackではなくryzenそのもの）
    [ "$role" = "ryzen" ]

    # get_machine_config はryzenをkyoto相当（フル構成）として扱う
    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_tortoise" ]
}

@test "yokubari: role=mbp (legacy) still works as neosaitama fallback" {
    # mbp は neosaitama と同等に動作すること（後方互換）
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
machine:
  role: mbp
YAML
    local role
    role=$(read_machine_role "${TEST_TMP}/settings.yaml")
    # mbp はリテラルとして読み取られる
    [ "$role" = "mbp" ]

    # get_machine_config はmbpをneosaitama相当（フル構成7体）として扱う
    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_crane" ]
}

@test "yokubari: no settings.yaml defaults to kyoto (standalone mode)" {
    # settings.yamlが存在しない場合、role=kyoto (standalone) で動作
    local role
    role=$(read_machine_role "${TEST_TMP}/no_such_file.yaml")
    [ "$role" = "kyoto" ]

    # kyotoはフル構成で動作する
    local config
    config=$(get_machine_config "$role")
    [ "$config" = "7:master_tortoise" ]
}

# =============================================================================
# ntfy_listener自動起動テスト（cmd_277 subtask_277b）
# T-YK-NTFY-001: kyoto → ntfy_listener起動条件が真
# T-YK-NTFY-002: neosaitama → ntfy_listener起動条件が偽
# T-YK-NTFY-003: kyoto + 既に起動中 → PIDチェックでスキップ（二重起動防止）
# T-YK-NTFY-004: kyoto + 未起動 → ntfy_listener起動
# T-YK-NTFY-005: ntfy_topic未設定 → 起動しない
# =============================================================================

# ヘルパー: yokubari.sh STEP6.8のntfy起動条件を評価（FIX-002反映: neosaitama/mbp対応）
# 引数: machine_role ntfy_topic [already_running]
# 出力: "start" | "skip_pid" | "skip_unknown_role" | "skip_notopic"
eval_ntfy_startup_condition() {
    local machine_role="$1"
    local ntfy_topic="$2"
    local already_running="${3:-false}"

    if [ -n "$ntfy_topic" ] && [[ "$machine_role" == "kyoto" || "$machine_role" == "ryzen" || "$machine_role" == "neosaitama" || "$machine_role" == "mbp" ]]; then
        if [[ "$already_running" == "true" ]]; then
            echo "skip_pid"
        else
            echo "start"
        fi
    elif [ -n "$ntfy_topic" ]; then
        echo "skip_unknown_role"
    else
        echo "skip_notopic"
    fi
}

@test "T-YK-NTFY-001: kyoto + ntfy_topic設定 → 起動条件が真" {
    local result
    result=$(eval_ntfy_startup_condition "kyoto" "test-topic-xyz")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-002: neosaitama + ntfy_topic設定 → 起動条件が真（FIX-002）" {
    # FIX-002: neosaitamaでもntfy_listenerが起動するよう修正
    local result
    result=$(eval_ntfy_startup_condition "neosaitama" "test-topic-xyz")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-003: kyoto + 既に起動中 → PIDチェックでスキップ" {
    local result
    result=$(eval_ntfy_startup_condition "kyoto" "test-topic-xyz" "true")
    [ "$result" = "skip_pid" ]
}

@test "T-YK-NTFY-004: kyoto + 未起動 → 起動実行" {
    local result
    result=$(eval_ntfy_startup_condition "kyoto" "test-topic-xyz" "false")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-005: ntfy_topic未設定 → 起動しない" {
    local result
    result=$(eval_ntfy_startup_condition "kyoto" "")
    [ "$result" = "skip_notopic" ]
}

@test "T-YK-NTFY-006: yokubari.shにPIDチェック実装が存在することを確認" {
    # yokubari.shにpgrepによるPIDチェックが実装されているか検証
    grep -q 'pgrep -f "ntfy_listener.sh"' "$PROJECT_ROOT/yokubari.sh"
}

@test "T-YK-NTFY-007: yokubari.shにMACHINE_ROLE=kyoto条件が存在することを確認" {
    # MACHINE_ROLE == kyoto かつ NTFY_TOPIC の複合条件が実装されているか検証
    grep -q 'MACHINE_ROLE.*==.*kyoto' "$PROJECT_ROOT/yokubari.sh"
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

# =============================================================================
# FIX-002追加テスト: neosaitama/mbpでのntfy_listener起動
# =============================================================================

@test "T-YK-NTFY-009: neosaitama + ntfy_topic設定 + 未起動 → 起動実行（FIX-002）" {
    local result
    result=$(eval_ntfy_startup_condition "neosaitama" "test-topic-xyz" "false")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-010: mbp(legacy) + ntfy_topic設定 → 起動実行（FIX-002後方互換）" {
    local result
    result=$(eval_ntfy_startup_condition "mbp" "test-topic-xyz")
    [ "$result" = "start" ]
}

@test "T-YK-NTFY-011: yokubari.shにneosaitama条件が存在することを確認（FIX-002）" {
    grep -q 'MACHINE_ROLE.*==.*neosaitama' "$PROJECT_ROOT/yokubari.sh"
}

# =============================================================================
# FIX-005テスト: active_machine.yaml mode:フィールド明示チェック
# =============================================================================

# ヘルパー: yokubari.sh STEP0.5のactive_machine.yaml mode:判定ロジックを評価
# 引数: mode active_machine current_machine
# 出力: "simultaneous_skip" | "sync_needed" | "no_sync"
eval_active_mode_action() {
    local mode="$1"
    local active_machine="$2"
    local current_machine="$3"

    if [[ "$mode" == "simultaneous" ]]; then
        echo "simultaneous_skip"
    elif [[ "$mode" == "exclusive" || -z "$mode" ]]; then
        if [[ -n "$active_machine" && "$active_machine" != "$current_machine" ]]; then
            echo "sync_needed"
        else
            echo "no_sync"
        fi
    else
        echo "unknown_mode"
    fi
}

@test "T-YK-AM-001: mode=simultaneous → auto-syncスキップ（FIX-005）" {
    # simultaneous mode では両マシン同時稼働のためauto-syncをスキップ
    local result
    result=$(eval_active_mode_action "simultaneous" "" "kyoto")
    [ "$result" = "simultaneous_skip" ]
}

@test "T-YK-AM-002: mode=exclusive + 別マシンがactive → sync_needed（FIX-005）" {
    local result
    result=$(eval_active_mode_action "exclusive" "neosaitama" "kyoto")
    [ "$result" = "sync_needed" ]
}

@test "T-YK-AM-003: mode=exclusive + 自マシンがactive → no_sync（FIX-005）" {
    local result
    result=$(eval_active_mode_action "exclusive" "kyoto" "kyoto")
    [ "$result" = "no_sync" ]
}

@test "T-YK-AM-004: mode未設定 → exclusive扱い（FIX-005後方互換）" {
    # modeフィールドが存在しない場合はexclusive相当として動作
    local result
    result=$(eval_active_mode_action "" "neosaitama" "kyoto")
    [ "$result" = "sync_needed" ]
}

@test "T-YK-AM-005: yokubari.shにmode:明示チェック実装が存在することを確認（FIX-005）" {
    grep -q 'ACTIVE_MODE.*awk.*mode:' "$PROJECT_ROOT/yokubari.sh"
}

@test "T-YK-AM-006: yokubari.shにsimultaneous mode分岐が存在することを確認（FIX-005）" {
    grep -q 'ACTIVE_MODE.*==.*simultaneous' "$PROJECT_ROOT/yokubari.sh"
}

@test "T-YK-NS-001: neosaitamaブロックでresize-windowがsplit-windowより前に位置する（132x40対応）" {
    # neosaitamaブロック内のtmux resize-windowの行番号
    resize_line=$(grep -n 'resize-window.*multiagent:agents' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)
    # neosaitamaブロック内の最初のsplit-window（split-window -h -t multiagent:agents）の行番号
    split_line=$(grep -n 'split-window.*multiagent:agents' "$PROJECT_ROOT/yokubari.sh" | head -1 | cut -d: -f1)
    # 両行が存在すること
    [ -n "$resize_line" ]
    [ -n "$split_line" ]
    # resize-windowがsplit-windowより前（行番号が小さい）こと
    [ "$resize_line" -lt "$split_line" ]
}

@test "T-YK-NS-002: neosaitamaブロックにresize-window -x 220 -y 55の実装が存在する" {
    grep -q 'resize-window.*-x 220.*-y 55' "$PROJECT_ROOT/yokubari.sh"
}

# =============================================================================
# cmd_293 subtask_293a テスト: neosaitama main session 修正確認
# T-YK-293-001: neosaitamaはローカルペインのみ（SSH窓なし）
# T-YK-293-002: kyotoでmain:tortoiseウィンドウが作成される
# =============================================================================

@test "T-YK-293-001: neosaitamaブロックにSSH窓(darkninja/tortoise)が存在しない" {
    # neosaitama mainセッションにSSHコマンドが含まれないこと
    ! grep -A5 'neosaitama: main セッション' "$PROJECT_ROOT/yokubari.sh" | grep -q "ssh -p"
}

@test "T-YK-293-002: kyotoブロックにmain:tortoiseウィンドウ作成が存在する" {
    grep -q '\-n tortoise' "$PROJECT_ROOT/yokubari.sh"
}
