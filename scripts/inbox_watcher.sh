#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# inbox_watcher.sh — メールボックス監視＆起動シグナル配信
# Usage: bash scripts/inbox_watcher.sh <agent_id> <pane_target> [cli_type]
# Example: bash scripts/inbox_watcher.sh gryakuza multiagent:0.0 claude
#
# 設計思想:
#   メッセージ本体はファイル（inbox YAML）に書く = 確実
#   起動シグナルは tmux send-keys（テキストとEnterを分離送信）
#   エージェントが自分でinboxをReadして処理する
#   冪等: 2回届いてもunreadがなければ何もしない
#
# ファイル変更検知: Linux→inotifywait (dir+moved_to監視, atomic write対応), macOS→fswatch（イベント駆動、ポーリングではない）
# Fallback 1: 10秒タイムアウト（WSL2 inotify不発時 / fswatch timeout の安全網）
# Fallback 2: rc=1処理（Claude Code atomic write = tmp+rename でinode変更時 → moved_toで検知）
#
# エスカレーション（未読メッセージが放置されている場合）:
#   0〜2分: 通常スリケン（send-keys）。ただしWorking中はスキップ
#   2〜4分: Escape×2 + スリケン（カーソル位置バグ対策）
#   4分〜 : /clear送信（5分に1回まで。強制リセット+YAML再読）
# ═══════════════════════════════════════════════════════════════

# ─── OS detection (cross-platform) ───
_UNAME_S=$(uname -s)

# ─── Testing guard ───
# When __INBOX_WATCHER_TESTING__=1, only function definitions are loaded.
# Argument parsing, file-watch check, and main loop are skipped.
# Test code sets variables (AGENT_ID, PANE_TARGET, CLI_TYPE, INBOX) externally.
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    set -euo pipefail

    # macOS (Darwin): GNU coreutils (timeout etc.) + util-linux (flock) via Homebrew
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
        export PATH="${_HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
    fi

    SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
    AGENT_ID="$1"
    PANE_TARGET="$2"
    CLI_TYPE="${3:-claude}"  # CLI種別（claude/codex/copilot）。未指定→claude（後方互換）

    INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"
    LOCKFILE="${INBOX}.lock"
    CACHE_DIR="$SCRIPT_DIR/queue/.cache"
    STATE_DIR="$SCRIPT_DIR/.state"
    mkdir -p "$CACHE_DIR" "$STATE_DIR"

    if [ -z "$AGENT_ID" ] || [ -z "$PANE_TARGET" ]; then
        echo "Usage: inbox_watcher.sh <agent_id> <pane_target> [cli_type]" >&2
        exit 1
    fi

    # Initialize inbox if not exists (atomic: write to tmp then rename to avoid TOCTOU)
    if [ ! -f "$INBOX" ]; then
        mkdir -p "${INBOX%/*}"
        _init_tmp="${INBOX}.init.$$"
        echo "messages: []" > "$_init_tmp"
        # mv -n: no-clobber — if another process created the file first, keep theirs
        mv -n "$_init_tmp" "$INBOX" 2>/dev/null || rm -f "$_init_tmp"
    fi

    echo "[$(date)] inbox_watcher started — agent: $AGENT_ID, pane: $PANE_TARGET, cli: $CLI_TYPE" >&2

    # ─── Graceful shutdown trap ───
    # Daemon process must log exit and clean up cache files.
    _inbox_watcher_cleanup() {
        local exit_code=$?
        trap - EXIT INT TERM   # 二重発火防止
        echo "[$(date)] inbox_watcher stopping — agent: $AGENT_ID (exit_code=$exit_code)" >&2
        # Clean up busy-detection cache (stale cache causes false-busy on restart)
        rm -f "${CACHE_DIR}/inbox_watcher_busy_cache_${AGENT_ID}" 2>/dev/null
        exit "$exit_code"
    }
    trap _inbox_watcher_cleanup EXIT INT TERM

    # Ensure file-watch tool is available (fswatch on macOS, inotifywait on Linux)
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        if ! command -v fswatch &>/dev/null; then
            echo "[inbox_watcher] ERROR: fswatch not found. Install: brew install fswatch" >&2
            exit 1
        fi
    else
        if ! command -v inotifywait &>/dev/null; then
            echo "[inbox_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
            exit 1
        fi
    fi
fi

# ─── Escalation state ───
# Time-based escalation: track how long unread messages have been waiting
FIRST_UNREAD_SEEN=${FIRST_UNREAD_SEEN:-0}
LAST_CLEAR_TS=${LAST_CLEAR_TS:-0}
ESCALATE_PHASE1=${ESCALATE_PHASE1:-120}
ESCALATE_PHASE2=${ESCALATE_PHASE2:-240}
ESCALATE_COOLDOWN=${ESCALATE_COOLDOWN:-300}
# FIX-006: Track busy→idle transitions to prevent false escalation after long tasks
PREV_WAS_BUSY=${PREV_WAS_BUSY:-0}

# ─── Nudge throttle ───
# Avoid spamming the same "inboxN" into the pane every timeout tick.
LAST_NUDGE_TS=${LAST_NUDGE_TS:-0}
LAST_NUDGE_COUNT=${LAST_NUDGE_COUNT:-""}
NUDGE_COOLDOWN_SEC=${NUDGE_COOLDOWN_SEC:-60}
# Codex は「思考中に入力が入ると即拾う」挙動があり、思考がループすることがあるため長めにする。
NUDGE_COOLDOWN_SEC_CODEX=${NUDGE_COOLDOWN_SEC_CODEX:-300}

# ─── Context reset tracking ───
# Tracks whether we've sent /new or /clear for the current task_assigned batch.
# Resets to 0 when all messages are read (FIRST_UNREAD_SEEN → 0).
NEW_CONTEXT_SENT=${NEW_CONTEXT_SENT:-0}

# ─── Phase feature flags (cmd_107 Phase 1/2/3) ───
# ASW_PHASE:
#   1 = self-watch base (compatible)
#   2 = disable normal スリケン by default
#   3 = FINAL_ESCALATION_ONLY (send-keys is fallback only)
ASW_PHASE=${ASW_PHASE:-1}
ASW_DISABLE_NORMAL_NUDGE=${ASW_DISABLE_NORMAL_NUDGE:-$([ "${ASW_PHASE}" -ge 2 ] && echo 1 || echo 0)}
ASW_FINAL_ESCALATION_ONLY=${ASW_FINAL_ESCALATION_ONLY:-$([ "${ASW_PHASE}" -ge 3 ] && echo 1 || echo 0)}
FINAL_ESCALATION_ONLY=${FINAL_ESCALATION_ONLY:-$ASW_FINAL_ESCALATION_ONLY}
ASW_NO_IDLE_FULL_READ=${ASW_NO_IDLE_FULL_READ:-1}
# Optional safety toggles:
# - ASW_DISABLE_ESCALATION=1: disable phase2/phase3 escalation actions
# - ASW_PROCESS_TIMEOUT=0: do not process unread on timeout ticks (event-only)
ASW_DISABLE_ESCALATION=${ASW_DISABLE_ESCALATION:-0}
ASW_PROCESS_TIMEOUT=${ASW_PROCESS_TIMEOUT:-1}

