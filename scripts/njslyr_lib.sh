#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# njslyr_lib.sh — njslyrコマンド共有ライブラリ
#
# njslyr_cmd.sh から source される共有ライブラリ。
# njslyr.sh の関数群を __NJSLYR_TESTING__=1 でsourceして継承する（方針A）。
#
# 直接実行は想定外。source で使用すること:
#   source scripts/njslyr_lib.sh
#
# 設計書: context/cmd_269-infra-design.md (Section A-3 実装依存関係)
# ═══════════════════════════════════════════════════════════════

# ─── 二重source防止ガード ───
[[ -n "${__NJSLYR_LIB_LOADED__:-}" ]] && return 0
__NJSLYR_LIB_LOADED__=1

# ─── Variables ───
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.state}"

# ─── njslyr.sh の関数群を継承 ───
# 方針A: __NJSLYR_TESTING__=1 でmain()起動を抑制してsource
# - njslyr.shのstage3_slay()、agent_is_busy()等の関数が利用可能になる
# - 既存テスト(test_njslyr_stages.bats)も同変数を使用しており整合性が高い
# - njslyr.sh本体は変更しない（readのみ）
__NJSLYR_TESTING__=1 source "$SCRIPT_DIR/njslyr.sh" 2>/dev/null || {
    echo "[WARN] njslyr_lib.sh: njslyr.sh source failed. Check: $SCRIPT_DIR/njslyr.sh" >&2
}
if ! declare -f stage3_slay > /dev/null 2>&1; then
    echo "[WARN] njslyr_lib.sh: stage3_slay() unavailable after source. Slay operations will fail." >&2
fi

# ─── resolve_pane_by_agent_id ───
# @agent_id から全セッション横断でpane_idを解決する
# njslyr.sh の get_pane_target() は multiagent:agents限定だが、
# こちらは -a フラグで全セッションを対象にする（yakuzatengu対応）
resolve_pane_by_agent_id() {
    local agent_id="$1"
    tmux list-panes -a -F '#{@agent_id} #{pane_id}' 2>/dev/null \
        | awk -v id="$agent_id" '$1 == id {print $2; exit}'
}
