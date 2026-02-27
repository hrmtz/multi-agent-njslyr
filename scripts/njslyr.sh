#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# njslyr.sh — オヒルネエージェント粛清デーモン（Ninja Slayer）
# ニンジャスレイヤー: アイドル/無応答/長時間thinkingのエージェントを自動検知・粛清
#
# Design: docs/njslyr_design.md
# Phase: 2 (Implementation)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# macOS (Darwin): GNU coreutils via Homebrew gnubin
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
fi

# Cross-platform sed -i (BSD vs GNU)
sedi() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── Configuration ───
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-${SCRIPT_DIR%/*}}"
DASHBOARD="$PROJECT_ROOT/dashboard.md"
LOG_DIR="$PROJECT_ROOT/queue/logs"
METRICS_DIR="$PROJECT_ROOT/queue/metrics"
STATE_DIR="$PROJECT_ROOT/.state"

CACHE_DIR="$PROJECT_ROOT/queue/.cache"
mkdir -p "$LOG_DIR" "$METRICS_DIR" "$STATE_DIR" "$CACHE_DIR"

# ─── Thresholds (seconds) ───
IDLE_TIMEOUT=300           # 5 minutes idle without task
NUDGE_NO_RESPONSE=120      # 2 minutes after nudge
THINKING_TIMEOUT=600       # 10 minutes thinking
STAGE3_COOLDOWN=1800       # 30 minutes cooldown for Stage 3
RESTART_LOOP_WINDOW=1800   # 30 minutes window for restart loop detection
RESTART_LOOP_MAX=3         # Max 3 restarts in 30 min
# B-2: STALE_THRESHOLD >= STAGE3_COOLDOWN * 2 (3600 >= 1800*2) to avoid deleting
# stage_last files that are still within the cooldown window.
STALE_THRESHOLD=3600       # 1 hour: stale state file age threshold (B-2 check_stale_state)
# B-4: 4-hour long-running refresh interval. Chosen to be long enough that it does not
# interfere with normal operation cycles (15-min interval * 16 = 4h), but short enough
# to prevent STATE_DIR accumulation in multi-day continuous runs.
REFRESH_INTERVAL=14400     # 4 hours: long-running refresh interval (B-4)

# Assertion: STALE_THRESHOLD must be >= STAGE3_COOLDOWN * 2 (UNIFIED-MED-006)
(( STALE_THRESHOLD >= STAGE3_COOLDOWN * 2 )) || {
    echo "ERROR: STALE_THRESHOLD($STALE_THRESHOLD) < STAGE3_COOLDOWN*2($((STAGE3_COOLDOWN*2)))" >&2
    exit 1
}

# ─── Dynamic tmux window/pane resolution (FIX-002/FIX-003) ───
SETTINGS_YAML="$PROJECT_ROOT/config/settings.yaml"

# get_agents_window: neosaitamaリネーム対応 — agents/neosaitama/kyotoを動的検出
get_agents_window() {
    tmux list-windows -t multiagent -F '#{window_name}' 2>/dev/null \
        | grep -E '^(agents|neosaitama|kyoto)$' | head -1
}

# get_monitor_window: machine roleに応じてmonitorウィンドウを返す
# kyoto → main:monitor / neosaitama → main:crane
get_monitor_window() {
    local role
    role=$(awk '/^  role:/ {print $2; exit}' "$SETTINGS_YAML" 2>/dev/null)
    role="${role:-kyoto}"
    # Legacy role normalization
    case "$role" in
        mbp)   role="neosaitama" ;;
        ryzen) role="kyoto" ;;
    esac
    case "$role" in
        neosaitama) echo "main:crane" ;;
        *)          echo "main:monitor" ;;
    esac
}

# ─── Session mode (default: once) ───
# "once" = single execution (for cron/tmux timer)
# "continuous" = infinite loop with 15-minute sleep (for daemon mode)
MODE="${1:-once}"

# ─── Startup banner ───
show_startup_banner() {
    echo ""
    # ═══════════════════════════════════════════════════════════════════════════
    # ネオサイタマ電脳IRC切断シーケンス（yokubari.sh接続シーケンスの対）
    # yokubari.sh: ◆WARNING◆→接続→✓ / njslyr.sh: ◆SHUTDOWN◆→切断→✗
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;31m◆◆◆ SHUTDOWN ◆◆◆\033[0m  \033[1;33m電脳空間切断開始\033[0m  \033[1;31m◆◆◆ SHUTDOWN ◆◆◆\033[0m"
    echo ""
    echo -e "\033[1;35m卍\033[0m \033[0;37mネオサイタマ電脳IRCコトダマ空間から切断中...\033[0m"
    sleep 0.1
    echo -e "\033[1;33m  ✗\033[0m \033[0;37m[1/5] #マッポーの世 チャネル離脱\033[0m"
    sleep 0.1
    echo -e "\033[1;33m  ✗\033[0m \033[0;37m[2/5] コトダマ空間ソケット解放中\033[0m"
    sleep 0.1
    echo -e "\033[0;31m  ✗\033[0m \033[0;37m[3/5] サイバーパンクプロトコル解除\033[0m"
    sleep 0.1
    echo -e "\033[0;31m  ✗\033[0m \033[0;37m[4/5] UNIXニューロン認証解除\033[0m"
    sleep 0.1
    echo -e "\033[1;31m  ✗\033[0m \033[0;37m[5/5] ニンジャソウル・リンク切断\033[0m"
    sleep 0.1
    echo -e "\033[1;31m  サヨナラ！\033[0m \033[1;37m切断処理を開始する。\033[0m"
    sleep 0.2
    echo ""

    # タイトルバナー（yokubari.shと同一のASCIIアート、赤枠＋終了テーマ）
    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███╗   ██╗     ██╗███████╗██╗  ██╗   ██╗██████╗                    \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m████╗  ██║     ██║██╔════╝██║  ╚██╗ ██╔╝██╔══██╗                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔██╗ ██║     ██║███████╗██║   ╚████╔╝ ██████╔╝                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║╚██╗██║██   ██║╚════██║██║    ╚██╔╝  ██╔══██╗                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║ ╚████║╚█████╔╝███████║███████╗██║   ██║  ██║                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚═╝  ╚═══╝ ╚════╝ ╚══════╝╚══════╝╚═╝   ╚═╝  ╚═╝                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m    \033[1;37mサヨナラ。ニンジャスレイヤーです。\033[0m  \033[1;31m☠\033[0m  \033[1;35mグワーッ！\033[0m                \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # ドクロ紋章（yokubari.shのクローンヤクザ隊列AAの対・粛清の印）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;31m  ╔═══════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m  ║\033[0m         \033[1;37m【 ニンジャスレイヤー ・ 粛清デーモン起動 】\033[0m                \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ╚═══════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "                       \033[1;31m     ▄▄▄████████▄▄▄\033[0m"
    echo -e "                       \033[1;31m   ▄██▀▀▀      ▀▀▀██▄\033[0m"
    echo -e "                       \033[1;31m  ██▀   ▄▀▀▀▀▀▄   ▀██\033[0m"
    echo -e "                       \033[1;31m ██   ▄█ \033[1;33m◉\033[1;31m    \033[1;33m◉\033[1;31m █▄   ██\033[0m"
    echo -e "                       \033[1;31m ██   ██         ██   ██\033[0m"
    echo -e "                       \033[1;31m  ██▄  ▀▀▄▄▲▄▄▀▀  ▄██\033[0m"
    echo -e "                       \033[1;31m   ▀██▄ ▄█████▄ ▄██▀\033[0m"
    echo -e "                       \033[1;31m     ▀▀███████████▀▀\033[0m"
    echo ""
    echo -e "                  \033[1;31m「「「 ニンジャ殺すべし、慈悲はない 」」」\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # 粛清モード情報（yokubari.shのシステム情報ボックスの対）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m粛清プロトコル\033[0m 〜 \033[1;31mオヒルネ・ニンジャ狩り\033[0m 〜                    \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                 \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;36mStage 1\033[0m: スリケン    \033[1;33mStage 2\033[0m: カラテチョップ    \033[1;31mStage 3\033[0m: スレイ  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[0;37m  (inbox通知)         (/clear強制)          (kill+再起動)\033[0m  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# ─── Farewell haiku generator ───
generate_farewell_haiku() {
    local -a haiku=(
        "闇に消え    電脳の海に    波ひとつ"
        "切断の    音なき音に    月冴える"
        "ソケット閉じ    コトダマ散りて    夜が来る"
        "粛清の    刃を収めて    静寂なり"
        "巡回を    終えてニンジャは    闇に溶く"
        "ナムサン    トークン散りて    暁光なし"
    )
    local idx=$(( RANDOM % ${#haiku[@]} ))
    echo "${haiku[$idx]}"
}

# ─── Completion banner ───
show_completion_banner() {
    local slain_count="$1"
    local healthy_count="$2"

    echo ""
    # ═══════════════════════════════════════════════════════════════════════════
    # コトダマ空間切断完了シーケンス（yokubari.sh接続完了の対）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;35m卍\033[0m \033[0;37mコトダマ空間切断シーケンス実行中...\033[0m"
    sleep 0.1
    echo -e "\033[1;33m  ✗\033[0m \033[0;37m[1/4] ニンジャソウル・リンク解放完了\033[0m"
    sleep 0.1
    echo -e "\033[0;31m  ✗\033[0m \033[0;37m[2/4] エージェント監視ループ終了\033[0m"
    sleep 0.1
    echo -e "\033[0;31m  ✗\033[0m \033[0;37m[3/4] 電脳IRCソケット完全切断\033[0m"
    sleep 0.1
    echo -e "\033[1;31m  ✗\033[0m \033[0;37m[4/4] コトダマ空間からのログアウト完了\033[0m"
    sleep 0.2

    echo ""
    echo -e "\033[1;31m  ╔═══════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m         \033[1;37m【 粛清結果報告 ・ インガオホー 】\033[0m                            \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ╠═══════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    printf "  \033[1;31m║\033[0m  \033[1;31m  ☠ 爆発四散:\033[0m %-3s体                                                \033[1;31m║\033[0m\n" "$slain_count"
    printf "  \033[1;31m║\033[0m  \033[1;32m  ✓ 健全:\033[0m     %-3s体                                                \033[1;31m║\033[0m\n" "$healthy_count"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ╠═══════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[1;32m✓\033[0m ニンジャソウル消滅完了                                          \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[1;32m✓\033[0m 全エージェント巡回完了                                          \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[1;32m✓\033[0m 電脳IRC切断完了                                                \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[1;32m✓\033[0m コトダマ空間ログアウト完了                                      \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ╠═══════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[1;37mサヨナラ！ニンジャスレイヤーは闇に消えた。\033[0m                        \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m  \033[0;37mナムアミダブツ…\033[0m                                                   \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ║\033[0m                                                                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m  ╚═══════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # 辞世の句（ランダム・yokubari.shの起動メッセージの対）
    # ═══════════════════════════════════════════════════════════════════════════
    local farewell
    farewell=$(generate_farewell_haiku)
    echo -e "  \033[1;31m════════════════════════════════════════════════════════════\033[0m"
    echo -e "  \033[0;35m  ${farewell}\033[0m"
    echo -e "  \033[1;31m════════════════════════════════════════════════════════════\033[0m"
    echo ""
}

# ─── Logging ───
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [njslyr] $*" >&2
}

log_execution() {
    local agent_id="$1"
    local stage="$2"
    local result="$3"
    local reason="$4"

    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local log_file="$LOG_DIR/njslyr_${timestamp//:/-}.log"

    cat >> "$log_file" << EOF
---
timestamp: "$timestamp"
agent_id: "$agent_id"
stage: "$stage"
result: "$result"
reason: "$reason"
---
EOF
}

# ─── Dashboard update ───
update_dashboard() {
    local message="$1"
    local lockfile="${DASHBOARD}.lock"

    if [[ ! -f "$DASHBOARD" ]]; then
        log "WARNING: dashboard.md not found, skipping dashboard update"
        return 0
    fi

    (
        flock -w 3 200 || exit 1

        if grep -q "^## 🚨ヨウタイオウ" "$DASHBOARD"; then
            local temp_file
            temp_file=$(TMPDIR="$CACHE_DIR" mktemp)
            if awk -v msg="$message" '
                /^## 🚨ヨウタイオウ/ {
                    print
                    print ""
                    print "- " msg
                    skip_next_blank = 1
                    next
                }
                skip_next_blank && /^$/ {
                    skip_next_blank = 0
                    next
                }
                {print}
            ' "$DASHBOARD" > "$temp_file"; then
                mv "$temp_file" "$DASHBOARD" || rm -f "$temp_file"
            else
                rm -f "$temp_file"
            fi
        else
            {
                echo ""
                echo "## 🚨ヨウタイオウ"
                echo ""
                echo "- $message"
            } >> "$DASHBOARD"
        fi
    ) 200>"$lockfile" 2>/dev/null
}

# ─── Inbox notification ───
notify_darkninja() {
    local message="$1"
    local priority="${2:-P2}"

    bash "$SCRIPT_DIR/inbox_write.sh" darkninja "$message" system_notice njslyr "" "$priority" 2>/dev/null || true
}

# ─── バリキドリンク投与・解除ヘルパー関数 ───
# Usage:
#   inject_barikidorink "multiagent:0.1"                              # yakuza1にOpus投与
#   inject_barikidorink "multiagent:0.1" "queue/tasks/yakuza1.yaml"   # 投与 + タスク割り当て
#   detox_barikidorink "multiagent:0.1"                               # yakuza1をSonnetに復帰
inject_barikidorink() {
    local pane=$1
    local task_yaml="${2:-}"
    local _project_root="${PROJECT_ROOT:-$SCRIPT_DIR}"
    local agent_id
    agent_id=$(tmux show-options -pv -t "$pane" @agent_id 2>/dev/null || echo "")

    # Idempotency: skip model switch if already Opus
    local current_model
    current_model=$(tmux show-options -pv -t "$pane" @model_name 2>/dev/null || echo "")
    if [ "$current_model" = "Opus" ]; then
        echo "[barikidorink] ${agent_id:-$pane} already Opus, skipping model switch" >&2
    else
        tmux send-keys -t "$pane" "/model opus"
        sleep 0.3
        tmux send-keys -t "$pane" Escape
        sleep 0.1
        tmux send-keys -t "$pane" Enter
        sleep 0.5
        tmux set-option -p -t "$pane" @model_name "Opus"
        tmux select-pane -t "$pane" -P 'bg=#1a002e'
        sleep 0.3
        tmux send-keys -t "$pane" "/clear"
        sleep 0.3
        tmux send-keys -t "$pane" Escape
        sleep 0.1
        tmux send-keys -t "$pane" Enter
        sleep 5
    fi

    # Task assignment via inbox_write (inbox_watcher handles nudge automatically)
    if [ -n "$task_yaml" ] && [ -n "$agent_id" ]; then
        bash "$_project_root/scripts/inbox_write.sh" "$agent_id" \
            "タスクYAMLを読んで作業開始せよ。" task_assigned "yakuzatengu" "$task_yaml" "P0"
    elif [ "$current_model" != "Opus" ] && [ -n "$agent_id" ]; then
        # Re-nudge: no task_yaml given, manually check inbox unread and send nudge
        local unread_count
        unread_count=$(grep -c 'read: false' "$_project_root/queue/inbox/${agent_id}.yaml" 2>/dev/null) || unread_count=0
        if [ "$unread_count" -gt 0 ]; then
            tmux send-keys -t "$pane" "inbox${unread_count}"
            sleep 0.3
            tmux send-keys -t "$pane" Escape
            sleep 0.1
            tmux send-keys -t "$pane" Enter
        fi
    fi
}

detox_barikidorink() {
    local pane=$1
    tmux send-keys -t "$pane" "/model sonnet"
    sleep 0.3
    tmux send-keys -t "$pane" Escape
    sleep 0.1
    tmux send-keys -t "$pane" Enter
    sleep 0.5
    tmux set-option -p -t "$pane" @model_name "Sonnet"
    tmux select-pane -t "$pane" -P 'bg=default'
    sleep 0.3
    tmux send-keys -t "$pane" "/clear"
    sleep 0.3
    tmux send-keys -t "$pane" Escape
    sleep 0.1
    tmux send-keys -t "$pane" Enter
}

# ─── Validate @agent_id assignments (2026-02-18 恒久対策) ───
# multiagentセッションのpaneに "darkninja" IDが誤設定されていないかを検証し、
# 検知した場合はダッシュボードへ警告を記録してダークニンジャに通知する。
validate_agent_ids() {
    local suspicious_panes
    local agents_win monitor_win
    agents_win=$(get_agents_window)
    monitor_win=$(get_monitor_window)
    suspicious_panes=$(
        {
            [[ -n "$agents_win" ]] && tmux list-panes -t "multiagent:${agents_win}" -F '#{pane_index} #{@agent_id}' 2>/dev/null
            [[ -n "$monitor_win" ]] && tmux list-panes -t "${monitor_win}" -F 'monitor:#{pane_index} #{@agent_id}' 2>/dev/null
        } | awk '$2 == "darkninja" {print $1}' || true
    )

    if [[ -n "$suspicious_panes" ]]; then
        local msg="🚨 @agent_id誤設定検知！multiagentペイン(${suspicious_panes})にdarkninja IDが設定されている。yokubari.shで再起動が必要。"
        log "ALERT: $msg"
        update_dashboard "$msg"
        notify_darkninja "$msg" P0
        return 1
    fi
    return 0
}

# ─── Get all monitored agents ───
get_monitored_agents() {
    # Dynamically detect agents from tmux pane @agent_id
    # Exclude darkninja (human agent)
    # Check agents window (dynamic name) + monitor window (machine-role-dependent)
    local agents_win monitor_win
    agents_win=$(get_agents_window)
    monitor_win=$(get_monitor_window)
    {
        [[ -n "$agents_win" ]] && tmux list-panes -t "multiagent:${agents_win}" -F '#{@agent_id}' 2>/dev/null
        [[ -n "$monitor_win" ]] && tmux list-panes -t "${monitor_win}" -F '#{@agent_id}' 2>/dev/null
    } | grep -v '^$' | \
        grep -v '^darkninja$' | \
        sort -u || true
}

# ─── Check inbox unread ───
has_inbox_unread() {
    local agent_id="$1"
    local inbox="$PROJECT_ROOT/queue/inbox/${agent_id}.yaml"

    [[ -f "$inbox" ]] && grep -q '^ *read: false$' "$inbox"
}

# ─── Get inbox unread count (S-2: should_spawn_yakuzatengu用) ───
get_inbox_unread_count() {
    local agent_id="$1"
    local inbox="$PROJECT_ROOT/queue/inbox/${agent_id}.yaml"

    [[ ! -f "$inbox" ]] && echo "0" && return 0
    grep -c '^ *read: false$' "$inbox" 2>/dev/null || true
}

# ─── Get latest task YAML for agent (dedup: replaces 5x ls -t|head -1) ───
get_latest_task_yaml() {
    local agent_id="$1"
    # shellcheck disable=SC2012
    ls -t "$PROJECT_ROOT/queue/tasks/${agent_id}"*.yaml 2>/dev/null | head -1
}

# ─── Check task YAML status ───
get_task_status() {
    local agent_id="$1"
    # M1 fix: Use glob pattern to match _subtask_xxx.yaml files
    local task_yaml
    task_yaml=$(get_latest_task_yaml "$agent_id")

    if [[ -z "$task_yaml" || ! -f "$task_yaml" ]]; then
        echo "idle"
        return 0
    fi

    # Extract status field from YAML (single awk — replaces grep|head|sed 3-process pipe)
    local status
    status=$(awk '/^ *status: /{sub(/.*status: */,""); sub(/ *$/,""); print; exit}' "$task_yaml" 2>/dev/null || true)
    echo "${status:-idle}"
}