# ─── Metrics hooks (FR-006 / NFR-003) ───
# unread_latency_sec / read_count / estimated_tokens are intentionally explicit
READ_COUNT=${READ_COUNT:-0}
READ_BYTES_TOTAL=${READ_BYTES_TOTAL:-0}
ESTIMATED_TOKENS_TOTAL=${ESTIMATED_TOKENS_TOTAL:-0}
METRICS_FILE=${METRICS_FILE:-${SCRIPT_DIR:-$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)}/queue/metrics/${AGENT_ID:-unknown}_selfwatch.yaml}
_METRICS_WRITE_COUNTER=${_METRICS_WRITE_COUNTER:-0}

update_metrics() {
    local bytes_read="${1:-0}"
    # FIX-012: $EPOCHSECONDS avoids date fork
    local now=${EPOCHSECONDS:-$(date +%s)}

    READ_COUNT=$((READ_COUNT + 1))
    READ_BYTES_TOTAL=$((READ_BYTES_TOTAL + bytes_read))
    ESTIMATED_TOKENS_TOTAL=$((ESTIMATED_TOKENS_TOTAL + ((bytes_read + 3) / 4)))

    local unread_latency_sec=0
    if [ "$FIRST_UNREAD_SEEN" -gt 0 ] 2>/dev/null; then
        unread_latency_sec=$((now - FIRST_UNREAD_SEEN))
    fi

    # FIX-012: Write throttle — only write metrics every 10 cycles
    _METRICS_WRITE_COUNTER=$((_METRICS_WRITE_COUNTER + 1))
    if [ $((_METRICS_WRITE_COUNTER % 10)) -eq 0 ] || [ "$unread_latency_sec" -gt 1 ]; then
        mkdir -p "${METRICS_FILE%/*}" 2>/dev/null || true
        cat > "$METRICS_FILE" <<EOF
agent_id: "${AGENT_ID:-unknown}"
timestamp: "$(date -Iseconds)"
unread_latency_sec: $unread_latency_sec
read_count: $READ_COUNT
bytes_read: $READ_BYTES_TOTAL
estimated_tokens: $ESTIMATED_TOKENS_TOTAL
EOF
    fi

    # FIX-012: bash (( )) replaces awk float comparison (0 forks)
    if (( unread_latency_sec > 1 )); then
        check_latency_sla "$unread_latency_sec"
    fi
}

# ─── Latency SLA monitoring (P2-施策3) ───
# FIX-013: Write to .state/alerts/ instead of dashboard.md (eliminates awk race with gryakuza)
check_latency_sla() {
    local latency_sec="$1"
    local alert_dir="${STATE_DIR}/alerts"
    local alert_file="${alert_dir}/${AGENT_ID}_sla.yaml"

    mkdir -p "$alert_dir" 2>/dev/null || true
    cat > "$alert_file" <<EOF
agent_id: "${AGENT_ID}"
timestamp: "$(date -Iseconds)"
latency_sec: $latency_sec
threshold_sec: 1.5
type: sla_violation
EOF
    echo "[inbox_watcher] SLA alert written: ${AGENT_ID} latency=${latency_sec}s → ${alert_file}" >&2
}

disable_normal_nudge() {
    [ "${ASW_DISABLE_NORMAL_NUDGE:-0}" = "1" ]
}

should_throttle_nudge() {
    local unread_count="${1:-0}"

    local effective_cli
    effective_cli=$(get_effective_cli_type)

    local cooldown_sec="${NUDGE_COOLDOWN_SEC:-60}"
    if [[ "$effective_cli" == "codex" ]]; then
        cooldown_sec="${NUDGE_COOLDOWN_SEC_CODEX:-300}"
    fi

    if [ "${LAST_NUDGE_COUNT:-}" = "$unread_count" ] && [ "${LAST_NUDGE_TS:-0}" -gt 0 ]; then
        local age=$((SECONDS - LAST_NUDGE_TS))
        if [ "$age" -lt "${cooldown_sec}" ]; then
            echo "[$(date)] [SKIP] Throttling スリケン for $AGENT_ID: inbox${unread_count} (${age}s < ${cooldown_sec}s, cli=$effective_cli)" >&2
            return 0
        fi
    fi

    LAST_NUDGE_COUNT="$unread_count"
    LAST_NUDGE_TS="$SECONDS"
    return 1
}

is_valid_cli_type() {
    case "${1:-}" in
        claude|codex|copilot|kimi) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── CLI type cache (TTL 5s, avoids repeated tmux show-options calls) ───
_CLI_CACHE_RESULT=""
_CLI_CACHE_TS=0

get_effective_cli_type() {
    # FIX-020: TTL extended 5→60s (CLI type rarely changes mid-session)
    if [ -n "$_CLI_CACHE_RESULT" ] && [ "$(( SECONDS - _CLI_CACHE_TS ))" -lt 60 ]; then
        echo "$_CLI_CACHE_RESULT"
        return 0
    fi

    local pane_cli_raw=""
    local pane_cli=""
    local result=""

    pane_cli_raw=$(timeout 2 tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || true)
    # Consolidate echo|tr|head|tr pipe (4 forks) into parameter expansion (0 forks)
    pane_cli="${pane_cli_raw%%$'\n'*}"
    pane_cli="${pane_cli//$'\r'/}"
    pane_cli="${pane_cli//[[:space:]]/}"

    if is_valid_cli_type "$pane_cli"; then
        if is_valid_cli_type "${CLI_TYPE:-}" && [ "$pane_cli" != "${CLI_TYPE}" ]; then
            echo "[$(date)] [WARN] CLI drift detected for $AGENT_ID: arg=${CLI_TYPE}, pane=${pane_cli}. Using pane value." >&2
        fi
        result="$pane_cli"
    elif is_valid_cli_type "${CLI_TYPE:-}"; then
        if [ -n "$pane_cli" ]; then
            echo "[$(date)] [WARN] Invalid pane @agent_cli for $AGENT_ID: '${pane_cli}'. Falling back to arg=${CLI_TYPE}." >&2
        fi
        result="${CLI_TYPE}"
    else
        # Fail-closed: when CLI is unknown, take codex-safe path (no C-c, /clear->/new)
        echo "[$(date)] [WARN] CLI unresolved for $AGENT_ID (pane='${pane_cli:-<empty>}', arg='${CLI_TYPE:-<empty>}'). Fallback=codex-safe." >&2
        result="codex"
    fi

    _CLI_CACHE_RESULT="$result"
    _CLI_CACHE_TS=$SECONDS
    echo "$result"
}

