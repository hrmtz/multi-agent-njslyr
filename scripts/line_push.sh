#!/usr/bin/env bash
# line_push.sh — LINE push message to ラオモト
#
# Usage: bash scripts/line_push.sh "<message>"
#
# Required env vars (load from config/line.env or ~/.bashrc):
#   LINE_CHANNEL_ACCESS_TOKEN
#   LINE_USER_ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE_ENV_FILE="${SCRIPT_DIR}/../config/line.env"

# Load credentials from config/line.env if it exists
if [[ -f "${LINE_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${LINE_ENV_FILE}"
fi

# Validate arguments
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 \"<message>\"" >&2
  exit 1
fi

MESSAGE="$1"

# Validate required env vars
if [[ -z "${LINE_CHANNEL_ACCESS_TOKEN:-}" ]]; then
  echo "Error: LINE_CHANNEL_ACCESS_TOKEN is not set" >&2
  exit 1
fi

if [[ -z "${LINE_USER_ID:-}" ]]; then
  echo "Error: LINE_USER_ID is not set" >&2
  exit 1
fi

# Escape message for JSON (backslash, double-quote, newline)
ESCAPED_MESSAGE="${MESSAGE//\\/\\\\}"
ESCAPED_MESSAGE="${ESCAPED_MESSAGE//\"/\\\"}"
ESCAPED_MESSAGE="${ESCAPED_MESSAGE//$'\n'/\\n}"

JSON_BODY="{\"to\":\"${LINE_USER_ID}\",\"messages\":[{\"type\":\"text\",\"text\":\"${ESCAPED_MESSAGE}\"}]}"

# Send LINE push message
RESPONSE=$(curl --silent --show-error --fail \
  --request POST \
  --url "https://api.line.me/v2/bot/message/push" \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${LINE_CHANNEL_ACCESS_TOKEN}" \
  --data "${JSON_BODY}")

echo "${RESPONSE}"
