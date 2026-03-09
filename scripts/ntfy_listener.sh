#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ntfy Input Listener — prefix routing + multi-topic subscription
# Streams messages from ntfy topics, routes by prefix, writes to inbox YAML.
# NOT polling — uses ntfy's streaming endpoint (long-lived HTTP connection).
# FR-066: ntfy認証対応 (Bearer token / Basic auth)
#
# Prefix system:
#   push:cmd_xxx:branch        → auto git pull + darkninja notify
#   sync:project_name:done     → auto rsync pull (cross_sync.sh) + darkninja notify
#   cmd:cmd_xxx:内容           → forward to darkninja + gryakuza inbox
#   handover:kyoto|neosaitama (or ryzen|mbp for compat) → active_machine.yaml update + gryakuza P0 notify
#   hb:host:epoch:agents:load:ctx → heartbeat (heartbeat topic only)
#   ping:source:epoch:message      → ping: heartbeat YAML update (no ntfy_inbox recording)
#   report:{base64_yaml}       → MBP→Ryzen レポート返送受信・queue/reports/保存
#
# Topic separation (based on machine.role in settings.yaml):
#   {base}                     → main topic (all machines)
#   {base}-heartbeat           → heartbeat topic (crane/tortoise)
#   {base}-{role}              → machine-specific topic
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"
TOPIC=$(awk '/ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' "$SETTINGS")
MACHINE_ROLE=$(awk '/^  role:/ {print $2; exit}' "$SETTINGS")
MACHINE_ROLE="${MACHINE_ROLE:-kyoto}"
# FIX-006: Legacy role name normalization (cmd_274 rename: mbp→neosaitama, ryzen→kyoto)
case "$MACHINE_ROLE" in
  mbp)   MACHINE_ROLE="neosaitama" ;;
  ryzen) MACHINE_ROLE="kyoto" ;;
esac
INBOX="$SCRIPT_DIR/queue/ntfy_inbox.yaml"
LOCKFILE="${INBOX}.lock"
CORRUPT_DIR="$SCRIPT_DIR/logs/ntfy_inbox_corrupt"
STATE_DIR="$SCRIPT_DIR/.state"
LAST_ID_FILE="$STATE_DIR/ntfy_last_id"
mkdir -p "$STATE_DIR"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

if [[ -z "$TOPIC" ]]; then
    echo "[ntfy_listener] ntfy_topic not configured in settings.yaml" >&2
    exit 1
fi

# トピック名セキュリティ検証（失敗しても動作継続、但し警告を記録）
if ! ntfy_validate_topic "$TOPIC"; then
    echo "[ntfy_listener] WARN: ntfy_topic validation failed: '$TOPIC' — continuing anyway" >&2
    # TODO: strictモードが追加された場合はここでexit 1に変更
fi

# Multi-topic subscription: {base},{base}-heartbeat,{base}-{role},{laomoto}
TOPIC_LAOMOTO=$(awk '/ntfy_topic_laomoto:/ {gsub(/"/, ""); print $2; exit}' "$SETTINGS")
SUBSCRIBE_TOPICS="${TOPIC},${TOPIC}-heartbeat,${TOPIC}-${MACHINE_ROLE}"
[[ -n "$TOPIC_LAOMOTO" ]] && SUBSCRIBE_TOPICS="${SUBSCRIBE_TOPICS},${TOPIC_LAOMOTO}"

# Initialize inbox if not exists
if [[ ! -f "$INBOX" ]]; then
    echo "inbox:" > "$INBOX"
fi

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/api_keys.env")

# Parse all needed JSON fields in a single python3 invocation.
# Output: <event><US><tags><US><message><US><id><US><topic>  (US = ASCII unit separator 0x1f)
parse_message_fields() {
    python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print("\x1f".join([
        d.get("event", ""),
        ",".join(d.get("tags", [])),
        d.get("message", ""),
        d.get("id", ""),
        d.get("topic", "")
    ]))
except Exception:
    print("\x1f\x1f\x1f\x1f")' 2>/dev/null
}

