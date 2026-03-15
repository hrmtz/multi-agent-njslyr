#!/bin/bash
# test_inbox_write.sh — inbox_write.sh の単体テストスクリプト
# Usage: bash scripts/test_inbox_write.sh
# 実際のinboxファイルを汚染しない設計（テスト用ダミーエージェント名を使用）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INBOX_WRITE="$SCRIPT_DIR/scripts/inbox_write.sh"
TEST_AGENT="test_dummy_$$"
TEST_INBOX="$SCRIPT_DIR/queue/inbox/${TEST_AGENT}.yaml"
PASS=0
FAIL=0

# ─── ヘルパー関数 ───

pass() {
    echo "  [PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL=$((FAIL + 1))
}

assert_exit_ok() {
    local label="$1"
    local exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        pass "$label"
    else
        fail "$label (exit code: $exit_code)"
    fi
}

assert_exit_fail() {
    local label="$1"
    local exit_code="$2"
    if [ "$exit_code" -ne 0 ]; then
        pass "$label (exit code: $exit_code, expected non-zero)"
    else
        fail "$label (expected non-zero exit but got 0)"
    fi
}

assert_yaml_contains() {
    local label="$1"
    local pattern="$2"
    if grep -q "$pattern" "$TEST_INBOX" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (pattern not found: $pattern)"
    fi
}

assert_yaml_not_contains() {
    local label="$1"
    local pattern="$2"
    if ! grep -q "$pattern" "$TEST_INBOX" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (unexpected pattern found: $pattern)"
    fi
}

# ─── テスト前後のセットアップ/クリーンアップ ───

setup() {
    # テスト用inboxファイルを初期化
    echo "messages: []" > "$TEST_INBOX"
}

cleanup() {
    # テスト用inboxを削除
    rm -f "$TEST_INBOX" "${TEST_INBOX}.lock" 2>/dev/null || true
}

trap cleanup EXIT

# ─── テスト開始 ───

echo "=== inbox_write.sh テスト開始 ==="
echo "テスト用エージェント: $TEST_AGENT"
echo "テスト用inbox: $TEST_INBOX"
echo ""

# ────────────────────────────────────────────────────────────
# TC-01: 通常メッセージ送信（全引数あり）
# ────────────────────────────────────────────────────────────
echo "--- TC-01: 通常メッセージ送信（全引数あり） ---"
setup

exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" "テストメッセージ" "report_received" "yakuza4" "queue/tasks/test.yaml" "P1" >/dev/null 2>&1 || exit_code=$?

assert_exit_ok "TC-01-01: exit code = 0" "$exit_code"
assert_yaml_contains "TC-01-02: メッセージが書き込まれた" "テストメッセージ"
assert_yaml_contains "TC-01-03: fromが正しい" "from: yakuza4"
assert_yaml_contains "TC-01-04: typeが正しい" "type: report_received"
assert_yaml_contains "TC-01-05: priorityが正しい（P1）" "priority: P1"
assert_yaml_contains "TC-01-06: task_yaml_pathが記録された" "task_yaml_path: queue/tasks/test.yaml"
assert_yaml_contains "TC-01-07: read: falseで未読" "read: false"
assert_yaml_contains "TC-01-08: message IDが生成された" "id: msg_"

# ────────────────────────────────────────────────────────────
# TC-02: task_yaml_path省略時（空文字）
# ────────────────────────────────────────────────────────────
echo ""
echo "--- TC-02: task_yaml_path省略時（空文字） ---"
setup

exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" "YAMLパスなしメッセージ" "task_assigned" "smith" "" "P2" >/dev/null 2>&1 || exit_code=$?

assert_exit_ok "TC-02-01: exit code = 0（空文字でもエラーなし）" "$exit_code"
assert_yaml_contains "TC-02-02: メッセージが書き込まれた" "YAMLパスなしメッセージ"
assert_yaml_not_contains "TC-02-03: task_yaml_pathが含まれない" "task_yaml_path"

# ────────────────────────────────────────────────────────────
# TC-03: priority省略時（type別デフォルト）
# ────────────────────────────────────────────────────────────
echo ""
echo "--- TC-03: priority省略時（type別デフォルト） ---"

# TC-03-01: task_assigned → P2
setup
bash "$INBOX_WRITE" "$TEST_AGENT" "P2デフォルトテスト" "task_assigned" "smith" "" >/dev/null 2>&1 || true
assert_yaml_contains "TC-03-01: task_assigned → priority P2（デフォルト）" "priority: P2"

# TC-03-02: cmd_new → P0
setup
bash "$INBOX_WRITE" "$TEST_AGENT" "P0デフォルトテスト" "cmd_new" "darkninja" "" >/dev/null 2>&1 || true
assert_yaml_contains "TC-03-02: cmd_new → priority P0（デフォルト）" "priority: P0"

# TC-03-03: report_received（通常） → P1
setup
bash "$INBOX_WRITE" "$TEST_AGENT" "P1デフォルトテスト" "report_received" "soukaiya" "" >/dev/null 2>&1 || true
assert_yaml_contains "TC-03-03: report_received（通常）→ priority P1（デフォルト）" "priority: P1"

