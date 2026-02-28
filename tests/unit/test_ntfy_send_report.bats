#!/usr/bin/env bats
# test_ntfy_send_report.bats — ntfy_send_report.sh ユニットテスト (cmd_278i)
#
# テスト構成:
#   T-NSR-001: FIX-003 — Tags: outbound ヘッダーがcurlに含まれること
#   T-NSR-002: FIX-010 — HTTP 4xx → exit 1 + エラーメッセージ
#   T-NSR-003: FIX-010 — HTTP 200 → 正常終了 + ステータス表示
#   T-NSR-004: FIX-010 — curl自体の失敗(exit !=0) → exit 1

# --- セットアップ ---

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    TEST_TMP="$(mktemp -d "$BATS_TMPDIR/ntfy_send_report_test.XXXXXX")"

    # Mock project structure
    MOCK_PROJECT="$TEST_TMP/project"
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts}

    # Mock settings.yaml
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
ntfy_topic: "test-topic-12345"
YAML

    # Mock ntfy_auth.sh
    cat > "$MOCK_PROJECT/lib/ntfy_auth.sh" << 'MOCK'
ntfy_get_auth_args() { echo ""; }
MOCK

    # Mock report YAML
    MOCK_REPORT="$TEST_TMP/test_report.yaml"
    cat > "$MOCK_REPORT" << 'YAML'
worker_id: yakuza4
task_id: subtask_278i
status: completed
YAML

    # Create mock bin directory
    mkdir -p "$TEST_TMP/mock_bin"

    # Mock base64 (just output a fixed string)
    cat > "$TEST_TMP/mock_bin/base64" << 'MOCK'
#!/bin/bash
echo "bW9ja19iYXNlNjRfb3V0cHV0"
MOCK
    chmod +x "$TEST_TMP/mock_bin/base64"

    # Mock tr (passthrough)
    cat > "$TEST_TMP/mock_bin/tr" << 'MOCK'
#!/bin/bash
cat
MOCK
    chmod +x "$TEST_TMP/mock_bin/tr"

    # Mock awk (returns topic)
    cat > "$TEST_TMP/mock_bin/awk" << 'MOCK'
#!/bin/bash
echo "test-topic-12345"
MOCK
    chmod +x "$TEST_TMP/mock_bin/awk"

    # Mock sleep (no-op for fast test execution — retry backoff uses sleep)
    cat > "$TEST_TMP/mock_bin/sleep" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TMP/mock_bin/sleep"

    # Mock date (for retry log timestamp)
    cat > "$TEST_TMP/mock_bin/date" << 'MOCK'
#!/bin/bash
echo "2026-02-28T01:00:00"
MOCK
    chmod +x "$TEST_TMP/mock_bin/date"

    # Mock mkdir (for log dir creation)
    cat > "$TEST_TMP/mock_bin/mkdir" << 'MOCK'
#!/bin/bash
command mkdir "$@"
MOCK
    chmod +x "$TEST_TMP/mock_bin/mkdir"

    # curl args log
    CURL_ARGS_LOG="$TEST_TMP/curl_args.log"
    export CURL_ARGS_LOG

    # Create the patched send script (replace SCRIPT_DIR)
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy_send_report.sh" > "$TEST_TMP/send_report.sh"
    chmod +x "$TEST_TMP/send_report.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: create a mock curl that returns a specific HTTP status
make_mock_curl() {
    local http_status="$1"
    local curl_exit="${2:-0}"
    cat > "$TEST_TMP/mock_bin/curl" << MOCK
#!/bin/bash
printf '%s\n' "\$@" >> "${CURL_ARGS_LOG}"
for arg in "\$@"; do
    if [[ "\$arg" == *"http_code"* ]]; then
        printf '%s' "${http_status}"
        exit ${curl_exit}
    fi
done
exit ${curl_exit}
MOCK
    chmod +x "$TEST_TMP/mock_bin/curl"
}

# ═══════════════════════════════════════════════════════════════
# FIX-011: ${TOPIC}-kyoto送信 + outboundタグ廃止テスト
# ═══════════════════════════════════════════════════════════════

@test "T-NSR-001: ntfy_send_report.sh sends to TOPIC-kyoto and excludes outbound tag" {
    make_mock_curl "200"

    run env PATH="$TEST_TMP/mock_bin:$PATH" bash "$TEST_TMP/send_report.sh" "$MOCK_REPORT"
    [ "$status" -eq 0 ]

    # Verify sends to -kyoto topic (FIX-011: topic separation instead of outbound tag)
    [ -f "$CURL_ARGS_LOG" ]
    grep -q "\-kyoto" "$CURL_ARGS_LOG"

    # outboundタグは含まれない
    ! grep -q "Tags: outbound" "$CURL_ARGS_LOG"
}

# ═══════════════════════════════════════════════════════════════
# FIX-010: HTTP status検証テスト
# ═══════════════════════════════════════════════════════════════

@test "T-NSR-002: ntfy_send_report.sh fails on HTTP 403 with error message" {
    make_mock_curl "403"

    run env PATH="$TEST_TMP/mock_bin:$PATH" bash "$TEST_TMP/send_report.sh" "$MOCK_REPORT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"POST failed"* ]]
    [[ "$output" == *"HTTP 403"* ]]
}

@test "T-NSR-003: ntfy_send_report.sh succeeds on HTTP 200 with status display" {
    make_mock_curl "200"

    run env PATH="$TEST_TMP/mock_bin:$PATH" bash "$TEST_TMP/send_report.sh" "$MOCK_REPORT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sent:"* ]]
    [[ "$output" == *"HTTP 200"* ]]
}

@test "T-NSR-004: ntfy_send_report.sh fails when curl exits non-zero" {
    make_mock_curl "000" 7

    run env PATH="$TEST_TMP/mock_bin:$PATH" bash "$TEST_TMP/send_report.sh" "$MOCK_REPORT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed after retries"* ]]
}