# ─── Get pane target for agent ───
get_pane_target() {
    local agent_id="$1"
    local result agents_win monitor_win
    agents_win=$(get_agents_window)
    monitor_win=$(get_monitor_window)
    # Find pane with matching @agent_id in agents window first (dynamic name)
    if [[ -n "$agents_win" ]]; then
        result=$(tmux list-panes -t "multiagent:${agents_win}" -F '#{pane_index} #{@agent_id}' 2>/dev/null | \
            awk -v id="$agent_id" -v win="$agents_win" '$2 == id {print "multiagent:" win "." $1; exit}')
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi
    # Fallback: check monitor window (main:monitor or main:crane)
    if [[ -n "$monitor_win" ]]; then
        tmux list-panes -t "${monitor_win}" -F '#{pane_index} #{@agent_id}' 2>/dev/null | \
            awk -v id="$agent_id" -v win="$monitor_win" '$2 == id {print win "." $1; exit}'
    fi
}

# ─── Agent busy detection (from inbox_watcher.sh pattern) ───
agent_is_busy() {
    local pane_target="$1"
    local pane_tail

    pane_tail=$(timeout 1 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -5 || echo "")

    # Check for busy markers (BUG-3 fix: expanded patterns — confirmed Claude Code outputs only)
    if grep -qiE '(Working|Thinking|Planning|Sending|Generating|\(thinking\)|thought for|Cogitated|思考中|考え中|計画中|送信中|処理中|実行中|生成中|esc to interrupt)' <<< "$pane_tail"; then
        return 0  # busy
    fi

    return 1  # idle
}

