#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# njslyr.sh — オヒルネエージェント粛清デーモン（Ninja Slayer）
# ニンジャスレイヤー: アイドル/無応答/長時間thinkingのエージェントを自動検知・粛清
#
# Design: docs/njslyr_design.md
# Phase: 2 (Implementation)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ───
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
DASHBOARD="$PROJECT_ROOT/dashboard.md"
LOG_DIR="$PROJECT_ROOT/queue/logs"
METRICS_DIR="$PROJECT_ROOT/queue/metrics"
STATE_DIR="$PROJECT_ROOT/.state"

mkdir -p "$LOG_DIR" "$METRICS_DIR" "$STATE_DIR"

# ─── Thresholds (seconds) ───
IDLE_TIMEOUT=300           # 5 minutes idle without task
NUDGE_NO_RESPONSE=120      # 2 minutes after nudge
THINKING_TIMEOUT=600       # 10 minutes thinking
STAGE3_COOLDOWN=1800       # 30 minutes cooldown for Stage 3
RESTART_LOOP_WINDOW=1800   # 30 minutes window for restart loop detection
RESTART_LOOP_MAX=3         # Max 3 restarts in 30 min

# ─── Session mode (default: once) ───
# "once" = single execution (for cron/tmux timer)
# "continuous" = infinite loop with 15-minute sleep (for daemon mode)
MODE="${1:-once}"

# ─── Startup banner ───
show_startup_banner() {
    cat << 'EOF'

◆◆◆ SHUTDOWN ◆◆◆  電脳空間切断開始  ◆◆◆ SHUTDOWN ◆◆◆

卍 ネオサイタマ電脳IRCコトダマ空間から切断中...
  ✗ #マッポーの世 チャネル離脱
  ✗ サイバーパンクプロトコル解除
  ✗ UNIXニューロン認証解除
  サヨナラ！切断処理を開始する。

EOF
}

