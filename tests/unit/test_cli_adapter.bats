#!/usr/bin/env bats
# test_cli_adapter.bats — cli_adapter.sh ユニットテスト
# Multi-CLI統合設計書 §4.1 準拠

# --- セットアップ ---

setup() {
    # テスト用のtmpディレクトリ
    TEST_TMP="$(mktemp -d)"

    # プロジェクトルート
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # デフォルトsettings（cliセクションなし = 後方互換テスト）
    cat > "${TEST_TMP}/settings_none.yaml" << 'YAML'
language: ja
shell: bash
display_mode: shout
YAML

    # claude only settings
    cat > "${TEST_TMP}/settings_claude_only.yaml" << 'YAML'
cli:
  default: claude
YAML

    # mixed CLI settings (dict形式)
    cat > "${TEST_TMP}/settings_mixed.yaml" << 'YAML'
cli:
  default: claude
  agents:
    darkninja:
      type: claude
      model: opus
    gryakuza:
      type: claude
      model: opus
    yakuza1:
      type: claude
      model: sonnet
    yakuza2:
      type: claude
      model: sonnet
    yakuza3:
      type: claude
      model: sonnet
    yakuza4:
      type: claude
      model: sonnet
    yakuza5:
      type: codex
    yakuza6:
      type: codex
    yakuza7:
      type: copilot
    yakuza8:
      type: copilot
YAML

    # 文字列形式のagent設定
    cat > "${TEST_TMP}/settings_string_agents.yaml" << 'YAML'
cli:
  default: claude
  agents:
    yakuza5: codex
    yakuza7: copilot
YAML

    # 不正CLI名
    cat > "${TEST_TMP}/settings_invalid_cli.yaml" << 'YAML'
cli:
  default: claudee
  agents:
    yakuza1: invalid_cli
YAML

    # codexデフォルト
    cat > "${TEST_TMP}/settings_codex_default.yaml" << 'YAML'
cli:
  default: codex
YAML

    # 空ファイル
    cat > "${TEST_TMP}/settings_empty.yaml" << 'YAML'
YAML

    # YAML構文エラー
    cat > "${TEST_TMP}/settings_broken.yaml" << 'YAML'
cli:
  default: [broken yaml
  agents: {{invalid
YAML

    # モデル指定付き
    cat > "${TEST_TMP}/settings_with_models.yaml" << 'YAML'
cli:
  default: claude
  agents:
    yakuza1:
      type: claude
      model: haiku
    yakuza5:
      type: codex
      model: gpt-5
models:
  gryakuza: sonnet
YAML

    # kimi CLI settings
    cat > "${TEST_TMP}/settings_kimi.yaml" << 'YAML'
cli:
  default: claude
  agents:
    yakuza3:
      type: kimi
      model: k2.5
    yakuza4:
      type: kimi
YAML

    # kimi default settings
    cat > "${TEST_TMP}/settings_kimi_default.yaml" << 'YAML'
cli:
  default: kimi
YAML
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ヘルパー: 特定のsettings.yamlでcli_adapterをロード
load_adapter_with() {
    local settings_file="$1"
    export CLI_ADAPTER_SETTINGS="$settings_file"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
}

# =============================================================================
# get_cli_type テスト
# =============================================================================

# --- 正常系 ---

@test "get_cli_type: cliセクションなし → claude (後方互換)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_cli_type "darkninja")
    [ "$result" = "claude" ]
}

@test "get_cli_type: claude only設定 → claude" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(get_cli_type "yakuza1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed設定 darkninja → claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "darkninja")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed設定 yakuza5 → codex" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "yakuza5")
    [ "$result" = "codex" ]
}

@test "get_cli_type: mixed設定 yakuza7 → copilot" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "yakuza7")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: mixed設定 yakuza1 → claude (個別設定)" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "yakuza1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 文字列形式 yakuza5 → codex" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "yakuza5")
    [ "$result" = "codex" ]
}

@test "get_cli_type: 文字列形式 yakuza7 → copilot" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "yakuza7")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: kimi設定 yakuza3 → kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "yakuza3")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: kimi設定 yakuza4 → kimi (モデル指定なし)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "yakuza4")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: kimiデフォルト設定 → kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_cli_type "yakuza1")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: 未定義agent → default継承" {
    load_adapter_with "${TEST_TMP}/settings_codex_default.yaml"
    result=$(get_cli_type "yakuza3")
    [ "$result" = "codex" ]
}