normalize_special_command() {
    local msg_type="${1:-}"
    local raw_content="${2:-}"

    case "$msg_type" in
        clear_command)
            echo "/clear"
            ;;
        model_switch)
            if [[ "$raw_content" =~ ^/model[[:space:]]+[^[:space:]].* ]]; then
                echo "$raw_content"
            else
                echo "[$(date)] [SKIP] Invalid model_switch payload for $AGENT_ID: ${raw_content:-<empty>}" >&2
            fi
            ;;
    esac
}

# FIX-014: bash化 (python3排除) + task_yaml_path動的引継ぎ
enqueue_recovery_task_assigned() {
    (
        flock -x 200

        # Dedup guard: existing unread auto-recovery → skip
        _dedup=$(awk '
            BEGIN { found = 0 }
            /^- / {
                if (in_block && is_recovery && is_unread) { found = 1; exit }
                in_block = 1; is_recovery = 0; is_unread = 0
            }
            in_block && /\[auto-recovery\]/ { is_recovery = 1 }
            in_block && /read: false/ { is_unread = 1 }
            END {
                if (in_block && is_recovery && is_unread) found = 1
                print found
            }
        ' "$INBOX" 2>/dev/null)
        if [ "${_dedup:-0}" = "1" ]; then
            echo "SKIP_DUPLICATE"
            exit 0
        fi

        # FIX-014: Find last task_yaml_path from task_assigned (dynamic, not hardcoded)
        _last_task_path=$(awk '
            /^- / { in_block = 1; is_ta = 0; tp = "" }
            in_block && /type: task_assigned/ { is_ta = 1 }
            in_block && /task_yaml_path: / {
                tp = $0; sub(/.*task_yaml_path: */, "", tp)
                gsub(/^[\047"]|[\047"]$/, "", tp)
            }
            in_block && /^  read:/ && is_ta && tp != "" { last = tp }
            END { if (last != "") print last }
        ' "$INBOX" 2>/dev/null)
        _last_task_path="${_last_task_path:-queue/tasks/${AGENT_ID}.yaml}"

        # Handle "messages: []" (inline empty list) → convert to block format for append
        # macOS: sed -i requires '' as backup extension (BSD sed vs GNU sed)
        if grep -q '^messages: \[\]' "$INBOX" 2>/dev/null; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' 's/^messages: \[\]$/messages:/' "$INBOX"
            else
                sed -i 's/^messages: \[\]$/messages:/' "$INBOX"
            fi
        fi

        _now_ts=$(date -Iseconds)
        _msg_id="msg_auto_recovery_$(date +%Y%m%d_%H%M%S)_$(head -c4 /dev/urandom | od -A n -t x1 | tr -d ' \n')"

        printf '%s\n' \
            "- content: \"[auto-recovery] /clear 後の再着手通知。${_last_task_path} を再読し、assigned タスクを即時再開せよ。\"" \
            "  from: inbox_watcher" \
            "  id: ${_msg_id}" \
            "  read: false" \
            "  timestamp: '${_now_ts}'" \
            "  type: task_assigned" >> "$INBOX"
        echo "$_msg_id"
    ) 200>"$LOCKFILE" 2>/dev/null
}

no_idle_full_read() {
    local trigger="${1:-timeout}"
    [ "${ASW_NO_IDLE_FULL_READ:-1}" = "1" ] || return 1
    [ "$trigger" = "timeout" ] || return 1
    [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ] || return 1
    return 0
}

# summary-first: unread_count fast-path before full read
# FIX-015: Pattern relaxed to tolerate trailing whitespace and case variations.
get_unread_count_fast() {
    local count
    count=$(grep -ciE '^\s+read:\s*(false)\s*$' "$INBOX" 2>/dev/null) || count=0
    echo "$count"
}

# ─── Extract unread message info ───
# FIX-002: bash/awk implementation (replaces python3 — saves 50-130ms/call)
# FIX-005: Pure read-only (no specials marking). Use mark_specials_read() after delivery.
# Output: line 1=normal_count, line 2=has_task_assigned(0/1), line 3+=specials(type\tcontent)
# Test anchor for bats awk pattern: get_unread_info\\(\\)
get_unread_info() {
    (
        flock -s 200  # FIX-002: shared lock (read-only, no writes)
        awk '
        /^- / {
            if (in_block && is_unread) {
                if (btype == "clear_command" || btype == "model_switch") {
                    gsub(/\t/, " ", bcontent)
                    if (sp != "") sp = sp "\n"
                    sp = sp btype "\t" bcontent
                } else {
                    nc++
                    if (btype == "task_assigned") ht = 1
                }
            }
            in_block = 1; is_unread = 0; btype = ""; bcontent = ""
            if (/^- content: /) {
                bcontent = $0; sub(/^- content: */, "", bcontent)
                gsub(/^[\047"]|[\047"]$/, "", bcontent)
            } else if (/^- type: /) {
                btype = $0; sub(/^- type: */, "", btype)
            } else if (/^- read: false/) { is_unread = 1 }
            next
        }
        in_block && /^  content: / {
            bcontent = $0; sub(/^  content: */, "", bcontent)
            gsub(/^[\047"]|[\047"]$/, "", bcontent)
            next
        }
        in_block && /^  type: / { btype = $0; sub(/^  type: */, "", btype); next }
        in_block && /^  read: false/ { is_unread = 1; next }
        in_block && /^  read: true/ { is_unread = 0; next }
        END {
            if (in_block && is_unread) {
                if (btype == "clear_command" || btype == "model_switch") {
                    gsub(/\t/, " ", bcontent)
                    if (sp != "") sp = sp "\n"
                    sp = sp btype "\t" bcontent
                } else {
                    nc++
                    if (btype == "task_assigned") ht = 1
                }
            }
            print nc + 0
            print ht + 0
            if (sp != "") print sp
        }
        ' "$INBOX" 2>/dev/null
    ) 200>"$LOCKFILE"
}

# ─── Mark special messages as read (at-least-once delivery) ───
# FIX-005: Called AFTER send_cli_command() succeeds for specials.
# If this fails, specials remain unread → next cycle retries.
mark_specials_read() {
    (
        flock -x 200
        awk '
        { lines[NR] = $0 }
        END {
            changed = 0; in_block = 0; is_special = 0; read_line = 0; is_unread = 0
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ /^- /) {
                    if (in_block && is_special && is_unread && read_line > 0) {
                        sub(/read: false/, "read: true", lines[read_line])
                        changed = 1
                    }
                    in_block = 1; is_special = 0; read_line = 0; is_unread = 0
                }
                if (in_block && (lines[i] ~ /  type: clear_command/ || lines[i] ~ /  type: model_switch/)) {
                    is_special = 1
                }
                if (in_block && lines[i] ~ /  read: false/) {
                    read_line = i; is_unread = 1
                }
                if (in_block && lines[i] ~ /  read: true/) {
                    is_unread = 0; read_line = 0
                }
            }
            if (in_block && is_special && is_unread && read_line > 0) {
                sub(/read: false/, "read: true", lines[read_line])
                changed = 1
            }
            if (changed) {
                for (i = 1; i <= NR; i++) print lines[i]
            }
        }
        ' "$INBOX" > "${INBOX}.tmp.$$" 2>/dev/null
        if [ -s "${INBOX}.tmp.$$" ]; then
            mv "${INBOX}.tmp.$$" "$INBOX"
        else
            rm -f "${INBOX}.tmp.$$"
        fi
    ) 200>"$LOCKFILE" 2>/dev/null
}