append_ntfy_inbox() {
    local msg_id="$1"
    local ts="$2"
    local msg="$3"
    local status="${4:-pending}"

    _run_locked() {
        NTFY_INBOX_PATH="$INBOX" \
        NTFY_CORRUPT_DIR="$CORRUPT_DIR" \
        MSG_ID="$msg_id" \
        MSG_TS="$ts" \
        MSG_TEXT="$msg" \
        MSG_STATUS="$status" \
        python3 - << 'PY'
import datetime
import os
import shutil
import sys
import tempfile
import yaml

path = os.environ["NTFY_INBOX_PATH"]
corrupt_dir = os.environ.get("NTFY_CORRUPT_DIR", "")
entry = {
    "id": os.environ.get("MSG_ID", ""),
    "timestamp": os.environ.get("MSG_TS", ""),
    "message": os.environ.get("MSG_TEXT", ""),
    "status": os.environ.get("MSG_STATUS", "pending"),
}

data = {}
parse_error = False

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            loaded = yaml.safe_load(f)
        if isinstance(loaded, dict):
            data = loaded
        elif loaded is None:
            data = {}
        else:
            parse_error = True
    except Exception:
        parse_error = True

if parse_error and os.path.exists(path):
    try:
        if corrupt_dir:
            os.makedirs(corrupt_dir, exist_ok=True)
            backup = os.path.join(
                corrupt_dir,
                f"ntfy_inbox_corrupt_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.yaml",
            )
            shutil.copy2(path, backup)
    except Exception:
        pass
    data = {}

items = data.get("inbox")
if not isinstance(items, list):
    items = []
items.append(entry)
data["inbox"] = items

tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
        yaml.safe_dump(
            data,
            f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )
    os.replace(tmp_path, path)
except Exception as e:
    try:
        os.unlink(tmp_path)
    except Exception:
        pass
    print(f"[ntfy_listener] failed to write inbox: {e}", file=sys.stderr)
    sys.exit(1)
PY
    }

    # Cross-platform file locking: flock (Linux) or mkdir fallback (macOS)
    if command -v flock &>/dev/null; then
        ( flock -w 5 200 || { echo "[ntfy_listener] lock timeout: ntfy_inbox busy for 5s" >&2; exit 1; }; _run_locked ) 200>"$LOCKFILE"
    else
        local lock_dir="${LOCKFILE}.d"
        local retries=10
        while ! mkdir "$lock_dir" 2>/dev/null; do
            retries=$((retries - 1))
            if [[ $retries -le 0 ]]; then
                echo "[ntfy_listener] failed to acquire lock" >&2
                return 1
            fi
            sleep 0.5
        done
        _run_locked
        rmdir "$lock_dir" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════
# Prefix routing handlers
# ═══════════════════════════════════════════════════════════════

# push:cmd_xxx:branch → auto git pull + darkninja notify
handle_push() {
    local payload="$1"
    local cmd_id branch
    cmd_id="${payload%%:*}"
    branch="${payload#*:}"
    if [[ ! "$branch" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: Invalid branch: ${branch:0:50}" >&2
        return 1
    fi
    echo "[$(date)] [ntfy_listener] push: cmd=$cmd_id branch=$branch — running git pull" >&2
    if (cd "$SCRIPT_DIR" && git pull --ff-only origin "$branch" 2>&1) | \
        while IFS= read -r gitline; do echo "[$(date)] [git pull] $gitline" >&2; done; then
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "push受信: $cmd_id ($branch) — git pull完了。" \
            ntfy_received ntfy_listener
    else
        echo "[$(date)] [ntfy_listener] WARNING: git pull failed for branch=$branch" >&2
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "push受信: $cmd_id ($branch) — git pull失敗。手動確認せよ。" \
            ntfy_received ntfy_listener "" P1
    fi
}

# sync:project_name:done → auto rsync pull (cross_sync.sh) + darkninja notify
handle_sync() {
    local payload="$1"
    local project status
    project="${payload%%:*}"
    status="${payload#*:}"
    echo "[$(date)] [ntfy_listener] sync: project=$project status=$status" >&2
    local sync_script="$SCRIPT_DIR/scripts/cross_sync.sh"
    if [[ ! -x "$sync_script" ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: cross_sync.sh not found or not executable" >&2
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "sync受信: $project ($status) — cross_sync.sh未検出。手動対応せよ。" \
            ntfy_received ntfy_listener "" P1
        return 1
    fi
    if bash "$sync_script" pull 2>&1 | \
        while IFS= read -r syncline; do echo "[$(date)] [cross_sync] $syncline" >&2; done; then
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "sync受信: $project ($status) — rsync pull完了。" \
            ntfy_received ntfy_listener
    else
        echo "[$(date)] [ntfy_listener] WARNING: cross_sync.sh pull failed" >&2
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "sync受信: $project ($status) — rsync pull失敗。手動確認せよ。" \
            ntfy_received ntfy_listener "" P1
    fi
}

# cmd:cmd_xxx:内容 → forward to darkninja + gryakuza inbox
handle_cmd() {
    local payload="$1"
    local cmd_id content
    cmd_id="${payload%%:*}"
    content="${payload#*:}"
    echo "[$(date)] [ntfy_listener] cmd: $cmd_id: ${content:0:80}" >&2
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
        "ntfy cmd受信: $cmd_id: $content" \
        ntfy_received ntfy_listener
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "ntfy cmd受信: $cmd_id: $content" \
        ntfy_received ntfy_listener
}

# handover:ryzen|mbp → active_machine.yaml update + gryakuza P0 notify
handle_handover() {
    local target="$1"
    echo "[$(date)] [ntfy_listener] handover: target=$target" >&2
    if [[ "$target" != "kyoto" && "$target" != "neosaitama" && "$target" != "ryzen" && "$target" != "mbp" ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid handover target: $target" >&2
        return 1
    fi
    local am_file="$SCRIPT_DIR/queue/active_machine.yaml"
    # FIX-009: simultaneous mode中はhandover拒否
    local current_mode
    current_mode=$(awk '/^mode:/{print $2}' "$am_file" 2>/dev/null)
    if [[ "$current_mode" == "simultaneous" ]]; then
        echo "[$(date)] [ntfy_listener] WARN: handover rejected: simultaneous mode active — use ntfy 'set_mode:exclusive' first" >&2
        return 1
    fi
    local ts tz_len
    ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
    tz_len=${#ts}
    ts="${ts:0:$((tz_len-2))}:${ts:$((tz_len-2))}"
    # Atomic write via temp file
    local tmp_file
    tmp_file=$(mktemp "${am_file}.XXXXXX")
    cat > "$tmp_file" << EOF
mode: exclusive
primary: $target
since: "$ts"
activated_by: laomoto
handover_by: laomoto
standby_mode: minimal        # minimal | full_stop
EOF
    mv -f "$tmp_file" "$am_file"
    echo "[$(date)] [ntfy_listener] active_machine.yaml updated → $target" >&2
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "handover受信: active_machine → $target に切り替え。即時handoverプロセスを開始せよ。" \
        system_notice ntfy_listener "" P0
}

# hb:host:epoch:agents:load:ctx_summary → heartbeat YAML update
handle_heartbeat() {
    local payload="$1"
    local host epoch agents load ctx_summary
    IFS=':' read -r host epoch agents load ctx_summary <<< "$payload"

    # Input validation: all fields strictly validated (YAML injection防止)
    if [[ ! "$host" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat host: ${host:0:50}" >&2
        return 1
    fi
    if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat epoch: ${epoch:0:30}" >&2
        return 1
    fi
    if [[ ! "$agents" =~ ^[0-9]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat agents: ${agents:0:30}" >&2
        return 1
    fi
    if [[ ! "$load" =~ ^[0-9.]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat load: ${load:0:30}" >&2
        return 1
    fi
    if [[ ! "$ctx_summary" =~ ^(ok|warn|critical)$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat ctx_summary '${ctx_summary:0:30}', sanitizing to unknown" >&2
        ctx_summary="unknown"
    fi

    echo "[$(date)] [ntfy_listener] heartbeat: host=$host agents=$agents load=$load ctx=$ctx_summary" >&2
    local hb_dir="$SCRIPT_DIR/queue/heartbeat"
    mkdir -p "$hb_dir"

    # Cross-platform timestamp: GNU date -d (Linux) or date -r (macOS/BSD)
    local ts
    if date -d "@${epoch}" "+%Y" &>/dev/null; then
        ts=$(date -d "@${epoch}" "+%Y-%m-%dT%H:%M:%S%z")
    elif date -r "${epoch}" "+%Y" &>/dev/null; then
        ts=$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z")
    else
        ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
    fi
    # Insert colon in timezone offset: +0900 → +09:00 (bash 3.2 compatible)
    local tz_len=${#ts}
    ts="${ts:0:$((tz_len-2))}:${ts:$((tz_len-2))}"

    # Atomic write via temp file
    local tmp_file
    tmp_file=$(mktemp "${hb_dir}/${host}.yaml.XXXXXX")
    cat > "$tmp_file" << EOF
machine_id: $host
last_beat: "$ts"
status: alive
agents_active: $agents
load_avg: $load
context_summary: $ctx_summary
EOF
    mv -f "$tmp_file" "$hb_dir/${host}.yaml"

    # NTFY-004: watcher_supervisorのheartbeat watchdog用にtimestampを記録
    echo "$(date +%s)" > "$SCRIPT_DIR/logs/ntfy_listener_last_heartbeat.txt"
}

# ping:source:epoch:message → heartbeat YAML update (no ntfy_inbox recording)
handle_ping() {
    local payload="$1"
    local source epoch message
    IFS=':' read -r source epoch message <<< "$payload"

    # Input validation
    if [[ ! "$source" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid ping source: ${source:0:50}" >&2
        return 1
    fi
    if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid ping epoch: ${epoch:0:30}" >&2
        return 1
    fi
    # Sanitize message: remove characters unsafe in unquoted YAML scalar
    message="${message//$'\n'/ }"
    message="${message//\"/\'}"
    message="${message//\\/}"
    message="${message:0:200}"

    echo "[$(date)] [ntfy_listener] ping: source=$source epoch=$epoch msg=${message:0:50}" >&2
    local hb_dir="$SCRIPT_DIR/queue/heartbeat"
    mkdir -p "$hb_dir"

    # Cross-platform timestamp: GNU date -d (Linux) or date -r (macOS/BSD)
    local ts
    if date -d "@${epoch}" "+%Y" &>/dev/null; then
        ts=$(date -d "@${epoch}" "+%Y-%m-%dT%H:%M:%S%z")
    elif date -r "${epoch}" "+%Y" &>/dev/null; then
        ts=$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z")
    else
        ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
    fi
    # Insert colon in timezone offset: +0900 → +09:00 (bash 3.2 compatible)
    local tz_len=${#ts}
    ts="${ts:0:$((tz_len-2))}:${ts:$((tz_len-2))}"

    # Atomic write via temp file
    local tmp_file
    tmp_file=$(mktemp "${hb_dir}/${source}.yaml.XXXXXX")
    cat > "$tmp_file" << EOF
machine_id: $source
last_ping: "$ts"
status: alive
ping_message: "$message"
EOF
    mv -f "$tmp_file" "${hb_dir}/${source}.yaml"
}

# report:{base64エンコードされたYAML} → MBP側からのレポート受信・保存 (cmd_278 T2)
handle_report() {
    local payload="$1"
    local log_file="$SCRIPT_DIR/logs/ntfy_listener.log"
    mkdir -p "$(dirname "$log_file")"

    # base64デコード（クロスプラットフォーム: Linux=-d, macOS=-D）
    local decoded
    decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) || \
    decoded=$(printf '%s' "$payload" | base64 -D 2>/dev/null) || {
        echo "[$(date)] [ntfy_listener] ERROR: report: base64 decode failed" >&2
        echo "[$(date)] [ntfy_listener] ERROR: report: base64 decode failed" >> "$log_file"
        return 1
    }

    # YAMLバリデーション: worker_id, task_id フィールド確認（yaml.safe_load でインジェクション防止）
    local worker_id task_id
    worker_id=$(printf '%s' "$decoded" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
    print(d.get("worker_id", "") if isinstance(d, dict) else "")
except Exception:
    print("")
' 2>/dev/null)
    task_id=$(printf '%s' "$decoded" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
    print(d.get("task_id", "") if isinstance(d, dict) else "")
except Exception:
    print("")
' 2>/dev/null)

    # worker_id / task_id バリデーション（^[a-zA-Z0-9_-]+$）
    if [[ ! "$worker_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: report: invalid or missing worker_id: '${worker_id:0:50}'" >&2
        echo "[$(date)] [ntfy_listener] ERROR: report: invalid worker_id" >> "$log_file"
        return 1
    fi
    if [[ ! "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: report: invalid or missing task_id: '${task_id:0:50}'" >&2
        echo "[$(date)] [ntfy_listener] ERROR: report: invalid task_id" >> "$log_file"
        return 1
    fi

    # 書き込み先決定: queue/reports/{worker_id}_report_{task_id}.yaml
    local reports_dir="$SCRIPT_DIR/queue/reports"
    mkdir -p "$reports_dir"
    local report_filename="${worker_id}_report_${task_id}.yaml"
    local report_path="$reports_dir/$report_filename"

    # 既存ファイル上書き防止: タイムスタンプsuffixを付与
    if [[ -f "$report_path" ]]; then
        local ts_suffix
        ts_suffix=$(date "+%Y%m%d_%H%M%S")
        report_path="${reports_dir}/${worker_id}_report_${task_id}_${ts_suffix}.yaml"
    fi

    # Atomic write via temp file (path traversal防止: reports_dir 内のみ)
    local tmp_file
    tmp_file=$(mktemp "${reports_dir}/.report_XXXXXX.yaml")
    printf '%s\n' "$decoded" > "$tmp_file"
    mv -f "$tmp_file" "$report_path"

    echo "[$(date)] [ntfy_listener] report: saved → $report_path" >&2
    echo "[$(date)] [ntfy_listener] report: saved → $report_path" >> "$log_file"

    # gryakuza inbox通知
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "MBP report受信: ${task_id}" \
        report_received ntfy_listener "$report_path"
}

# dispatch:{base64_yaml} → decode YAML, write to queue/tasks/, notify worker (cmd_278 T1)
handle_task_dispatch() {
    local b64_payload="$1"

    # Cross-platform base64 decode: GNU base64 -d (Linux) or macOS base64 -D
    local decoded
    if decoded=$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null) && [[ -n "$decoded" ]]; then
        : # GNU base64 -d succeeded
    elif decoded=$(printf '%s' "$b64_payload" | base64 -D 2>/dev/null) && [[ -n "$decoded" ]]; then
        : # macOS base64 -D succeeded
    else
        echo "[$(date)] [ntfy_listener] ERROR: dispatch: base64 decode failed" >&2
        return 1
    fi

    # Extract fields via yaml.safe_load (prevents YAML injection — never eval content)
    local task_id parent_cmd worker_id
    task_id=$(printf '%s' "$decoded" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
    task_data = d.get("task", d) if isinstance(d, dict) else {}
    print(task_data.get("task_id", "") if isinstance(task_data, dict) else "")
except Exception:
    print("")
' 2>/dev/null)
    parent_cmd=$(printf '%s' "$decoded" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
    task_data = d.get("task", d) if isinstance(d, dict) else {}
    print(task_data.get("parent_cmd", "") if isinstance(task_data, dict) else "")
except Exception:
    print("")
' 2>/dev/null)
    worker_id=$(printf '%s' "$decoded" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin)
    task_data = d.get("task", d) if isinstance(d, dict) else {}
    print(task_data.get("assigned_to", "unknown") if isinstance(task_data, dict) else "unknown")
except Exception:
    print("unknown")
' 2>/dev/null)
    worker_id="${worker_id:-unknown}"

    # Validate required fields
    if [[ -z "$task_id" || -z "$parent_cmd" ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: dispatch: missing task_id or parent_cmd in YAML" >&2
        return 1
    fi

    # task_id: alphanumeric + underscore/hyphen only (path traversal prevention)
    if [[ ! "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: dispatch: invalid task_id: ${task_id:0:50}" >&2
        return 1
    fi

    # worker_id: same character class validation
    if [[ ! "$worker_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: dispatch: invalid worker_id '${worker_id:0:30}', using unknown" >&2
        worker_id="unknown"
    fi

    # Write YAML to queue/tasks/ (atomic via temp file, path confined to tasks_dir)
    local tasks_dir="$SCRIPT_DIR/queue/tasks"
    mkdir -p "$tasks_dir"
    local task_file="${tasks_dir}/${worker_id}_${task_id}.yaml"

    # FIX-006: 既存ファイル上書き保護（handle_report()と統一）
    if [[ -f "$task_file" ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: Task file already exists: $task_file — skipping to prevent overwrite" >&2
        # DESIGN-003: アイサツ:error を sender に返送（上書き保護でスキップした旨を通知）
        local err_aisatsu_topic
        case "$MACHINE_ROLE" in
            neosaitama|mbp) err_aisatsu_topic="${TOPIC}-kyoto" ;;
            kyoto|ryzen)    err_aisatsu_topic="${TOPIC}-neosaitama" ;;
            *)              err_aisatsu_topic="${TOPIC}-kyoto" ;;
        esac
        curl -s -X POST "https://ntfy.sh/${err_aisatsu_topic}" \
            "${AUTH_ARGS[@]}" -H 'Content-Type: text/plain' \
            -d "aisatsu:${task_id}:error" --max-time 10 -o /dev/null 2>/dev/null || true
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${tasks_dir}/${worker_id}_${task_id}.yaml.XXXXXX")
    printf '%s\n' "$decoded" > "$tmp_file"
    mv -f "$tmp_file" "$task_file"

    echo "[$(date)] [ntfy_listener] dispatch: task_id=$task_id worker=$worker_id → $task_file" >&2

    # FIX-004: gryakuzaに通知（dispatch受信を報告 → gryakuzaがworkerに割り当て）
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "ntfy dispatch受信: $task_id → $task_file 保存済み。確認して割り当てよ。" \
        report_received ntfy_listener "$task_file"

    # cmd_330: アイサツ返送 — SSH経由 Kyoto gryakuza inbox書き込み（ntfyフォールバック付き）
    local _aisatsu_sent=false
    if [[ "$MACHINE_ROLE" == "kyoto" || "$MACHINE_ROLE" == "ryzen" ]]; then
        # Kyoto上での実行: ローカルinbox_write（loopback防止）
        if bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
            "aisatsu受領: ${task_id} → NeoSaitama受領済み。ドーモ。" \
            system_notice ntfy_listener "" P2 2>/dev/null; then
            echo "[$(date)] [ntfy_listener] dispatch: アイサツ(ローカル) → gryakuza inbox (task_id=${task_id})" >&2
            _aisatsu_sent=true
        fi
    else
        # NeoSaitama上での実行: SSH経由でKyoto gryakuza inboxに書き込み
        if bash "$SCRIPT_DIR/lib/ssh_inbox_write.sh" gryakuza \
            "aisatsu受領: ${task_id} → NeoSaitama受領済み。ドーモ。" \
            system_notice ntfy_listener "" P2 2>/dev/null; then
            echo "[$(date)] [ntfy_listener] dispatch: アイサツ(SSH) → Kyoto gryakuza inbox (task_id=${task_id})" >&2
            _aisatsu_sent=true
        fi
    fi
    # SSH/ローカル失敗時のフォールバック: ntfy aisatsu: POST
    if [[ "$_aisatsu_sent" == "false" ]]; then
        local aisatsu_topic
        case "$MACHINE_ROLE" in
            neosaitama|mbp) aisatsu_topic="${TOPIC}-kyoto" ;;
            kyoto|ryzen)    aisatsu_topic="${TOPIC}-neosaitama" ;;
            *)              aisatsu_topic="${TOPIC}-kyoto" ;;
        esac
        if curl -s -X POST "https://ntfy.sh/${aisatsu_topic}" \
            "${AUTH_ARGS[@]}" \
            -H 'Content-Type: text/plain' \
            -d "aisatsu:${task_id}:ok" \
            --max-time 10 -o /dev/null 2>/dev/null; then
            echo "[$(date)] [ntfy_listener] dispatch: アイサツ(ntfyフォールバック) → ${aisatsu_topic} (aisatsu:${task_id}:ok)" >&2
        else
            local aisatsu_err_payload="aisatsu:${task_id}:error"
            curl -s -X POST "https://ntfy.sh/${aisatsu_topic}" \
                "${AUTH_ARGS[@]}" -H 'Content-Type: text/plain' \
                -d "$aisatsu_err_payload" --max-time 10 -o /dev/null 2>/dev/null || true
            echo "[$(date)] [ntfy_listener] WARNING: dispatch: アイサツ送信失敗 (error送信試行) for ${task_id}" >&2
        fi
    fi
}

# suriken:{agent_id}:{count} → クロスマシンsuriken受信・ローカルペインにnudge (cmd_298)
handle_suriken() {
    local payload="$1"
    local log_file="$SCRIPT_DIR/logs/ntfy_listener.log"
    mkdir -p "$(dirname "$log_file")"

    # パース: agent_id:count
    local agent_id count
    IFS=':' read -r agent_id count <<< "$payload"

    # agent_id バリデーション（[a-z0-9_]+ のみ許可、インジェクション防止）
    if [[ ! "$agent_id" =~ ^[a-z0-9_]+$ ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: suriken: invalid agent_id='$agent_id'" >&2
        echo "[$(date)] [ntfy_listener] ERROR: suriken: invalid agent_id='$agent_id'" >> "$log_file"
        return 1
    fi

    # count デフォルト（未指定時は1）+ 整数強制（プロンプトインジェクション防止）
    count="${count:-1}"
    [[ ! "$count" =~ ^[0-9]+$ ]] && count=1

    # ローカルペイン探索
    local pane_id
    pane_id=$(tmux list-panes -a -F '#{pane_id} #{@agent_id}' 2>/dev/null \
              | awk -v id="$agent_id" '$2==id {print $1; exit}')

    if [[ -n "$pane_id" ]]; then
        # オートコンプリート安全nudge送信（text → Escape → Enter）
        local nudge_text="スリケン！inbox${count}"
        tmux send-keys -t "$pane_id" "$nudge_text" 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$pane_id" Escape 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$pane_id" Enter 2>/dev/null
        echo "[$(date)] [ntfy_listener] suriken: nudge sent to $agent_id ($pane_id) count=$count" >&2
        echo "[$(date)] [ntfy_listener] suriken: nudge sent to $agent_id ($pane_id) count=$count" >> "$log_file"
    else
        echo "[$(date)] [ntfy_listener] ERROR: suriken: pane not found for agent_id='$agent_id'" >&2
        echo "[$(date)] [ntfy_listener] ERROR: suriken: pane not found for agent_id='$agent_id'" >> "$log_file"
        return 1
    fi
}

# aisatsu:{task_id}:{status} → dispatch アイサツ受信（ntfyフォールバック受信用）(cmd_328/cmd_330)
# cmd_330以降: メインパスはSSH経由でKyoto gryakuza inboxに直接書き込み。
# このハンドラはSSH失敗時のntfy経由フォールバック確認用として維持。
handle_aisatsu() {
    local payload="$1"
    local task_id aisatsu_status
    IFS=':' read -r task_id aisatsu_status <<< "$payload"

    # task_id validation
    if [[ ! "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[$(date)] [ntfy_listener] ERROR: aisatsu: invalid task_id: ${task_id:0:50}" >&2
        return 1
    fi

    # aisatsu_status validation (ok|error only; unknown values sanitized)
    if [[ ! "$aisatsu_status" =~ ^(ok|error)$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: aisatsu: invalid status '${aisatsu_status:0:30}', treating as unknown" >&2
        aisatsu_status="unknown"
    fi

    echo "[$(date)] [ntfy_listener] aisatsu: task_id=$task_id status=$aisatsu_status" >&2

    # Notify darkninja that dispatch アイサツ was received
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
        "dispatch アイサツ確認: ${task_id} → ${aisatsu_status}" \
        system_notice ntfy_listener
}

# activate:simultaneous → active_machine.yaml をsimultaneousモードに更新
handle_activate_simultaneous() {
    echo "[$(date)] [ntfy_listener] activate:simultaneous received" >&2
    local am_file="$SCRIPT_DIR/queue/active_machine.yaml"
    local ts tz_len
    ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
    tz_len=${#ts}
    ts="${ts:0:$((tz_len-2))}:${ts:$((tz_len-2))}"
    local tmp_file
    tmp_file=$(mktemp "${am_file}.XXXXXX")
    cat > "$tmp_file" << EOF
mode: simultaneous
primary: kyoto
secondary: neosaitama
since: "$ts"
activated_by: laomoto_ntfy
EOF
    mv -f "$tmp_file" "$am_file"
    echo "[$(date)] [ntfy_listener] active_machine.yaml updated → simultaneous" >&2
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" gryakuza \
        "activate:simultaneous 受信。active_machine.yaml をsimultaneousモードに更新した。同時稼働準備を開始せよ。" \
        ntfy_received ntfy_listener "" P0
}

# LINE image/video/file download handler
# payload format: {messageId}:{mediaType}:{fileName}
handle_lineimg() {
    local payload="$1"
    local message_id="${payload%%:*}"
    local rest="${payload#*:}"
    local media_type="${rest%%:*}"
    local file_name="${rest#*:}"

    echo "[$(date)] [ntfy_listener] lineimg: downloading ${media_type} messageId=${message_id}" >&2
    local saved_path
    saved_path=$(bash "$SCRIPT_DIR/scripts/line_image_download.sh" "$message_id" "$media_type" "$file_name" 2>&1)
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        local label="画像"
        [[ "$media_type" == "video" ]] && label="動画"
        [[ "$media_type" == "file" ]] && label="ファイル"
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "LINE ${label}受信: ${saved_path}" "laomoto_message" "ntfy_listener" "" P1
        echo "[$(date)] [ntfy_listener] lineimg: saved to ${saved_path}" >&2
    else
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "LINE画像DL失敗: messageId=${message_id} error=${saved_path}" "system_notice" "ntfy_listener" "" P1
        echo "[$(date)] [ntfy_listener] lineimg: FAILED messageId=${message_id}" >&2
    fi
}

# laomotoトピックメッセージ → darkninja inbox転送（LINE直通チャット）
# cmd_342 FIX: MACHINE_ROLE別ルーティング（重複防止）
# - Kyoto: darkninja + master_tortoise にローカル書き込み（従来動作）
# - NeoSaitama: master_crane にローカル書き込みのみ
#   理由: 同時稼働モードで両マシンがlaomotopicを購読するため、
#   NeoSaitamaがSSHでKyoto darkninja書き込みするとKyoto分と重複になる
handle_laomoto() {
    local msg="$1"
    # lineimg: prefix on laomoto topic → delegate to lineimg handler
    if [[ "$msg" == lineimg:* ]]; then
        handle_lineimg "${msg#lineimg:}"
        return
    fi
    if [[ "$MACHINE_ROLE" == "kyoto" || "$MACHINE_ROLE" == "ryzen" ]]; then
        # Kyoto (primary): darkninja + master_tortoise にローカル書き込み
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "LINE: $msg" "laomoto_message" "ntfy_listener" "" P1
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" master_tortoise \
            "LINE: $msg" "laomoto_message" "ntfy_listener" "" P1
        # Wake darkninja for deep reply
        bash "$SCRIPT_DIR/scripts/njslyr_cmd.sh" suriken darkninja 2>/dev/null &
        echo "[$(date)] [ntfy_listener] laomoto → darkninja+master_tortoise+suriken (local/Kyoto): ${msg:0:80}" >&2
    else
        # NeoSaitama (secondary): master_crane にローカル書き込みのみ
        # (darkninja転送はKyoto側で実施済み。SSH二重書き込み防止)
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" master_crane \
            "LINE: $msg" "laomoto_message" "ntfy_listener" "" P1
        echo "[$(date)] [ntfy_listener] laomoto → master_crane (local/NeoSaitama): ${msg:0:80}" >&2
    fi
}

# Route message by prefix. Returns 0 if handled, 1 if fallback needed.
# Return code 2 means: handled but skip ntfy_inbox recording (e.g. ping:).
route_message() {
    local msg="$1"
    local msg_topic="$2"
    # Heartbeat topic messages: only hb handler, no ntfy_inbox
    if [[ "$msg_topic" == *-heartbeat ]]; then
        local prefix="${msg%%:*}"
        if [[ "$prefix" == "hb" ]]; then
            handle_heartbeat "${msg#*:}"
        else
            echo "[$(date)] [ntfy_listener] WARNING: non-hb message on heartbeat topic: ${msg:0:50}" >&2
        fi
        return 0
    fi
    # Laomoto topic: all messages forwarded directly to darkninja (bypass prefix routing)
    if [[ -n "$TOPIC_LAOMOTO" && "$msg_topic" == "$TOPIC_LAOMOTO" ]]; then
        handle_laomoto "$msg"
        return 0
    fi
    # Main/machine-specific topic: route by prefix
    local prefix="${msg%%:*}"
    local payload="${msg#*:}"
    case "$prefix" in
        push)
            handle_push "$payload"
            return 0
            ;;
        sync)
            handle_sync "$payload"
            return 0
            ;;
        cmd)
            handle_cmd "$payload"
            return 0
            ;;
        handover)
            handle_handover "$payload"
            return 0
            ;;
        hb)
            # hb on main topic — still handle it
            handle_heartbeat "$payload"
            return 0
            ;;
        ping)
            # ping: handled — skip ntfy_inbox recording (return 2)
            handle_ping "$payload"
            return 2
            ;;
        dispatch)
            handle_task_dispatch "$payload"
            return 0
            ;;
        report)
            handle_report "$payload"
            return 0
            ;;
        suriken)
            handle_suriken "$payload"
            return 2
            ;;
        aisatsu)
            # cmd_328: dispatch アイサツ受信 — darkninja通知、ntfy_inbox記録あり
            handle_aisatsu "$payload"
            return 0
            ;;
        lineimg)
            # LINE image/video/file download: lineimg:{messageId}:{mediaType}:{fileName}
            handle_lineimg "$payload"
            return 0
            ;;
        activate)
            if [[ "$payload" == "simultaneous" ]]; then
                handle_activate_simultaneous
            else
                echo "[$(date)] [ntfy_listener] WARNING: unknown activate subcommand: ${payload:0:50}" >&2
            fi
            return 0
            ;;
        *)
            # Free text from Raomoto's phone → forward to darkninja inbox
            bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
                "ntfy free text: $msg" "ntfy_message" "ntfy_listener" "" P1
            echo "[$(date)] [ntfy_listener] free text forwarded to darkninja: ${msg:0:80}" >&2
            return 0
            ;;
    esac
}

# Graceful shutdown: log and exit cleanly on SIGTERM/SIGINT
cleanup() {
    echo "[$(date)] [ntfy_listener] shutting down (signal received)" >&2
    exit 0
}
trap cleanup SIGTERM SIGINT

_auth_type="${NTFY_TOKEN:+token}"
_auth_type="${_auth_type:-${NTFY_USER:+basic}}"
_auth_type="${_auth_type:-none}"
echo "[$(date)] ntfy listener started — topics: ${TOPIC:0:8}...(masked) role: $MACHINE_ROLE (auth: $_auth_type)" >&2
unset _auth_type

while true; do
    # Graceful shutdown via flag file (.state/ntfy_listener_stop)
    if [[ -f "$STATE_DIR/ntfy_listener_stop" ]]; then
        echo "[$(date)] [ntfy_listener] graceful stop requested" >&2
        rm -f "$STATE_DIR/ntfy_listener_stop"
        exit 0
    fi

    # 再接続時のmissed message回収: 最後に受信したIDからのみ取得（FAIL-001対策）
    # 初回起動時はsince_param空（全履歴取得するとflood）
    _since_param=""
    if [[ -f "$LAST_ID_FILE" ]]; then
        _last_id=$(cat "$LAST_ID_FILE" 2>/dev/null)
        [[ -n "$_last_id" ]] && _since_param="?since=${_last_id}"
    fi

    # Stream new messages from multiple topics (long-lived connection)
    # FIX-022: Use -sS (show errors on stderr) instead of suppressing all stderr with 2>/dev/null
    curl -sS --no-buffer --max-time 300 "${AUTH_ARGS[@]}" "https://ntfy.sh/$SUBSCRIBE_TOPICS/json${_since_param}" 2>> "$SCRIPT_DIR/logs/ntfy_listener_curl.log" | while IFS= read -r line; do
        # Parse all needed fields in a single python3 call (including topic)
        IFS=$'\x1f' read -r EVENT _ MSG MSG_ID MSG_TOPIC < <(parse_message_fields <<< "$line")

        # Skip keepalive pings and non-message events
        [[ "$EVENT" != "message" ]] && continue

        # Skip empty messages
        [[ -z "$MSG" ]] && continue

        # 最後に受信したメッセージIDを保存（再接続時のmissed message回収に使用）
        [[ -n "$MSG_ID" ]] && echo "$MSG_ID" > "$LAST_ID_FILE"

        # %:z is GNU-only (+09:00). Use %z (+0900) and insert colon for portability.
        TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S%z")
        _ts_len=${#TIMESTAMP}
        TIMESTAMP="${TIMESTAMP:0:$((_ts_len-2))}:${TIMESTAMP:$((_ts_len-2))}"

        echo "[$(date)] Received [$MSG_TOPIC]: $MSG" >&2

        # Route by prefix. Heartbeat messages skip ntfy_inbox entirely.
        _route_result=0
        route_message "$MSG" "$MSG_TOPIC" || _route_result=$?
        case $_route_result in
            0)
                # Known prefix handled — skip ntfy_inbox for heartbeat topic
                if [[ "$MSG_TOPIC" != *-heartbeat ]]; then
                    # Non-heartbeat routed messages: record in ntfy_inbox as processed
                    append_ntfy_inbox "$MSG_ID" "$TIMESTAMP" "$MSG" "processed" || \
                        echo "[$(date)] [ntfy_listener] WARNING: failed to append ntfy_inbox entry" >&2
                fi
                ;;
            2)
                # ping: handled — skip ntfy_inbox recording entirely
                ;;
            *)
                # Unknown prefix — log to ntfy_unrecognized.log, record in ntfy_inbox as pending
                # Do NOT forward to darkninja inbox (prevents inbox pollution)
                mkdir -p "$SCRIPT_DIR/logs"
                echo "[$(date)] [UNRECOGNIZED PREFIX] topic=$MSG_TOPIC msg=${MSG:0:200}" >> "$SCRIPT_DIR/logs/ntfy_unrecognized.log"
                append_ntfy_inbox "$MSG_ID" "$TIMESTAMP" "$MSG" || \
                    echo "[$(date)] [ntfy_listener] WARNING: failed to append ntfy_inbox entry" >&2
                ;;
        esac
    done

    # Connection dropped — reconnect after brief pause
    echo "[$(date)] Connection lost, reconnecting in 5s...${_since_param:+ (since=${_last_id})}" >&2
    sleep 5
done
