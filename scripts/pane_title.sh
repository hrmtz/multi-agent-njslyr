#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# pane_title.sh — ペインタイトル更新ヘルパー (cmd_338)
# Usage: source scripts/pane_title.sh; update_pane_title <pane> <agent_id> <model_str> [extra_env]
#
# モデル略称マッピング:
#   ANTHROPIC_BASE_URL含む extra_env → [DS]
#   opus / claude-opus         → [Opus]
#   haiku / claude-haiku       → [Hku]
#   sonnet / claude-sonnet / 空 → [Snt]
#   その他                     → [?]
# ═══════════════════════════════════════════════════════════════

# model_str + extra_env からモデル略称を返す
# 引数: model_str, extra_env (optional)
# 出力: [DS] / [Opus] / [Hku] / [Snt] / [?]
get_model_badge() {
    local model_str="${1:-}"
    local extra_env="${2:-}"

    # DS判定: extra_envにANTHROPIC_BASE_URLが含まれる
    if [[ "$extra_env" == *"ANTHROPIC_BASE_URL"* ]]; then
        echo "[DS]"
        return
    fi

    # model_strベースの判定（小文字化して比較）
    local model_lower
    model_lower=$(printf '%s' "$model_str" | tr '[:upper:]' '[:lower:]')

    case "$model_lower" in
        *opus*)   echo "[Opus]" ;;
        *haiku*)  echo "[Hku]" ;;
        *sonnet*) echo "[Snt]" ;;
        "")       echo "[Snt]" ;;
        *)        echo "[?]" ;;
    esac
}

# ペインタイトルを更新
# 引数: pane_target, agent_id, model_str, extra_env (optional)
update_pane_title() {
    local pane_target="$1"
    local agent_id="$2"
    local model_str="${3:-}"
    local extra_env="${4:-}"

    local badge
    badge=$(get_model_badge "$model_str" "$extra_env")

    tmux select-pane -t "$pane_target" -T "${agent_id}${badge}" 2>/dev/null || true
}