# ─── Parse get_unread_info() output (pure bash, 0 forks) ───
# Sets: _UI_COUNT, _UI_HAS_TASK, _UI_SPECIALS
_parse_unread_info() {
    local _info="$1"
    _UI_COUNT="${_info%%$'\n'*}"
    _UI_COUNT="${_UI_COUNT:-0}"
    local _rest="${_info#*$'\n'}"
    _UI_HAS_TASK="${_rest%%$'\n'*}"
    _UI_HAS_TASK="${_UI_HAS_TASK:-0}"
    if [[ "$_rest" == *$'\n'* ]]; then
        _UI_SPECIALS="${_rest#*$'\n'}"
    else
        _UI_SPECIALS=""
    fi
}

# ─── Resolve pane target dynamically via @agent_id ───
# Fixes pane index drift when panes are added/removed.
# Falls back to startup PANE_TARGET if @agent_id lookup fails.
# 5-second TTL cache to avoid repeated tmux list-panes calls.
_RESOLVE_CACHE_TARGET=""
_RESOLVE_CACHE_TS=0

resolve_pane_target() {
    # FIX-010: Cache TTL extended 5→30s to reduce tmux list-panes calls.
    # Also sets _RESOLVE_PANE_FOUND for orphan check integration.
    if [ -n "$_RESOLVE_CACHE_TARGET" ] && [ "$(( SECONDS - _RESOLVE_CACHE_TS ))" -lt 30 ]; then
        PANE_TARGET="$_RESOLVE_CACHE_TARGET"
        return 0
    fi

    # Darkninja uses a separate session — skip dynamic resolution
    if [ "$AGENT_ID" = "darkninja" ]; then
        _RESOLVE_CACHE_TARGET="$PANE_TARGET"
        _RESOLVE_CACHE_TS=$SECONDS
        _RESOLVE_PANE_FOUND=1
        return 0
    fi

    # Dynamic lookup: find pane by @agent_id
    local resolved
    resolved=$(tmux list-panes -a -F '#{@agent_id} #{pane_id}' 2>/dev/null \
        | awk -v id="$AGENT_ID" '$1 == id {print $2; exit}') || true

    if [ -n "$resolved" ]; then
        PANE_TARGET="$resolved"
        _RESOLVE_CACHE_TARGET="$resolved"
        _RESOLVE_CACHE_TS=$SECONDS
        _RESOLVE_PANE_FOUND=1
        return 0
    fi

    # Fallback: keep startup PANE_TARGET (may be stale but better than nothing)
    echo "[$(date)] [WARN] resolve_pane_target: @agent_id=$AGENT_ID not found, using fallback $PANE_TARGET" >&2
    _RESOLVE_CACHE_TARGET="$PANE_TARGET"
    _RESOLVE_CACHE_TS=$SECONDS
    _RESOLVE_PANE_FOUND=0
    return 0
}

# ─── Send CLI command via pty direct write ───
# For /clear and /model only. These are CLI commands, not conversation messages.
# CLI_TYPE別分岐: claude→そのまま, codex→/clear対応・/modelスキップ,
#                  copilot→Ctrl-C+再起動・/modelスキップ
# 実行時にtmux paneの @agent_cli を再確認し、ドリフト時はpane値を優先する。
send_cli_command() {
    local cmd="$1"
    resolve_pane_target
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never inject CLI commands into the darkninja pane.
    # Darkninja is controlled by the Lord; keystroke injection can clobber human input.
    if [ "$AGENT_ID" = "darkninja" ]; then
        echo "[$(date)] [SKIP] darkninja: suppressing CLI command injection ($cmd)" >&2
        return 0
    fi

    # CLI別コマンド変換
    local actual_cmd="$cmd"
    case "$effective_cli" in
        codex)
            # Codex: /clear不存在→/newで新規会話開始, /model非対応→スキップ
            # /clearはCodexでは未定義コマンドでCLI終了してしまうため、/newに変換
            if [[ "$cmd" == "/clear" ]]; then
                echo "[$(date)] [SEND-KEYS] Codex /clear→/new: starting new conversation for $AGENT_ID" >&2
                # Dismiss suggestion UI first (typing "x" clears autocomplete prompt)
                tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null
                sleep 0.3
                tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                sleep 0.3
                tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null
                sleep 0.3
                tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
                sleep 1
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on codex)" >&2
                return 0
            fi
            ;;
        copilot)
            # Copilot: /clearはCtrl-C+再起動, /model非対応→スキップ
            if [[ "$cmd" == "/clear" ]]; then
                echo "[$(date)] [SEND-KEYS] Copilot /clear: sending Ctrl-C + restart for $AGENT_ID" >&2
                tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null
                sleep 2
                tmux send-keys -t "$PANE_TARGET" "copilot --yolo" 2>/dev/null
                sleep 0.3
                tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
                sleep 1
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on copilot)" >&2
                return 0
            fi
            ;;
        # claude: commands pass through as-is
    esac

    echo "[$(date)] [SEND-KEYS] Sending CLI command to $AGENT_ID ($effective_cli): $actual_cmd" >&2
    # Clear stale input first, then send command
    # Codex CLI: C-c when idle causes CLI to exit — skip it
    if [[ "$effective_cli" != "codex" ]]; then
        tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null
        sleep 0.2
    fi
    if [[ "$effective_cli" == "codex" ]]; then
        # Codex TUI: text and Enter must be separated (TUI compatibility)
        tmux send-keys -t "$PANE_TARGET" "$actual_cmd" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
    else
        # Claude CLI: text → Escape (dismiss autocomplete) → Enter
        tmux send-keys -t "$PANE_TARGET" "$actual_cmd" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
    fi

    # /clear needs extra wait time before follow-up
    if [[ "$actual_cmd" == "/clear" ]]; then
        sleep 1
    else
        sleep 0.5
    fi
}

