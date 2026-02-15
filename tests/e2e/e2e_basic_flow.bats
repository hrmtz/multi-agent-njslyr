#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-001: Basic Flow Test
# ═══════════════════════════════════════════════════════════════
# Validates the core orchestration flow:
#   1. cmd YAML placed → gryakuza inbox notified
#   2. gryakuza processes cmd → creates subtask for yakuza1
#   3. yakuza1 receives task_assigned → processes task
#   4. yakuza1 writes completion report
#   5. yakuza1 notifies gryakuza → gryakuza receives report_received
#
# Uses mock_cli.sh (no real AI APIs needed).
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# Load E2E helpers
E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

# ─── Lifecycle ───

setup_file() {
    # Skip in CI if tmux is not available
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 3
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    # Wait briefly for mock CLIs to be ready
    sleep 1
}

# ═══════════════════════════════════════════════════════════════
# E2E-001-A: Direct task assignment to yakuza
# ═══════════════════════════════════════════════════════════════
# Simplified flow: place task YAML + send inbox nudge → yakuza processes

@test "E2E-001-A: yakuza1 processes assigned task via inbox nudge" {
    # 1. Place task YAML for yakuza1
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_yakuza1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/yakuza1.yaml"

    # 2. Write task_assigned to yakuza1's inbox
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "yakuza1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "gryakuza"

    # 3. Send inbox nudge to yakuza1
    local yakuza1_pane
    yakuza1_pane=$(pane_target 1)
    send_to_pane "$yakuza1_pane" "inbox1"

    # 4. Wait for task to complete (status → done)
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.status" "done" 30
    assert_success

    # 5. Verify report was written
    run wait_for_file "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" 10
    assert_success

    # 6. Verify report content
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" "status" "done"
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" "worker_id" "yakuza1"
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" "task_id" "subtask_test_001a"

    # 7. Verify inbox was processed (all read)
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/yakuza1.yaml" 0
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-001-B: Gryakuza decomposes cmd into subtask for yakuza
# ═══════════════════════════════════════════════════════════════

@test "E2E-001-B: gryakuza receives cmd, decomposes into yakuza subtask" {
    # 1. Place cmd YAML for gryakuza
    cp "$PROJECT_ROOT/tests/e2e/fixtures/cmd_basic.yaml" \
       "$E2E_QUEUE/queue/darkninja_to_gryakuza.yaml"

    # 2. Write cmd_new to gryakuza's inbox
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "gryakuza" \
        "cmd_test_001を発行した。" "cmd_new" "darkninja"

    # 3. Send nudge to gryakuza — gryakuza reads inbox, sees cmd_new, decomposes
    local gryakuza_pane
    gryakuza_pane=$(pane_target 0)
    send_to_pane "$gryakuza_pane" "inbox1"

    # 4. Wait for gryakuza to create subtask for yakuza1
    run wait_for_file "$E2E_QUEUE/queue/tasks/yakuza1.yaml" 20
    assert_success

    # 5. Verify subtask was created with correct structure
    assert_yaml_field "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.status" "assigned"
    assert_yaml_field "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.parent_cmd" "cmd_test_001"

    # 6. Wait and verify yakuza1 received task_assigned inbox
    sleep 3
    run assert_inbox_message_exists "$E2E_QUEUE/queue/inbox/yakuza1.yaml" "gryakuza" "task_assigned"
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-001-C: Full flow — cmd → decompose → execute → report
# ═══════════════════════════════════════════════════════════════

@test "E2E-001-C: full flow from cmd to completion report" {
    # 1. Place cmd YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/cmd_basic.yaml" \
       "$E2E_QUEUE/queue/darkninja_to_gryakuza.yaml"

    local gryakuza_pane yakuza1_pane
    gryakuza_pane=$(pane_target 0)
    yakuza1_pane=$(pane_target 1)

    # 2. Trigger gryakuza to decompose (inbox1 → process_inbox detects cmd_new → decompose)
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "gryakuza" \
        "cmd_test_001を発行した。" "cmd_new" "darkninja"
    send_to_pane "$gryakuza_pane" "inbox1"

    # 3. Wait for subtask creation
    run wait_for_file "$E2E_QUEUE/queue/tasks/yakuza1.yaml" 20
    assert_success

    # 4. Trigger yakuza1 to process
    send_to_pane "$yakuza1_pane" "inbox1"

    # 5. Wait for completion
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.status" "done" 30
    assert_success

    # 6. Verify report exists
    run wait_for_file "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" 10
    assert_success

    # 7. Verify report fields
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" "status" "done"

    # 8. Verify gryakuza received report notification
    sleep 2
    run assert_inbox_message_exists "$E2E_QUEUE/queue/inbox/gryakuza.yaml" "yakuza1" "report_received"
    assert_success
}
