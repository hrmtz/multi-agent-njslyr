#!/bin/bash
set -euo pipefail

# macOS (Darwin): GNU coreutils + util-linux (flock) via Homebrew
if [[ "$(uname -s)" == "Darwin" ]]; then
    _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
    export PATH="${_HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
fi

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

PROJECT_ROOT="$SCRIPT_DIR"
STATE_DIR="$PROJECT_ROOT/.state"
RESCAN_FILE="$STATE_DIR/rescan_watchers"
RESTART_LOG="${RESTART_LOG:-$STATE_DIR/watcher_restart.log}"

# NTFY-004: heartbeat watchdog設定
HEARTBEAT_TIMEOUT=180  # 3分間heartbeat受信なしでntfy_listener再起動
NTFY_LISTENER_HEARTBEAT="$PROJECT_ROOT/logs/ntfy_listener_last_heartbeat.txt"
NTFY_LISTENER_LOG="$PROJECT_ROOT/logs/ntfy_listener.log"

# KYOTO-MONITOR: Kyoto SSH heartbeat監視 + 緊急縮退モード（NeoSaitamaのみ）
KYOTO_HEARTBEAT_TIMEOUT=180   # 3分間SSH応答なし→障害確定（3サイクル×60s）
KYOTO_ALERT_TIMEOUT=1800      # 30分間ラオモト応答なし→emergency_degraded移行
KYOTO_CHECK_INTERVAL=60       # SSH疎通確認間隔（秒）
KYOTO_LAST_SEEN="$STATE_DIR/kyoto_last_seen"
KYOTO_NEXT_CHECK="$STATE_DIR/kyoto_next_check"
KYOTO_ALERT_SENT="$STATE_DIR/kyoto_alert_sent_at"
KYOTO_PRE_EMERGENCY="$STATE_DIR/kyoto_pre_emergency_mode"

mkdir -p logs queue/inbox "$STATE_DIR"

# Per-agent backoff state: consecutive restart count and next-allowed-restart timestamp
declare -A RESTART_COUNT
declare -A BACKOFF_UNTIL

# Return backoff wait seconds based on consecutive restart count.
# Schedule: 1st→5s, 2nd→10s, 3rd→30s, 4th+→60s (cap)
backoff_seconds() {
    local count="$1"
    if   (( count <= 1 )); then echo 5
    elif (( count == 2 )); then echo 10
    elif (( count == 3 )); then echo 30
    else                        echo 60
    fi
}

# Append a restart event to RESTART_LOG.
# Format: <ISO8601> agent=<name> attempt=<n>
log_restart() {
    local agent="$1" count="$2"
    printf '%s agent=%s attempt=%d\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$agent" "$count" >> "$RESTART_LOG"
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

# Check if a pane with session:window.index format exists.
# Used only for darkninja (fixed session target).
pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

# For darkninja only: static session target (darkninja:main.0).
# Kept separate because darkninja runs in a dedicated session, not multiagent:agents.
start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    # FIX-024: Use [%] anchor to avoid partial match (yakuza1 matching yakuza10 etc.)
    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        # Running: reset consecutive restart count on stable recovery
        RESTART_COUNT[$agent]=0
        return 0
    fi

    # Not running: check backoff window
    local now
    now=${EPOCHSECONDS:-$(date +%s)}
    local backoff_until=${BACKOFF_UNTIL[$agent]:-0}
    if (( now < backoff_until )); then
        return 0
    fi

    # Restart with backoff tracking
    local count delay
    count=$(( ${RESTART_COUNT[$agent]:-0} + 1 ))
    RESTART_COUNT[$agent]=$count
    log_restart "$agent" "$count"
    delay=$(backoff_seconds "$count")
    BACKOFF_UNTIL[$agent]=$(( now + delay ))

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null); cli=${cli:-claude}
    # FIX-021: Stagger restarts to prevent thundering herd fork exhaustion
    sleep $(( RANDOM % 2 ))
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
    echo "[watcher_supervisor] started inbox_watcher for $agent (attempt=${count}, next_backoff=${delay}s)"
}

