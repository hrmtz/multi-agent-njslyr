#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ntfy Input Listener
# Streams messages from ntfy topic, writes to inbox YAML, wakes darkninja.
# NOT polling — uses ntfy's streaming endpoint (long-lived HTTP connection).
# FR-066: ntfy認証対応 (Bearer token / Basic auth)
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"
TOPIC=$(awk '/ntfy_topic:/ {gsub(/"/, ""); print $2; exit}' "$SETTINGS")
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
# Output: <event><US><tags><US><message><US><id>  (US = ASCII unit separator 0x1f)
parse_message_fields() {
    python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print("\x1f".join([
        d.get("event", ""),
        ",".join(d.get("tags", [])),
        d.get("message", ""),
        d.get("id", "")
    ]))
except Exception:
    print("\x1f\x1f\x1f")' 2>/dev/null
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

# Graceful shutdown: log and exit cleanly on SIGTERM/SIGINT
cleanup() {
    echo "[$(date)] [ntfy_listener] shutting down (signal received)" >&2
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[$(date)] ntfy listener started — topic: $TOPIC (auth: ${NTFY_TOKEN:+token}${NTFY_USER:+basic}${NTFY_TOKEN:-${NTFY_USER:-none}})" >&2

while true; do
    # Stream new messages (long-lived connection, blocks until message arrives)
    curl -s --no-buffer "${AUTH_ARGS[@]}" "https://ntfy.sh/$TOPIC/json" 2>/dev/null | while IFS= read -r line; do
        # Parse all needed fields in a single python3 call
        IFS=$'\x1f' read -r EVENT TAGS MSG MSG_ID < <(parse_message_fields <<< "$line")

        # Skip keepalive pings and non-message events
        [[ "$EVENT" != "message" ]] && continue

        # Skip outbound messages (sent by our own scripts/ntfy.sh)
        [[ "$TAGS" == *outbound* ]] && continue

        # Skip empty messages
        [[ -z "$MSG" ]] && continue

        # %:z is GNU-only (+09:00). Use %z (+0900) and insert colon for portability.
        TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S%z")
        TIMESTAMP="${TIMESTAMP:0:-2}:${TIMESTAMP: -2}"

        echo "[$(date)] Received: $MSG" >&2

        # Append to inbox YAML (flock + atomic write; multiline-safe)
        if ! append_ntfy_inbox "$MSG_ID" "$TIMESTAMP" "$MSG"; then
            echo "[$(date)] [ntfy_listener] WARNING: failed to append ntfy_inbox entry" >&2
            continue
        fi

        # Wake darkninja via inbox (ntfy処理はダークニンジャが直接受信)
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" darkninja \
            "ntfyから新しいメッセージ受信。queue/ntfy_inbox.yaml を確認し処理せよ。" \
            ntfy_received ntfy_listener
    done

    # Connection dropped — reconnect after brief pause
    echo "[$(date)] Connection lost, reconnecting in 5s..." >&2
    sleep 5
done