# ─── Thinking detection ───
agent_is_thinking() {
    local pane_target="$1"
    local pane_content

    pane_content=$(timeout 1 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -10 || echo "")

    # Check for thinking markers (BUG-3 fix: add bracketed (thinking) pattern)
    if grep -qiE '(Thinking|\(thinking\)|思考中|Planning|考え中|計画中)' <<< "$pane_content"; then
        return 0  # thinking
    fi

    return 1  # not thinking
}

# ─── Check if long_running task ───
is_long_running_task() {
    local agent_id="$1"
    local task_yaml
    task_yaml=$(get_latest_task_yaml "$agent_id")

    [[ -n "$task_yaml" && -f "$task_yaml" ]] && grep -q '^ *long_running: *true' "$task_yaml"
}

# ─── Check inbox_watcher recent /clear ───
inbox_watcher_recently_cleared() {
    local agent_id="$1"
    # BUG-6 fix: Use shared clear lock file (written by njslyr stage2, inbox_watcher clear_command/Phase 3)
    # Note: TOCTOU with inbox_watcher.sh. Mitigated by multi-layer cooldown.
    local clear_lock="$STATE_DIR/clear_last_${agent_id}"

    [[ ! -f "$clear_lock" ]] && return 1

    local last_clear_ts
    read -r last_clear_ts < "$clear_lock" 2>/dev/null || last_clear_ts=0

    local now
    now=$(date +%s)

    # If any /clear was sent within last 5 minutes, skip
    [[ $((now - last_clear_ts)) -lt 300 ]]
}

# ─── Restart counter ───
get_restart_count() {
    local agent_id="$1"
    local restart_file="$METRICS_DIR/njslyr_restarts_${agent_id}.yaml"

    [[ ! -f "$restart_file" ]] && echo "0" && return 0

    local count
    count=$(awk '/count:/{sub(/.*: */,""); print; exit}' "$restart_file" 2>/dev/null); count="${count:-0}"
    echo "$count"
}

increment_restart_count() {
    local agent_id="$1"
    local restart_file="$METRICS_DIR/njslyr_restarts_${agent_id}.yaml"

    local count
    count=$(get_restart_count "$agent_id")
    count=$((count + 1))

    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')

    cat > "$restart_file" << EOF
count: $count
last_restart: "$timestamp"
EOF
}

reset_restart_count() {
    local agent_id="$1"
    local restart_file="$METRICS_DIR/njslyr_restarts_${agent_id}.yaml"

    rm -f "$restart_file"
}

check_restart_loop() {
    local agent_id="$1"
    local restart_file="$METRICS_DIR/njslyr_restarts_${agent_id}.yaml"

    [[ ! -f "$restart_file" ]] && return 1  # no loop

    local count last_restart
    # Single awk per field (replaces grep|sed 2-process pipe with 1 awk each)
    count=$(awk '/count:/{sub(/.*: */,""); print; exit}' "$restart_file" 2>/dev/null); count="${count:-0}"
    last_restart=$(awk '/last_restart:/{sub(/.*: *"/,""); sub(/".*/,""); print; exit}' "$restart_file" 2>/dev/null); last_restart="${last_restart:-1970-01-01T00:00:00}"

    # Convert timestamp to epoch (macOS native date: -j flag; GNU date: -d flag)
    local last_restart_epoch
    last_restart_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$last_restart" '+%s' 2>/dev/null \
        || date -d "$last_restart" '+%s' 2>/dev/null \
        || echo "0")

    local now
    now=$(date +%s)

    # If count >= 3 and last restart within 30 min window, it's a restart loop
    if [[ $count -ge $RESTART_LOOP_MAX ]] && [[ $((now - last_restart_epoch)) -lt $RESTART_LOOP_WINDOW ]]; then
        return 0  # restart loop detected
    fi

    return 1  # no loop
}

# ─── Stage 1: Suriken (スリケン) ───
stage1_suriken() {
    local agent_id="$1"
    local reason="$2"

    log "[KARATE] イヤーッ！${agent_id} に [スリケン] を投擲！理由: ${reason}"

    local message="🔪 ニンジャスレイヤーのスリケン！inbox確認せよ。理由: ${reason}"
    bash "$SCRIPT_DIR/inbox_write.sh" "$agent_id" "$message" njslyr njslyr "" P1 2>/dev/null || true

    log_execution "$agent_id" "Stage 1 (スリケン)" "success" "$reason"

    return 0
}

# ─── Stage 2: Chop (/clear) ───
stage2_chop() {
    local agent_id="$1"
    local reason="$2"

    log "[KARATE] ドゴォーン！${agent_id} に [カラテ・チョップ] を放つ！理由: ${reason}"

    local message="🥋 ニンジャスレイヤーのカラテ・チョップ！セッションリセットする。理由: ${reason}"
    bash "$SCRIPT_DIR/inbox_write.sh" "$agent_id" "$message" clear_command njslyr "" P0 2>/dev/null || true

    # M2 fix: Record stage2 timestamp for escalation to stage3
    local stage2_ts_file="$STATE_DIR/njslyr_${agent_id}_stage2_last"
    date +%s > "$stage2_ts_file"

    # BUG-6 fix: Write shared clear lock
    local clear_lock="$STATE_DIR/clear_last_${agent_id}"
    date +%s > "$clear_lock"

    log_execution "$agent_id" "Stage 2 (チョップ)" "success" "$reason"

    return 0
}