# For all agents except darkninja: dynamically resolve pane_id from @agent_id.
# UNIFIED-MED-005: pgrep uses [%] to match %pane_id format (avoids trailing-space ambiguity).
# C-ISSUE-1: pane_exists() is not used here; empty pane_id check replaces it.
# pane_map: cached output of "tmux list-panes -a -F '#{@agent_id} #{pane_id}'" (passed from scan_all_agents)
start_watcher_for_agent() {
    local agent="$1"
    local log_file="$2"
    local pane_map="$3"

    ensure_inbox_file "$agent"

    # Dynamic pane lookup by @agent_id (uses caller-cached tmux output — no extra fork)
    local pane_id
    pane_id=$(awk -v id="$agent" '$1 == id {print $2; exit}' <<< "$pane_map")

    if [[ -z "$pane_id" ]]; then
        # Pane not found: skip (expected after yakuzatengu despawn or pane not yet spawned)
        return 0
    fi

    # UNIFIED-MED-005: [%] matches the literal % prefix of pane_id (e.g. %42)
    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        # Running: reset consecutive restart count on stable recovery
        RESTART_COUNT[$agent]=0
        return 0
    fi

    # Not running: check backoff window
    local now
    now=${EPOCHSECONDS:-$(date +%s)}
    local backoff_until=${BACKOFF_UNTIL[$agent]:-0}
    if (( now < backoff_until )); then
        return 0
    fi

    # Restart with backoff tracking
    local count delay
    count=$(( ${RESTART_COUNT[$agent]:-0} + 1 ))
    RESTART_COUNT[$agent]=$count
    log_restart "$agent" "$count"
    delay=$(backoff_seconds "$count")
    BACKOFF_UNTIL[$agent]=$(( now + delay ))

    local cli
    cli=$(tmux show-options -p -t "$pane_id" -v @agent_cli 2>/dev/null); cli=${cli:-claude}
    # FIX-021: Stagger restarts to prevent thundering herd fork exhaustion
    sleep $(( RANDOM % 2 ))
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane_id" "$cli" >> "$log_file" 2>&1 &
    echo "[watcher_supervisor] started inbox_watcher for $agent → $pane_id (attempt=${count}, next_backoff=${delay}s)"
}

# Scan all agents and ensure their inbox_watchers are running.
# Called from main loop (periodic) and on RESCAN_FILE signal (immediate).
scan_all_agents() {
    # FIX-005: darkninja — correct session target (main:darkninja, not darkninja:main)
    # neosaitama does not have darkninja, so skip based on machine role
    local _machine_role
    _machine_role=$(awk '/^  role:/ {print $2; exit}' "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null)
    _machine_role="${_machine_role:-kyoto}"
    case "$_machine_role" in mbp) _machine_role="neosaitama" ;; ryzen) _machine_role="kyoto" ;; esac
    if [[ "$_machine_role" == "kyoto" ]]; then
        start_watcher_if_missing "darkninja" "main:darkninja.0" "logs/inbox_watcher_darkninja.log"
    fi

    # Cache full pane map once to avoid N tmux calls per agent (N+1 → 1).
    local pane_map
    pane_map=$(tmux list-panes -a -F '#{@agent_id} #{pane_id}' 2>/dev/null) || true

    # FIX-004: Dynamic agents window name (agents on kyoto, neosaitama on neosaitama)
    local _agents_window
    _agents_window=$(tmux list-windows -t multiagent -F '#{window_name}' 2>/dev/null \
        | grep -E '^(agents|neosaitama|kyoto)$' | head -1 || true)
    _agents_window="${_agents_window:-agents}"

    # All agents in multiagent:{agents_window}: detect dynamically by @agent_id.
    # Handles yakuzatengu spawn/despawn transparently.
    # awk replaces grep -v '^$' | sort -u (one process instead of two).
    while IFS= read -r agent; do
        [[ -z "$agent" || "$agent" == "darkninja" ]] && continue
        start_watcher_for_agent "$agent" "logs/inbox_watcher_${agent}.log" "$pane_map"
    done < <(tmux list-panes -t "multiagent:${_agents_window}" -F '#{@agent_id}' 2>/dev/null \
        | awk 'NF && !seen[$0]++' || true)
}

