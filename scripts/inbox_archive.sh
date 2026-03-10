#!/bin/bash
# inbox_archive.sh — 既読メッセージを自動アーカイブ（排他ロック付き）
# Usage: bash scripts/inbox_archive.sh <agent_id> [--keep N]
# Example: bash scripts/inbox_archive.sh smith --keep 5

set -e

# macOS (Darwin): util-linux (flock) via Homebrew
if [[ "$(uname -s)" == "Darwin" ]]; then
    _HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
    export PATH="${_HOMEBREW_PREFIX}/opt/util-linux/bin:$PATH"
fi

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

# Parse arguments
AGENT_ID=""
KEEP=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            if [ -z "${2:-}" ]; then
                echo "ERROR: --keep requires a value" >&2
                exit 1
            fi
            KEEP="$2"
            shift 2
            ;;
        --keep=*)
            KEEP="${1#--keep=}"
            shift
            ;;
        -*)
            echo "ERROR: Unknown option '$1'" >&2
            exit 1
            ;;
        *)
            if [ -z "$AGENT_ID" ]; then
                AGENT_ID="$1"
            else
                echo "ERROR: Unexpected argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$AGENT_ID" ]; then
    echo "Usage: inbox_archive.sh <agent_id> [--keep N]" >&2
    echo "  agent_id: Agent ID (e.g. smith, yakuza1, soukaiya)" >&2
    echo "  --keep N: Number of recent read:true messages to keep (default: 5)" >&2
    exit 1
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --keep must be a non-negative integer, got '$KEEP'" >&2
    exit 1
fi

INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"
LOCKFILE="${INBOX}.lock"
ARCHIVE_DIR="$SCRIPT_DIR/queue/inbox/archive"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
ARCHIVE_FILE="${ARCHIVE_DIR}/${AGENT_ID}_${TIMESTAMP}.yaml"

# Inbox must exist
if [ ! -f "$INBOX" ]; then
    echo "[inbox_archive] No inbox found for '${AGENT_ID}' at $INBOX" >&2
    exit 0
fi

# Create archive directory if needed
mkdir -p "$ARCHIVE_DIR"

# Atomic archive with flock
attempt=0
max_attempts=5

_backoff_delays=("" "0.2" "0.4" "0.8" "1.6")
while [ $attempt -lt $max_attempts ]; do
    if (
        flock -w 5 200 || exit 1

        python3 -c "
import yaml, sys, os, tempfile

inbox_path = '$INBOX'
archive_path = '$ARCHIVE_FILE'
keep = int('$KEEP')

try:
    with open(inbox_path) as f:
        data = yaml.safe_load(f)

    if not data or not data.get('messages'):
        print('[inbox_archive] No messages to archive.', file=sys.stderr)
        sys.exit(0)

    messages = data['messages']

    # Separate read and unread
    unread = [m for m in messages if not m.get('read', False)]
    read = [m for m in messages if m.get('read', False)]

    # Determine messages to archive (read:true older than keep N)
    to_keep_read = read[-keep:] if keep > 0 else []
    # read[:-keep] returns [] when len(read) <= keep (Python negative-index edge case)
    to_archive = read[:-keep] if keep > 0 else read

    if not to_archive:
        print(f'[inbox_archive] Nothing to archive (read={len(read)}, keep={keep}).', file=sys.stderr)
        sys.exit(0)

    # Write archive file
    archive_data = {
        'agent_id': '$AGENT_ID',
        'archived_at': '$TIMESTAMP',
        'source': inbox_path,
        'messages': to_archive
    }
    with open(archive_path, 'w') as f:
        yaml.dump(archive_data, f, default_flow_style=False, allow_unicode=True, indent=2)

    # Rewrite inbox with unread + kept read messages
    data['messages'] = unread + to_keep_read

    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox_path), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox_path)
    except:
        os.unlink(tmp_path)
        raise

    print(f'[inbox_archive] Archived {len(to_archive)} messages → {archive_path}', file=sys.stderr)
    print(f'[inbox_archive] Inbox now has {len(unread)} unread + {len(to_keep_read)} kept read messages.', file=sys.stderr)

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || exit 1

    ) 200>"$LOCKFILE"; then
        exit 0
    else
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            # Exponential backoff (precomputed): 0.1s * 2^attempt
            backoff_delay="${_backoff_delays[$attempt]}"
            echo "[inbox_archive] Lock timeout for $INBOX (attempt $((attempt + 1))/$max_attempts), retrying in ${backoff_delay}s..." >&2
            sleep "$backoff_delay"
        else
            echo "[inbox_archive] FAILED to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