# ─── Death cry generator (haiku or 爆発四散) ───
generate_death_cry() {
    local agent_id="$1"

    # 辞世の句コレクション (5-7-5 or 爆発四散)
    local -a haiku=(
        "     ║    散りてなお    赤き炎の    ヤクザ道                                        ║"
        "     ║    春風に    コンテキスト散る    無常                                        ║"
        "     ║    令月に    YAMLの海に    沈みけり                                          ║"
        "     ║    冬の夜    ソケット冷えて    ニンジャ死す                                  ║"
        "     ║    品質は    レビューの彼方    QC散る                                        ║"
        "     ║    朝露の    如くトークン    消えにけり                                      ║"
    )

    local -a bakuhatsu=(
        "     ║    アイエエエエ！ナンデ！？                                                  ║\n     ║    グワーッ！！爆発四散！！                                                  ║"
        "     ║    グワーッ！！                                                              ║\n     ║    「タスクが…まだ…」爆発四散！！                                            ║"
        "     ║    アイエエエ！スレイ！スレイ！                                              ║\n     ║    「オヌシのカラテは弱い」                                                  ║"
        "     ║    グワーッ！！                                                              ║\n     ║    「ラオモト＝サン…スミマセン…」                                            ║"
    )

    # 50/50 chance: haiku or 爆発四散
    local roll=$(( RANDOM % 2 ))
    if [[ $roll -eq 0 ]]; then
        local idx=$(( RANDOM % ${#haiku[@]} ))
        echo "${haiku[$idx]}"
    else
        local idx=$(( RANDOM % ${#bakuhatsu[@]} ))
        echo "${bakuhatsu[$idx]}"
    fi
}

# ─── Stage 3: Slay (kill + restart) ───
stage3_slay() {
    local agent_id="$1"
    local reason="$2"
    local pane_target="$3"

    log "[SLAY] ◆ツヨイ・カラテ！◆ ${agent_id} を粛清する！ニンジャソウル消滅！理由: ${reason}"

    # Check restart loop
    if check_restart_loop "$agent_id"; then
        log "アイエエエ！${agent_id} が再起動ループに陥っている！ニンジャの手に負えぬ。"
        update_dashboard "🚨 エージェント異常停止: ${agent_id} が30分以内に3回再起動。手動介入が必要。"
        notify_darkninja "🚨 アイエエエ！${agent_id} が再起動ループ！カラテでは解決できぬ。手動介入を求む。" P0
        log_execution "$agent_id" "Stage 3 (スレイ)" "blocked" "再起動ループ検知"
        return 1
    fi

    # ─── Pre-slay data preservation (cmd_277) ───

    # Data preservation Step 1: 粛清予告（ダッシュボード記載）
    log "Data preservation: 粛清予告をダッシュボードに記載..."
    update_dashboard "◆${agent_id}を粛清予定。データ保存中..."

    # Data preservation Step 2: /compact送信（コンテキスト保存）
    log "Data preservation: /compact送信中..."
    tmux send-keys -t "$pane_target" "/compact" Enter 2>/dev/null || true
    sleep 5  # サマリー生成待機

    # Data preservation Step 3: タスクYAML状態更新
    local pre_slay_task_yaml
    pre_slay_task_yaml=$(get_latest_task_yaml "$agent_id")
    local current_task_id="unknown"
    if [[ -n "$pre_slay_task_yaml" && -f "$pre_slay_task_yaml" ]]; then
        current_task_id=$(awk '/^ *task_id: /{sub(/.*task_id: */,""); gsub(/"/,""); print; exit}' "$pre_slay_task_yaml" 2>/dev/null); current_task_id="${current_task_id:-unknown}"
        log "Data preservation: タスクYAML状態更新 (${pre_slay_task_yaml})..."
        sedi 's/^ *status: .*/  status: slayed_by_njslyr/' "$pre_slay_task_yaml" 2>/dev/null || true
    fi

    # Data preservation Step 4: 粛清ログ記録
    local slay_timestamp
    slay_timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local slay_log="$LOG_DIR/njslyr_slay_${slay_timestamp//:/-}.yaml"
    log "Data preservation: 粛清ログ記録 (${slay_log})..."
    mkdir -p "$LOG_DIR"
    cat > "$slay_log" << SLAY_EOF
agent_id: "${agent_id}"
task_id: "${current_task_id}"
slay_reason: "${reason}"
timestamp: "${slay_timestamp}"
task_yaml_path: "${pre_slay_task_yaml:-none}"
SLAY_EOF

    # ─── End pre-slay data preservation ───

    # BUG-1 fix: Read @model_name before slay (to restore correct model/bg_color)
    local pane_model
    pane_model=$(tmux show-options -pv -t "$pane_target" @model_name 2>/dev/null || echo "")
    log "Pre-slay @model_name for ${agent_id}: '${pane_model}'"

    # Step 0: Prevent pane from closing when process dies
    # Without this, killing the process may close the pane and shrink the tmux window
    tmux set-option -p -t "$pane_target" remain-on-exit on 2>/dev/null || true

    # Step 1: Turn pane background red
    log "Turning ${pane_target} background to RED..."
    tmux select-pane -t "$pane_target" -P 'bg=red' 2>/dev/null || true

    # Step 2: Display death screen with haiku or 爆発四散 (visible in pane)
    local death_cry
    death_cry=$(generate_death_cry "$agent_id")
    log "断末魔: ${agent_id}"
    tmux respawn-pane -k -t "$pane_target" "bash -c 'printf \"\033[2J\033[H\n\n\n\033[1;37;41m\n\n     ╔══════════════════════════════════════════════════════════════════════════╗\n     ║    ＜＜＜ SLAY ＞＞＞                                                   ║\n     ║                                                                          ║\n${death_cry}\n     ║                                                                          ║\n     ║    【 ${agent_id} — 爆発四散！ 】                                  ║\n     ╚══════════════════════════════════════════════════════════════════════════╝\n\n     ◆ニンジャソウル消滅◆ サヨナラ！\033[0m\n\"; sleep 999999'" 2>/dev/null || true
    sleep 5

    # Step 3: Determine agent type for restart command
    local agent_type
    if [[ "$agent_id" == "gryakuza" ]]; then
        agent_type="gryakuza"
    elif [[ "$agent_id" == "soukaiya" ]]; then
        agent_type="soukaiya"
    elif [[ "$agent_id" =~ ^yakuza[0-9]+$ ]]; then
        agent_type="yakuza"
    else
        log "ERROR: Unknown agent type for ${agent_id}, cannot restart"
        log_execution "$agent_id" "Stage 3 (スレイ)" "failed" "不明なエージェントタイプ"
        return 1
    fi

    # Step 4: Determine model from @model_name (BUG-1 fix)
    local model
    local bg_color="default"
    if [[ -n "$pane_model" ]]; then
        case "$pane_model" in
            Opus|opus|OPUS)
                model="opus"
                bg_color="#1a002e"
                ;;
            Sonnet|sonnet|SONNET)
                model="sonnet"
                ;;
            *)
                log "WARNING: Unknown @model_name '${pane_model}' for ${agent_id}, defaulting to sonnet"
                model="sonnet"
                ;;
        esac
    else
        # Fallback: agent type default (backward compatible)
        if [[ "$agent_id" == "soukaiya" ]]; then
            model="opus"
        else
            model="sonnet"
        fi
    fi

    # ADDON-1: Clear thinking/idle state (prevent false positive after restart)
    rm -f "$STATE_DIR/njslyr_${agent_id}_thinking_start"
    rm -f "$STATE_DIR/njslyr_${agent_id}_idle_start"  # TODO(UNIFIED-MED-003): idle_start廃止後は削除

    # Step 5: Restart agent using respawn-pane (M3 fix - preserves grid layout)
    log "◆再ショウカン◆ ${agent_id}（type: ${agent_type}, model: ${model}, bg: ${bg_color}）…ニンジャソウル再覚醒！"
    sleep 1
    tmux respawn-pane -k -t "$pane_target" "claude --model ${model} --dangerously-skip-permissions" 2>/dev/null || true
    sleep 2

    # Step 6: Reset pane background (keep remain-on-exit ON permanently)
    # remain-on-exit stays on so if Claude CLI crashes later, the pane survives
    tmux select-pane -t "$pane_target" -P "bg=${bg_color}" 2>/dev/null || true

    # Step 7: Increment restart counter
    increment_restart_count "$agent_id"

    log "◆復帰完了◆ ${agent_id} ニンジャソウル再覚醒！ワザマエ！"
    log_execution "$agent_id" "Stage 3 (スレイ)" "success" "$reason"

    return 0
}

# ─── Cooldown check ───
check_cooldown() {
    local agent_id="$1"
    local stage="$2"
    local cooldown_file="$STATE_DIR/njslyr_${agent_id}_${stage}_last"

    [[ ! -f "$cooldown_file" ]] && return 0  # No cooldown active

    local last_ts
    read -r last_ts < "$cooldown_file" 2>/dev/null || last_ts=0

    local now
    now=$(date +%s)

    local elapsed=$((now - last_ts))

    # Stage 3 cooldown: 30 minutes
    if [[ "$stage" == "stage3" ]] && [[ $elapsed -lt $STAGE3_COOLDOWN ]]; then
        return 1  # Cooldown active
    fi

    return 0  # Cooldown passed
}

update_cooldown() {
    local agent_id="$1"
    local stage="$2"
    local cooldown_file="$STATE_DIR/njslyr_${agent_id}_${stage}_last"

    date +%s > "$cooldown_file"
}

# ─── Yakuza Tengu: STATEファイル存在チェック（M-1） ───
is_yakuzatengu_active() {
    [[ -f "$STATE_DIR/yakuzatengu_active" ]]
}

# ─── Yakuza Tengu: STATEクリーンアップ（M-7: clear_last含む） ───
cleanup_yakuzatengu_state() {
    rm -f "$STATE_DIR/yakuzatengu_active" \
          "$STATE_DIR/yakuzatengu_original_agent_id" \
          "$STATE_DIR/yakuzatengu_original_pane" \
          "$STATE_DIR/yakuzatengu_original_model" \
          "$STATE_DIR/yakuzatengu_spawn_time" \
          "$STATE_DIR/yakuzatengu_despawn_pending" \
          "$STATE_DIR/yakuzatengu_done" \
          "$STATE_DIR/clear_last_yakuzatengu" \
          "$STATE_DIR/njslyr_yakuzatengu_thinking_start" \
          "$STATE_DIR/njslyr_yakuzatengu_idle_start"  # TODO(UNIFIED-MED-003): idle_start廃止後は削除
}

# ─── Yakuza Tengu: spawn判定（M-4） ───
# トリガー条件1: gryakuza inbox未読 >= 5
# トリガー条件2: アイドルyakuza >= 3体 × 300秒
should_spawn_yakuzatengu() {
    local agent_id="$1"  # gryakuza

    # 二重spawn防止（M-1）
    is_yakuzatengu_active && return 1

    # トリガー条件1: inbox未読 >= 5 AND アイドルyakuza 1体以上
    local unread_count
    unread_count=$(get_inbox_unread_count "$agent_id")
    if [[ $unread_count -ge 5 ]]; then
        local has_idle=false
        while IFS= read -r yid; do
            [[ ! "$yid" =~ ^yakuza[0-9]+$ ]] && continue
            [[ -f "$STATE_DIR/njslyr_${yid}_idle_start" ]] && { has_idle=true; break; }  # TODO(UNIFIED-MED-003): check_agent_idle_v2()ベースに置き換え
        done < <(get_monitored_agents)
        if [[ "$has_idle" == "true" ]]; then
            log "spawn trigger: ${agent_id} inbox未読 ${unread_count}件 >= 5 (idle yakuza存在確認)"
            return 0
        fi
        log "INFO: spawn trigger 1条件充足だがアイドルyakuza不在。spawn見送り。"
    fi

    # トリガー条件2: アイドルyakuza >= 3体 × 300秒
    # NOTE: stat -c %Y はmacOS非対応（CB-04/CB-7）。catでidle_start中身を読む（S-4）
    # TODO(UNIFIED-MED-003): idle_start廃止後はcheck_agent_idle_v2()ベースに置き換え
    local idle_count=0
    local now; now=$(date +%s)
    while IFS= read -r yid; do
        [[ ! "$yid" =~ ^yakuza[0-9]+$ ]] && continue
        local idle_file="$STATE_DIR/njslyr_${yid}_idle_start"
        [[ ! -f "$idle_file" ]] && continue
        local idle_start; read -r idle_start < "$idle_file" 2>/dev/null || idle_start=0
        local idle_elapsed=$((now - idle_start))
        [[ $idle_elapsed -ge 300 ]] && idle_count=$(( idle_count + 1 ))
    done < <(get_monitored_agents)

    if [[ $idle_count -ge 3 ]]; then
        log "spawn trigger: アイドルyakuza ${idle_count}体 >= 3体(300秒以上)"
        return 0
    fi

    return 1
}

# ─── Yakuza Tengu: spawn実行（M-6: ロールバック付き・M-8: idle/thinking削除・M-9: #3a0025） ───
# instructions/yakuzatengu.md spawn_banner参照（バナーAA表示: respawn→banner→sleep→respawn→Opus）
spawn_yakuzatengu() {
    local _gryakuza_id="$1"  # unused: spawn selects idle yakuza independently

    # 二重spawn防止（M-1）
    is_yakuzatengu_active && { log "SKIP: yakuzatengu already active"; return 0; }

    # アイドルyakuzaNを選択（idle_elapsed最長の1体）
    # TODO(UNIFIED-MED-003): idle_start廃止後はcheck_agent_idle_v2()ベースに置き換え
    local orig_agent=""
    local max_idle=0
    local now; now=$(date +%s)
    while IFS= read -r yid; do
        [[ ! "$yid" =~ ^yakuza[0-9]+$ ]] && continue
        local idle_file="$STATE_DIR/njslyr_${yid}_idle_start"
        if [[ -f "$idle_file" ]]; then
            local idle_start; read -r idle_start < "$idle_file" 2>/dev/null || idle_start=0
            local idle_elapsed=$((now - idle_start))
            if [[ $idle_elapsed -gt $max_idle ]]; then
                max_idle=$idle_elapsed
                orig_agent="$yid"
            fi
        fi
    done < <(get_monitored_agents)

    if [[ -z "$orig_agent" ]]; then
        log "WARN: spawn_yakuzatengu: アイドルyakuzaN見つからず。spawn中止。"
        return 1
    fi

    local pane_target
    pane_target=$(get_pane_target "$orig_agent")
    if [[ -z "$pane_target" ]]; then
        log "ERROR: spawn_yakuzatengu: ${orig_agent} のpane見つからず。spawn中止。"
        return 1
    fi

    local orig_model
    orig_model=$(tmux show-options -pv -t "$pane_target" @model_name 2>/dev/null || echo "")
    [[ -z "$orig_model" ]] && orig_model="Sonnet"

    # BUG-T3 fix: 元のbg_colorを保存（rollback時に復元する）
    local orig_bg_color
    case "$orig_model" in
        Opus|opus|OPUS) orig_bg_color="#1a002e" ;;
        *) orig_bg_color="default" ;;
    esac

    log "spawn_yakuzatengu: ${orig_agent}(pane:${pane_target}, model:${orig_model}) → yakuzatengu"

    # M-5: STATEファイル書き込み（respawn-pane前に必ず完了）
    local spawn_time; spawn_time=$(date +%s)
    touch "$STATE_DIR/yakuzatengu_active"
    echo "$orig_agent" > "$STATE_DIR/yakuzatengu_original_agent_id"
    # BUG-T5 fix: pane_id（%N形式）を保存（pane_indexはペイン追加削除でズレる可能性あり）
    local orig_pane_id agents_win_spawn
    agents_win_spawn=$(get_agents_window)
    orig_pane_id=$([[ -n "$agents_win_spawn" ]] && tmux list-panes -t "multiagent:${agents_win_spawn}" -F '#{pane_index} #{pane_id} #{@agent_id}' 2>/dev/null | \
        awk -v id="$orig_agent" '$3 == id {print $2; exit}')
    echo "${orig_pane_id:-$pane_target}" > "$STATE_DIR/yakuzatengu_original_pane"
    echo "$orig_model" > "$STATE_DIR/yakuzatengu_original_model"
    echo "$spawn_time" > "$STATE_DIR/yakuzatengu_spawn_time"

    # M-8: spawn時にidle/thinkingファイル削除
    rm -f "$STATE_DIR/njslyr_${orig_agent}_thinking_start"
    rm -f "$STATE_DIR/njslyr_${orig_agent}_idle_start"  # TODO(UNIFIED-MED-003): idle_start廃止後は削除

    # S-3: 元yakuzaNタスクYAML statusをsuspendedに変更
    local task_yaml orig_task_status
    task_yaml=$(get_latest_task_yaml "$orig_agent")
    if [[ -n "$task_yaml" && -f "$task_yaml" ]]; then
        # BUG-T3 fix: 変更前のstatusを保存（rollback時に復元する）
        orig_task_status=$(awk '/^ *status:/{gsub(/['\''"]/, "", $2); print $2; exit}' "$task_yaml" 2>/dev/null); orig_task_status="${orig_task_status:-assigned}"
        sedi 's/^ *status: .*/  status: suspended/' "$task_yaml" 2>/dev/null || true
        log "spawn_yakuzatengu: ${orig_agent} タスクYAML statusをsuspendedに変更（元: ${orig_task_status}）"
    fi

    # remain-on-exit設定（恒久ルール）
    tmux set-option -p -t "$pane_target" remain-on-exit on 2>/dev/null || true

    # M-9: bg_color=#3a0025（ダークピンク）— バナー表示前に設定
    tmux select-pane -t "$pane_target" -P "bg=#3a0025" 2>/dev/null || true

    # バナー表示（instructions/yakuzatengu.md spawn_banner参照）
    # 演出: respawn-pane→バナー→sleep 3→respawn-pane→Opus起動（stage3_slay死亡演出と同パターン）
    tmux respawn-pane -k -t "$pane_target" \
        "bash -c 'printf \"\033[2J\033[H\n\n\n\033[1;37m\n  \
╔═══════════════════════════════════════════════╗\n  \
║                                               ║\n  \
║    ＜＜＜  YAKUZA TENGU ONLINE  ＞＞＞        ║\n  \
║                                               ║\n  \
║      神 々 の 使 者                           ║\n  \
║      ヤ ク ザ 天 狗  参 上                    ║\n  \
║                                               ║\n  \
║             ブッダエイメン                    ║\n  \
║                                               ║\n  \
║         「私を呼んだな。」                    ║\n  \
║                                               ║\n  \
╚═══════════════════════════════════════════════╝\n\n  \
◆ピンクの光が見える◆\033[0m\n\"; sleep 999999'" \
        2>/dev/null || true
    sleep 3

    # M-6: Sonnet起動（失敗時はSTATEロールバック）（仕様変更: Opus→Sonnet by gryakuza 2026-02-25）
    if ! tmux respawn-pane -k -t "$pane_target" \
        "claude --model claude-sonnet-4-6 --dangerously-skip-permissions" 2>/dev/null; then
        log "ERROR: spawn_yakuzatengu respawn-pane失敗。ロールバック。"
        # BUG-T3 fix: bg_color復元（Opusなら#1a002e、それ以外はdefault）
        tmux select-pane -t "$pane_target" -P "bg=${orig_bg_color}" 2>/dev/null || true
        # BUG-T3 fix: task YAML status復元（suspendedから元のstatusに戻す）
        if [[ -n "${task_yaml:-}" && -f "${task_yaml:-}" ]]; then
            sedi "s/^ *status: suspended/  status: ${orig_task_status:-assigned}/" "$task_yaml" 2>/dev/null || true
        fi
        rm -f "$STATE_DIR/yakuzatengu_active" \
              "$STATE_DIR/yakuzatengu_original_agent_id" \
              "$STATE_DIR/yakuzatengu_original_pane" \
              "$STATE_DIR/yakuzatengu_original_model" \
              "$STATE_DIR/yakuzatengu_spawn_time"
        return 1
    fi
    sleep 1

    # @agent_id設定: yakuzatengu
    tmux set-option -p -t "$pane_target" @agent_id "yakuzatengu" 2>/dev/null || true

    # @model_name設定（M-10: 正確なモデルID用途の記録）
    tmux set-option -p -t "$pane_target" @model_name "Sonnet" 2>/dev/null || true

    # 起床スリケン送信
    bash "$SCRIPT_DIR/inbox_write.sh" "yakuzatengu" \
        "ヤクザ天狗spawn完了。instructions/yakuzatengu.mdを読み、任務を開始せよ。" \
        task_assigned njslyr "" P0 2>/dev/null || true

    log "◆ヤクザ天狗召喚◆ ${orig_agent} → yakuzatengu(claude-sonnet-4-6, #3a0025)。押し売り参上！"
    return 0
}

# ─── Yakuza Tengu: despawn判定（M-2: 2サイクル確認+Guard時間+4時間上限） ───
should_despawn_yakuzatengu() {
    # Guard時間チェック: spawn後300秒未満はdespawn禁止（M-2）
    local spawn_time now elapsed
    read -r spawn_time < "$STATE_DIR/yakuzatengu_spawn_time" 2>/dev/null || spawn_time=0
    now=$(date +%s)
    elapsed=$((now - spawn_time))
    if [[ $elapsed -lt 300 ]]; then
        log "yakuzatengu guard: ${elapsed}秒 < 300秒。despawn保留。"
        return 1
    fi

    # 4時間上限: spawn後14400秒超過で強制despawn（M-2）
    if [[ $elapsed -ge 14400 ]]; then
        log "yakuzatengu 4時間上限超過。強制despawn。"
        return 0
    fi

    # 自己despawnシグナル: yakuzatengu_done存在時は即座despawn（M-2）
    if [[ -f "$STATE_DIR/yakuzatengu_done" ]]; then
        log "yakuzatengu自己despawnシグナル検知。"
        return 0
    fi

    # ヤマヒロ復帰判定
    local gryakuza_unread
    gryakuza_unread=$(get_inbox_unread_count "gryakuza")
    local gryakuza_thinking=false
    local pane
    pane=$(get_pane_target "gryakuza")
    if [[ -n "$pane" ]] && agent_is_thinking "$pane"; then
        gryakuza_thinking=true
    fi

    # 復帰条件: inbox未読<3 AND thinking解消
    if [[ $gryakuza_unread -lt 3 && "$gryakuza_thinking" == "false" ]]; then
        # 2サイクル確認（M-2）
        if [[ -f "$STATE_DIR/yakuzatengu_despawn_pending" ]]; then
            log "yakuzatengu despawn: 2サイクル目確認OK。despawn実行。"
            return 0
        else
            touch "$STATE_DIR/yakuzatengu_despawn_pending"
            log "yakuzatengu despawn: 1サイクル目。pending記録。次サイクルで再確認。"
            return 1
        fi
    else
        # 条件不充足 → pending削除（リセット）
        rm -f "$STATE_DIR/yakuzatengu_despawn_pending"
        return 1
    fi
}

# ─── Yakuza Tengu: despawn実行（M-6: respawn失敗時STATE保持） ───
despawn_yakuzatengu() {
    log "despawn_yakuzatengu: ヤクザ天狗帰還開始"

    # STATEファイル読み込み
    local orig_agent orig_pane orig_model
    read -r orig_agent < "$STATE_DIR/yakuzatengu_original_agent_id" 2>/dev/null || orig_agent=""
    read -r orig_pane < "$STATE_DIR/yakuzatengu_original_pane" 2>/dev/null || orig_pane=""
    read -r orig_model < "$STATE_DIR/yakuzatengu_original_model" 2>/dev/null || orig_model="Sonnet"

    if [[ -z "$orig_agent" || -z "$orig_pane" ]]; then
        log "ERROR: despawn_yakuzatengu: STATEファイル不完全。cleanup実行。"
        cleanup_yakuzatengu_state
        return 1
    fi

    # モデルとbg_colorを決定（M-10: 正確なモデルID）
    local model bg_color
    case "$orig_model" in
        Opus|opus|OPUS)
            model="claude-opus-4-6"
            bg_color="#1a002e"
            ;;
        *)
            model="claude-sonnet-4-6"
            bg_color="default"
            ;;
    esac

    log "despawn_yakuzatengu: yakuzatengu → ${orig_agent}(model:${model}, bg:${bg_color})"

    # remain-on-exit設定（恒久ルール）
    tmux set-option -p -t "$orig_pane" remain-on-exit on 2>/dev/null || true

    # M-6: respawn-pane: 元モデル復元（失敗時はSTATE保持・次サイクルで再試行）
    if ! tmux respawn-pane -k -t "$orig_pane" \
        "claude --model ${model} --dangerously-skip-permissions" 2>/dev/null; then
        log "ERROR: despawn respawn-pane失敗。STATE保持。次サイクルで再試行。"
        return 1
    fi
    sleep 1

    # @agent_id復元
    tmux set-option -p -t "$orig_pane" @agent_id "$orig_agent" 2>/dev/null || true

    # bg_color復元
    tmux select-pane -t "$orig_pane" -P "bg=${bg_color}" 2>/dev/null || true

    # @model_name復元
    tmux set-option -p -t "$orig_pane" @model_name "$orig_model" 2>/dev/null || true

    # M-7: STATEクリーンアップ（M-11: yakuzatenguのthinking/idle含む・clear_last含む）
    cleanup_yakuzatengu_state

    # 起床スリケン送信
    bash "$SCRIPT_DIR/inbox_write.sh" "$orig_agent" \
        "ヤクザ天狗despawn完了。Session Start手順を実行し、タスクYAMLを再読せよ。" \
        task_assigned njslyr "" P0 2>/dev/null || true

    log "◆ヤクザ天狗帰還◆ yakuzatengu → ${orig_agent}。任務完了、押し売り去る。"
    return 0
}

