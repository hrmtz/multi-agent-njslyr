#!/usr/bin/env bash
# ssh_fallback.sh — SSH接続共通ライブラリ
# cmd_298: SSHを第一級通信手段として公式化
#
# 提供変数:
#   SSH_OPTS — ssh接続オプション（タイムアウト, キー確認, バッチモード）
#
# 提供関数:
#   _ssh_get_peer_host      → settings.yamlからpeerホスト名取得
#   _ssh_get_peer_project   → settings.yamlからpeerプロジェクトルート取得
#   ssh_send_suriken <agent_id> → SSH経由でリモートsuriken送信

# SSH接続オプション（共通）
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# settings.yaml パス解決
_ssh_settings_yaml() {
    echo "${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/config/settings.yaml"
}

# settings.yaml から peer_host 読み込み
_ssh_get_peer_host() {
    awk '/^  peer_host:/ {print $2; exit}' "$(_ssh_settings_yaml)" 2>/dev/null
}

# settings.yaml から peer_project_root 読み込み
_ssh_get_peer_project() {
    awk '/^  peer_project_root:/ {print $2; exit}' "$(_ssh_settings_yaml)" 2>/dev/null
}

# SSH経由でリモートsuriken送信
# 引数: agent_id (必須)
# 戻り値: 0=成功, 1=失敗（peer情報なし or SSH接続失敗）
ssh_send_suriken() {
    local agent_id="$1"
    # agent_id validation: リモートコマンドインジェクション防御
    # 許可パターン: [a-z0-9_]+ のみ（例: yakuza3, smith, master_tortoise）
    if [[ ! "$agent_id" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ssh_fallback] REJECTED: invalid agent_id '$agent_id' (must match [a-z0-9_]+)" >&2
        return 1
    fi
    local peer_host peer_project
    peer_host=$(_ssh_get_peer_host)
    peer_project=$(_ssh_get_peer_project)
    [[ -z "$peer_host" || -z "$peer_project" ]] && return 1
    # NJSLYR_SSH_DEPTH=1: 再帰防止ガード (FIX-LBUG-001)
    # リモート側cmd_suriken()冒頭でdepth>=1なら即return 1（無限ループ防止）
    # shellcheck disable=SC2086
    NJSLYR_SSH_DEPTH=1 ssh $SSH_OPTS "$peer_host" \
        "cd '$peer_project' && NJSLYR_SSH_DEPTH=1 bash scripts/njslyr_cmd.sh suriken '$agent_id'" 2>&1
}
