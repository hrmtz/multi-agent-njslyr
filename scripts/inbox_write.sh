#!/bin/bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> [type] [from] [task_yaml_path] [priority]
# Example: bash scripts/inbox_write.sh gryakuza "ヤクザ5号、任務完了" report_received yakuza5 "" P1
# Example (task_assigned): bash scripts/inbox_write.sh yakuza3 "タスクYAML読んで作業開始" task_assigned gryakuza queue/tasks/yakuza3_subtask_237c.yaml P2

# macOS SSH non-interactive shell PATH fix (Homebrew binaries not loaded by default)
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

set -e

# macOS (Darwin): util-linux (flock) via Homebrew
if [[ "$(uname -s)" == "Darwin" ]]; then
    _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
    export PATH="${_HOMEBREW_PREFIX}/bin:/usr/local/bin:${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
fi

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="${3:-wake_up}"
FROM="${4:-unknown}"
TASK_YAML_PATH="${5:-}"
PRIORITY_ARG="${6:-}"

# Type-based default priority mapping (if priority not explicitly provided)
if [ -z "$PRIORITY_ARG" ]; then
    case "$TYPE" in
        cmd_new)
            PRIORITY="P0"  # Raomoto directive = highest priority
            ;;
        report_received)
            # Check for BLOCKING keyword in content
            if [[ "$CONTENT" =~ [Bb][Ll][Oo][Cc][Kk][Ii][Nn][Gg] ]]; then
                PRIORITY="P0"  # BLOCKING issue = emergency
            else
                PRIORITY="P1"  # Normal QC result = high priority
            fi
            ;;
        task_assigned|clear_command|model_switch)
            PRIORITY="P2"  # Normal operational tasks
            ;;
        *)
            PRIORITY="P3"  # Info sharing, proposals, etc.
            ;;
    esac
else
    PRIORITY="$PRIORITY_ARG"
fi

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> [type] [from] [task_yaml_path] [priority]" >&2
    exit 1
fi

# Validate priority
case "$PRIORITY" in
    P0|P1|P2|P3)
        # Valid priority
        ;;
    *)
        echo "ERROR: Invalid priority '$PRIORITY'. Must be P0, P1, P2, or P3." >&2
        exit 1
        ;;
esac

# Initialize inbox if not exists
if [ ! -f "$INBOX" ]; then
    mkdir -p "$(dirname "$INBOX")"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp-based; single date fork, printf builtin for rand)
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")
printf -v _rand '%04x%04x' "$RANDOM" "$RANDOM"
MSG_ID="msg_${TIMESTAMP//[^0-9]/}_${_rand}"

# Atomic write with flock (exponential backoff: max 5 retries)
# Backoff delays: 0.1s, 0.2s, 0.4s, 0.8s (doubles each time)
attempt=0
max_attempts=5

_backoff_delays=("" "0.2" "0.4" "0.8" "1.6")
while [ $attempt -lt $max_attempts ]; do
    if (
        flock -w 5 200 || exit 1

        # Add message via python3 (unified YAML handling)
        # Pass user-controlled strings via env vars to avoid shell injection
        INBOX_PATH="$INBOX" INBOX_CONTENT="$CONTENT" INBOX_TASK_YAML="$TASK_YAML_PATH" \
        INBOX_MSG_ID="$MSG_ID" INBOX_FROM="$FROM" INBOX_TIMESTAMP="$TIMESTAMP" \
        INBOX_TYPE="$TYPE" INBOX_PRIORITY="$PRIORITY" \
        python3 -c "
import yaml, sys, os, tempfile

try:
    inbox_path = os.environ['INBOX_PATH']

    # Load existing inbox
    with open(inbox_path) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message (all fields via env vars — safe from shell injection)
    new_msg = {
        'id': os.environ['INBOX_MSG_ID'],
        'from': os.environ['INBOX_FROM'],
        'timestamp': os.environ['INBOX_TIMESTAMP'],
        'type': os.environ['INBOX_TYPE'],
        'priority': os.environ['INBOX_PRIORITY'],
        'content': os.environ['INBOX_CONTENT'],
        'read': False
    }
    # Add task_yaml_path if provided (for task_assigned messages)
    task_yaml = os.environ.get('INBOX_TASK_YAML', '')
    if task_yaml:
        new_msg['task_yaml_path'] = task_yaml
    data['messages'].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages
        data['messages'] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox_path), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox_path)
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || exit 1

    ) 200>"$LOCKFILE"; then
        # Success
        echo "[inbox_write] Message written to $INBOX (attempt $((attempt + 1)))" >&2
        exit 0
    else
        # Lock timeout or error
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            # Exponential backoff (precomputed): 0.1s * 2^attempt
            backoff_delay="${_backoff_delays[$attempt]}"
            echo "[inbox_write] Lock timeout for $INBOX (attempt $((attempt + 1))/$max_attempts), retrying in ${backoff_delay}s..." >&2
            sleep "$backoff_delay"
        else
            echo "[inbox_write] FAILED to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
