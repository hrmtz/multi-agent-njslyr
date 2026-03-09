#!/usr/bin/env bats
# test_line_push.bats — line_push.sh ユニットテスト
# 自己研鑽タスク（yakuza4）
#
# テスト構成:
#   T-LP-001: 引数なし → exit 1 + usageメッセージ
#   T-LP-002: 引数2個以上 → exit 1 + usageメッセージ
#   T-LP-003: LINE_CHANNEL_ACCESS_TOKEN未設定 → exit 1
#   T-LP-004: LINE_USER_ID未設定 → exit 1
#   T-LP-005: 正常送信（curlモック）→ exit 0, LINE APIが呼ばれる
#   T-LP-006: ダブルクォートを含むメッセージ → JSON安全にエスケープ
#   T-LP-007: バックスラッシュを含むメッセージ → JSON安全にエスケープ
#   T-LP-008: 改行を含むメッセージ → \nエスケープ
#   T-LP-009: config/line.envから認証情報を読み込む
#   T-LP-010: line.env.sampleファイル存在確認
#   T-LP-011: line.env本体はgit非追跡確認

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export LINE_PUSH_SCRIPT="$PROJECT_ROOT/scripts/line_push.sh"

    [ -f "$LINE_PUSH_SCRIPT" ] || return 1
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/line_push_test.XXXXXX")"
    export TEST_TMP

    # 分離スクリプト環境を作成
    # （config/line.envを持たないディレクトリにスクリプトをコピー）
    ISOLATED_SCRIPT_DIR="$TEST_TMP/isolated_scripts"
    mkdir -p "$ISOLATED_SCRIPT_DIR" "$ISOLATED_SCRIPT_DIR/../config"
    cp "$LINE_PUSH_SCRIPT" "$ISOLATED_SCRIPT_DIR/line_push.sh"
    export ISOLATED_SCRIPT_DIR

    # curlモック（引数をログに記録して成功を返す）
    CURL_LOG="$TEST_TMP/curl_calls.log"
    export CURL_LOG
    mkdir -p "$TEST_TMP/mock_bin"
    cat > "$TEST_TMP/mock_bin/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${CURL_LOG}"
echo '{}'
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"

    # テスト用に環境変数をクリア
    unset LINE_CHANNEL_ACCESS_TOKEN
    unset LINE_USER_ID

    export PATH="$TEST_TMP/mock_bin:$PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ═══════════════════════════════════════════════════════════════
# 引数バリデーションテスト
# ═══════════════════════════════════════════════════════════════

# --- T-LP-001: 引数なし → exit 1 ---