# ─── Send context reset before new task ───
# Called when task_assigned is detected in unread messages.
# Sends the appropriate "new conversation" command per CLI type to clear
# stale context from the previous task.
# CLI mapping: claude→/clear, codex→/new, copilot→/clear, kimi→/clear
send_context_reset() {
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never inject CLI commands into the darkninja pane.
    if [ "$AGENT_ID" = "darkninja" ]; then
        echo "[$(date)] [SKIP] darkninja: suppressing context reset" >&2
        return 0
    fi

    local reset_cmd
    case "$effective_cli" in
        codex)    reset_cmd="/new" ;;
        claude)   reset_cmd="/clear" ;;
        copilot)  reset_cmd="/clear" ;;
        kimi)     reset_cmd="/clear" ;;
        *)        reset_cmd="/new" ;;  # safe default (codex-safe)
    esac

    echo "[$(date)] [CONTEXT-RESET] Sending $reset_cmd before task_assigned for $AGENT_ID ($effective_cli)" >&2

    # Dismiss Codex suggestion UI before sending reset command
    if [[ "$effective_cli" == "codex" ]]; then
        tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
        sleep 0.3
    fi

    # Send the command
    if [[ "$effective_cli" == "codex" ]]; then
        # Codex TUI: text and Enter must be separated
        tmux send-keys -t "$PANE_TARGET" "$reset_cmd" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
    else
        # Claude CLI: text → Escape (dismiss autocomplete) → Enter
        tmux send-keys -t "$PANE_TARGET" "$reset_cmd" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
    fi

    # FIX-003: Fixed 2s wait after /clear (polling abolished — 15s dead time eliminated)
    sleep 2
}

# ─── Cross-platform file change wait ───
# Darwin: fswatch -1 (one-shot), Linux: inotifywait
# Returns: 0=event, 1=error/inode-change, 2=timeout
_wait_for_file_change() {
    local file="$1"
    local sec="${2:-30}"
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        timeout "$sec" fswatch -1 "$file" >/dev/null 2>&1
        local rc=$?
        if [ "$rc" -eq 124 ]; then
            return 2  # timeout → map to inotifywait timeout code
        fi
        return $rc
    else
        local dir="${file%/*}"
        local filename="${file##*/}"
        inotifywait -q -t "$sec" -e moved_to -e close_write -e modify \
            --include "^${filename}$" "$dir" 2>/dev/null
        return $?
    fi
}

# ─── Agent self-watch detection ───
# Check if the agent has an active file-watch (inotifywait/fswatch) on its inbox.
# If yes, the agent will self-wake — スリケン不要.
agent_has_self_watch() {
    # FIX-009: TTL 30s cache — pgrep full-process-scan is expensive, cache result
    local _now_sw=${EPOCHSECONDS:-$(date +%s)}
    if [ -n "${_SELF_WATCH_CACHE+x}" ] && [ $((_now_sw - ${_SELF_WATCH_CACHE_TS:-0})) -lt 30 ]; then
        return "$_SELF_WATCH_CACHE"
    fi

    # Codex/Copilot/Kimi CLIs cannot run self-watch. Only Claude Code agents can.
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    if [[ "$effective_cli" != "claude" ]]; then
        _SELF_WATCH_CACHE=1; _SELF_WATCH_CACHE_TS=$_now_sw
        return 1  # non-Claude CLIs never have self-watch
    fi
    # For Claude Code agents: check if a file-watch process exists that is NOT
    # a child of this inbox_watcher process (exclude our own watcher).
    local my_pgid
    my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    local _watch_pattern
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        _watch_pattern="fswatch.*inbox/${AGENT_ID}.yaml"
    else
        _watch_pattern="inotifywait.*inbox/${AGENT_ID}.yaml"
    fi
    local found=1  # default: not found
    while IFS= read -r pid; do
        local pid_pgid
        pid_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$pid_pgid" != "$my_pgid" ]]; then
            found=0  # found a file-watch NOT from our process group
            break
        fi
    done < <(pgrep -f "$_watch_pattern" 2>/dev/null)
    _SELF_WATCH_CACHE=$found; _SELF_WATCH_CACHE_TS=$_now_sw
    return $found
}

# ─── Agent busy detection (with cache, TTL 2s) ───
# Check if the agent's CLI is currently processing (Working/thinking/etc).
# Working中のスリケン送信はテキストがキューに入るがEnterが消失する.
# Returns 0 (true) if agent is busy, 1 if idle.
# P2-施策2: Cache tmux capture-pane result (TTL 2s) to reduce API calls.
agent_is_busy() {
    resolve_pane_target
    local cache_file="${CACHE_DIR}/inbox_watcher_busy_cache_${AGENT_ID}"
    # FIX-011: TTL extended 2→5s, $EPOCHSECONDS avoids date fork
    local cache_ttl_sec=5
    local now
    now=${EPOCHSECONDS:-$(date +%s)}

    # Check cache validity
    if [ -f "$cache_file" ]; then
        local cache_mtime
        # Platform-specific stat (macOS vs Linux)
        if [[ "$_UNAME_S" == "Darwin" ]]; then
            cache_mtime=$(/usr/bin/stat -f %m "$cache_file" 2>/dev/null || echo 0)
        else
            cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        fi

        local cache_age=$((now - cache_mtime))
        if [ "$cache_age" -lt "$cache_ttl_sec" ]; then
            # Cache hit — return cached value (validate: must be 0 or 1)
            # $(<file) avoids cat fork
            local cached_result
            cached_result=$(<"$cache_file") 2>/dev/null
            cached_result="${cached_result:-1}"
            case "$cached_result" in
                0|1) return "$cached_result" ;;
                *) ;; # corrupted cache — fall through to actual check
            esac
        fi
    fi

    # Cache miss or expired — run actual check
    local pane_tail
    # Only check the bottom 5 lines of the pane. Old busy markers ("esc to interrupt",
    # "Working") linger in scroll-back and cause false-busy if we scan too many lines.
    # P1-1: timeout shortened from 2s to 1s for faster delivery (40% latency reduction)
    pane_tail=$(timeout 1 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null | tail -5)

    # If timeout fails (rc=124), treat as idle (not busy) to avoid false-busy blocking スリケン
    local rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "1" > "$cache_file"  # cache: idle
        return 1  # timeout → idle (proceed with スリケン)
    fi

    # ── Idle check (takes priority) — consolidated from 2 greps into 1 ──
    if grep -qE '(\? for shortcuts|context left|^(❯|›)[[:space:]]*$)' <<< "$pane_tail"; then
        echo "1" > "$cache_file"  # cache: idle
        return 1  # idle
    fi

    # ── Busy markers (bottom 5 lines only) — consolidated from 3 greps into 1 ──
    if grep -qiE '(esc to interrupt|background terminal running|Working|Thinking|Planning|Sending|task is in progress|Compacting conversation|thought for|思考中|考え中|計画中|送信中|処理中|実行中)' <<< "$pane_tail"; then
        echo "0" > "$cache_file"  # cache: busy
        return 0  # busy
    fi
    echo "1" > "$cache_file"  # cache: idle
    return 1  # idle
}