@test "get_cli_type: 空agent_id → claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "")
    [ "$result" = "claude" ]
}

# --- 全yakuza パターン ---

@test "get_cli_type: mixed設定 yakuza1-8全パターン" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    [ "$(get_cli_type yakuza1)" = "claude" ]
    [ "$(get_cli_type yakuza2)" = "claude" ]
    [ "$(get_cli_type yakuza3)" = "claude" ]
    [ "$(get_cli_type yakuza4)" = "claude" ]
    [ "$(get_cli_type yakuza5)" = "codex" ]
    [ "$(get_cli_type yakuza6)" = "codex" ]
    [ "$(get_cli_type yakuza7)" = "copilot" ]
    [ "$(get_cli_type yakuza8)" = "copilot" ]
}

# --- エラー系 ---

@test "get_cli_type: 不正CLI名 → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "yakuza1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 不正default → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "gryakuza")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 空YAMLファイル → claude" {
    load_adapter_with "${TEST_TMP}/settings_empty.yaml"
    result=$(get_cli_type "darkninja")
    [ "$result" = "claude" ]
}

@test "get_cli_type: YAML構文エラー → claude" {
    load_adapter_with "${TEST_TMP}/settings_broken.yaml"
    result=$(get_cli_type "yakuza1")
    [ "$result" = "claude" ]
}

@test "get_cli_type: 存在しないファイル → claude" {
    load_adapter_with "/nonexistent/path/settings.yaml"
    result=$(get_cli_type "darkninja")
    [ "$result" = "claude" ]
}

# =============================================================================
# build_cli_command テスト
# =============================================================================

@test "build_cli_command: claude + model → claude --model opus --dangerously-skip-permissions" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "darkninja")
    [ "$result" = "claude --model opus --dangerously-skip-permissions" ]
}

@test "build_cli_command: codex + default model → codex --model sonnet ..." {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "yakuza5")
    [ "$result" = "codex --model sonnet --dangerously-bypass-approvals-and-sandbox --no-alt-screen" ]
}

@test "build_cli_command: copilot → copilot --yolo" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "yakuza7")
    [ "$result" = "copilot --yolo" ]
}

@test "build_cli_command: kimi + model → kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "yakuza3")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: kimi (モデル指定なし) → kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "yakuza4")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: cliセクションなし → claude フォールバック" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(build_cli_command "yakuza1")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

@test "build_cli_command: settings読取失敗 → claude フォールバック" {
    load_adapter_with "/nonexistent/settings.yaml"
    result=$(build_cli_command "yakuza1")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

# =============================================================================
# get_instruction_file テスト
# =============================================================================

@test "get_instruction_file: darkninja + claude → instructions/darkninja.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "darkninja")
    [ "$result" = "instructions/darkninja.md" ]
}

@test "get_instruction_file: gryakuza + claude → instructions/gryakuza.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "gryakuza")
    [ "$result" = "instructions/gryakuza.md" ]
}

@test "get_instruction_file: yakuza1 + claude → instructions/yakuza.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "yakuza1")
    [ "$result" = "instructions/yakuza.md" ]
}

@test "get_instruction_file: yakuza5 + codex → instructions/codex-yakuza.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "yakuza5")
    [ "$result" = "instructions/codex-yakuza.md" ]
}

@test "get_instruction_file: yakuza7 + copilot → .github/copilot-instructions-yakuza.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "yakuza7")
    [ "$result" = ".github/copilot-instructions-yakuza.md" ]
}

@test "get_instruction_file: yakuza3 + kimi → instructions/generated/kimi-yakuza.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_instruction_file "yakuza3")
    [ "$result" = "instructions/generated/kimi-yakuza.md" ]
}

@test "get_instruction_file: darkninja + kimi → instructions/generated/kimi-darkninja.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_instruction_file "darkninja")
    [ "$result" = "instructions/generated/kimi-darkninja.md" ]
}

@test "get_instruction_file: cli_type引数で明示指定 (codex)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "darkninja" "codex")
    [ "$result" = "instructions/codex-darkninja.md" ]
}

