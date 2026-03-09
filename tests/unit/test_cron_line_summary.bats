#!/usr/bin/env bats
# test_cron_line_summary.bats — cron_line_summary.sh ユニットテスト
# 自己研鑽タスク（yakuza4）
#
# テスト構成:
#   T-CLS-001: tmuxセッションなし → exit 0 / inbox_write未呼出
#   T-CLS-002: quiet hours内（hour=3, quiet 0-7） → 送信なし
#   T-CLS-003: quiet hours外（hour=10） → inbox_write呼出
#   T-CLS-004: quiet_end境界値（hour=7, quiet_end=7） → 送信あり（7 < 7はFALSE）
#   T-CLS-005: quiet_start境界値（hour=0, quiet_start=0） → 送信なし（0 >= 0はTRUE）
#   T-CLS-006: 先頭ゼロ時刻（08） → 10#算術で正常処理 → quiet hours外なら送信
#   T-CLS-007: 先頭ゼロ時刻（09） → 10#算術で正常処理 → quiet hours外なら送信
#   T-CLS-008: settings.yamlにquiet_hours未定義 → デフォルト（start=0,end=7）適用
#   T-CLS-009: inbox_write引数確認（darkninja宛・cron_summary type・P2）

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CRON_SCRIPT="$PROJECT_ROOT/scripts/cron_line_summary.sh"
    [ -f "$CRON_SCRIPT" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/cron_line_summary_test.XXXXXX")"
    export TEST_TMP

    # 分離プロジェクト構造を構築
    ISOLATED_DIR="$TEST_TMP/project"
    mkdir -p "$ISOLATED_DIR/scripts" "$ISOLATED_DIR/config" "$ISOLATED_DIR/mock_bin"
    export ISOLATED_DIR

    # スクリプトをコピーしてCRLF除去
    cp "$CRON_SCRIPT" "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    tr -d '\r' < "$ISOLATED_DIR/scripts/cron_line_summary.sh" \
        > "$ISOLATED_DIR/scripts/cron_line_summary.sh.tmp"
    mv "$ISOLATED_DIR/scripts/cron_line_summary.sh.tmp" \
        "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    chmod +x "$ISOLATED_DIR/scripts/cron_line_summary.sh"

    # デフォルト設定ファイル（quiet_hours: 0-7）
    cat > "$ISOLATED_DIR/config/settings.yaml" << 'YAML'
machine:
  role: kyoto
quiet_hours_start: 0
quiet_hours_end: 7
YAML

    # inbox_write.sh モック（呼び出し引数をログに記録）
    INBOX_LOG="$TEST_TMP/inbox_write_calls.log"
    export INBOX_LOG
    cat > "$ISOLATED_DIR/scripts/inbox_write.sh" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${INBOX_LOG}"
exit 0
MOCK
    chmod +x "$ISOLATED_DIR/scripts/inbox_write.sh"

    # tmux モック（MOCK_TMUX_SESSION=1でセッションあり、0でなし）
    cat > "$ISOLATED_DIR/mock_bin/tmux" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"has-session"* ]]; then
    if [[ "${MOCK_TMUX_SESSION:-1}" == "1" ]]; then
        exit 0
    else
        exit 1
    fi
fi
exit 0
MOCK
    chmod +x "$ISOLATED_DIR/mock_bin/tmux"

    # date モック（MOCK_HOUR で返す時刻を制御）
    cat > "$ISOLATED_DIR/mock_bin/date" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"+%H"* ]]; then
    printf "%s\n" "${MOCK_HOUR:-10}"
    exit 0
fi
/usr/bin/date "$@"
MOCK
    chmod +x "$ISOLATED_DIR/mock_bin/date"

    # モックbinをPATHの先頭に追加
    export PATH="$ISOLATED_DIR/mock_bin:$PATH"
    export MOCK_TMUX_SESSION=1
    export MOCK_HOUR=10
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ═══════════════════════════════════════════════════════════════
# tmuxセッション確認テスト
# ═══════════════════════════════════════════════════════════════

@test "T-CLS-001: tmuxセッションなし → exit 0 / inbox_write未呼出" {
    MOCK_TMUX_SESSION=0
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# quiet hours テスト
# ═══════════════════════════════════════════════════════════════

@test "T-CLS-002: quiet hours内（hour=3, quiet 0-7） → 送信なし" {
    MOCK_HOUR=03
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$INBOX_LOG" ]
}

@test "T-CLS-003: quiet hours外（hour=10） → inbox_write呼出" {
    MOCK_HOUR=10
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
}

@test "T-CLS-004: quiet_end境界値（hour=7, quiet_end=7） → 送信あり（7 < 7はFALSE）" {
    MOCK_HOUR=07
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
}

@test "T-CLS-005: quiet_start境界値（hour=0, quiet_start=0） → 送信なし（0 >= 0はTRUE）" {
    MOCK_HOUR=00
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# 先頭ゼロ（octal）バグ回避テスト
# ═══════════════════════════════════════════════════════════════

@test "T-CLS-006: 先頭ゼロ時刻08 → 10#算術で正常処理・quiet hours外なら送信" {
    # quiet_start=0, quiet_end=7 → hour 8 は範囲外 → 送信
    MOCK_HOUR=08
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
}

@test "T-CLS-007: 先頭ゼロ時刻09 → 10#算術で正常処理・quiet hours外なら送信" {
    MOCK_HOUR=09
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# settings.yaml設定不在テスト
# ═══════════════════════════════════════════════════════════════

@test "T-CLS-008: settings.yamlにquiet_hoursキーなし → デフォルト（start=0,end=7）・hour=10で送信" {
    # quiet_hours_start/endキーを持たない設定ファイル（awk は exit 0、値は空）
    cat > "$ISOLATED_DIR/config/settings.yaml" << 'YAML'
machine:
  role: kyoto
YAML
    MOCK_HOUR=10
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# inbox_write引数確認テスト
# ═══════════════════════════════════════════════════════════════

@test "T-CLS-009: inbox_write引数確認（darkninja宛・cron_summary type・P2）" {
    MOCK_HOUR=10
    run bash "$ISOLATED_DIR/scripts/cron_line_summary.sh"
    [ "$status" -eq 0 ]
    [ -f "$INBOX_LOG" ]
    grep -q "darkninja" "$INBOX_LOG"
    grep -q "cron_summary" "$INBOX_LOG"
    grep -q "P2" "$INBOX_LOG"
}
