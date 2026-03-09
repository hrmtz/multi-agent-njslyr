#!/usr/bin/env bats
# test_cross_sync.bats — cross_sync.sh ユニットテスト
# cmd_275 Round3: SEC-001 入力バリデーション + サブコマンド + 前提条件
#
# テスト構成:
#   T-CS-001: PEER_HOST空文字でエラー終了
#   T-CS-002: PEER_HOST不正文字（セミコロン等）でエラー終了
#   T-CS-003: PEER_PROJECT_ROOT ".." 含むパスでエラー終了
#   T-CS-004: PEER_PROJECT_ROOT相対パスでエラー終了
#   T-CS-005: push/pull以外のサブコマンドでusage表示
#   T-CS-006: settings.yaml未存在でエラー終了
#   T-CS-007: flock取得失敗時のタイムアウト動作

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CROSS_SYNC="$PROJECT_ROOT/scripts/cross_sync.sh"

    [ -f "$CROSS_SYNC" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/cross_sync_test.XXXXXX")"

    # Build a minimal fake project structure for cross_sync.sh
    export FAKE_PROJECT="$TEST_TMPDIR/project"
    mkdir -p "$FAKE_PROJECT/scripts"
    mkdir -p "$FAKE_PROJECT/config"
    mkdir -p "$FAKE_PROJECT/.state"
    mkdir -p "$FAKE_PROJECT/logs"

    # Copy cross_sync.sh to fake project so SCRIPT_DIR resolves correctly
    cp "$CROSS_SYNC" "$FAKE_PROJECT/scripts/cross_sync.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# Helper: create settings.yaml with given peer_host and peer_project_root
_write_settings() {
    local host="$1"
    local root="$2"
    cat > "$FAKE_PROJECT/config/settings.yaml" <<EOF
machine:
  role: ryzen
  peer_host: $host
  peer_project_root: $root
EOF
}

# --- T-CS-001: PEER_HOST空文字でエラー終了 ---

@test "T-CS-001: PEER_HOST空文字でエラー終了" {
    _write_settings "" "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_HOST"
}

# --- T-CS-002: PEER_HOST不正文字（セミコロン等）でエラー終了 ---

@test "T-CS-002: PEER_HOST不正文字（セミコロン等）でエラー終了" {
    _write_settings "host;rm -rf /" "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_HOST"
}

# --- T-CS-003: PEER_PROJECT_ROOT ".." 含むパスでエラー終了 ---

@test "T-CS-003: PEER_PROJECT_ROOT '..' 含むパスでエラー終了" {
    _write_settings "validhost" "/home/user/../etc/passwd"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_PROJECT_ROOT"
}

# --- T-CS-004: PEER_PROJECT_ROOT相対パスでエラー終了 ---

@test "T-CS-004: PEER_PROJECT_ROOT相対パスでエラー終了" {
    _write_settings "validhost" "relative/path/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_PROJECT_ROOT"
}

# --- T-CS-005: push/pull以外のサブコマンドでusage表示 ---

@test "T-CS-005: push/pull以外のサブコマンドでusage表示" {
    _write_settings "validhost" "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" status
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "usage"
}

# --- T-CS-005b: サブコマンドなしでusage表示 ---

@test "T-CS-005b: サブコマンドなしでusage表示" {
    _write_settings "validhost" "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "usage"
}

# --- T-CS-006: settings.yaml未存在でエラー終了 ---

@test "T-CS-006: settings.yaml未存在でエラー終了" {
    # Don't create settings.yaml — leave config dir empty
    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
}

# --- T-CS-007: flock取得失敗時のタイムアウト動作 ---

@test "T-CS-007: flock取得失敗時のタイムアウト動作" {
    _write_settings "validhost" "/home/user/project"

    # Pre-acquire the lock file with flock in background
    local lockfile="$FAKE_PROJECT/.state/njslyr_sync.lock"
    mkdir -p "$(dirname "$lockfile")"

    # Hold the lock in a background subshell
    (
        flock -n 200 || exit 1
        sleep 10
    ) 200>"$lockfile" &
    local lock_pid=$!

    # Small delay to ensure lock is acquired
    sleep 0.2

    # cross_sync.sh should fail because flock -n cannot acquire the lock
    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "already running"

    # Cleanup background process
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true
}

# --- T-CS-008: PEER_HOST shellインジェクション (バッククォート) ---

@test "T-CS-008: PEER_HOST shellインジェクション (バッククォート) でエラー終了" {
    _write_settings '`whoami`' "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_HOST"
}

# --- T-CS-009: PEER_PROJECT_ROOT空文字でエラー終了 ---

@test "T-CS-009: PEER_PROJECT_ROOT空文字でエラー終了" {
    _write_settings "validhost" ""

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_PROJECT_ROOT"
}

# --- T-CS-010: PEER_HOST $() コマンド置換でエラー終了 ---

@test "T-CS-010: PEER_HOST \$() コマンド置換でエラー終了" {
    _write_settings '$(whoami)' "/home/user/project"

    run bash "$FAKE_PROJECT/scripts/cross_sync.sh" push
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid PEER_HOST"
}
