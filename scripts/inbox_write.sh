#!/bin/bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> [type] [from] [task_yaml_path] [priority]
# Example: bash scripts/inbox_write.sh gryakuza "ヤクザ5号、任務完了" report_received yakuza5 "" P1
# Example (task_assigned): bash scripts/inbox_write.sh yakuza3 "タスクYAML読んで作業開始" task_assigned gryakuza queue/tasks/yakuza3_subtask_237c.yaml P2

set -e

# macOS (Darwin): util-linux (flock) via Homebrew
if [[ "$(uname -s)" == "Darwin" ]]; then
    _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
    export PATH="${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
            if echo "$CONTENT" | grep -qi "BLOCKING"; then
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

# Generate unique message ID (timestamp-based)
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Atomic write with flock (exponential backoff: max 5 retries)
# Backoff delays: 0.1s, 0.2s, 0.4s, 0.8s (doubles each time)
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
    if (
        flock -w 5 200 || exit 1

        # Add message via python3 (unified YAML handling)
        python3 -c "
import yaml, sys

try:
    # Load existing inbox
    with open('$INBOX') as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message
    new_msg = {
        'id': '$MSG_ID',
        'from': '$FROM',
        'timestamp': '$TIMESTAMP',
        'type': '$TYPE',
        'priority': '$PRIORITY',
        'content': '''$CONTENT''',
        'read': False
    }
    # Add task_yaml_path if provided (for task_assigned messages)
    if '$TASK_YAML_PATH':
        new_msg['task_yaml_path'] = '$TASK_YAML_PATH'
    data['messages'].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages
        data['messages'] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile, os
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname('$INBOX'), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, '$INBOX')
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
            # Exponential backoff: 0.1s * 2^attempt
            # attempt=0 → 0.1s, attempt=1 → 0.2s, attempt=2 → 0.4s, attempt=3 → 0.8s
            backoff_delay=$(awk "BEGIN {print 0.1 * (2 ^ $attempt)}")
            echo "[inbox_write] Lock timeout for $INBOX (attempt $((attempt + 1))/$max_attempts), retrying in ${backoff_delay}s..." >&2
            sleep "$backoff_delay"
        else
            echo "[inbox_write] FAILED to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