# NTFY-004: heartbeat watchdog — ntfy_listenerのサイレントドロップを検出して再起動
# logs/ntfy_listener_last_heartbeat.txt に記録された最終受信epochと現在時刻を比較する。
# HEARTBEAT_TIMEOUT秒以上経過していた場合、ntfy_listenerをkillして再起動する。
check_heartbeat_watchdog() {
    # heartbeat timestampファイルが存在しない場合はスキップ（ntfy_listener未起動）
    [[ ! -f "$NTFY_LISTENER_HEARTBEAT" ]] && return 0

    local last_hb now elapsed
    last_hb=$(cat "$NTFY_LISTENER_HEARTBEAT" 2>/dev/null)
    # 不正な値の場合はスキップ
    [[ ! "$last_hb" =~ ^[0-9]+$ ]] && return 0

    now=${EPOCHSECONDS:-$(date +%s)}
    elapsed=$(( now - last_hb ))

    if (( elapsed >= HEARTBEAT_TIMEOUT )); then
        echo "[watcher_supervisor] NTFY-004 watchdog: heartbeat stale (${elapsed}s >= ${HEARTBEAT_TIMEOUT}s). Restarting ntfy_listener..." >&2

        # Step 1: graceful stop signal (.state/ntfy_listener_stop ファイルベース)
        touch "$STATE_DIR/ntfy_listener_stop"
        sleep 5

        # Step 2: graceful stopで終了しなかった場合のみ force kill
        # D006 exception: watcher_supervisor is infrastructure layer,
        # kill target is monitored process (ntfy_listener), not an agent.
        # This is a supervisor→monitored-process restart, not agent termination.
        local ntfy_pid
        ntfy_pid=$(pgrep -f "scripts/ntfy_listener.sh" 2>/dev/null | head -1)
        if [[ -n "$ntfy_pid" ]]; then
            kill "$ntfy_pid" 2>/dev/null || true
            sleep 1
        fi

        # stop signal cleanup
        rm -f "$STATE_DIR/ntfy_listener_stop"

        # ntfy_listener 再起動
        mkdir -p "$(dirname "$NTFY_LISTENER_LOG")"
        nohup bash "$PROJECT_ROOT/scripts/ntfy_listener.sh" >> "$NTFY_LISTENER_LOG" 2>&1 &
        echo "[watcher_supervisor] ntfy_listener restarted (PID: $!)"

        # 再起動直後はtimestampを更新して即時再検出を防止
        date +%s > "$NTFY_LISTENER_HEARTBEAT"
    fi
}

