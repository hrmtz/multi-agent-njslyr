#!/bin/bash
# cron_status_push.sh — Collect agent status and push to Cloudflare KV
# Usage: * * * * * bash /path/to/cron_status_push.sh
#
# Reads tmux panes, task YAMLs, heartbeat YAMLs, and system load,
# then PUTs a JSON blob to Cloudflare KV (key: agent_status, TTL: 120s).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
LOGFILE="$PROJECT_ROOT/queue/logs/cron_status_push.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Load Cloudflare credentials
ENV_FILE="$PROJECT_ROOT/config/api_keys.env"
if [[ ! -f "$ENV_FILE" ]]; then
    log "ERROR: $ENV_FILE not found"
    exit 1
fi

# Source safely (grep to avoid non-ASCII issues)
eval "$(grep -E '^(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_KV_NAMESPACE_ID)=' "$ENV_FILE" | tr -d '\r')"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" || -z "${CLOUDFLARE_KV_NAMESPACE_ID:-}" ]]; then
    log "ERROR: Missing CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, or CLOUDFLARE_KV_NAMESPACE_ID in $ENV_FILE"
    exit 1
fi

# Collect hostname and timestamp
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TIMESTAMP_JST=$(TZ=Asia/Tokyo date '+%H:%M')

# Collect load average
LOAD_AVG=$(cut -d' ' -f1 /proc/loadavg)

# Collect tmux agent info (agent_id, command, model)
TMUX_DATA=""
if tmux has-session -t multiagent 2>/dev/null; then
    TMUX_DATA=$(tmux list-panes -a -F '#{@agent_id}|#{pane_current_command}|#{@model_name}' 2>/dev/null || echo "")
fi

# Collect task status from YAML files (simple grep, no yaml parser needed)
TASK_DATA=""
for f in "$PROJECT_ROOT"/queue/tasks/yakuza*.yaml "$PROJECT_ROOT"/queue/tasks/cmd_*.yaml; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f" .yaml)
    task_id=$(grep -oP 'task_id:\s*\K\S+' "$f" 2>/dev/null || echo "null")
    task_status=$(grep -oP 'status:\s*\K\S+' "$f" 2>/dev/null || echo "unknown")
    TASK_DATA+="${fname}|${task_id}|${task_status}"$'\n'
done

# Collect heartbeat data
HB_DATA=""
for f in "$PROJECT_ROOT"/queue/heartbeat/*.yaml; do
    [[ -f "$f" ]] || continue
    machine_id=$(grep -oP 'machine_id:\s*\K\S+' "$f" 2>/dev/null || echo "unknown")
    last_beat=$(grep -oP 'last_beat:\s*"\K[^"]+' "$f" 2>/dev/null || echo "")
    hb_st=$(grep -oP 'status:\s*\K\S+' "$f" 2>/dev/null || echo "unknown")
    hb_load=$(grep -oP 'load_avg:\s*\K\S+' "$f" 2>/dev/null || echo "")
    hb_context=$(grep -oP 'context_summary:\s*\K\S+' "$f" 2>/dev/null || echo "")
    HB_DATA+="${machine_id}|${last_beat}|${hb_st}|${hb_load}|${hb_context}"$'\n'
done

# Export variables for python3 subprocess
export HOSTNAME TIMESTAMP TIMESTAMP_JST LOAD_AVG TMUX_DATA TASK_DATA HB_DATA

# Build JSON with python3 (stdlib only)
JSON_PAYLOAD=$(python3 << 'PYEOF'
import json, sys, os

tmux_raw = os.environ.get("TMUX_DATA", "")
task_raw = os.environ.get("TASK_DATA", "")
hb_raw = os.environ.get("HB_DATA", "")

agents = []
for line in tmux_raw.strip().split("\n"):
    if not line.strip():
        continue
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    agent_id, cmd, model = parts[0].strip(), parts[1].strip(), parts[2].strip()
    if not agent_id:
        continue
    agents.append({
        "id": agent_id,
        "process": cmd,
        "model": model or None
    })

tasks = []
for line in task_raw.strip().split("\n"):
    if not line.strip():
        continue
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    fname, task_id, status = parts
    tasks.append({
        "file": fname.strip(),
        "task_id": task_id.strip() if task_id.strip() != "null" else None,
        "status": status.strip()
    })

heartbeats = []
for line in hb_raw.strip().split("\n"):
    if not line.strip():
        continue
    parts = line.split("|", 4)
    if len(parts) < 5:
        continue
    mid, lb, st, ld, ctx = parts
    heartbeats.append({
        "machine": mid.strip(),
        "last_beat": lb.strip(),
        "status": st.strip(),
        "load": ld.strip(),
        "context": ctx.strip()
    })

payload = {
    "hostname": os.environ.get("HOSTNAME", "unknown"),
    "timestamp": os.environ.get("TIMESTAMP", ""),
    "timestamp_jst": os.environ.get("TIMESTAMP_JST", ""),
    "load_avg": os.environ.get("LOAD_AVG", ""),
    "agents": agents,
    "tasks": tasks,
    "heartbeats": heartbeats
}

print(json.dumps(payload, ensure_ascii=False))
PYEOF
)

if [[ -z "$JSON_PAYLOAD" || "$JSON_PAYLOAD" == "null" ]]; then
    log "ERROR: Failed to build JSON payload"
    exit 1
fi

# PUT to Cloudflare KV
KV_URL="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/storage/kv/namespaces/${CLOUDFLARE_KV_NAMESPACE_ID}/values/agent_status"

HTTP_CODE=$(curl -s -o /tmp/cron_status_push_resp.txt -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-raw "$JSON_PAYLOAD" \
    "${KV_URL}?expiration_ttl=120")

if [[ "$HTTP_CODE" == "200" ]]; then
    log "OK: pushed agent_status (${#JSON_PAYLOAD} bytes)"
else
    RESP=$(cat /tmp/cron_status_push_resp.txt 2>/dev/null || echo "no response body")
    log "ERROR: KV PUT returned HTTP ${HTTP_CODE}: ${RESP}"
fi