# TC-03-04: report_received（BLOCKING含む） → P0
setup
bash "$INBOX_WRITE" "$TEST_AGENT" "BLOCKING 緊急事態" "report_received" "soukaiya" "" >/dev/null 2>&1 || true
assert_yaml_contains "TC-03-04: report_received（BLOCKING含む）→ priority P0" "priority: P0"

# TC-03-05: 未知のtype → P3
setup
bash "$INBOX_WRITE" "$TEST_AGENT" "P3デフォルトテスト" "system_notice" "smith" "" >/dev/null 2>&1 || true
assert_yaml_contains "TC-03-05: 未知のtype → priority P3（デフォルト）" "priority: P3"

# ────────────────────────────────────────────────────────────
# TC-04: 不正な引数時のエラー処理
# ────────────────────────────────────────────────────────────
echo ""
echo "--- TC-04: 不正な引数時のエラー処理 ---"

# TC-04-01: 引数なし → エラー
exit_code=0
bash "$INBOX_WRITE" >/dev/null 2>&1 || exit_code=$?
assert_exit_fail "TC-04-01: 引数なし → 非ゼロ終了" "$exit_code"

# TC-04-02: target_agentのみ（contentなし）→ エラー
exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" >/dev/null 2>&1 || exit_code=$?
assert_exit_fail "TC-04-02: contentなし → 非ゼロ終了" "$exit_code"

# TC-04-03: 不正なpriority → エラー
exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" "テスト" "task_assigned" "smith" "" "INVALID" >/dev/null 2>&1 || exit_code=$?
assert_exit_fail "TC-04-03: 不正なpriority（INVALID）→ 非ゼロ終了" "$exit_code"

# TC-04-04: 不正なpriority（P5）→ エラー
exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" "テスト" "task_assigned" "smith" "" "P5" >/dev/null 2>&1 || exit_code=$?
assert_exit_fail "TC-04-04: 不正なpriority（P5）→ 非ゼロ終了" "$exit_code"

# ────────────────────────────────────────────────────────────
# TC-05: 並行書き込みのflock動作（概念テスト）
# ────────────────────────────────────────────────────────────
echo ""
echo "--- TC-05: 並行書き込みのflock動作（概念テスト） ---"
setup

# set -eu を一時無効（バックグラウンドジョブ + コマンド置換との競合を回避）
set +eu

# 10件を並行して書き込む
for i in $(seq 1 10); do
    bash "$INBOX_WRITE" "$TEST_AGENT" "並行メッセージ $i" "task_assigned" "smith" "" "P2" >/dev/null 2>&1 &
done
wait  # 全バックグラウンドジョブ完了を待つ

# メッセージ数を検証（10件すべて書き込まれているはず）
msg_count=$(python3 -c "
import yaml
try:
    with open('$TEST_INBOX') as f:
        data = yaml.safe_load(f)
    print(len(data.get('messages', [])))
except:
    print(0)
" 2>/dev/null)
msg_count=${msg_count:-0}

if [ "$msg_count" -eq 10 ]; then
    pass "TC-05-01: 並行10件書き込み → 全件保存（count=$msg_count）"
else
    fail "TC-05-01: 並行10件書き込み → 期待10件、実際${msg_count}件"
fi

# YAMLが壊れていないことを確認
python3 -c "
import yaml, sys
try:
    with open('$TEST_INBOX') as f:
        data = yaml.safe_load(f)
    assert isinstance(data, dict), 'YAML構造が不正'
    assert 'messages' in data, 'messagesキーがない'
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
yaml_exit=$?
if [ "$yaml_exit" -eq 0 ]; then
    pass "TC-05-02: 並行書き込み後もYAMLが正常構造を維持"
else
    fail "TC-05-02: YAMLが壊れた"
fi

# set -eu を再有効化
set -eu

# ────────────────────────────────────────────────────────────
# TC-06: 既存inboxがない場合の自動初期化
# ────────────────────────────────────────────────────────────
echo ""
echo "--- TC-06: inboxファイル自動初期化 ---"
# テスト用inboxを削除してから書き込む
rm -f "$TEST_INBOX"

exit_code=0
bash "$INBOX_WRITE" "$TEST_AGENT" "初期化テスト" "task_assigned" "smith" "" >/dev/null 2>&1 || exit_code=$?

assert_exit_ok "TC-06-01: inboxなしでもexitcode=0" "$exit_code"
if [ -f "$TEST_INBOX" ]; then
    pass "TC-06-02: inboxが自動作成された"
else
    fail "TC-06-02: inboxが作成されなかった"
fi
assert_yaml_contains "TC-06-03: メッセージが書き込まれた" "初期化テスト"

# ─── 結果サマリー ───

echo ""
echo "=== テスト結果 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
TOTAL=$((PASS + FAIL))
echo "TOTAL: $TOTAL"

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "[ALL PASS] ワザマエ！全テスト通過。"
    exit 0
else
    echo ""
    echo "[FAIL] ${FAIL}件のテストが失敗した。"
    exit 1
fi
