#!/usr/bin/env bash
# ssh_tailscale_sync.sh — Tailscale IP → ~/.ssh/config 自動同期
# WSL2ではtailscaleコマンドがWindows側なので cmd.exe 経由で取得
# Usage: bash scripts/ssh_tailscale_sync.sh [--check]

set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"

# Tailscale host→SSH Host mapping
declare -A HOSTS=(
  [peer-hostname]="hrmtz"
  [example-nas]="nkmr"
)

# SSH options per host (example-nas has IdentityFile)
declare -A EXTRA_OPTS=(
  [example-nas]="    IdentityFile ~/.ssh/id_ed25519_nas
    IdentitiesOnly yes"
)

get_tailscale_ip() {
  local hostname="$1"
  local ip=""

  # Try WSL2 path (Windows tailscale)
  if command -v /mnt/c/Windows/System32/cmd.exe &>/dev/null; then
    ip=$(/mnt/c/Windows/System32/cmd.exe /c "tailscale status" 2>/dev/null \
      | tr -d '\r' \
      | grep -w "$hostname" \
      | awk '{print $1}')
  fi

  # Fallback: native tailscale
  if [ -z "$ip" ] && command -v tailscale &>/dev/null; then
    ip=$(tailscale status 2>/dev/null \
      | grep -w "$hostname" \
      | awk '{print $1}')
  fi

  echo "$ip"
}

check_only=false
if [ "${1:-}" = "--check" ]; then
  check_only=true
fi

changes=0

for ts_host in "${!HOSTS[@]}"; do
  user="${HOSTS[$ts_host]}"
  new_ip=$(get_tailscale_ip "$ts_host")

  if [ -z "$new_ip" ]; then
    echo "WARN: $ts_host not found in tailscale status (offline?)"
    continue
  fi

  # Get current IP from SSH config
  current_ip=$(tr -d '\r' < "$SSH_CONFIG" 2>/dev/null \
    | grep -A10 "^Host ${ts_host}$" \
    | grep "HostName" | head -1 | awk '{print $2}' || true)

  if [ "$current_ip" = "$new_ip" ]; then
    echo "OK: $ts_host → $new_ip (unchanged)"
  else
    echo "UPDATE: $ts_host → $new_ip (was: ${current_ip:-MISSING})"
    changes=$((changes + 1))

    if [ "$check_only" = false ]; then
      # Remove old entry
      if grep -q "Host ${ts_host}$" "$SSH_CONFIG" 2>/dev/null; then
        # Delete from "Host <name>" to next "Host " or EOF
        sed -i "/^Host ${ts_host}$/,/^Host /{/^Host ${ts_host}$/d;/^Host /!d}" "$SSH_CONFIG"
        # Clean up any trailing empty lines
        sed -i '/^$/N;/^\n$/d' "$SSH_CONFIG"
      fi

      # Append new entry
      extra="${EXTRA_OPTS[$ts_host]:-}"
      cat >> "$SSH_CONFIG" << ENTRY

Host ${ts_host}
    HostName ${new_ip}
    User ${user}
${extra:+${extra}
}    ControlMaster auto
    ControlPath ~/.ssh/cm_%r@%h:%p
    ControlPersist 600
    ServerAliveInterval 30
    ServerAliveCountMax 3
ENTRY
      echo "  → ~/.ssh/config updated"

      # Kill stale control sockets
      rm -f "$HOME/.ssh/cm_"*"${ts_host}"* 2>/dev/null || true
    fi
  fi
done

if [ $changes -eq 0 ]; then
  echo "No changes needed."
else
  echo "$changes host(s) updated."
fi
