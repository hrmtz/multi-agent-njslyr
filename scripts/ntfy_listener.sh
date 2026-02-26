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
#   handover:ryzen|mbp         → active_machine.yaml update + gryakuza P0 notify
#   hb:host:epoch:agents:load:ctx → heartbeat (heartbeat topic only)
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
MACHINE_ROLE="${MACHINE_ROLE:-ryzen}"
INBOX="$SCRIPT_DIR/queue/ntfy_inbox.yaml"
LOCKFILE="${INBOX}.lock"
CORRUPT_DIR="$SCRIPT_DIR/logs/ntfy_inbox_corrupt"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

if [[ -z "$TOPIC" ]]; then
    echo "[ntfy_listener] ntfy_topic not configured in settings.yaml" >&2
    exit 1
fi

# トピック名セキュリティ検証
ntfy_validate_topic "$TOPIC" || true

# Multi-topic subscription: {base},{base}-heartbeat,{base}-{role}
SUBSCRIBE_TOPICS="${TOPIC},${TOPIC}-heartbeat,${TOPIC}-${MACHINE_ROLE}"

# Initialize inbox if not exists
if [[ ! -f "$INBOX" ]]; then
    echo "inbox:" > "$INBOX"
fi

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

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

    _run_locked() {
        NTFY_INBOX_PATH="$INBOX" \
        NTFY_CORRUPT_DIR="$CORRUPT_DIR" \
        MSG_ID="$msg_id" \
        MSG_TS="$ts" \
        MSG_TEXT="$msg" \
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
    "status": "pending",
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
    if [[ "$target" != "ryzen" && "$target" != "mbp" ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid handover target: $target" >&2
        return 1
    fi
    local am_file="$SCRIPT_DIR/queue/active_machine.yaml"
    local ts tz_len
    ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
    tz_len=${#ts}
    ts="${ts:0:$((tz_len-2))}:${ts:$((tz_len-2))}"
    # Atomic write via temp file
    local tmp_file
    tmp_file=$(mktemp "${am_file}.XXXXXX")
    cat > "$tmp_file" << EOF
active_machine: $target
since: "$ts"
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

    # Input validation: host must be alphanumeric/underscore/hyphen only (path traversal防止)
    if [[ ! "$host" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[$(date)] [ntfy_listener] WARNING: invalid heartbeat host: ${host:0:50}" >&2
        return 1
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
}

# Route message by prefix. Returns 0 if handled, 1 if fallback needed.
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
        *)
            # Unknown prefix or no prefix → fallback to original behavior
            echo "[$(date)] [ntfy_listener] unrecognized prefix, fallback to darkninja: ${msg:0:80}" >&2
            return 1
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
echo "[$(date)] ntfy listener started — topics: $SUBSCRIBE_TOPICS role: $MACHINE_ROLE (auth: $_auth_type)" >&2
unset _auth_type

while true; do
    # Stream new messages from multiple topics (long-lived connection)
    curl -s --no-buffer "${AUTH_ARGS[@]}" "https://ntfy.sh/$SUBSCRIBE_TOPICS/json" 2>/dev/null | while IFS= read -r line; do
        # Parse all needed fields in a single python3 call (including topic)
        IFS=$'\x1f' read -r EVENT TAGS MSG MSG_ID MSG_TOPIC < <(parse_message_fields <<< "$line")

        # Skip keepalive pings and non-message events
        [[ "$EVENT" != "message" ]] && continue

        # Skip outbound messages (sent by our own scripts/ntfy.sh)
        [[ "$TAGS" == *outbound* ]] && continue

        # Skip empty messages
        [[ -z "$MSG" ]] && continue

        # %:z is GNU-only (+09:00). Use %z (+0900) and insert colon for portability.
        TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S%z")
        _ts_len=${#TIMESTAMP}
        TIMESTAMP="${TIMESTAMP:0:$((_ts_len-2))}:${TIMESTAMP:$((_ts_len-2))}"

        echo "[$(date)] Received [$MSG_TOPIC]: $MSG" >&2

        # Route by prefix. Heartbeat messages skip ntfy_inbox entirely.
        if route_message "$MSG" "$MSG_TOPIC"; then
            # Known prefix handled — skip ntfy_inbox for heartbeat topic
            if [[ "$MSG_TOPIC" != *-heartbeat ]]; then
                # Non-heartbeat routed messages: still record in ntfy_inbox for audit
                append_ntfy_inbox "$MSG_ID" "$TIMESTAMP" "$MSG" || \
                    echo "[$(date)] [ntfy_listener] WARNING: failed to append ntfy_inbox entry" >&2
            fi
        else
            # Unknown prefix — original behavior: ntfy_inbox + darkninja
            if ! append_ntfy_inbox "$MSG_ID" "$TIMESTAMP" "$MSG"; then
                echo "[$(date)] [ntfy_listener] WARNING: failed to append ntfy_inbox entry" >&2
                continue
            fi
            bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
                "ntfyから新しいメッセージ受信。queue/ntfy_inbox.yaml を確認し処理せよ。" \
                ntfy_received ntfy_listener
        fi
    done

    # Connection dropped — reconnect after brief pause
    echo "[$(date)] Connection lost, reconnecting in 5s..." >&2
    sleep 5
done