@test "get_instruction_file: cli_type引数で明示指定 (copilot)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "gryakuza" "copilot")
    [ "$result" = ".github/copilot-instructions-gryakuza.md" ]
}

@test "get_instruction_file: 全CLI × 全role組み合わせ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # claude
    [ "$(get_instruction_file darkninja claude)" = "instructions/darkninja.md" ]
    [ "$(get_instruction_file gryakuza claude)" = "instructions/gryakuza.md" ]
    [ "$(get_instruction_file yakuza1 claude)" = "instructions/yakuza.md" ]
    # codex
    [ "$(get_instruction_file darkninja codex)" = "instructions/codex-darkninja.md" ]
    [ "$(get_instruction_file gryakuza codex)" = "instructions/codex-gryakuza.md" ]
    [ "$(get_instruction_file yakuza3 codex)" = "instructions/codex-yakuza.md" ]
    # copilot
    [ "$(get_instruction_file darkninja copilot)" = ".github/copilot-instructions-darkninja.md" ]
    [ "$(get_instruction_file gryakuza copilot)" = ".github/copilot-instructions-gryakuza.md" ]
    [ "$(get_instruction_file yakuza5 copilot)" = ".github/copilot-instructions-yakuza.md" ]
    # kimi
    [ "$(get_instruction_file darkninja kimi)" = "instructions/generated/kimi-darkninja.md" ]
    [ "$(get_instruction_file gryakuza kimi)" = "instructions/generated/kimi-gryakuza.md" ]
    [ "$(get_instruction_file yakuza7 kimi)" = "instructions/generated/kimi-yakuza.md" ]
}

@test "get_instruction_file: 不明なagent_id → 空文字 + return 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run get_instruction_file "unknown_agent"
    [ "$status" -eq 1 ]
}

# =============================================================================
# validate_cli_availability テスト
# =============================================================================

@test "validate_cli_availability: claude → 0 (インストール済み)" {
    command -v claude >/dev/null 2>&1 || skip "claude not installed (CI environment)"
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "claude"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: 不正CLI名 → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "invalid_type"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown CLI type"* ]]
}

@test "validate_cli_availability: 空文字 → 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability ""
    [ "$status" -eq 1 ]
}

@test "validate_cli_availability: codex mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # モックcodexコマンドを作成
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/codex"
    chmod +x "${TEST_TMP}/bin/codex"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "codex"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: copilot mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/copilot"
    chmod +x "${TEST_TMP}/bin/copilot"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "copilot"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi-cli mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi-cli"
    chmod +x "${TEST_TMP}/bin/kimi-cli"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi mock (PATH操作)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi"
    chmod +x "${TEST_TMP}/bin/kimi"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: codex未インストール → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # PATHからcodexを除外（空PATHは危険なのでminimal PATHを設定）
    PATH="/usr/bin:/bin" run validate_cli_availability "codex"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Codex CLI not found"* ]]
}

@test "validate_cli_availability: kimi未インストール → 1 + エラーメッセージ" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    PATH="/usr/bin:/bin" run validate_cli_availability "kimi"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Kimi CLI not found"* ]]
}

# =============================================================================
# get_agent_model テスト
# =============================================================================

@test "get_agent_model: cliセクションなし darkninja → opus (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "darkninja")
    [ "$result" = "opus" ]
}

@test "get_agent_model: cliセクションなし gryakuza → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "gryakuza")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: cliセクションなし yakuza1 → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "yakuza1")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: cliセクションなし yakuza5 → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "yakuza5")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: YAML指定 yakuza1 → haiku (オーバーライド)" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "yakuza1")
    [ "$result" = "haiku" ]
}

@test "get_agent_model: modelsセクションから取得 gryakuza → sonnet" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "gryakuza")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: codexエージェントのmodel yakuza5 → gpt-5" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "yakuza5")
    [ "$result" = "gpt-5" ]
}

@test "get_agent_model: 未知agent → sonnet (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "unknown_agent")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: kimi CLI yakuza3 → k2.5 (YAML指定)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "yakuza3")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI yakuza4 → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "yakuza4")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI darkninja → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "darkninja")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI gryakuza → k2.5 (デフォルト)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "gryakuza")
    [ "$result" = "k2.5" ]
}
