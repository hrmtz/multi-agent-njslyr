#!/bin/bash
# line_image_download.sh — Download LINE content (image/video/file) by messageId
# Usage: bash scripts/line_image_download.sh <messageId> [mediaType] [fileName]
# Saves to reel/line_images/ with timestamp prefix
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_KEYS_ENV="${SCRIPT_DIR}/config/api_keys.env"
SAVE_DIR="${SCRIPT_DIR}/reel/line_images"
mkdir -p "$SAVE_DIR"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <messageId> [mediaType] [fileName]" >&2
    exit 1
fi

MESSAGE_ID="$1"
MEDIA_TYPE="${2:-image}"
FILE_NAME="${3:-}"

# Load LINE token
if [[ -f "$API_KEYS_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$API_KEYS_ENV"
fi
if [[ -z "${LINE_CHANNEL_ACCESS_TOKEN:-}" ]]; then
    echo "[line_image_download] ERROR: LINE_CHANNEL_ACCESS_TOKEN not set" >&2
    exit 1
fi

# Determine extension
case "$MEDIA_TYPE" in
    image) EXT="jpg" ;;
    video) EXT="mp4" ;;
    file)  EXT="${FILE_NAME##*.}" ; EXT="${EXT:-bin}" ;;
    *)     EXT="bin" ;;
esac

# Use original filename if provided, otherwise generate from timestamp+messageId
if [[ -n "$FILE_NAME" ]]; then
    OUTFILE="${SAVE_DIR}/$(date '+%Y%m%d_%H%M%S')_${FILE_NAME}"
else
    OUTFILE="${SAVE_DIR}/$(date '+%Y%m%d_%H%M%S')_${MESSAGE_ID}.${EXT}"
fi

# Download from LINE Content API
HTTP_CODE=$(curl -s -o "$OUTFILE" -w "%{http_code}" \
    -H "Authorization: Bearer ${LINE_CHANNEL_ACCESS_TOKEN}" \
    "https://api-data.line.me/v2/bot/message/${MESSAGE_ID}/content")

if [[ "$HTTP_CODE" -eq 200 ]]; then
    FILE_SIZE=$(stat -c %s "$OUTFILE" 2>/dev/null || echo "?")
    echo "[line_image_download] OK: ${OUTFILE} (${FILE_SIZE} bytes)" >&2
    echo "$OUTFILE"
else
    rm -f "$OUTFILE"
    echo "[line_image_download] ERROR: HTTP ${HTTP_CODE} for messageId=${MESSAGE_ID}" >&2
    exit 1
fi