# ─── Main agent check logic ───
# ─── B-4: check_long_running_refresh ─────────────────────────────────────────
# 長期稼働リフレッシュ（UNIFIED-LOW-005/MED-006）
# 4時間に1回、staleなidle_startファイルを削除してSTATE_DIRを整理する
# idle_startのみを削除対象。stage_lastはB-2 check_stale_state()の責任。
# REFRESH_INTERVAL=14400 の根拠: 15分巡回サイクル * 16 = 4時間。
# 多日連続稼働時のSTATE_DIR肥大化を防ぎつつ、通常運用サイクルに干渉しない間隔。
check_long_running_refresh() {
    local now last_refresh elapsed
    now=$(date +%s)
    read -r last_refresh < "$STATE_DIR/njslyr_last_refresh" 2>/dev/null || last_refresh=0
    elapsed=$(( now - last_refresh ))

    if [[ $elapsed -ge $REFRESH_INTERVAL ]]; then
        log "INFO: 長期稼働リフレッシュ実行（${elapsed}秒経過）"
        # idle_startのみ削除（stage_lastはB-2の責任）
        find "$STATE_DIR" -name "njslyr_*_idle_start" -mmin +30 -delete 2>/dev/null || true
        echo "$now" > "$STATE_DIR/njslyr_last_refresh"
        log "INFO: リフレッシュ完了"
    fi
}

