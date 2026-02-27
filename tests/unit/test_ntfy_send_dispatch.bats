#!/usr/bin/env bats
# test_ntfy_send_dispatch.bats — ntfy_send_dispatch.sh ユニットテスト
# cmd_278 FIX-001
#
# テスト構成:
#   T-DISP-001: 正常系 - YAMLをbase64エンコードしてntfyへ送信
#   T-DISP-002: エラー系 - タスクファイル不在
#   T-DISP-003: エラー系 - settings.yaml不在
#   T-DISP-004: エラー系 - NTFY_TOPIC未設定
#   T-DISP-005: セキュリティ - path traversal拒否
#   T-DISP-006: 送信内容確認 - dispatch:プレフィックス + outboundタグ

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export DISPATCH_SCRIPT="$PROJECT_ROOT/scripts/ntfy_send_dispatch.sh"
    [ -f "$DISPATCH_SCRIPT" ] || return 1
}

setup() {
    export MOCK_DIR="$(mktemp -d "$BATS_TMPDIR/dispatch_test.XXXXXX")"

    # モックプロジェクト構造を構築
    mkdir -p "$MOCK_DIR/config" "$MOCK_DIR/scripts" "$MOCK_DIR/lib" "$MOCK_DIR/queue/tasks"

    # settings.yaml（正常系用）
    cat > "$MOCK_DIR/config/settings.yaml" << 'EOF'
ntfy_topic: bjk-test-topic-12345
machine:
  role: kyoto
  peer_host: peer-hostname
EOF

    # lib/ntfy_auth.sh（本物をコピー）
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_DIR/lib/"

    # テスト用タスクYAML
    cat > "$MOCK_DIR/queue/tasks/yakuza3_subtask_test.yaml" << 'EOF'
id: subtask_test
parent_cmd: cmd_278
assigned_to: yakuza3
status: assigned
EOF

    # curlモック（引数をログファイルに記録）
    export CURL_LOG="$MOCK_DIR/curl_args.log"
    cat > "$MOCK_DIR/mock_curl" << MOCK
#!/bin/bash
# curlモック: 引数を記録し、200を返す
echo "\$@" > "$CURL_LOG"
# -w '%{http_code}' に対して200を出力
echo -n "200"
MOCK
    chmod +x "$MOCK_DIR/mock_curl"

    # ntfy_send_dispatch.sh のモック版を作成（curlをモックに差し替え）
    sed \
        "s|SCRIPT_DIR=\"\$(cd.*|SCRIPT_DIR=\"$MOCK_DIR\"|" \
        "$DISPATCH_SCRIPT" > "$MOCK_DIR/scripts/ntfy_send_dispatch.sh"
    # curlをモックに差し替え
    sed -i "s|curl -s |$MOCK_DIR/mock_curl -s |" "$MOCK_DIR/scripts/ntfy_send_dispatch.sh"
    chmod +x "$MOCK_DIR/scripts/ntfy_send_dispatch.sh"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# --- T-DISP-001: 正常系 ---

@test "T-DISP-001: ntfy_send_dispatch sends YAML base64-encoded to ntfy neosaitama topic" {
    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" \
        "$MOCK_DIR/queue/tasks/yakuza3_subtask_test.yaml"

    [ "$status" -eq 0 ]
    # SUCCESSメッセージが出力される
    [[ "$output" == *"SUCCESS"* ]]
    # ntfy-neosaitamaトピック宛に送信されている
    [ -f "$CURL_LOG" ]
    grep -q "neosaitama" "$CURL_LOG"
}

# --- T-DISP-002: エラー系 - タスクファイル不在 ---

@test "T-DISP-002: ntfy_send_dispatch exits 1 when task file not found" {
    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" \
        "$MOCK_DIR/queue/tasks/nonexistent.yaml"

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"not found"* ]]
}

# --- T-DISP-003: エラー系 - settings.yaml不在 ---

@test "T-DISP-003: ntfy_send_dispatch exits 1 when settings.yaml not found" {
    # settings.yamlを削除してスタンドアロン状態に
    rm "$MOCK_DIR/config/settings.yaml"

    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" \
        "$MOCK_DIR/queue/tasks/yakuza3_subtask_test.yaml"

    [ "$status" -eq 1 ]
    [[ "$output" == *"settings.yaml not found"* ]]
    [[ "$output" == *"dispatch unavailable"* ]]
}

# --- T-DISP-004: エラー系 - NTFY_TOPIC未設定 ---

@test "T-DISP-004: ntfy_send_dispatch exits 1 when ntfy_topic not in settings.yaml" {
    # ntfy_topicを含まないsettings.yamlで上書き
    cat > "$MOCK_DIR/config/settings.yaml" << 'EOF'
machine:
  role: kyoto
EOF

    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" \
        "$MOCK_DIR/queue/tasks/yakuza3_subtask_test.yaml"

    [ "$status" -eq 1 ]
    [[ "$output" == *"ntfy_topic not configured"* ]]
}

# --- T-DISP-005: セキュリティ - path traversal拒否 ---

@test "T-DISP-005: ntfy_send_dispatch rejects path traversal outside project root" {
    # プロジェクト外のファイルを指定（/etc/passwdなど）
    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" "/etc/passwd"

    [ "$status" -eq 1 ]
    [[ "$output" == *"path traversal"* ]]
}

# --- T-DISP-006: 送信内容確認 - dispatch:プレフィックス + neosaitamaトピック (FIX-011) ---

@test "T-DISP-006: ntfy_send_dispatch sends dispatch: prefix to neosaitama topic without outbound tag" {
    run bash "$MOCK_DIR/scripts/ntfy_send_dispatch.sh" \
        "$MOCK_DIR/queue/tasks/yakuza3_subtask_test.yaml"

    [ "$status" -eq 0 ]
    [ -f "$CURL_LOG" ]

    # dispatch:プレフィックスが含まれる
    grep -q "dispatch:" "$CURL_LOG"

    # neosaitamaトピック宛に送信されている（トピック分離による自己ループ防止）
    grep -q "neosaitama" "$CURL_LOG"

    # Title: task_dispatch が設定されている
    grep -q "task_dispatch" "$CURL_LOG"

    # outboundタグは含まれない（FIX-011: マシン固有トピック方式に移行）
    ! grep -q "Tags: outbound" "$CURL_LOG"
}
