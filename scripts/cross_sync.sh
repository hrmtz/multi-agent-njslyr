#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# cross_sync.sh — Cross-machine rsync synchronization
#
# Syncs state YAML and MCP memory between Ryzen and MBP via Tailscale.
# Code is synced via git (not rsync). Machine-local files are excluded.
#
# Usage: bash scripts/cross_sync.sh push|pull
#
# Sync categories:
#   Code:          git push/pull (NOT handled here)
#   State YAML:    queue/tasks/, queue/reports/, dashboard.md
#   MCP memory:    ~/.claude/projects/.../memory/ (Ryzen→MBP one-way)
#   Not synced:    queue/inbox/, .state/, logs/, queue/heartbeat/
#
# Prerequisites:
#   - Tailscale connected (tailscale ping check)
#   - config/settings.yaml: machine.role, peer_host, peer_project_root
#   - rsync installed on both machines
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"
LOCKFILE="$SCRIPT_DIR/.state/njslyr_sync.lock"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/cross_sync.log"
LOG_TAG="[cross_sync]"
MAX_RETRIES=3
RETRY_INTERVAL=5

# ─── Read configuration ───────────────────────────────────────

MACHINE_ROLE=$(awk '/^  role:/ {print $2; exit}' "$SETTINGS")
PEER_HOST=$(awk '/^  peer_host:/ {print $2; exit}' "$SETTINGS")
PEER_PROJECT_ROOT=$(awk '/^  peer_project_root:/ {print $2; exit}' "$SETTINGS")

MACHINE_ROLE="${MACHINE_ROLE:-ryzen}"

# ─── Input validation (SEC-001) ──────────────────────────────
# Validate settings.yaml-derived values to prevent shell injection / path traversal