# ─── B-2: check_stale_state ───────────────────────────────────────────────────
# 健全性チェック: staleなタイムスタンプファイルを検知して削除する（UNIFIED-MED-004/MED-006参照）
# stage_last削除責任はcheck_stale_state()のみが持つ（B-4は削除しない）
# 制約: STALE_THRESHOLD >= STAGE3_COOLDOWN * 2 (3600 >= 1800*2) を維持すること
check_stale_state() {
    local agent_id="$1"
    local now
    now=$(date +%s)

    local state_file age ts
    for state_file in "$STATE_DIR/njslyr_${agent_id}_stage1_last" \
                      "$STATE_DIR/njslyr_${agent_id}_stage2_last" \
                      "$STATE_DIR/njslyr_${agent_id}_stage3_last"; do
        [[ ! -f "$state_file" ]] && continue
        read -r ts < "$state_file" 2>/dev/null || ts=0
        age=$(( now - ts ))
        if [[ $age -gt $STALE_THRESHOLD ]]; then
            log "WARN: stale state file detected: $state_file (age: ${age}s). Removing."
            rm -f "$state_file"
        fi
    done
}

# ─── B-1: check_agent_idle_v2 ─────────────────────────────────────────────────
# idle_start非依存のidle判定（UNIFIED-HIGH-004 + UNIFIED-MED-009連携）
# Returns 0 (idle) or 1 (not idle)
# 前提: A-2 chop() が $STATE_DIR/clear_last_${agent_id} を更新していること（UNIFIED-MED-009）
check_agent_idle_v2() {
    local agent_id="$1"

    # Step0: graceピリオドチェック（/clear直後180秒間はidle扱いしない）
    # clear_last_${agent_id} は A-2 chop() が echo "$(date +%s)" で更新する
    local clear_last grace_elapsed
    read -r clear_last < "$STATE_DIR/clear_last_${agent_id}" 2>/dev/null || clear_last=0
    grace_elapsed=$(( $(date +%s) - clear_last ))
    if [[ $grace_elapsed -lt 180 ]]; then
        return 1  # grace period: /clear直後はidle扱いしない
    fi

    # Step1: タスクYAMLでstatus確認
    local task_yaml task_status
    task_yaml=$(get_latest_task_yaml "$agent_id")
    if [[ -z "$task_yaml" ]]; then
        task_status="idle"
    else
        task_status=$(awk '/^ *status: /{sub(/.*status: */,""); sub(/ *$/,""); print; exit}' "$task_yaml" 2>/dev/null || true)
        task_status="${task_status:-idle}"
    fi

    # Step2: inbox unread確認（unreadがある場合はidle扱いしない）
    if has_inbox_unread "$agent_id"; then
        return 1  # not idle (has work to do)
    fi

    # Step3: pane出力確認（Working/Thinkingでないか）
    local pane_target
    pane_target=$(get_pane_target "$agent_id")
    if [[ -n "$pane_target" ]] && agent_is_busy "$pane_target"; then
        return 1  # not idle (actively working)
    fi

    [[ "$task_status" == "idle" ]]
}

