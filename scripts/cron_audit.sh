#!/bin/bash
# cron_audit.sh — 4時間間隔でcrontab衛生チェック + ログ肥大の自動切り詰め
# Usage: 0 */4 * * * bash /home/hrmtz/project/multi-agent-njslyr/scripts/cron_audit.sh
#
# Checks:
#   1. Ghost entries: crontab行のスクリプトが存在しない
#   2. Duplicate entries: 同じスクリプトが複数回登録されている
#   3. Oversized logs: queue/logs/ 内の10MB超ファイルを5MBに切り詰め
#   4. Out-of-project entries: multi-agent-njslyr外を指すエントリ
#
# 問題検知時のみ darkninja inbox に報告。問題なければ何もしない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/*}"
LOGDIR="$PROJECT_ROOT/queue/logs"
LOGFILE="$LOGDIR/cron_audit.log"
LOG_SIZE_LIMIT=$((10 * 1024 * 1024))  # 10MB
LOG_TRIM_TO=5000                       # 切り詰め後の行数

ISSUES=()

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

log "=== cron_audit start ==="

# --- 1. Ghost entries: スクリプトファイルが存在しないcrontabエントリ ---
while IFS= read -r line; do
    # コメント行・空行をスキップ
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    # bash/sh で実行されるスクリプトパスを抽出
    script_path=""
    if [[ "$line" =~ bash[[:space:]]+([^[:space:]>]+) ]]; then
        script_path="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ sh[[:space:]]+([^[:space:]>]+) ]]; then
        script_path="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$script_path" && ! -f "$script_path" ]]; then
        ISSUES+=("GHOST: スクリプト不在 '$script_path' ← cron: ${line:0:80}")
        log "GHOST: $script_path not found"
    fi
done < <(crontab -l 2>/dev/null)

# --- 2. Duplicate entries: 同じスクリプトが複数回登録 ---
dupes=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | \
    sed -n 's/.*bash \([^ >]*\).*/\1/p' | sort | uniq -d)
if [[ -n "$dupes" ]]; then
    while IFS= read -r dup; do
        count=$(crontab -l 2>/dev/null | grep -c "$dup")
        ISSUES+=("DUPE: '$dup' が${count}回登録されている")
        log "DUPE: $dup x$count"
    done <<< "$dupes"
fi

# --- 3. Oversized logs: 10MB超のログを5000行に切り詰め（自動修復） ---
if [[ -d "$LOGDIR" ]]; then
    while IFS= read -r logpath; do
        filesize=$(stat -c%s "$logpath" 2>/dev/null || echo 0)
        if [[ "$filesize" -gt "$LOG_SIZE_LIMIT" ]]; then
            filename=$(basename "$logpath")
            size_mb=$(( filesize / 1024 / 1024 ))
            log "TRIM: $filename (${size_mb}MB) → ${LOG_TRIM_TO} lines"
            tail -n "$LOG_TRIM_TO" "$logpath" > "${logpath}.tmp" && mv "${logpath}.tmp" "$logpath"
            ISSUES+=("TRIMMED: ${filename} (${size_mb}MB→切り詰め済み)")
        fi
    done < <(find "$LOGDIR" -name "*.log" -type f 2>/dev/null)
fi

# --- 4. Out-of-project entries: multi-agent-njslyr外を指すエントリ ---
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    script_path=""
    if [[ "$line" =~ bash[[:space:]]+([^[:space:]>]+) ]]; then
        script_path="${BASH_REMATCH[1]}"
    fi

    # 相対パスの場合、同じcron行にcdでプロジェクトに移動していれば許可
    if [[ -n "$script_path" && ! "$script_path" =~ multi-agent-njslyr ]]; then
        if [[ ! "$script_path" =~ ^/ && "$line" =~ multi-agent-njslyr ]]; then
            : # 相対パス + cd先がプロジェクト内 → OK
        else
            ISSUES+=("EXTERNAL: プロジェクト外スクリプト '$script_path'")
            log "EXTERNAL: $script_path"
        fi
    fi
done < <(crontab -l 2>/dev/null)

# --- 結果判定 ---
if [[ ${#ISSUES[@]} -eq 0 ]]; then
    log "ALL CLEAR: 問題なし"
    log "=== cron_audit end ==="
    exit 0
fi

# --- 問題あり → darkninja inbox に報告 ---
REPORT="cron衛生チェック: ${#ISSUES[@]}件の問題検知。"
for issue in "${ISSUES[@]}"; do
    REPORT+=" | $issue"
done

# inbox_write が使えるか確認
if [[ -f "$SCRIPT_DIR/inbox_write.sh" ]]; then
    bash "$SCRIPT_DIR/inbox_write.sh" \
        darkninja \
        "$REPORT" \
        cron_audit_report \
        cron \
        "" \
        P2

    log "Report sent to darkninja inbox"

    # suriken で起こす（失敗しても続行）
    bash "$SCRIPT_DIR/njslyr_cmd.sh" suriken darkninja >> "$LOGFILE" 2>&1 || true
else
    log "WARNING: inbox_write.sh not found, report only in log"
fi

log "=== cron_audit end (${#ISSUES[@]} issues) ==="
