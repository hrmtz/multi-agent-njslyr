#!/usr/bin/env bats
# test_inbox_archive.bats — inbox_archive.sh ユニットテスト
#
# テスト構成:
#   T-A01: 引数バリデーション — agent_id未指定でexit 1
#   T-A02: --keep 不正値でexit 1
#   T-A03: inboxファイル不在でexit 0（グレースフル）
#   T-A04: read:true メッセージが --keep=0 でアーカイブに移動される
#   T-A05: --keep N で最新N件のread:trueが元ファイルに残る
#   T-A06: read:false メッセージは常に保持される
#   T-A07: アーカイブファイルの構造検証

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INBOX_ARCHIVE_SCRIPT="$PROJECT_ROOT/scripts/inbox_archive.sh"

    [ -f "$INBOX_ARCHIVE_SCRIPT" ] || return 1
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_archive_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    # inbox_archive.sh の SCRIPT_DIR をテスト用 tmpdir に差し替え
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_archive.sh" > "$TEST_SCRIPT_DIR/inbox_archive.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_archive.sh"

    export TEST_ARCHIVE_SCRIPT="$TEST_SCRIPT_DIR/inbox_archive.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ヘルパー: テスト用inboxを生成
create_test_inbox() {
    local agent_id="$1"
    local inbox_file="$TEST_INBOX_DIR/${agent_id}.yaml"
    cat > "$inbox_file" << 'EOF'
messages:
- content: 'メッセージ1（read済）'
  from: smith
  id: msg_001
  priority: P2
  read: true
  timestamp: '2026-02-18T01:00:00'
  type: task_assigned
- content: 'メッセージ2（read済）'
  from: smith
  id: msg_002
  priority: P2
  read: true
  timestamp: '2026-02-18T02:00:00'
  type: task_assigned
- content: 'メッセージ3（read済）'
  from: smith
  id: msg_003
  priority: P1
  read: true
  timestamp: '2026-02-18T03:00:00'
  type: report_received
- content: 'メッセージ4（未読）'
  from: darkninja
  id: msg_004
  priority: P1
  read: false
  timestamp: '2026-02-18T04:00:00'
  type: task_assigned
EOF
    echo "$inbox_file"
}

# =============================================================================
# T-A01: 引数バリデーション — agent_id未指定でexit 1
# =============================================================================

@test "T-A01: no arguments → exit 1 with Usage message" {
    run bash "$TEST_ARCHIVE_SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

# =============================================================================
# T-A02: --keep 不正値でexit 1
# =============================================================================

@test "T-A02: --keep with non-integer value → exit 1" {
    create_test_inbox "test_agent"
    run bash "$TEST_ARCHIVE_SCRIPT" "test_agent" --keep abc
    [ "$status" -eq 1 ]
    [[ "$output" =~ "integer" ]]
}

# =============================================================================
# T-A03: inboxファイル不在でexit 0（グレースフル）
# =============================================================================

@test "T-A03: missing inbox file → exit 0 gracefully" {
    run bash "$TEST_ARCHIVE_SCRIPT" "nonexistent_agent"
    [ "$status" -eq 0 ]
}

# =============================================================================
# T-A04: read:true メッセージが --keep=0 でアーカイブに移動される
# =============================================================================

@test "T-A04: --keep=0 → all read:true messages moved to archive" {
    create_test_inbox "test_agent"

    run bash "$TEST_ARCHIVE_SCRIPT" "test_agent" --keep 0
    [ "$status" -eq 0 ]

    # アーカイブファイルが作成されていること
    local archive_count
    archive_count=$(ls "$TEST_INBOX_DIR/archive/test_agent_"*.yaml 2>/dev/null | wc -l)
    [ "$archive_count" -ge 1 ]

    # アーカイブに3件のread:trueが含まれること
    python3 << PYEOF
import yaml, sys, glob
files = sorted(glob.glob('$TEST_INBOX_DIR/archive/test_agent_*.yaml'))
with open(files[-1]) as f:
    data = yaml.safe_load(f)
msgs = data.get('messages', [])
assert len(msgs) == 3, f"Expected 3 archived messages, got {len(msgs)}"
assert all(m.get('read') for m in msgs), "All archived messages should have read:true"
PYEOF
    [ "$?" -eq 0 ]

    # 元ファイルにread:trueのメッセージが残っていないこと
    python3 << PYEOF
import yaml
with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)
msgs = data.get('messages', [])
read_msgs = [m for m in msgs if m.get('read')]
assert len(read_msgs) == 0, f"Expected 0 read:true messages in inbox, got {len(read_msgs)}"
PYEOF
    [ "$?" -eq 0 ]
}