# ─── Check inbox_watcher process health ───
check_inbox_watcher() {
    local agent_id="$1"
    # pgrep で watcher プロセスを確認
    if ! pgrep -f "inbox_watcher.sh.*${agent_id}" >/dev/null 2>&1; then
        log "WARN: inbox_watcher for ${agent_id} not found. Attempting restart..."
        # watcher_supervisor.sh が存在すれば、それ経由で再起動
        local supervisor="${SCRIPT_DIR}/watcher_supervisor.sh"
        if [[ -f "$supervisor" ]]; then
            bash "$supervisor" "$agent_id" &
            log "INFO: watcher_supervisor started for ${agent_id}"
        else
            log "ERROR: watcher_supervisor.sh not found. Manual restart required."
        fi
    fi
}

check_agent() {
    local agent_id="$1"

    # State file paths (BUG-4/5: declared once, used in thinking/idle blocks)
    local thinking_state_file="$STATE_DIR/njslyr_${agent_id}_thinking_start"
    # TODO(UNIFIED-MED-003/MED-010): idle_state_file is kept for safety during transition.
    # check_agent_idle_v2() no longer depends on this file. Remove after stabilization.
    local idle_state_file="$STATE_DIR/njslyr_${agent_id}_idle_start"

    # B-2: 健全性チェック（staleなタイムスタンプファイルを削除）
    check_stale_state "$agent_id"

    # Watcher health check
    check_inbox_watcher "$agent_id"

    # Get pane target
    local pane_target
    pane_target=$(get_pane_target "$agent_id")

    if [[ -z "$pane_target" ]]; then
        log "SKIP: ${agent_id} has no active pane"
        return 0
    fi

    # Cost optimization: Check inbox unread first (bash grep, no API)
    local has_unread=false
    if has_inbox_unread "$agent_id"; then
        has_unread=true
    fi

    # Get task status
    local task_status
    task_status=$(get_task_status "$agent_id")

    # BUG-5 fix: Clear idle tracking when agent has a task
    if [[ "$task_status" != "idle" ]]; then
        rm -f "$idle_state_file"
    fi

    # Check if agent is thinking
    local is_thinking=false
    if agent_is_thinking "$pane_target"; then
        is_thinking=true
    fi

    # ─── Detection logic ───

    # (0) Yakuza Tengu spawn check (BUG-SPAWN-1 fix: must run BEFORE thinking detection)
    # Reason: gryakuza is most likely thinking when inbox piles up (= when tengu is needed).
    # Previously at L1126, blocked by thinking early return. Moved here to ensure evaluation.
    if [[ "$agent_id" == "gryakuza" ]]; then
        if ! is_yakuzatengu_active; then
            if should_spawn_yakuzatengu "$agent_id"; then
                spawn_yakuzatengu "$agent_id"
            fi
        fi
    fi

    # (3) Thinking long time (highest priority)
    # Exception: thinking long time is checked even without inbox unread
    if [[ "$is_thinking" == "true" ]]; then
        # Check if long_running task
        if is_long_running_task "$agent_id"; then
            log "SKIP: ${agent_id} is thinking but has long_running:true flag"
            return 0
        fi

        # BUG-4 fix: Track thinking start time via state file
        if [[ ! -f "$thinking_state_file" ]]; then
            # First detection — record start time
            date +%s > "$thinking_state_file"
            log "INFO: ${agent_id} thinking開始を記録"
            return 0
        fi

        # Calculate elapsed thinking time
        local thinking_start
        read -r thinking_start < "$thinking_state_file" 2>/dev/null || thinking_start=0
        local now
        now=$(date +%s)
        local thinking_elapsed=$((now - thinking_start))

        if [[ $thinking_elapsed -ge $THINKING_TIMEOUT ]]; then
            log "[KARATE] ${agent_id} がThinking${thinking_elapsed}秒！THINKING_TIMEOUT(${THINKING_TIMEOUT}秒)超過！"
            rm -f "$thinking_state_file"

            # gryakuza / yakuzatengu are limited to Stage 1 only (m2 fix + S-5)
            if [[ "$agent_id" == "gryakuza" ]] || [[ "$agent_id" == "yakuzatengu" ]]; then
                stage1_suriken "$agent_id" "thinking超過（${thinking_elapsed}秒）"
                update_cooldown "$agent_id" "stage1"
                return 0
            fi

            # Other agents: escalate to Stage 2
            if check_cooldown "$agent_id" "stage2"; then
                stage2_chop "$agent_id" "thinking超過（${thinking_elapsed}秒）"
                update_cooldown "$agent_id" "stage2"
            else
                log "SKIP: ${agent_id} Stage 2 cooldown active (thinking超過)"
            fi
            return 0
        fi

        log "INFO: ${agent_id} thinking中（${thinking_elapsed}秒経過 / timeout: ${THINKING_TIMEOUT}秒）"
        return 0
    fi

    # BUG-4 fix: Clear thinking state if agent is no longer thinking
    if [[ -f "$thinking_state_file" ]]; then
        log "INFO: ${agent_id} thinking終了を検知。state file削除。"
        rm -f "$thinking_state_file"
    fi

    # Cost optimization filter: Skip if no inbox unread (unless thinking or idle)
    # BUG-5 fix: Allow idle agents to pass through even without inbox unread
    if [[ "$has_unread" == "false" && "$task_status" != "idle" ]]; then
        log "SKIP: ${agent_id} has no inbox unread (cost optimization)"
        return 0
    fi

    # m2 fix: gryakuza is limited to Stage 1 only (monitor_context.sh has priority)
    local gryakuza_stage1_only=false
    if [[ "$agent_id" == "gryakuza" ]]; then
        gryakuza_stage1_only=true
        # NOTE: spawn判定は(0)に移動済み（BUG-SPAWN-1 fix）。ここでは不要。
    fi

    # (2) スリケン無応答 (Stage 1 → Stage 2)
    # Check if we've sent Stage 1 スリケン before and it's been 2+ minutes
    local stage1_ts_file="$STATE_DIR/njslyr_${agent_id}_stage1_last"
    if [[ -f "$stage1_ts_file" ]]; then
        local stage1_ts
        read -r stage1_ts < "$stage1_ts_file" 2>/dev/null || stage1_ts=0
        local now
        now=$(date +%s)
        local elapsed=$((now - stage1_ts))

        # Check if inbox is still unread after 2 minutes
        if [[ $elapsed -ge $NUDGE_NO_RESPONSE ]] && [[ "$has_unread" == "true" ]]; then
            # m2 fix: Skip Stage 2 for gryakuza (spawn already handled above)
            if [[ "$gryakuza_stage1_only" == "true" ]]; then
                log "SKIP: ${agent_id} is limited to Stage 1 (monitor_context.sh priority)"
                return 0
            fi
            # S-5: yakuzatengu is Stage 1 only (don't apply Stage 2 to the tengu)
            if [[ "$agent_id" == "yakuzatengu" ]]; then
                log "SKIP: yakuzatengu is Stage 1 only"
                return 0
            fi

            # スリケン無応答 → Stage 2
            if check_cooldown "$agent_id" "stage2"; then
                stage2_chop "$agent_id" "スリケン無応答（${elapsed}秒経過）"
                update_cooldown "$agent_id" "stage2"
                rm -f "$stage1_ts_file"  # Stage 1タイムスタンプ削除（Stage 2→3エスカレーションを有効化）
                return 0
            else
                log "SKIP: ${agent_id} Stage 2 cooldown active"
                return 0
            fi
        fi
    fi

    # M2 fix: Stage 2 → Stage 3 escalation
    # Check if we've sent Stage 2 /clear before and it's been 2+ minutes
    local stage2_ts_file="$STATE_DIR/njslyr_${agent_id}_stage2_last"
    if [[ -f "$stage2_ts_file" ]]; then
        local stage2_ts
        read -r stage2_ts < "$stage2_ts_file" 2>/dev/null || stage2_ts=0
        local now
        now=$(date +%s)
        local elapsed=$((now - stage2_ts))

        # Check if inbox is still unread after 2 minutes AND /clear had no effect
        if [[ $elapsed -ge $NUDGE_NO_RESPONSE ]] && [[ "$has_unread" == "true" ]]; then
            # m2 fix: Skip Stage 3 for gryakuza / S-5: yakuzatengu Stage 1 only
            if [[ "$gryakuza_stage1_only" == "true" ]] || [[ "$agent_id" == "yakuzatengu" ]]; then
                log "SKIP: ${agent_id} is limited to Stage 1 (monitor_context.sh priority)"
                return 0
            fi

            # /clear no response → Stage 3
            if check_cooldown "$agent_id" "stage3"; then
                # m1 fix: Return stage3_slay exit code for slain_count tracking
                if stage3_slay "$agent_id" "/clear無応答（${elapsed}秒経過）" "$pane_target"; then
                    update_cooldown "$agent_id" "stage3"
                    # Clear stage1/stage2 timestamps after Stage 3 execution
                    rm -f "$stage1_ts_file" "$stage2_ts_file"
                    return 1  # Slain
                else
                    return 0  # Failed (e.g., restart loop detected)
                fi
            else
                log "SKIP: ${agent_id} Stage 3 cooldown active"
                return 0
            fi
        fi
    fi

    # (1) Idle timeout
    # B-1: check_agent_idle_v2() でidle判定（idle_start非依存・graceピリオド付き）
    # graceピリオド/inbox unread/pane busyを総合判断してアイドル状態を返す（UNIFIED-HIGH-004）
    if check_agent_idle_v2 "$agent_id"; then
        local now
        now=$(date +%s)

        if [[ ! -f "$idle_state_file" ]]; then
            # First idle detection: record start time
            echo "$now" > "$idle_state_file"
            log "INFO: ${agent_id} is idle — tracking started"
            return 0
        fi

        local idle_start
        read -r idle_start < "$idle_state_file" 2>/dev/null || idle_start=0
        local idle_elapsed=$((now - idle_start))

        if [[ $idle_elapsed -ge $IDLE_TIMEOUT ]]; then
            # Idle too long → Stage 1 suriken
            # Note: idle suriken送信後は通常のスリケン無応答エスカレーション
            # (Stage 1→2→3) が引き継ぐ。inbox_write.shでinboxに書き込まれた
            # surikenが未読となり、次サイクルからhas_unread=trueで通常フローに移行。
            stage1_suriken "$agent_id" "アイドル超過（${idle_elapsed}秒）"
            update_cooldown "$agent_id" "stage1"
            # Reset idle timer (next suriken after another IDLE_TIMEOUT)
            echo "$now" > "$idle_state_file"
        else
            log "INFO: ${agent_id} is idle (${idle_elapsed}s / ${IDLE_TIMEOUT}s threshold)"
        fi
        return 0
    fi

    # Default: Send Stage 1 スリケン if inbox unread
    if [[ "$has_unread" == "true" ]]; then
        # Check if inbox_watcher already sent /clear recently
        if inbox_watcher_recently_cleared "$agent_id"; then
            log "SKIP: ${agent_id} already handled by inbox_watcher (recent /clear)"
            return 0
        fi

        # Check if agent is busy (don't interrupt Working)
        if agent_is_busy "$pane_target"; then
            log "SKIP: ${agent_id} is busy (Working/Thinking)"
            return 0
        fi

        # Send Stage 1 スリケン
        stage1_suriken "$agent_id" "inbox未読あり"
        update_cooldown "$agent_id" "stage1"
        return 0
    fi

    # No action needed
    log "INFO: ${agent_id} is healthy"
    return 0
}