# KYOTO-MONITOR: Kyoto SSH heartbeat監視 + 緊急縮退モード自動移行（NeoSaitamaのみ動作）
# ラオモト裁定 Option A: 30分タイムアウト → emergency_degraded モード
check_kyoto_heartbeat_and_emergency() {
    # NeoSaitama (role=neosaitama) のみ実行。Kyoto側ではスキップ。
    local _role
    _role=$(awk '/^  role:/ {print $2; exit}' "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null)
    _role="${_role:-kyoto}"
    case "$_role" in mbp) _role="neosaitama" ;; ryzen) _role="kyoto" ;; esac
    [[ "$_role" != "neosaitama" ]] && return 0

    local peer_host
    peer_host=$(awk '/peer_host:/ {print $2; exit}' "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null)
    [[ -z "$peer_host" ]] && return 0

    local now
    now=${EPOCHSECONDS:-$(date +%s)}

    # Rate-limit: KYOTO_CHECK_INTERVAL秒に1回のみSSH確認実行
    local next_check
    next_check=$(cat "$KYOTO_NEXT_CHECK" 2>/dev/null)
    [[ ! "$next_check" =~ ^[0-9]+$ ]] && next_check=0
    if (( now < next_check )); then
        return 0
    fi
    printf '%s\n' "$(( now + KYOTO_CHECK_INTERVAL ))" > "$KYOTO_NEXT_CHECK"

    local am_file="$PROJECT_ROOT/queue/active_machine.yaml"

    # SSH ping Kyoto（BatchMode=yes: パスワード入力待ちを防止）
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$peer_host" "exit 0" >/dev/null 2>&1; then
        # Kyoto生存: last_seen更新
        printf '%s\n' "$now" > "$KYOTO_LAST_SEEN"

        # emergency_degradedからの復旧処理
        local current_mode
        current_mode=$(awk '/^mode:/ {print $2; exit}' "$am_file" 2>/dev/null)
        if [[ "$current_mode" == "emergency_degraded" ]]; then
            local pre_mode
            pre_mode=$(cat "$KYOTO_PRE_EMERGENCY" 2>/dev/null)
            pre_mode="${pre_mode:-simultaneous}"
            echo "[watcher_supervisor] KYOTO-MONITOR: Kyoto SSH restored. Reverting emergency_degraded → ${pre_mode}." >&2
            local ts
            ts=$(date "+%Y-%m-%dT%H:%M:%S+09:00")
            local tmp_file="${STATE_DIR}/am_recovery_$$"
            cat > "$tmp_file" << EOF
mode: ${pre_mode}
primary: kyoto
secondary: neosaitama
since: "${ts}"
activated_by: watcher_supervisor
recovered_from: emergency_degraded
EOF
            mv "$tmp_file" "$am_file"
            bash "$PROJECT_ROOT/scripts/inbox_write.sh" smith \
                "緊急縮退モード解除: Kyoto SSH疎通回復。${pre_mode}モードに復帰。新規cmd採番制限を解除。" \
                "system_notice" "watcher_supervisor" "" P0 2>/dev/null || true
            rm -f "$KYOTO_ALERT_SENT" "$KYOTO_PRE_EMERGENCY"
        fi
        return 0
    fi

    # SSH失敗: elapsed計算
    local last_seen
    last_seen=$(cat "$KYOTO_LAST_SEEN" 2>/dev/null)
    if [[ ! "$last_seen" =~ ^[0-9]+$ ]]; then
        # 初回失敗: ベースライン記録してまだ障害扱いしない
        printf '%s\n' "$now" > "$KYOTO_LAST_SEEN"
        return 0
    fi

    local elapsed=$(( now - last_seen ))

    # 3分未満: まだ警戒中（障害未確定）
    if (( elapsed < KYOTO_HEARTBEAT_TIMEOUT )); then
        return 0
    fi

    # 障害確定（3分以上SSH応答なし）: ラオモトへntfy通知（初回のみ）
    if [[ ! -f "$KYOTO_ALERT_SENT" ]]; then
        echo "[watcher_supervisor] KYOTO-MONITOR: Kyoto heartbeat lost (${elapsed}s). Alerting Laomoto via ntfy." >&2
        local ntfy_topic
        ntfy_topic=$(awk '/ntfy_topic:/ {print $2; exit}' "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null)
        if [[ -n "$ntfy_topic" ]]; then
            curl -s --max-time 10 -X POST "https://ntfy.sh/${ntfy_topic}" \
                -H "Title: CRITICAL: Kyoto障害検知" \
                -H "Priority: urgent" \
                -d "NeoSaitamaがKyotoのSSH heartbeatを${elapsed}秒間検知できません。handover:neosaitama を送信してください。30分以内に応答がない場合、緊急縮退モード(emergency_degraded)に自動移行します。" \
                >/dev/null 2>&1 || true
        fi
        bash "$PROJECT_ROOT/scripts/inbox_write.sh" smith \
            "CRITICAL: Kyoto SSH heartbeat喪失 (${elapsed}秒経過)。ラオモトへntfy通知送信済み。30分応答なし→emergency_degradedに自動移行予定。" \
            "system_notice" "watcher_supervisor" "" P0 2>/dev/null || true
        printf '%s\n' "$now" > "$KYOTO_ALERT_SENT"
        return 0
    fi

    # アラート送信済み: 30分タイムアウト確認
    local alert_sent
    alert_sent=$(cat "$KYOTO_ALERT_SENT" 2>/dev/null)
    [[ ! "$alert_sent" =~ ^[0-9]+$ ]] && return 0

    local alert_elapsed=$(( now - alert_sent ))
    if (( alert_elapsed < KYOTO_ALERT_TIMEOUT )); then
        return 0  # まだ30分経過していない（ラオモト応答待ち）
    fi

    # 30分タイムアウト: 既にemergency_degradedまたはexclusiveなら重複移行しない
    local current_mode
    current_mode=$(awk '/^mode:/ {print $2; exit}' "$am_file" 2>/dev/null)
    if [[ "$current_mode" == "emergency_degraded" || "$current_mode" == "exclusive" ]]; then
        return 0
    fi

    # 緊急縮退モード（emergency_degraded）移行（ラオモト裁定 Option A）
    echo "[watcher_supervisor] KYOTO-MONITOR: 30min timeout. No Laomoto response. Activating emergency_degraded." >&2
    printf '%s\n' "${current_mode:-simultaneous}" > "$KYOTO_PRE_EMERGENCY"

    local ts
    ts=$(date "+%Y-%m-%dT%H:%M:%S+09:00")
    local tmp_file="${STATE_DIR}/am_emergency_$$"
    cat > "$tmp_file" << EOF
mode: emergency_degraded
primary: neosaitama
since: "${ts}"
triggered_by: kyoto_heartbeat_timeout_30min
kyoto_last_seen: "${ts}"
restrictions:
  new_cmd_assignment: forbidden
  in_progress_tasks: continue
EOF
    mv "$tmp_file" "$am_file"

    bash "$PROJECT_ROOT/scripts/inbox_write.sh" smith \
        "緊急縮退モード（emergency_degraded）移行完了。Kyoto SSH heartbeat喪失から30分経過、ラオモト応答なし。既存in_progressタスクのみ継続可。新規cmd採番禁止。active_machine.yaml更新済み。解除: Kyoto復旧またはhandover:neosaitama。" \
        "system_notice" "watcher_supervisor" "" P0 2>/dev/null || true

    local ntfy_topic
    ntfy_topic=$(awk '/ntfy_topic:/ {print $2; exit}' "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null)
    if [[ -n "$ntfy_topic" ]]; then
        curl -s --max-time 10 -X POST "https://ntfy.sh/${ntfy_topic}" \
            -H "Title: 緊急縮退モード移行完了" \
            -H "Priority: urgent" \
            -d "NeoSaitamaが緊急縮退モード(emergency_degraded)に移行しました。既存タスクのみ継続。解除: handover:neosaitama または Kyoto復旧。" \
            >/dev/null 2>&1 || true
    fi
}

# Graceful shutdown: log and exit cleanly on SIGTERM/SIGINT
cleanup() {
    echo "[watcher_supervisor] shutting down (signal received)" >&2
    exit 0
}
trap cleanup SIGTERM SIGINT

while true; do
    # UNIFIED-HIGH-008: rescan_watchers signal
    # spawn_tengu() / despawn_tengu() touch this file to trigger immediate rescanning.
    # macOS has no inotifywait, so we use polling (checked once per loop iteration).
    if [[ -f "$RESCAN_FILE" ]]; then
        # LOW-002: mv方式（アトミック操作）でrm後・scan前の新シグナル消失を防止
        # mv失敗（同時実行等）はtrueで無視。その場合次ループで再検知される
        mv "$RESCAN_FILE" "${RESCAN_FILE}.processing" 2>/dev/null || true
        echo "[watcher_supervisor] rescan_watchers signal detected. Running immediate scan."
        scan_all_agents
        sleep 5
        continue  # LOW-001: rescan後は通常スキャンをスキップ（2重スキャン防止）
    fi

    check_heartbeat_watchdog
    check_kyoto_heartbeat_and_emergency
    scan_all_agents
    sleep 5
done