# =============================================================================
# T-A05: --keep N で最新N件のread:trueが元ファイルに残る
# =============================================================================

@test "T-A05: --keep=2 → 2 most recent read:true messages kept in inbox" {
    create_test_inbox "test_agent"

    run bash "$TEST_ARCHIVE_SCRIPT" "test_agent" --keep 2
    [ "$status" -eq 0 ]

    # 元ファイルにread:trueが2件残ること
    python3 << PYEOF
import yaml
with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)
msgs = data.get('messages', [])
read_msgs = [m for m in msgs if m.get('read')]
assert len(read_msgs) == 2, f"Expected 2 read:true messages kept, got {len(read_msgs)}"
# 最新2件（msg_002, msg_003）が残っていること
ids = [m['id'] for m in read_msgs]
assert 'msg_002' in ids, "msg_002 should be kept"
assert 'msg_003' in ids, "msg_003 should be kept"
PYEOF
    [ "$?" -eq 0 ]

    # アーカイブに1件（msg_001）が移動していること
    python3 << PYEOF
import yaml, glob
files = sorted(glob.glob('$TEST_INBOX_DIR/archive/test_agent_*.yaml'))
with open(files[-1]) as f:
    data = yaml.safe_load(f)
msgs = data.get('messages', [])
assert len(msgs) == 1, f"Expected 1 archived message, got {len(msgs)}"
assert msgs[0]['id'] == 'msg_001', f"Expected msg_001 archived, got {msgs[0]['id']}"
PYEOF
    [ "$?" -eq 0 ]
}

# =============================================================================
# T-A06: read:false メッセージは常に保持される
# =============================================================================

@test "T-A06: read:false messages always preserved regardless of --keep" {
    create_test_inbox "test_agent"

    run bash "$TEST_ARCHIVE_SCRIPT" "test_agent" --keep 0
    [ "$status" -eq 0 ]

    # read:falseのメッセージが元ファイルに残ること
    python3 << PYEOF
import yaml
with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)
msgs = data.get('messages', [])
unread = [m for m in msgs if not m.get('read', False)]
assert len(unread) == 1, f"Expected 1 unread message, got {len(unread)}"
assert unread[0]['id'] == 'msg_004', f"Expected msg_004, got {unread[0]['id']}"
PYEOF
    [ "$?" -eq 0 ]
}

# =============================================================================
# T-A07: アーカイブファイルの構造検証
# =============================================================================

@test "T-A07: archive file has correct structure (agent_id, archived_at, source, messages)" {
    create_test_inbox "test_agent"

    run bash "$TEST_ARCHIVE_SCRIPT" "test_agent" --keep 0
    [ "$status" -eq 0 ]

    python3 << PYEOF
import yaml, glob
files = sorted(glob.glob('$TEST_INBOX_DIR/archive/test_agent_*.yaml'))
assert len(files) >= 1, "Archive file should exist"
with open(files[-1]) as f:
    data = yaml.safe_load(f)
assert data.get('agent_id') == 'test_agent', f"agent_id missing or wrong: {data.get('agent_id')}"
assert data.get('archived_at'), "archived_at field missing"
assert data.get('source'), "source field missing"
assert isinstance(data.get('messages'), list), "messages should be a list"
PYEOF
    [ "$?" -eq 0 ]
}