# ─── Main execution ───
main() {
    show_startup_banner

    local slain_count=0
    local healthy_count=0

    # B-4: 長期稼働リフレッシュチェック（各ループ開始時）
    check_long_running_refresh

    # @agent_id誤設定検証（darkninja IDがmultiagentペインに混入していないか確認）
    validate_agent_ids || true

    # Get all monitored agents
    local agents
    agents=$(get_monitored_agents)

    if [[ -z "$agents" ]]; then
        log "No agents to monitor. Exiting."
        return 0
    fi

    log "◆巡回対象◆ $(echo "$agents" | tr '\n' ' ')…ニンジャの目は逃さぬ"

    # Display patrol targets with header box (mirrors yokubari.sh agent deployment)
    echo -e "\033[1;31m  ┌─────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;31m  │\033[0m  \033[1;33m◆巡回開始◆\033[0m \033[0;37mオヒルネ・ニンジャを狩る。逃げ場はない。\033[0m        \033[1;31m│\033[0m"
    echo -e "\033[1;31m  └─────────────────────────────────────────────────────────────────┘\033[0m"
    echo ""

    # Check each agent
    local agent_num=0

    while IFS= read -r agent_id; do
        [[ -z "$agent_id" ]] && continue
        agent_num=$((agent_num + 1))

        echo -ne "  \033[1;36m  ⚔\033[0m \033[1;37m${agent_id}\033[0m \033[0;37m─────────\033[0m "
        if check_agent "$agent_id"; then
            healthy_count=$((healthy_count + 1))
            echo -e "\033[1;32m◆健全◆ カラテが足りている\033[0m"
        else
            slain_count=$((slain_count + 1))
            echo -e "\033[1;31m☠ 爆発四散！サヨナラ！ニンジャソウル消滅！\033[0m"
        fi
    done <<< "$agents"

    # yakuzatengu despawnチェック（M-3: main()ループ内、check_agent()ループ後）
    if is_yakuzatengu_active; then
        if should_despawn_yakuzatengu; then
            despawn_yakuzatengu
        fi
    fi

    echo ""

    show_completion_banner "$slain_count" "$healthy_count"

    log "◆実際完了◆ 爆発四散: ${slain_count}体 / 健全: ${healthy_count}体。ニンジャスレイヤーは闇に消えた。"
    echo -e "\033[0;37m  ◆実際完了◆ ニンジャスレイヤーは電脳空間の闇に溶けた。ナムアミダブツ。\033[0m"
}

# ─── Entry point ───
# Skip main execution if in testing mode (for bats tests)
if [[ -z "${__NJSLYR_TESTING__:-}" ]]; then
    if [[ "$MODE" == "continuous" ]]; then
        log "◆常駐監視モード起動◆ 15分間隔で巡回する。ニンジャは決して眠らぬ。"
        while true; do
            main
            log "◆潜伏◆ 15分間…闇に潜む。"
            sleep 900  # 15 minutes
        done
    else
        # Single execution mode (default)
        main
    fi
fi