# ─── Pane focus detection (human safety) ───
# If the target pane is currently active, avoid injecting keystrokes.
pane_is_active() {
    local active=""
    active=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{pane_active}' 2>/dev/null || true)
    [ "$active" = "1" ]
}

# ─── Send wake-up スリケン ───
# Layered approach:
#   1. If agent has active inotifywait self-watch → skip (agent wakes itself)
#   2. If agent is busy (Working) → skip (Working中のスリケンはEnter消失)
#   3. tmux send-keys (短いスリケンのみ、timeout 5s)
send_wakeup() {
    local unread_count="$1"
    resolve_pane_target
    local nudge="スリケン！inbox${unread_count}"

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing normal スリケン for $AGENT_ID" >&2
        return 0
    fi

    # 優先度1: Agent self-watch — スリケン不要（エージェントが自分で気づく）
    if agent_has_self_watch; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID has active self-watch, スリケン不要" >&2
        return 0
    fi

    # 優先度2: Agent busy — スリケン送信するとEnterが消失するためスキップ
    # Claude Code agents: Stop hook handles delivery, スリケン不要 at all.
    if agent_is_busy; then
        local busy_cli_wakeup
        busy_cli_wakeup=$(get_effective_cli_type)
        if [[ "$busy_cli_wakeup" == "claude" ]]; then
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (claude) — Stop hook will deliver, スリケン不要" >&2
        else
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy ($busy_cli_wakeup), deferring スリケン" >&2
        fi
        return 0
    fi

    if should_throttle_nudge "$unread_count"; then
        return 0
    fi

    # Darkninja: send normal スリケン like other agents.
    # ラオモトが入力中にテキストが混入するリスクはあるが、
    # display-message（5秒で消える）ではダークニンジャが起きない問題の方が深刻。
    # C-u（入力クリア）はpane_is_active時にスキップされるため、ラオモトの入力は保護される。

    # 優先度3: tmux send-keys（テキストとEnterを分離 — Codex TUI対策）
    echo "[$(date)] [SEND-KEYS] Sending スリケン to $PANE_TARGET for $AGENT_ID" >&2

    # Codex suggestion UI dismissal: typing any character dismisses the autocomplete
    # suggestion prompt (› Implement {feature} etc.) that traps idle agents.
    # Sequence: "x" (dismiss suggestion) → C-u (clear input) → nudge → Enter
    local effective_cli_for_nudge
    effective_cli_for_nudge=$(get_effective_cli_type)
    if [[ "$effective_cli_for_nudge" == "codex" ]]; then
        tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
        sleep 0.3
    fi

    if tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
        # Phase 1: text → Escape (dismiss autocomplete) → Enter.
        # Claude CLI autocomplete can swallow Enter if sent immediately after text.
        # Escape dismisses the autocomplete popup before Enter is processed.
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
        echo "[$(date)] Wake-up sent to $AGENT_ID (${unread_count} unread)" >&2
        return 0
    fi

    echo "[$(date)] WARNING: send-keys failed or timed out for $AGENT_ID" >&2
    return 1
}

# ─── Send wake-up スリケン with Escape prefix ───
# Phase 2 escalation: send Escape×2 + C-c to clear stuck input, then スリケン.
# Addresses the "echo last tool call" cursor position bug and stale input.
send_wakeup_with_escape() {
    local unread_count="$1"
    resolve_pane_target
    local nudge="スリケン！inbox${unread_count}"
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    local c_ctrl_state="skipped"

    # Safety: never send Escape escalation to darkninja. It can wipe the Lord's input.
    if [ "$AGENT_ID" = "darkninja" ]; then
        echo "[$(date)] [SKIP] darkninja: suppressing Escape escalation; sending plain スリケン" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Codex CLI: ESC は「中断」になりやすく、人間操作中の事故も多い。
    # Phase 2 の Escape エスカレーションは無効化し、通常スリケンのみに落とす。
    if [[ "$effective_cli" == "codex" ]]; then
        echo "[$(date)] [SKIP] codex: suppressing Escape escalation for $AGENT_ID; sending plain スリケン" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Claude Code: Stop hookがturn終了時にinbox未読を検出→自動処理する。
    # Escape送信は処理中のturnを中断させるため有害。Phase 2は通常スリケンに落とす。
    if [[ "$effective_cli" == "claude" ]]; then
        echo "[$(date)] [SKIP] claude: suppressing Escape escalation for $AGENT_ID (Stop hook handles delivery); sending plain スリケン" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing phase2 スリケン for $AGENT_ID" >&2
        return 0
    fi

    if agent_has_self_watch; then
        return 0
    fi

    # Phase 2 still skips if agent is busy — Escape during Working would interrupt
    if agent_is_busy; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (Working), deferring Phase 2 スリケン" >&2
        return 0
    fi

    echo "[$(date)] [SEND-KEYS] ESCALATION Phase 2: Escape×2 + スリケン for $AGENT_ID (cli=$effective_cli)" >&2
    # Escape×2 to exit any mode
    tmux send-keys -t "$PANE_TARGET" Escape Escape 2>/dev/null
    sleep 0.5
    # C-c to clear stale input (but Codex CLI terminates on C-c when idle, so skip it)
    if [[ "$effective_cli" != "codex" ]]; then
        tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null
        sleep 0.5
        c_ctrl_state="sent"
    fi
    if tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
        sleep 0.3
        tmux send-keys -t "$PANE_TARGET" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null
        echo "[$(date)] Escape+スリケン sent to $AGENT_ID (${unread_count} unread, cli=$effective_cli, C-c=$c_ctrl_state)" >&2
        return 0
    fi

    echo "[$(date)] WARNING: send-keys failed for Escape+スリケン ($AGENT_ID)" >&2
    return 1
}