# ─── Completion banner ───
show_completion_banner() {
    local slain_count="$1"
    local healthy_count="$2"
    cat << EOF

◆粛清完了: ${slain_count}体処理 / ${healthy_count}体健全◆

  ✓ ニンジャソウル消滅完了
  ✓ 全エージェント停止完了
  ✓ 電脳IRC切断完了

サヨナラ！ニンジャスレイヤーは闇に消えた。

EOF
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
            temp_file=$(mktemp)
            awk -v msg="$message" '
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
            ' "$DASHBOARD" > "$temp_file" && mv "$temp_file" "$DASHBOARD"
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
#   inject_barikidorink "multiagent:0.1"   # yakuza1にOpus投与
#   detox_barikidorink "multiagent:0.1"    # yakuza1をSonnetに復帰
inject_barikidorink() {
    local pane=$1
    tmux send-keys -t "$pane" "/model opus" Enter
    sleep 0.5
    tmux set-option -p -t "$pane" @model_name "Opus"
    tmux select-pane -t "$pane" -P 'bg=#1a002e'
    sleep 0.3
    tmux send-keys -t "$pane" "/clear" Enter
}

detox_barikidorink() {
    local pane=$1
    tmux send-keys -t "$pane" "/model sonnet" Enter
    sleep 0.5
    tmux set-option -p -t "$pane" @model_name "Sonnet"
    tmux select-pane -t "$pane" -P 'bg=default'
    sleep 0.3
    tmux send-keys -t "$pane" "/clear" Enter
}

# ─── Get all monitored agents ───
get_monitored_agents() {
    # Dynamically detect agents from yokubari.sh process list
    # Exclude darkninja (human agent)
    tmux list-panes -t multiagent -F '#{@agent_id}' 2>/dev/null | \
        grep -v '^$' | \
        grep -v '^darkninja$' | \
        sort -u || true
}

# ─── Check inbox unread ───
has_inbox_unread() {
    local agent_id="$1"
    local inbox="$PROJECT_ROOT/queue/inbox/${agent_id}.yaml"

    [[ -f "$inbox" ]] && grep -q '^ *read: false$' "$inbox"
}

# ─── Check task YAML status ───
get_task_status() {
    local agent_id="$1"
    # M1 fix: Use glob pattern to match _subtask_xxx.yaml files
    local task_yaml
    task_yaml=$(ls -t "$PROJECT_ROOT/queue/tasks/${agent_id}"*.yaml 2>/dev/null | head -1)

    if [[ -z "$task_yaml" || ! -f "$task_yaml" ]]; then
        echo "idle"
        return 0
    fi

    # Extract status field from YAML (simple grep approach)
    local status
    status=$(grep '^ *status: ' "$task_yaml" | head -1 | sed 's/.*status: *//;s/ *$//' || echo "idle")
    echo "$status"
}

# ─── Get pane target for agent ───
get_pane_target() {
    local agent_id="$1"
    # Find pane with matching @agent_id
    tmux list-panes -t multiagent -F '#{pane_index} #{@agent_id}' 2>/dev/null | \
        awk -v id="$agent_id" '$2 == id {print "multiagent:1." $1; exit}'
}

# ─── Agent busy detection (from inbox_watcher.sh pattern) ───
agent_is_busy() {
    local pane_target="$1"
    local pane_tail

    pane_tail=$(timeout 1 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -5 || echo "")

    # Check for busy markers
    if echo "$pane_tail" | grep -qiE '(Working|Thinking|Planning|Sending|思考中|考え中|計画中|送信中|処理中|実行中|esc to interrupt)'; then
        return 0  # busy
    fi

    return 1  # idle
}

# ─── Thinking detection ───
agent_is_thinking() {
    local pane_target="$1"
    local pane_content

    pane_content=$(timeout 1 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -10 || echo "")

    # Check for thinking markers
    if echo "$pane_content" | grep -qiE '(Thinking|思考中|Planning|考え中|計画中)'; then
        return 0  # thinking
    fi

    return 1  # not thinking
}

# ─── Check if long_running task ───
is_long_running_task() {
    local agent_id="$1"
    local task_yaml
    task_yaml=$(ls -t "$PROJECT_ROOT/queue/tasks/${agent_id}"*.yaml 2>/dev/null | head -1)

    [[ -n "$task_yaml" && -f "$task_yaml" ]] && grep -q '^ *long_running: *true' "$task_yaml"
}

# ─── Check inbox_watcher recent /clear ───
inbox_watcher_recently_cleared() {
    local agent_id="$1"
    local state_file="$METRICS_DIR/inbox_watcher_state_${agent_id}.yaml"

    [[ ! -f "$state_file" ]] && return 1

    local last_clear_ts
    last_clear_ts=$(grep 'LAST_CLEAR_TS:' "$state_file" 2>/dev/null | sed 's/.*: *//' || echo "0")

    local now
    now=$(date +%s)

    # If inbox_watcher sent /clear within last 5 minutes, skip
    [[ $((now - last_clear_ts)) -lt 300 ]]
}

# ─── Restart counter ───
get_restart_count() {
    local agent_id="$1"
    local restart_file="$METRICS_DIR/njslyr_restarts_${agent_id}.yaml"

    [[ ! -f "$restart_file" ]] && echo "0" && return 0

    local count
    count=$(grep 'count:' "$restart_file" 2>/dev/null | sed 's/.*: *//' || echo "0")
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

    local count
    local last_restart
    count=$(grep 'count:' "$restart_file" 2>/dev/null | sed 's/.*: *//' || echo "0")
    last_restart=$(grep 'last_restart:' "$restart_file" 2>/dev/null | sed 's/.*: *"//;s/".*//' || echo "1970-01-01T00:00:00")

    # Convert timestamp to epoch
    local last_restart_epoch
    last_restart_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$last_restart" '+%s' 2>/dev/null || echo "0")

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

    log "[KARATE] ${agent_id} に [スリケン] を投げた！理由: ${reason}"

    local message="🔪 ニンジャスレイヤーのスリケン！inbox確認せよ。理由: ${reason}"
    bash "$SCRIPT_DIR/inbox_write.sh" "$agent_id" "$message" njslyr njslyr "" P1 2>/dev/null || true

    log_execution "$agent_id" "Stage 1 (スリケン)" "success" "$reason"

    return 0
}

# ─── Stage 2: Chop (/clear) ───
stage2_chop() {
    local agent_id="$1"
    local reason="$2"

    log "[KARATE] ${agent_id} に [チョップ] を放つ！理由: ${reason}"

    local message="🥋 ニンジャスレイヤーのカラテ・チョップ！セッションリセットする。理由: ${reason}"
    bash "$SCRIPT_DIR/inbox_write.sh" "$agent_id" "$message" clear_command njslyr "" P0 2>/dev/null || true

    # M2 fix: Record stage2 timestamp for escalation to stage3
    local stage2_ts_file="$STATE_DIR/njslyr_${agent_id}_stage2_last"
    date +%s > "$stage2_ts_file"

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

    log "[SLAY] ツヨイ・カラテ！${agent_id} を粛清する！理由: ${reason}"

    # Check restart loop
    if check_restart_loop "$agent_id"; then
        log "ERROR: Restart loop detected for ${agent_id}. Stopping auto-slay."
        update_dashboard "🚨 エージェント異常停止: ${agent_id} が30分以内に3回再起動。手動介入が必要。"
        notify_darkninja "🚨 エージェント異常停止: ${agent_id} が再起動ループに陥りました。手動介入が必要です。" P0
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
    pre_slay_task_yaml=$(ls -t "$PROJECT_ROOT/queue/tasks/${agent_id}"*.yaml 2>/dev/null | head -1)
    local current_task_id="unknown"
    if [[ -n "$pre_slay_task_yaml" && -f "$pre_slay_task_yaml" ]]; then
        current_task_id=$(grep '^ *task_id: ' "$pre_slay_task_yaml" | head -1 | sed 's/.*task_id: *//;s/[" ]*$//' || echo "unknown")
        log "Data preservation: タスクYAML状態更新 (${pre_slay_task_yaml})..."
        sed -i '' 's/^ *status: .*/  status: slayed_by_njslyr/' "$pre_slay_task_yaml" 2>/dev/null || true
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
    sleep 3

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

    # Step 4: Determine model based on agent_type (C3 fix)
    local model
    if [[ "$agent_id" == "soukaiya" ]]; then
        model="opus"
    else
        model="sonnet"
    fi

    # Step 5: Restart agent using respawn-pane (M3 fix - preserves grid layout)
    log "Restarting ${agent_id} (type: ${agent_type}, model: ${model})..."
    sleep 1
    tmux respawn-pane -k -t "$pane_target" "claude --model ${model} --dangerously-skip-permissions" 2>/dev/null || true
    sleep 2

    # Step 6: Reset pane background and remain-on-exit
    tmux select-pane -t "$pane_target" -P 'bg=default' 2>/dev/null || true
    tmux set-option -p -t "$pane_target" remain-on-exit off 2>/dev/null || true

    # Step 7: Increment restart counter
    increment_restart_count "$agent_id"

    log "復帰完了: ${agent_id} を再起動しました。"
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
    last_ts=$(cat "$cooldown_file")

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

# ─── Main agent check logic ───
check_agent() {
    local agent_id="$1"

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

    # Check if agent is thinking
    local is_thinking=false
    if agent_is_thinking "$pane_target"; then
        is_thinking=true
    fi

    # ─── Detection logic ───

    # (3) Thinking long time (highest priority)
    # Exception: thinking long time is checked even without inbox unread
    if [[ "$is_thinking" == "true" ]]; then
        # Check if long_running task
        if is_long_running_task "$agent_id"; then
            log "SKIP: ${agent_id} is thinking but has long_running:true flag"
            return 0
        fi

        # TODO: Track thinking start time (requires state file)
        # For now, we skip thinking detection in Phase 2
        # Will be implemented in Phase 2.1 with state tracking
        log "INFO: ${agent_id} is thinking (tracking not yet implemented)"
        return 0
    fi

    # Cost optimization filter: Skip if no inbox unread (unless thinking)
    if [[ "$has_unread" == "false" ]]; then
        log "SKIP: ${agent_id} has no inbox unread (cost optimization)"
        return 0
    fi

    # m2 fix: gryakuza is limited to Stage 1 only (monitor_context.sh has priority)
    local gryakuza_stage1_only=false
    if [[ "$agent_id" == "gryakuza" ]]; then
        gryakuza_stage1_only=true
    fi

    # (2) スリケン無応答 (Stage 1 → Stage 2)
    # Check if we've sent Stage 1 スリケン before and it's been 2+ minutes
    local stage1_ts_file="$STATE_DIR/njslyr_${agent_id}_stage1_last"
    if [[ -f "$stage1_ts_file" ]]; then
        local stage1_ts
        stage1_ts=$(cat "$stage1_ts_file")
        local now
        now=$(date +%s)
        local elapsed=$((now - stage1_ts))

        # Check if inbox is still unread after 2 minutes
        if [[ $elapsed -ge $NUDGE_NO_RESPONSE ]] && [[ "$has_unread" == "true" ]]; then
            # m2 fix: Skip Stage 2 for gryakuza
            if [[ "$gryakuza_stage1_only" == "true" ]]; then
                log "SKIP: ${agent_id} is limited to Stage 1 (monitor_context.sh priority)"
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
        stage2_ts=$(cat "$stage2_ts_file")
        local now
        now=$(date +%s)
        local elapsed=$((now - stage2_ts))

        # Check if inbox is still unread after 2 minutes AND /clear had no effect
        if [[ $elapsed -ge $NUDGE_NO_RESPONSE ]] && [[ "$has_unread" == "true" ]]; then
            # m2 fix: Skip Stage 3 for gryakuza
            if [[ "$gryakuza_stage1_only" == "true" ]]; then
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
    # Check if agent has no task and has been idle for 5+ minutes
    if [[ "$task_status" == "idle" ]]; then
        # TODO: Track idle start time (requires state file)
        # For now, we skip idle detection in Phase 2
        # Will be implemented in Phase 2.1 with state tracking
        log "INFO: ${agent_id} is idle (tracking not yet implemented)"
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

    # Get all monitored agents
    local agents
    agents=$(get_monitored_agents)

    if [[ -z "$agents" ]]; then
        log "No agents to monitor. Exiting."
        return 0
    fi

    log "Monitoring agents: $(echo "$agents" | tr '\n' ' ')"

    # Check each agent
    while IFS= read -r agent_id; do
        [[ -z "$agent_id" ]] && continue

        # Special handling: darkninja is excluded
        if [[ "$agent_id" == "darkninja" ]]; then
            log "SKIP: darkninja (human agent, excluded from purge)"
            continue
        fi

        # Special handling: gryakuza is limited to Stage 1 only
        if [[ "$agent_id" == "gryakuza" ]]; then
            log "INFO: ${agent_id} (monitor_context.sh priority, njslyr=Stage 1 only)"
            # TODO: Implement gryakuza-specific logic (Stage 1 only)
            # For Phase 2, we apply same logic but Stage 2/3 are skipped in check_agent
        fi

        check_agent "$agent_id" && healthy_count=$((healthy_count + 1)) || slain_count=$((slain_count + 1))
    done <<< "$agents"

    show_completion_banner "$slain_count" "$healthy_count"

    log "Execution complete. Slain: $slain_count, Healthy: $healthy_count"
}

# ─── Entry point ───
# Skip main execution if in testing mode (for bats tests)
if [[ -z "${__NJSLYR_TESTING__:-}" ]]; then
    if [[ "$MODE" == "continuous" ]]; then
        log "Starting continuous monitoring mode (15-minute intervals)"
        while true; do
            main
            log "Sleeping for 15 minutes..."
            sleep 900  # 15 minutes
        done
    else
        # Single execution mode (default)
        main
    fi
fi
