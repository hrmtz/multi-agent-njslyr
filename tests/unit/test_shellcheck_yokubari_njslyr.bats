#!/usr/bin/env bats
# test_shellcheck_yokubari_njslyr.bats — ShellCheck静的解析テスト
# cmd_275 Round3 Group C (subtask_275m)
#
# yokubari.sh + njslyr.sh の ShellCheck warning 0件を検証

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "shellcheck: yokubari.sh warning 0件" {
    run shellcheck -S warning "$PROJECT_ROOT/yokubari.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: scripts/njslyr.sh warning 0件" {
    run shellcheck -S warning "$PROJECT_ROOT/scripts/njslyr.sh"
    [ "$status" -eq 0 ]
}