# ─── Process cycle ───
process_unread() {
    local trigger="${1:-event}"

    # summary-first: unread_count fast-path (Phase 2/3 optimization)
    # unread_count fast-path lets us skip expensive full reads when idle.
    # get_unread_count_fast now outputs plain number (grep-based, no python3).
    local fast_count
    fast_count=$(get_unread_count_fast)
    fast_count="${fast_count:-0}"

    # P1-2: fast-path expansion — skip full read when unread=0, regardless of trigger type
    # (previously limited to timeout trigger only; now applies to event trigger as well)
    if [ "$fast_count" -eq 0 ] 2>/dev/null; then
        # FIX-008: unread=0 → early return. No agent_is_busy() call (saves 140 forks/min).
        # C-u only on transition from unread>0 to unread=0 (one-time cleanup).
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "[$(date)] All messages read for $AGENT_ID — escalation reset (fast-path)" >&2
            if [ "$AGENT_ID" = "darkninja" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            else
                tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
            fi
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        return 0
    fi

    local info
    info=$(get_unread_info)

    # Parse info in one pass (pure bash, 0 forks — replaces 3 python3 invocations)
    local normal_count has_task_assigned specials
    _parse_unread_info "$info"
    normal_count=$_UI_COUNT
    has_task_assigned=$_UI_HAS_TASK
    specials=$_UI_SPECIALS

    local read_bytes=0
    if [ -f "$INBOX" ]; then
        # FIX-019: stat avoids wc fork (1 fork → 0 on Linux with bash stat cache)
        if [[ "$_UNAME_S" == "Darwin" ]]; then
            read_bytes=$(/usr/bin/stat -f %z "$INBOX" 2>/dev/null || echo 0)
        else
            read_bytes=$(stat -c %s "$INBOX" 2>/dev/null || echo 0)
        fi
    fi
    update_metrics "${read_bytes:-0}"

    # Handle special CLI commands first (/clear, /model)

    local clear_seen=0
    if [ -n "$specials" ]; then
        local msg_type msg_content cmd
        while IFS=$'\t' read -r msg_type msg_content; do
            [ -n "$msg_type" ] || continue
            if [ "$msg_type" = "clear_command" ]; then
                clear_seen=1
                # BUG-6 fix: Update shared clear lock on delivery
                # FIX-016: Also update LAST_CLEAR_TS to suppress nudges for 30s post-/clear
                local _clear_now=${EPOCHSECONDS:-$(date +%s)}
                printf '%s' "$_clear_now" > "${STATE_DIR}/clear_last_${AGENT_ID}"
                LAST_CLEAR_TS=$_clear_now
            fi
            cmd=$(normalize_special_command "$msg_type" "$msg_content")
            [ -n "$cmd" ] && send_cli_command "$cmd"
        done <<< "$specials"
        # FIX-005: Mark specials as read AFTER delivery (at-least-once guarantee)
        mark_specials_read
    fi

    # /clear は Codex で /new へ変換される。再起動直後の取りこぼし防止として
    # 追加 task_assigned を自動投入し、次サイクルで確実に wake-up 可能にする。
    if [ "$clear_seen" -eq 1 ]; then
        local recovery_id
        recovery_id=$(enqueue_recovery_task_assigned)
        if [ -n "$recovery_id" ] && [ "$recovery_id" != "SKIP_DUPLICATE" ] && [ "$recovery_id" != "ERROR" ]; then
            echo "[$(date)] [AUTO-RECOVERY] queued task_assigned for $AGENT_ID ($recovery_id)" >&2
        fi
        info=$(get_unread_info)
        _parse_unread_info "$info"
        normal_count=$_UI_COUNT
        has_task_assigned=$_UI_HAS_TASK
    fi

    if [ "$normal_count" -gt 0 ] 2>/dev/null; then
        # FIX-017: $EPOCHSECONDS avoids date fork
        local now
        now=${EPOCHSECONDS:-$(date +%s)}

        # When the agent is busy/thinking, do NOT escalate. Interrupting with Escape or /clear
        # can terminate the current thought.
        # FIX-006: Track busy→idle transition. While busy, true pause (no timer update).
        # On idle after busy, restart timer from Phase 1 (prevents immediate Phase 2/3 jump).
        if agent_is_busy; then
            PREV_WAS_BUSY=1
            echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy — pausing escalation (true pause)" >&2
            return 0
        fi
        # FIX-006: busy→idle transition — restart escalation from Phase 1
        if [ "$PREV_WAS_BUSY" -eq 1 ]; then
            FIRST_UNREAD_SEEN=$now
            PREV_WAS_BUSY=0
            echo "[$(date)] $AGENT_ID busy→idle transition — escalation timer restarted from Phase 1" >&2
        fi

        # FIX-016: Suppress nudges for 30s after /clear (agent is restarting)
        # Exception: allow nudge in same cycle as /clear (auto-recovery needs immediate wake-up)
        if [ "$clear_seen" -eq 0 ] && [ "$LAST_CLEAR_TS" -gt 0 ] && [ $((now - LAST_CLEAR_TS)) -lt 30 ]; then
            echo "[$(date)] $normal_count unread for $AGENT_ID — nudge suppressed ($((now - LAST_CLEAR_TS))s since /clear)" >&2
            return 0
        fi

        # ─── Context reset before new task ───
        # Send /new or /clear once when task_assigned is first detected,
        # to clear stale context from the previous task.
        # Skip if: (1) already sent this batch, (2) clear_command already handled above,
        #          (3) agent is darkninja (human-controlled).
        if [ "$has_task_assigned" = "1" ] && [ "$NEW_CONTEXT_SENT" -eq 0 ] && [ "$clear_seen" -eq 0 ]; then
            send_context_reset
            NEW_CONTEXT_SENT=1
        fi

        # Track when we first saw unread messages
        if [ "$FIRST_UNREAD_SEEN" -eq 0 ]; then
            FIRST_UNREAD_SEEN=$now
        fi

        if [ "${ASW_DISABLE_ESCALATION:-0}" = "1" ]; then
            echo "[$(date)] $normal_count unread for $AGENT_ID (escalation disabled)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, no normal スリケン for $AGENT_ID" >&2
            else
                send_wakeup "$normal_count" || true
            fi
            return 0
        fi

        local age=$((now - FIRST_UNREAD_SEEN))

        if [ "$age" -lt "$ESCALATE_PHASE1" ]; then
            # Phase 1 (0-2 min): Standard スリケン
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, deferring to escalation-only path" >&2
            else
                send_wakeup "$normal_count" || true
            fi
        elif [ "$age" -lt "$ESCALATE_PHASE2" ]; then
            # Phase 2 (2-4 min): Escape + スリケン
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — escalating: Escape+スリケン)" >&2
            send_wakeup_with_escape "$normal_count" || true
        else
            # Phase 3 (4+ min): /clear (throttled to once per 5 min)
            # FIX-004: darkninja向けは/clear送信不可(send_cli_commandがSKIP)のため
            # FIRST_UNREAD_SEENリセットしない。リセットするとPhase1に戻り無限ループする。
            if [ "$AGENT_ID" = "darkninja" ]; then
                echo "[$(date)] ESCALATION Phase 3: darkninja — /clear suppressed (human-controlled). ${normal_count} unread, ${age}s." >&2
                # Alert記録（gryakuza集約用）
                mkdir -p "${STATE_DIR}/alerts" 2>/dev/null || true
                printf 'agent_id: darkninja\ntimestamp: "%s"\nunread_count: %s\nage_sec: %s\naction: phase3_suppressed\n' \
                    "$(date -Iseconds)" "$normal_count" "$age" > "${STATE_DIR}/alerts/darkninja_undeliverable.yaml"
                # tmux通知（5秒表示）
                timeout 2 tmux display-message -d 5000 "ALERT: inbox ${normal_count} unread for darkninja (${age}s)" 2>/dev/null || true
                # Phase2スリケンを継続（ループに入らない）
                send_wakeup_with_escape "$normal_count" || true
            elif [ "$LAST_CLEAR_TS" -lt "$((now - ESCALATE_COOLDOWN))" ]; then
                local effective_cli
                effective_cli=$(get_effective_cli_type)
                if [[ "$effective_cli" == "codex" ]]; then
                    # Codex /clear -> /new は会話を切ってしまうため、安全側に倒す。
                    echo "[$(date)] ESCALATION Phase 3: $AGENT_ID unresponsive for ${age}s, but cli=codex — skipping /clear." >&2
                    FIRST_UNREAD_SEEN=$now  # Reset timer (no destructive action)
                    send_wakeup "$normal_count" || true
                else
                    echo "[$(date)] ESCALATION Phase 3: Agent $AGENT_ID unresponsive for ${age}s. Sending /clear." >&2
                    send_cli_command "/clear"
                    # BUG-6 fix: Update shared clear lock on Phase 3 /clear
                    printf '%s' "$now" > "${STATE_DIR}/clear_last_${AGENT_ID}"
                    LAST_CLEAR_TS=$now
                    FIRST_UNREAD_SEEN=0  # Reset — will re-detect on next cycle
                    NEW_CONTEXT_SENT=0
                fi
            else
                # Cooldown active — fall back to Escape+スリケン
                echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — /clear cooldown, using Escape+スリケン)" >&2
                send_wakeup_with_escape "$normal_count" || true
            fi
        fi
    else
        # No unread messages — reset escalation tracker
        # FIX-008: C-u only on transition, no agent_is_busy() call
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "[$(date)] All messages read for $AGENT_ID — escalation reset" >&2
            if [ "$AGENT_ID" = "darkninja" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            else
                tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
            fi
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
    fi
}