if [[ -z "$PEER_HOST" ]] || [[ ! "$PEER_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "$LOG_TAG ERROR: Invalid PEER_HOST: '$PEER_HOST'" >&2
    exit 1
fi
if [[ -z "$PEER_PROJECT_ROOT" ]] || [[ ! "$PEER_PROJECT_ROOT" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || [[ "$PEER_PROJECT_ROOT" == *..* ]]; then
    echo "$LOG_TAG ERROR: Invalid PEER_PROJECT_ROOT: '$PEER_PROJECT_ROOT'" >&2
    exit 1
fi

# ─── Cleanup trap for temp files ─────────────────────────────
# Track all temp files created during execution; clean on EXIT
_CROSS_SYNC_TMPFILES=()
_cross_sync_cleanup() {
    for f in ${_CROSS_SYNC_TMPFILES[@]:+"${_CROSS_SYNC_TMPFILES[@]}"}; do
        rm -f "$f" 2>/dev/null
    done
}
trap _cross_sync_cleanup EXIT

# ─── Subcommand validation ────────────────────────────────────

SUBCMD="${1:-}"
if [[ "$SUBCMD" != "push" && "$SUBCMD" != "pull" ]]; then
    echo "Usage: $0 push|pull" >&2
    echo "  push  — Sync local state to peer machine" >&2
    echo "  pull  — Sync peer state to local machine" >&2
    exit 1
fi

# ─── Rsync excludes ───────────────────────────────────────────

RSYNC_EXCLUDES=(
    ".git/"
    "queue/inbox/"         # machine-local (agent-specific)
    "queue/heartbeat/"     # machine-local (heartbeat YAML)
    ".state/"              # machine-local (locks, state files)
    "logs/"                # machine-local (log files)
    "node_modules/"
    "*.lock"               # flock lock files
    "projects/"            # git-ignored secrets
    ".claude/"             # CLI local settings
    "queue/archive/"       # archived old data
    "queue/metrics/"       # local metrics
    "queue/logs/"          # queue logs
)

# Build rsync exclude args
EXCLUDE_ARGS=()
for excl in "${RSYNC_EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=("--exclude=$excl")
done

# ─── Rsync paths for state YAML ───────────────────────────────

# State YAML sync targets (relative to project root)
STATE_PATHS=(
    "queue/tasks/"
    "queue/reports/"
    "dashboard.md"
    "queue/active_machine.yaml"
)

# MCP memory path (Ryzen→MBP one-way only) — dynamically resolved from project root
_mcp_project_slug=$(echo "$SCRIPT_DIR" | sed 's|^/||; s|/|-|g')
MCP_MEMORY_DIR="$HOME/.claude/projects/-${_mcp_project_slug}/memory/"

# ─── Helper functions ──────────────────────────────────────────

log_info() {
    echo "[$(date)] $LOG_TAG $*" >&2
}

log_warn() {
    echo "[$(date)] $LOG_TAG WARNING: $*" >&2
}

log_error() {
    echo "[$(date)] $LOG_TAG ERROR: $*" >&2
}

# Notify via ntfy on critical failure
ntfy_notify_failure() {
    local msg="$1"
    local ntfy_script="$SCRIPT_DIR/scripts/ntfy.sh"
    if [[ -x "$ntfy_script" ]]; then
        bash "$ntfy_script" "$LOG_TAG $msg" 2>/dev/null || true
    fi
}

# Check Tailscale connectivity to peer
check_tailscale() {
    log_info "Checking Tailscale connectivity to $PEER_HOST..."
    if ! command -v tailscale &>/dev/null; then
        log_error "tailscale command not found"
        return 1
    fi
    if ! tailscale ping --timeout=5s "$PEER_HOST" &>/dev/null; then
        log_error "Tailscale ping to $PEER_HOST failed — peer unreachable"
        return 1
    fi
    log_info "Tailscale connectivity OK"
    return 0
}

# Run rsync with retry logic
# Args: source_path dest_path [extra_rsync_args...]
rsync_with_retry() {
    local src="$1"
    local dest="$2"
    shift 2
    local extra_args=("$@")
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        attempt=$((attempt + 1))
        log_info "rsync attempt $attempt/$MAX_RETRIES: $src → $dest"
        # bash 3.x safe: ${extra_args[@]:+...} avoids unbound variable on empty array
        # stderr→ログファイル保持（完全抑制せず、失敗時の診断情報を残す）
        if rsync -avz --timeout=30 \
            -e "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
            "${EXCLUDE_ARGS[@]}" \
            ${extra_args[@]:+"${extra_args[@]}"} \
            "$src" "$dest" 2>>"$LOG_FILE" | \
            while IFS= read -r line; do log_info "  rsync: $line"; done; then
            log_info "rsync succeeded (attempt $attempt)"
            return 0
        fi
        if (( attempt < MAX_RETRIES )); then
            log_warn "rsync failed, retrying in ${RETRY_INTERVAL}s..."
            sleep "$RETRY_INTERVAL"
        fi
    done

    log_error "rsync failed after $MAX_RETRIES attempts: $src → $dest"
    return 1
}

# ─── Sync operations ──────────────────────────────────────────

# Sync state YAML files (push: local→peer, pull: peer→local)
sync_state_yaml() {
    local direction="$1"
    local failed=0

    for path in "${STATE_PATHS[@]}"; do
        local local_path="$SCRIPT_DIR/$path"
        local remote_path="$PEER_HOST:$PEER_PROJECT_ROOT/$path"

        # Skip if local source doesn't exist (for push)
        if [[ "$direction" == "push" && ! -e "$local_path" ]]; then
            log_warn "Skipping $path — local path not found"
            continue
        fi

        if [[ "$direction" == "push" ]]; then
            rsync_with_retry "$local_path" "$remote_path" || failed=1
        else
            # For pull, ensure local directory exists for directory targets
            if [[ "$path" == */ ]]; then
                mkdir -p "$local_path"
            fi
            rsync_with_retry "$remote_path" "$local_path" || failed=1
        fi
    done

    return "$failed"
}

# Sync MCP memory (Ryzen→MBP one-way only)
sync_mcp_memory() {
    local direction="$1"

    # MCP memory is always Ryzen→MBP (Ryzen=master)
    # Remote MCP path: derive slug from PEER_PROJECT_ROOT, use ~ for remote home expansion
    local _peer_slug
    _peer_slug=$(echo "$PEER_PROJECT_ROOT" | sed 's|^/||; s|/|-|g')
    local remote_mcp="$PEER_HOST:~/.claude/projects/-${_peer_slug}/memory/"

    if [[ "$direction" == "push" && "$MACHINE_ROLE" == "ryzen" ]]; then
        if [[ ! -d "$MCP_MEMORY_DIR" ]]; then
            log_warn "MCP memory directory not found: $MCP_MEMORY_DIR — skipping"
            return 0
        fi
        rsync_with_retry "$MCP_MEMORY_DIR" "$remote_mcp" || return 1
    elif [[ "$direction" == "pull" && "$MACHINE_ROLE" == "mbp" ]]; then
        mkdir -p "$MCP_MEMORY_DIR"
        rsync_with_retry "$remote_mcp" "$MCP_MEMORY_DIR" || return 1
    else
        log_info "MCP memory sync skipped (role=$MACHINE_ROLE direction=$direction — Ryzen=master)"
    fi
    return 0
}

# ─── Main execution ───────────────────────────────────────────

main() {
    log_info "Starting cross_sync: $SUBCMD (role=$MACHINE_ROLE peer=$PEER_HOST)"

    # Ensure directories exist for lock file and log file
    mkdir -p "$(dirname "$LOCKFILE")"
    mkdir -p "$LOG_DIR"

    # Tailscale connectivity check
    if ! check_tailscale; then
        ntfy_notify_failure "$SUBCMD failed: Tailscale unreachable ($PEER_HOST)"
        exit 1
    fi

    local sync_failed=0

    # Sync state YAML
    log_info "=== Syncing state YAML ($SUBCMD) ==="
    if ! sync_state_yaml "$SUBCMD"; then
        log_error "State YAML sync failed"
        sync_failed=1
    fi

    # Sync MCP memory
    log_info "=== Syncing MCP memory ($SUBCMD) ==="
    if ! sync_mcp_memory "$SUBCMD"; then
        log_error "MCP memory sync failed"
        sync_failed=1
    fi

    if (( sync_failed )); then
        ntfy_notify_failure "$SUBCMD partially failed — check logs"
        log_error "cross_sync $SUBCMD completed with errors"
        exit 1
    fi

    log_info "cross_sync $SUBCMD completed successfully"
}

# flock to prevent concurrent rsync (D009: lock in .state/, not /tmp/)
if command -v flock &>/dev/null; then
    mkdir -p "$(dirname "$LOCKFILE")"
    (
        if ! flock -n 200; then
            echo "$LOG_TAG ERROR: another cross_sync is already running" >&2
            exit 1
        fi
        main
    ) 200>"$LOCKFILE"
else
    # macOS fallback: mkdir-based lock
    LOCK_DIR="${LOCKFILE}.d"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$LOG_TAG ERROR: another cross_sync is already running" >&2
        exit 1
    fi
    # shellcheck disable=SC2064
    trap "_cross_sync_cleanup; rmdir '$LOCK_DIR' 2>/dev/null" EXIT
    main
fi
