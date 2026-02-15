#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-006: Parallel Tasks Test
# ═══════════════════════════════════════════════════════════════
# Validates that multiple yakuza can process tasks simultaneously:
#   1. Two tasks assigned to yakuza1 and yakuza2
#   2. Both receive inbox nudges
#   3. Both complete independently
#   4. Both reports are written
#
# Uses 3-pane setup (gryakuza + yakuza1 + yakuza2).
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
    sleep 1
}

# ═══════════════════════════════════════════════════════════════
# E2E-006-A: Two yakuza process tasks in parallel
# ═══════════════════════════════════════════════════════════════

@test "E2E-006-A: yakuza1 and yakuza2 complete tasks in parallel" {
    # 1. Place tasks for both yakuza
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_yakuza1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/yakuza1.yaml"
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_yakuza2_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/yakuza2.yaml"

    # 2. Send task_assigned to both inboxes
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "yakuza1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "gryakuza"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "yakuza2" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "gryakuza"

    # 3. Nudge both simultaneously
    local yakuza1_pane yakuza2_pane
    yakuza1_pane=$(pane_target 1)
    yakuza2_pane=$(pane_target 2)

    send_to_pane "$yakuza1_pane" "inbox1"
    send_to_pane "$yakuza2_pane" "inbox1"

    # 4. Both should complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.status" "done" 30
    assert_success
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza2.yaml" "task.status" "done" 30
    assert_success

    # 5. Both reports should exist
    run wait_for_file "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" 10
    assert_success
    run wait_for_file "$E2E_QUEUE/queue/reports/yakuza2_report.yaml" 10
    assert_success

    # 6. Reports should have correct agent IDs
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza1_report.yaml" "worker_id" "yakuza1"
    assert_yaml_field "$E2E_QUEUE/queue/reports/yakuza2_report.yaml" "worker_id" "yakuza2"
}

# ═══════════════════════════════════════════════════════════════
# E2E-006-B: Parallel tasks don't interfere with each other's inbox
# ═══════════════════════════════════════════════════════════════

@test "E2E-006-B: parallel tasks maintain inbox isolation" {
    # 1. Place tasks and send notifications
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_yakuza1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/yakuza1.yaml"
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_yakuza2_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/yakuza2.yaml"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "yakuza1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "gryakuza"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "yakuza2" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "gryakuza"

    local yakuza1_pane yakuza2_pane
    yakuza1_pane=$(pane_target 1)
    yakuza2_pane=$(pane_target 2)

    send_to_pane "$yakuza1_pane" "inbox1"
    send_to_pane "$yakuza2_pane" "inbox1"

    # 2. Wait for both to complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza1.yaml" "task.status" "done" 30
    assert_success
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/yakuza2.yaml" "task.status" "done" 30
    assert_success

    # 3. Each inbox should have its own messages (task_assigned from gryakuza + no cross-contamination)
    # yakuza1's inbox should NOT have yakuza2's messages
    run python3 -c "
import yaml
with open('$E2E_QUEUE/queue/inbox/yakuza1.yaml') as f:
    data = yaml.safe_load(f) or {}
msgs = data.get('messages', [])
# All messages in yakuza1's inbox should be addressed to yakuza1 context
# (no yakuza2 task_assigned should appear here)
for m in msgs:
    if m.get('type') == 'task_assigned' and 'yakuza2' in str(m.get('content', '')):
        print('CROSS-CONTAMINATION DETECTED')
        exit(1)
"
    assert_success
}