process_unread_once() {
    process_unread "startup"
}

# ─── Startup & Main loop (skipped in testing mode) ───
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then

# ─── Startup: process any existing unread messages ───
process_unread_once

# ─── Main loop: event-driven via inotifywait ───
# Timeout 5s: WSL2 /mnt/c/ can miss inotify events. Shorter timeout = faster escalation retry.
# Linux: dir監視 + moved_to イベントで atomic write (tmp→rename) に対応。
INOTIFY_TIMEOUT="${INOTIFY_TIMEOUT:-5}"

while true; do
    # FIX-010: Orphan check integrated with resolve_pane_target (avoids duplicate tmux list-panes)
    # Force cache refresh for orphan detection
    _RESOLVE_CACHE_TARGET=""
    resolve_pane_target
    if [ "${_RESOLVE_PANE_FOUND:-1}" -eq 0 ]; then
        echo "[inbox_watcher] pane for $AGENT_ID not found. Exiting orphan watcher." >&2
        exit 0
    fi

    # Block until file is modified OR timeout (safety net for WSL2 / fswatch)
    # set +e: file-watch returns 2 on timeout, which would kill script under set -e
    set +e
    _wait_for_file_change "$INBOX" "$INOTIFY_TIMEOUT"
    rc=$?
    set -e

    # rc=0: event fired (instant delivery — moved_to/close_write/modify)
    # rc=1: watch invalidated — Claude Code uses atomic write (tmp+rename),
    #        which replaces the inode. inotifywait sees DELETE_SELF → rc=1.
    #        File still exists with new inode. Treat as event, re-watch next loop.
    # rc=2: timeout (5s safety net for WSL2 inotify gaps)
    # All cases: check for unread, then loop back to inotifywait (re-watches new inode)

    # FIX-001: Capture mtime before processing to detect gap-window writes
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        _mtime_before=$(/usr/bin/stat -f %m "$INBOX" 2>/dev/null || echo 0)
    else
        _mtime_before=$(stat -c %Y "$INBOX" 2>/dev/null || echo 0)
    fi

    if [ "$rc" -eq 2 ]; then
        if [ "${ASW_PROCESS_TIMEOUT:-1}" = "1" ]; then
            process_unread "timeout"
        fi
    else
        process_unread "event"
    fi

    # FIX-001: Recheck mtime — if inbox was modified during processing, skip wait and re-loop
    if [[ "$_UNAME_S" == "Darwin" ]]; then
        _mtime_after=$(/usr/bin/stat -f %m "$INBOX" 2>/dev/null || echo 0)
    else
        _mtime_after=$(stat -c %Y "$INBOX" 2>/dev/null || echo 0)
    fi
    [[ "$_mtime_before" != "$_mtime_after" ]] && continue
done

fi  # end testing guard