@test "T-LP-001: line_push.sh exits 1 with usage when no arguments provided" {
    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

# --- T-LP-002: 引数2個以上 → exit 1 ---

@test "T-LP-002: line_push.sh exits 1 with usage when too many arguments" {
    export LINE_CHANNEL_ACCESS_TOKEN="dummy_token"
    export LINE_USER_ID="Udummy"
    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "message1" "message2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

# ═══════════════════════════════════════════════════════════════
# 認証情報バリデーションテスト
# （分離環境: config/line.envなし → env varsのみ参照）
# ═══════════════════════════════════════════════════════════════

# --- T-LP-003: LINE_CHANNEL_ACCESS_TOKEN未設定 → exit 1 ---

@test "T-LP-003: line_push.sh exits 1 when LINE_CHANNEL_ACCESS_TOKEN is not set" {
    # 分離環境にline.envなし。LINE_USER_IDのみ設定
    export LINE_USER_ID="Udummy_user_id_12345"
    unset LINE_CHANNEL_ACCESS_TOKEN

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "test message"
    [ "$status" -eq 1 ]
    [[ "$output" == *"LINE_CHANNEL_ACCESS_TOKEN"* ]]
}

# --- T-LP-004: LINE_USER_ID未設定 → exit 1 ---

@test "T-LP-004: line_push.sh exits 1 when LINE_USER_ID is not set" {
    # 分離環境にline.envなし。LINE_CHANNEL_ACCESS_TOKENのみ設定
    export LINE_CHANNEL_ACCESS_TOKEN="dummy_channel_token"
    unset LINE_USER_ID

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "test message"
    [ "$status" -eq 1 ]
    [[ "$output" == *"LINE_USER_ID"* ]]
}

# ═══════════════════════════════════════════════════════════════
# 正常送信テスト
# ═══════════════════════════════════════════════════════════════

# --- T-LP-005: 正常送信（curlモック）→ exit 0 ---

@test "T-LP-005: line_push.sh sends message via curl to LINE API" {
    export LINE_CHANNEL_ACCESS_TOKEN="test_token_12345"
    export LINE_USER_ID="Utest_user_id_12345"

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "hello LINE"
    [ "$status" -eq 0 ]

    # curl が呼ばれたことを確認
    [ -f "$CURL_LOG" ]

    # LINE Push API エンドポイントが使われているか確認
    grep -q "line.me/v2/bot/message/push" "$CURL_LOG"

    # Bearer 認証ヘッダーが使われているか確認
    grep -q "Bearer test_token_12345" "$CURL_LOG"

    # ユーザーIDがペイロードに含まれているか確認
    grep -q "Utest_user_id_12345" "$CURL_LOG"

    # メッセージが含まれているか確認
    grep -q "hello LINE" "$CURL_LOG"
}

# ═══════════════════════════════════════════════════════════════
# メッセージエスケープテスト
# ═══════════════════════════════════════════════════════════════

# --- T-LP-006: ダブルクォートのエスケープ ---

@test "T-LP-006: line_push.sh escapes double quotes in message for JSON safety" {
    export LINE_CHANNEL_ACCESS_TOKEN="test_token"
    export LINE_USER_ID="Utest"

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" 'say "hello" world'
    [ "$status" -eq 0 ]

    [ -f "$CURL_LOG" ]
    # ダブルクォートが \" にエスケープされているか確認
    grep -q '\\"hello\\"' "$CURL_LOG"
}

# --- T-LP-007: バックスラッシュのエスケープ ---

@test "T-LP-007: line_push.sh escapes backslashes in message for JSON safety" {
    export LINE_CHANNEL_ACCESS_TOKEN="test_token"
    export LINE_USER_ID="Utest"

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" 'path\to\file'
    [ "$status" -eq 0 ]

    [ -f "$CURL_LOG" ]
    # バックスラッシュが \\ にエスケープされているか確認
    grep -q '\\\\' "$CURL_LOG"
}

# --- T-LP-008: 改行のエスケープ ---

@test "T-LP-008: line_push.sh escapes newlines in message for JSON safety" {
    export LINE_CHANNEL_ACCESS_TOKEN="test_token"
    export LINE_USER_ID="Utest"

    # $'\n' で改行を含むメッセージを作成
    local msg
    msg=$'first line\nsecond line'

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "$msg"
    [ "$status" -eq 0 ]

    [ -f "$CURL_LOG" ]
    # 改行が \n にエスケープされているか確認（リテラルな改行ではなくエスケープ済み）
    grep -q '\\n' "$CURL_LOG"
    # リテラルな改行（改行文字）がJSONボディ内にないこと
    local json_line
    json_line=$(grep "line.me" "$CURL_LOG")
    [[ "$json_line" != *$'\n'* ]]
}

# ═══════════════════════════════════════════════════════════════
# line.env読み込みテスト
# ═══════════════════════════════════════════════════════════════

# --- T-LP-009: config/line.envから認証情報を読み込む ---

@test "T-LP-009: line_push.sh loads credentials from config/line.env when present" {
    # 分離環境のconfig/line.envに認証情報を追記
    cat > "$ISOLATED_SCRIPT_DIR/../config/line.env" << 'EOF'
LINE_CHANNEL_ACCESS_TOKEN=token_from_env_file
LINE_USER_ID=Ufrom_env_file
EOF

    # 環境変数は未設定（envファイルから読み込まれるべき）
    unset LINE_CHANNEL_ACCESS_TOKEN
    unset LINE_USER_ID

    run bash "$ISOLATED_SCRIPT_DIR/line_push.sh" "env file test"
    [ "$status" -eq 0 ]

    [ -f "$CURL_LOG" ]
    grep -q "Bearer token_from_env_file" "$CURL_LOG"
    grep -q "Ufrom_env_file" "$CURL_LOG"
}

# ═══════════════════════════════════════════════════════════════
# ファイル存在・git追跡確認テスト
# ═══════════════════════════════════════════════════════════════

# --- T-LP-010: line.env.sampleファイル存在確認 ---

@test "T-LP-010: config/line.env.sample exists with required fields" {
    local sample="$PROJECT_ROOT/config/line.env.sample"
    [ -f "$sample" ]
    grep -q "LINE_CHANNEL_ACCESS_TOKEN" "$sample"
    grep -q "LINE_USER_ID" "$sample"
}

# --- T-LP-011: line.env本体はgit非追跡確認 ---

@test "T-LP-011: config/line.env is not tracked by git" {
    cd "$PROJECT_ROOT"
    # git check-ignoreでgitが無視することを確認
    run git check-ignore config/line.env
    [ "$status" -eq 0 ]
}
