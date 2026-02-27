#!/bin/bash
# multi-agent-shogun ネオサイタマ・デプロイメント・スクリプト（毎日の起動用）
# Daily Deployment Script for Multi-Agent Orchestration System
#
# 使用方法:
#   ./yokubari.sh           # 全エージェント起動（前回の状態を維持）
#   ./yokubari.sh -c        # キューをリセットして起動（クリーンスタート）
#   ./yokubari.sh -s        # セットアップのみ（Claude起動なし）
#   ./yokubari.sh -h        # ヘルプ表示

set -e

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# 並行起動防止（flock）
# ═══════════════════════════════════════════════════════════════════════════════
LOCKFILE="$SCRIPT_DIR/.yokubari.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "グワーッ！yokubari.sh は既に実行中！二重起動はケジメ案件！" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# trap/cleanup: 中断時のリソース解放
# ═══════════════════════════════════════════════════════════════════════════════
_cleanup() {
    local exit_code=$?
    # ロックファイル解放（fd 9 はプロセス終了時に自動クローズ）
    rm -f "$LOCKFILE"
    # バックグラウンドジョブがあれば待機（中断シグナルで残らないように）
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    exit "$exit_code"
}
trap _cleanup EXIT INT TERM

# macOS (Darwin): GNU coreutils via Homebrew gnubin + Claude Code CLI
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"
fi
# Linux/WSL: Claude Code CLI (~/.local/bin)
if [[ "$(uname -s)" == "Linux" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# 言語・シェル設定を読み取り（設定ファイル1回読み・fork 0で全キー抽出）
LANG_SETTING="ja"
SHELL_SETTING="bash"
NTFY_TOPIC=""
if [ -f "./config/settings.yaml" ]; then
    while read -r line; do
        case "$line" in
            language:*) LANG_SETTING="${line#*: }" ;;
            shell:*) SHELL_SETTING="${line#*: }" ;;
            ntfy_topic:*) NTFY_TOPIC="${line#*: }"; NTFY_TOPIC="${NTFY_TOPIC//\"/}" ;;
        esac
    done < ./config/settings.yaml
fi
# 空文字列ガード
LANG_SETTING="${LANG_SETTING:-ja}"
SHELL_SETTING="${SHELL_SETTING:-bash}"

# マシンロール読み取り（kyoto: フル構成9体, neosaitama: フル構成9体）
MACHINE_ROLE=""
if [ -f "./config/settings.yaml" ]; then
    MACHINE_ROLE=$(awk '/^  role:/{print $2}' ./config/settings.yaml 2>/dev/null)
fi
MACHINE_ROLE="${MACHINE_ROLE:-kyoto}"

# neosaitama: Kyoto SSH接続設定（cmd_287）
KYOTO_SSH_PORT="${KYOTO_SSH_PORT:-2200}"
KYOTO_HOST="${KYOTO_HOST:-peer-hostname}"

# マシンロール依存の早期定義（CLEAN_MODEブロックで使用されるため、STEP 5より前に必要）
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    YAKUZA_MAX=7
    MONITOR_AGENT="master_crane"
else
    YAKUZA_MAX=7
    MONITOR_AGENT="master_tortoise"
fi

# CLI Adapter読み込み（Multi-CLI Support）
if [ -f "$SCRIPT_DIR/lib/cli_adapter.sh" ]; then
    source "$SCRIPT_DIR/lib/cli_adapter.sh"
    CLI_ADAPTER_LOADED=true
else
    CLI_ADAPTER_LOADED=false
fi

# 暗黒メガコーポ名リスト（グレーターヤクザの所属企業をランダム選出）
MEGACORPS=(
    "オムラ・インダストリ"
    "ヨロシサン製薬"
    "ヨロシ・バイオサイバネティカ社"
    "スゴイテック社"
    "オナタカミ社"
    "ドンブリ・ポン社"
    "マグロアンドドラゴン社"
    "アサノサン・パワーズ社"
    "オムラ・メディテック社"
    "オモテ社"
    "コヨミ・エンタープライズ社"
    "サイサムラINC"
    "メガロ・キモチ社"
    "ヤサシイ・サイバーウェア社"
    "カタナ・オブ・リバプール社"
    "メガトリイ社"
    "ポンポン・エンタープライズ社"
    "モーモーバイオジェネティクス社"
    "チャノマ・コンフォーツ社"
)
GRYAKUZA_CORP="${MEGACORPS[$((RANDOM % ${#MEGACORPS[@]}))]}"

# 色付きログ関数（忍殺風）
log_info() {
    echo -e "\033[1;33m【IRC】\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m【実際完了】\033[0m $1"
}

log_war() {
    echo -e "\033[1;31m【カラテ】\033[0m $1" >&2
}

# ═══════════════════════════════════════════════════════════════════════════════
# プロンプト生成関数（bash/zsh対応）
# ───────────────────────────────────────────────────────────────────────────────
# 使用法: generate_prompt "ラベル" "色" "シェル"
# 色: red, green, blue, magenta, cyan, yellow
# ═══════════════════════════════════════════════════════════════════════════════
generate_prompt() {
    local label="$1"
    local color="$2"
    local shell_type="$3"

    if [ "$shell_type" == "zsh" ]; then
        # zsh用: %F{color}%B...%b%f 形式
        echo "(%F{${color}}%B${label}%b%f) %F{green}%B%~%b%f%# "
    else
        # bash用: \[\033[...m\] 形式
        local color_code
        case "$color" in
            red)     color_code="1;31" ;;
            green)   color_code="1;32" ;;
            yellow)  color_code="1;33" ;;
            blue)    color_code="1;34" ;;
            magenta) color_code="1;35" ;;
            cyan)    color_code="1;36" ;;
            *)       color_code="1;37" ;;  # white (default)
        esac
        echo "(\[\033[${color_code}m\]${label}\[\033[0m\]) \[\033[1;32m\]\w\[\033[0m\]\$ "
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# オプション解析
# ═══════════════════════════════════════════════════════════════════════════════
SETUP_ONLY=false
OPEN_TERMINAL=false
CLEAN_MODE=false
KESSEN_MODE=false
SHOGUN_NO_THINKING=false
SILENT_MODE=false
SHELL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--setup-only)
            SETUP_ONLY=true
            shift
            ;;
        -c|--clean)
            CLEAN_MODE=true
            shift
            ;;
        -k|--kessen)
            KESSEN_MODE=true
            shift
            ;;
        -t|--terminal)
            OPEN_TERMINAL=true
            shift
            ;;
        --darkninja-no-thinking)
            SHOGUN_NO_THINKING=true
            shift
            ;;
        -S|--silent)
            SILENT_MODE=true
            shift
            ;;
        -shell|--shell)
            if [[ -n "$2" && "$2" != -* ]]; then
                SHELL_OVERRIDE="$2"
                shift 2
            else
                echo "グワーッ！ -shell オプションには bash または zsh を指定せよ" >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo ""
            echo "◆ multi-agent-shogun ネオサイタマ・デプロイメント・スクリプト ◆"
            echo ""
            echo "使用方法: ./shutsujin_departure.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -c, --clean         キューとダッシュボードをリセットして起動（クリーンスタート）"
            echo "                      未指定時は前回の状態を維持して起動"
            echo "  -k, --kessen        ケッセンの陣（全ヤクザをOpusで起動）"
            echo "                      未指定時はヘイジの陣（ヤクザ1-7=Sonnet, ソウカイヤ=Opus）"
            echo "  -s, --setup-only    tmuxセッションのセットアップのみ（Claude起動なし）"
            echo "  -t, --terminal      Windows Terminal で新しいタブを開く"
            echo "  -shell, --shell SH  シェルを指定（bash または zsh）"
            echo "                      未指定時は config/settings.yaml の設定を使用"
            echo "  -S, --silent        サイレントモード（ヤクザの忍殺echo表示を無効化・API節約）"
            echo "                      未指定時はshoutモード（タスク完了時に忍殺語echo表示）"
            echo "  -h, --help          このヘルプを表示"
            echo ""
            echo "例:"
            echo "  ./shutsujin_departure.sh              # 前回の状態を維持してデプロイ"
            echo "  ./shutsujin_departure.sh -c           # クリーンスタート（キューリセット）"
            echo "  ./shutsujin_departure.sh -s           # セットアップのみ（手動でClaude起動）"
            echo "  ./shutsujin_departure.sh -t           # 全エージェント起動 + ターミナルタブ展開"
            echo "  ./shutsujin_departure.sh -shell bash  # bash用プロンプトで起動"
            echo "  ./shutsujin_departure.sh -k           # ケッセンの陣（全クローンヤクザOpus）"
            echo "  ./shutsujin_departure.sh -c -k         # クリーンスタート＋ケッセンの陣"
            echo "  ./shutsujin_departure.sh -shell zsh   # zsh用プロンプトで起動"
            echo "  ./shutsujin_departure.sh --darkninja-no-thinking  # ダークニンジャのthinkingを無効化（中継特化）"
            echo "  ./shutsujin_departure.sh -S           # サイレントモード（echo表示なし）"
            echo ""
            echo "モデル構成:"
            echo "  ダークニンジャ:      Opus（デフォルト。--darkninja-no-thinkingで無効化）"
            echo "  グレーターヤクザ:      Sonnet（高速タスク管理）"
            echo "  ソウカイヤ:      Opus（戦略立案・設計判断）"
            echo "  ヤクザ1-7:   Sonnet（ジッコウ部隊）"
            echo ""
            echo "陣形:"
            echo "  ヘイジの陣（デフォルト）: ヤクザ1-7=Sonnet, ソウカイヤ=Opus"
            echo "  ケッセンの陣（--kessen）:   全ヤクザ=Opus, ソウカイヤ=Opus"
            echo ""
            echo "表示モード:"
            echo "  shout（デフォルト）:  タスク完了時に忍殺語echo表示"
            echo "  silent（--silent）:   echo表示なし（API節約）"
            echo ""
            echo "マシンロール (config/settings.yaml machine.role):"
            echo "  kyoto（デフォルト）: フル構成（darkninja(main+monitor) + gryakuza + yakuza1-7 + soukaiya + master_tortoise）"
            echo "  neosaitama:        フル構成（crane(master_crane) + gryakuza + yakuza1-7 + soukaiya）"
            echo ""
            echo "エイリアス:"
            echo "  csst  → cd /mnt/c/tools/multi-agent-njslyr && ./yokubari.sh"
            echo "  css   → tmux attach-session -t main"
            echo "  csm   → tmux attach-session -t multiagent"
            echo ""
            exit 0
            ;;
        *)
            echo "アイエエエ！不明なオプション: $1" >&2
            echo "./yokubari.sh -h でヘルプを表示せよ" >&2
            exit 1
            ;;
    esac
done

# シェル設定のオーバーライド（コマンドラインオプション優先）
if [ -n "$SHELL_OVERRIDE" ]; then
    if [[ "$SHELL_OVERRIDE" == "bash" || "$SHELL_OVERRIDE" == "zsh" ]]; then
        SHELL_SETTING="$SHELL_OVERRIDE"
    else
        echo "グワーッ！ -shell には bash か zsh を指定せよ（指定値: $SHELL_OVERRIDE）。ケジメ案件！" >&2
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 出陣バナー表示（CC0ライセンスASCIIアート使用）
# ───────────────────────────────────────────────────────────────────────────────
# 【著作権・ライセンス表示】
# 忍者ASCIIアート: syntax-samurai/ryu - CC0 1.0 Universal (Public Domain)
# 出典: https://github.com/syntax-samurai/ryu
# "all files and scripts in this repo are released CC0 / kopimi!"
# ═══════════════════════════════════════════════════════════════════════════════
show_battle_cry() {
    clear

    # ═══════════════════════════════════════════════════════════════════════════
    # ネオサイタマ電脳IRC接続シーケンス（段階的表示）
    # ═══════════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "\033[1;36m◆◆◆ WARNING ◆◆◆\033[0m  \033[1;33m電脳空間接続開始\033[0m  \033[1;36m◆◆◆ WARNING ◆◆◆\033[0m"
    echo ""
    echo -e "\033[1;35m卍\033[0m \033[0;37mネオサイタマ電脳IRCコトダマ空間に接続中...\033[0m"
    sleep 0.3
    echo -e "\033[1;32m  ✓\033[0m \033[0;37mUNIXニューロン認証完了\033[0m"
    sleep 0.3
    echo -e "\033[1;32m  ✓\033[0m \033[0;37mサイバーパンクプロトコル確立\033[0m"
    sleep 0.3
    echo -e "\033[1;32m  ✓\033[0m \033[0;37m#マッポーの世 チャネル参加完了\033[0m"
    sleep 0.3
    echo -e "\033[1;33m  ワッショイ！\033[0m \033[1;37m接続完了。ドーモ。\033[0m"
    sleep 0.5
    echo ""

    # タイトルバナー（色付き）
    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███╗   ██╗     ██╗███████╗██╗  ██╗   ██╗██████╗                    \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m████╗  ██║     ██║██╔════╝██║  ╚██╗ ██╔╝██╔══██╗                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔██╗ ██║     ██║███████╗██║   ╚████╔╝ ██████╔╝                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║╚██╗██║██   ██║╚════██║██║    ╚██╔╝  ██╔══██╗                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║ ╚████║╚█████╔╝███████║███████╗██║   ██║  ██║                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚═╝  ╚═══╝ ╚════╝ ╚══════╝╚══════╝╚═╝   ╚═╝  ╚═╝                   \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m    \033[1;37mドーモ。ニンジャスレイヤーです。\033[0m  \033[1;36m⚔\033[0m  \033[1;35mイヤーッ！\033[0m                \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # クローンヤクザ隊列（ヤクザAA）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;34m  ╔═══════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m         \033[1;37m【 クローンヤクザ隊列 ・ 七名 + 幹部 配備 】\033[0m              \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚═══════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo "                  ⣿⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⢛⣛⣛⣛⣛⣛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠀⣠⠴⠊⠉⠁⠈⠀⠀⢀⡡⣿⣿⣶⣤⡀⠀⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠰⡮⡀⠀⠀⠀⢀⣀⠔⠊⢁⡠⠟⢿⣿⣿⣿⠆⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⢳⢬⣴⣶⠞⠋⣃⠔⠚⠉⠀⠀⢸⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠘⡇⠑⢿⡤⠎⠁⠀⠀⣠⢠⢀⣼⣿⡿⢿⡇⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⢀⡇⢄⠠⠀⢠⠎⢀⢄⣀⣼⣶⣿⣿⣝⢁⡇⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠘⡉⣷⣷⣷⡵⠲⣿⣿⣿⣿⡏⠀⡡⢮⣼⡅⠀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠀⠡⣿⣿⣿⠟⢂⢿⣿⡿⡟⠡⢲⠁⣯⡈⠳⣀⠀⠀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠀⠀⠹⡟⠣⡠⡴⠛⠡⠀⢸⠁⠂⠀⣿⢀⡔⠈⢧⡀⠀⠀⠀⣿"
    echo "                  ⣿⠀⠀⠀⠀⠀⠀⠀⢀⡵⡐⢩⡧⣄⡐⠂⡨⢃⠀⡾⡤⠊⠀⠀⠈⢻⣖⠤⡀⣿"
    echo "                  ⣿⠀⠀⠀⠀⢀⣠⠖⣱⡷⢿⠆⠀⠀⠀⡩⠖⢁⡼⠊⠀⠀⠀⠀⠀⣾⣿⣷⣆⣿"
    echo "                  ⣿⠀⡀⠠⣒⡵⣡⣾⡟⠀⢎⠫⡻⡋⣉⠠⠚⠁⠀⠀⠀⠀⠀⠀⣸⣿⣿⣿⣿⣿"
    echo "                  ⣿⣭⣶⣿⡟⣾⣿⡏⠀⢀⣴⣇⢠⢎⠅⣤⡀⠀⠀⠀⠀⢀⠠⡾⣿⣿⣿⣿⣿⣿"
    echo "                  ⣿⣿⣿⣟⣾⢿⣿⠀⣠⣺⣿⣿⣿⣿⣿⣿⣿⢦⡀⠔⠈⠁⡔⣰⣿⣿⣿⣿⣿⣿"
    echo "                  ⣿⣿⣿⣿⣵⣿⣿⣼⣥⣤⣿⣿⣿⣿⣿⣯⣥⣬⣭⣦⣤⣾⣿⣿⣿⣿⣿⣿⣿⣿"
    echo ""
    echo -e "                  \033[1;36m「「「 ザッケンナコラー！！ 」」」\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # システム情報
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37mmulti-agent-njslyr\033[0m 〜 \033[1;36mネオサイタマ・マルチエージェント統率\033[0m 〜  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                 \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35mダークニンジャ\033[0m: 統括  \033[1;31mグレーターヤクザ\033[0m: カンリ  \033[1;33mソウカイヤ\033[0m: 戦略  \033[1;34mヤクザ\033[0m: ×7  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# バリキドリンク投与・解除ヘルパー関数
# ───────────────────────────────────────────────────────────────────────────────
# Usage:
#   inject_barikidorink "multiagent:0.1"                              # yakuza1にOpus投与
#   inject_barikidorink "multiagent:0.1" "queue/tasks/yakuza1.yaml"   # 投与 + タスク割り当て
#   detox_barikidorink "multiagent:0.1"                               # yakuza1をSonnetに復帰
# ═══════════════════════════════════════════════════════════════════════════════
inject_barikidorink() {
    local pane=$1
    local task_yaml="${2:-}"
    local _project_root="${PROJECT_ROOT:-$SCRIPT_DIR}"
    local agent_id
    agent_id=$(tmux show-options -pv -t "$pane" @agent_id 2>/dev/null || echo "")

    # Idempotency: skip model switch if already Opus
    local current_model
    current_model=$(tmux show-options -pv -t "$pane" @model_name 2>/dev/null || echo "")
    if [ "$current_model" = "Opus" ]; then
        echo "[barikidorink] ${agent_id:-$pane} already Opus, skipping model switch" >&2
    else
        tmux send-keys -t "$pane" "/model opus"
        sleep 0.3
        tmux send-keys -t "$pane" Escape
        sleep 0.1
        tmux send-keys -t "$pane" Enter
        sleep 0.5
        tmux set-option -p -t "$pane" @model_name "Opus"
        tmux select-pane -t "$pane" -P 'bg=#1a002e'
        sleep 0.3
        tmux send-keys -t "$pane" "/clear"
        sleep 0.3
        tmux send-keys -t "$pane" Escape
        sleep 0.1
        tmux send-keys -t "$pane" Enter
        sleep 5
    fi

    # Task assignment via inbox_write (inbox_watcher handles nudge automatically)
    if [ -n "$task_yaml" ] && [ -n "$agent_id" ]; then
        bash "$_project_root/scripts/inbox_write.sh" "$agent_id" \
            "タスクYAMLを読んで作業開始せよ。" task_assigned "yakuzatengu" "$task_yaml" "P0"
    elif [ "$current_model" != "Opus" ] && [ -n "$agent_id" ]; then
        # Re-nudge: no task_yaml given, manually check inbox unread and send nudge
        local unread_count
        unread_count=$(grep -c 'read: false' "$_project_root/queue/inbox/${agent_id}.yaml" 2>/dev/null) || unread_count=0
        if [ "$unread_count" -gt 0 ]; then
            tmux send-keys -t "$pane" "inbox${unread_count}"
            sleep 0.3
            tmux send-keys -t "$pane" Escape
            sleep 0.1
            tmux send-keys -t "$pane" Enter
        fi
    fi
}

detox_barikidorink() {
    local pane=$1
    tmux send-keys -t "$pane" "/model sonnet"
    sleep 0.3
    tmux send-keys -t "$pane" Escape
    sleep 0.1
    tmux send-keys -t "$pane" Enter
    sleep 0.5
    tmux set-option -p -t "$pane" @model_name "Sonnet"
    tmux select-pane -t "$pane" -P 'bg=default'
    sleep 0.3
    tmux send-keys -t "$pane" "/clear"
    sleep 0.3
    tmux send-keys -t "$pane" Escape
    sleep 0.1
    tmux send-keys -t "$pane" Enter
}

# ═══════════════════════════════════════════════════════════════════════════════
# エージェント起動ヘルパー（CLI Adapter対応・重複排除）
# ───────────────────────────────────────────────────────────────────────────────
# Usage: launch_agent <pane_target> <agent_id> <default_model> [extra_env]
# ═══════════════════════════════════════════════════════════════════════════════
launch_agent() {
    local pane_target="$1"
    local agent_id="$2"
    local default_model="$3"
    local extra_env="${4:-}"

    local cli_type="claude"
    local cli_cmd="claude --model ${default_model} --dangerously-skip-permissions"

    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        cli_type=$(get_cli_type "$agent_id")
        if [ "$cli_type" = "claude" ] && [ "$default_model" = "opus" ] && [ "$KESSEN_MODE" = true ]; then
            cli_cmd="claude --model opus --dangerously-skip-permissions"
        else
            cli_cmd=$(build_cli_command "$agent_id")
        fi
    fi

    local startup_prompt
    startup_prompt=$(get_startup_prompt "$agent_id" 2>/dev/null) || true
    if [[ -n "$startup_prompt" ]]; then
        cli_cmd="$cli_cmd \"$startup_prompt\""
    fi

    tmux set-option -p -t "$pane_target" @agent_cli "$cli_type"
    if [[ -n "$extra_env" ]]; then
        tmux send-keys -t "$pane_target" "${extra_env} ${cli_cmd}"
    else
        tmux send-keys -t "$pane_target" "$cli_cmd"
    fi
    tmux send-keys -t "$pane_target" Enter
}

# inbox_watcher起動ヘルパー
# Usage: launch_watcher <agent_id> <pane_target> [env_vars]
launch_watcher() {
    local agent_id="$1"
    local pane_target="$2"
    local env_vars="${3:-}"

    local watcher_cli
    watcher_cli=$(tmux show-options -p -t "$pane_target" -v @agent_cli 2>/dev/null || echo "claude")

    if [[ -n "$env_vars" ]]; then
        # shellcheck disable=SC2086  # Intentional word splitting for multiple env vars
        nohup env $env_vars \
            bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "$agent_id" "$pane_target" "$watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_${agent_id}.log" 2>&1 &
    else
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "$agent_id" "$pane_target" "$watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_${agent_id}.log" 2>&1 &
    fi
    disown
}

# バナー表示実行
show_battle_cry

echo -e "  \033[1;33m◆陣立て開始◆ ドーモ。ネオサイタマ・デプロイメントを開始する。イヤーッ！\033[0m"
echo -e "  \033[1;36m◆マシンロール◆ ${MACHINE_ROLE} (フル構成9体)\033[0m"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 0.5: 起動時auto-sync（state pullのみ。handoverはntfy経由のラオモト明示的指示で実行）
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -f queue/active_machine.yaml ]]; then
    ACTIVE_MODE=$(awk '/^mode:/{print $2}' queue/active_machine.yaml 2>/dev/null)
    if [[ "$ACTIVE_MODE" == "simultaneous" ]]; then
        log_info "🔄 simultaneous mode — 両マシン同時稼働。auto-syncスキップ"
    elif [[ "$ACTIVE_MODE" == "exclusive" || -z "$ACTIVE_MODE" ]]; then
        ACTIVE_MACHINE=$(awk '/active_machine:/{print $2}' queue/active_machine.yaml 2>/dev/null)
        if [[ -n "$ACTIVE_MACHINE" && "$ACTIVE_MACHINE" != "$MACHINE_ROLE" ]]; then
            # NOTE: active_machine.yamlは更新しない。排他稼働切り替えはntfy handover:{target}のみ。
            log_info "🔄 別マシン(${ACTIVE_MACHINE})がアクティブ。最新状態をpull中..."
            current_branch=$(git branch --show-current 2>/dev/null)
            if [[ -n "$current_branch" ]]; then
                git pull --ff-only origin "$current_branch" 2>/dev/null || {
                    log_war "  └─ git pull失敗。手動マージが必要かもしれない。"
                }
            else
                log_war "  └─ detached HEAD状態のためgit pullスキップ。ブランチを確認せよ。"
            fi
            if [[ -x scripts/cross_sync.sh ]]; then
                bash scripts/cross_sync.sh pull 2>/dev/null || true
            fi
            log_success "  └─ state pull完了。handoverが必要ならntfyで 'handover:${MACHINE_ROLE}' を送信せよ。"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: 既存セッションクリーンアップ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 既存セッションをサツバツ！と破壊する..."
if tmux kill-session -t multiagent 2>/dev/null; then
    log_info "  └─ multiagent…サヨナラ！爆発四散！"
else
    log_info "  └─ multiagent…存在セズ。ナムアミダブツ"
fi
if tmux kill-session -t main 2>/dev/null; then
    log_info "  └─ main…サヨナラ！爆発四散！"
else
    log_info "  └─ main…存在セズ。ナムアミダブツ"
fi
# レガシーセッション名の掃除
tmux kill-session -t darkninja 2>/dev/null || true
tmux kill-session -t crane 2>/dev/null || true
tmux kill-session -t shogun 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1.5: 前回記録のバックアップ（--clean時のみ、内容がある場合）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    BACKUP_DIR="./logs/backup_$(date '+%Y%m%d_%H%M%S')"
    NEED_BACKUP=false

    if [ -f "./dashboard.md" ]; then
        if grep -q "cmd_" "./dashboard.md" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    # darkninja_to_gryakuza.yaml is deprecated (inbox-based system now).
    # Backup decision is based on dashboard.md and queue/tasks/ only.

    if [ "$NEED_BACKUP" = true ]; then
        mkdir -p "$BACKUP_DIR" || true
        cp "./dashboard.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/reports" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/tasks" "$BACKUP_DIR/" 2>/dev/null || true
        log_info "📦 前回のセンカ記録をバックアップ。インガオホー: $BACKUP_DIR"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: キューディレクトリ確保 + リセット（--clean時のみリセット）
# ═══════════════════════════════════════════════════════════════════════════════

# queue ディレクトリが存在しない場合は作成（初回起動時に必要）
[ -d ./queue/reports ] || mkdir -p ./queue/reports
[ -d ./queue/tasks ] || mkdir -p ./queue/tasks
# inbox ディレクトリ確保（OS別）
# WSL2: /mnt/c/ では inotifywait が動かないため Linux FS にシンボリックリンク
# macOS: ローカルFSなので直接ディレクトリでOK
if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p ./queue/inbox
else
    INBOX_LINUX_DIR="$HOME/.local/share/multi-agent-njslyr/inbox"
    _OLD_INBOX_LINUX_DIR="$HOME/.local/share/multi-agent-shogun/inbox"
    if [ ! -L ./queue/inbox ]; then
        # 旧パス（multi-agent-shogun）からのマイグレーション
        if [ -d "$_OLD_INBOX_LINUX_DIR" ] && [ ! -d "$INBOX_LINUX_DIR" ]; then
            mkdir -p "$(dirname "$INBOX_LINUX_DIR")"
            mv "$_OLD_INBOX_LINUX_DIR" "$INBOX_LINUX_DIR"
            log_info "  └─ inbox migrated: multi-agent-shogun → multi-agent-njslyr。インガオホー"
        else
            mkdir -p "$INBOX_LINUX_DIR"
        fi
        [ -d ./queue/inbox ] && cp ./queue/inbox/*.yaml "$INBOX_LINUX_DIR/" 2>/dev/null && rm -rf ./queue/inbox
        ln -sf "$INBOX_LINUX_DIR" ./queue/inbox
        log_info "  └─ inbox → Linux FS ($INBOX_LINUX_DIR) にシンボリックリンク作成。ワザマエ"
    fi
fi

if [ "$CLEAN_MODE" = true ]; then
    log_info "📜 前回のYAMLキューを破棄する…サヨナラ！"

    # ヤクザタスクファイルリセット
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        cat > "./queue/tasks/yakuza${i}.yaml" << EOF
# ヤクザ${i}専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
    done

    # ソウカイヤタスクファイルリセット
    cat > ./queue/tasks/soukaiya.yaml << EOF
# ソウカイヤ専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF

    # ヤクザレポートファイルリセット
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        cat > "./queue/reports/yakuza${i}_report.yaml" << EOF
worker_id: yakuza${i}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    done

    # ソウカイヤレポートファイルリセット
    cat > ./queue/reports/soukaiya_report.yaml << EOF
worker_id: soukaiya
task_id: null
timestamp: ""
status: idle
result: null
EOF

    # ntfy inbox リセット
    echo "inbox:" > ./queue/ntfy_inbox.yaml

    # agent inbox リセット
    for agent in darkninja gryakuza soukaiya "$MONITOR_AGENT"; do
        echo "messages:" > "./queue/inbox/${agent}.yaml"
    done
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        echo "messages:" > "./queue/inbox/yakuza${i}.yaml"
    done

    log_success "✅ 前回のデータ、全て爆発四散！クリーンスタート！ワザマエ！"
else
    log_info "📜 前回の状態を維持してデプロイする。カラテの蓄積はムダにしない"
    log_success "✅ キュー・レポートYAML、前回のデータを引き継ぐ。ワザマエ！"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: ダッシュボード初期化（--clean時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    log_info "📊 センキョウ・ダッシュボードをイニシャライズ中...イヤーッ！"
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

    if [ "$LANG_SETTING" = "ja" ]; then
        # 日本語のみ
        cat > ./dashboard.md << EOF
# 📊 センキョウ・ダッシュボード
最終更新: ${TIMESTAMP}

## 🚨 ヨウタイオウ - ラオモトのゴハンダンをお待ちしております
なし

## 🔄 ジッコウ中 - 只今、サイバーパンクなサギョウ中
なし

## ✅ 本日のセンカ
| 時刻 | 戦場 | 任務 | 結果 |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち
なし

## 🛠️ 生成されたスキル
なし

## ⏸️ 待機中
なし

## ❓ 伺い事項
なし
EOF
    else
        # 日本語 + 翻訳併記
        cat > ./dashboard.md << EOF
# 📊 センキョウ・ダッシュボード (Battle Status Report)
最終更新 (Last Updated): ${TIMESTAMP}

## 🚨 ヨウタイオウ - ラオモトのゴハンダンをお待ちしております (Action Required - Awaiting Lord's Decision)
なし (None)

## 🔄 ジッコウ中 - 只今、サイバーパンクなサギョウ中 (In Progress - Currently in Battle)
なし (None)

## ✅ 本日のセンカ (Today's Achievements)
| 時刻 (Time) | 戦場 (Battlefield) | 任務 (Mission) | 結果 (Result) |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち (Skill Candidates - Pending Approval)
なし (None)

## 🛠️ 生成されたスキル (Generated Skills)
なし (None)

## ⏸️ 待機中 (On Standby)
なし (None)

## ❓ 伺い事項 (Questions for Lord)
なし (None)
EOF
    fi

    log_success "  └─ ダッシュボード、イニシャライズ完了。ワザマエ！ (言語: $LANG_SETTING, シェル: $SHELL_SETTING)"
else
    log_info "📊 ゼンカイのダッシュボードを維持。センカの記録はカラテの証"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: tmux の存在確認
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v tmux &> /dev/null; then
    echo "" >&2
    echo "  ╔════════════════════════════════════════════════════════╗" >&2
    echo "  ║  アイエエエ！tmuxが存在しない！ナムアミダブツ！       ║" >&2
    echo "  ║  [ERROR] tmux not found!                              ║" >&2
    echo "  ╠════════════════════════════════════════════════════════╣" >&2
    echo "  ║  カラテが足りていない。まずfirst_setup.shを実行せよ:  ║" >&2
    echo "  ║     ./first_setup.sh                                  ║" >&2
    echo "  ╚════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: 本部セッション作成
#   kyoto:      darkninja セッション（main: ラオモト本体, monitor: master_tortoise）
#   neosaitama: crane セッション（main: master_crane）
# ═══════════════════════════════════════════════════════════════════════════════
# スマホ等の小画面クライアント対策: aggressive-resize + latest
# NOTE: tmuxサーバー不在時（全セッション破棄後）はset-optionが失敗する。
# 先にセッションを作成してサーバーを起動し、その後にグローバルオプションを設定する。

if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    # neosaitama: main セッション
    # window 1: darkninja — SSH peer-hostname:2200 → Kyoto (plain SSH, manual tmux attach)
    # window 2: tortoise  — SSH peer-hostname:2200 → Kyoto (plain SSH, manual tmux attach)
    # window 3: crane     — ローカル master_crane
    log_war "👑 キョート接続ウィンドウ + クレイン・ホンジンをコンストラクト中...イヤーッ！"
    # window 1: darkninja (SSH→Kyoto)
    tmux new-session -d -s main -n darkninja -x 200 -y 50 2>/dev/null || true
    tmux send-keys -t main:darkninja "ssh -p ${KYOTO_SSH_PORT} ${KYOTO_HOST}" Enter
    # window 2: tortoise (SSH→Kyoto)
    tmux new-window -t main -n tortoise
    tmux send-keys -t main:tortoise "ssh -p ${KYOTO_SSH_PORT} ${KYOTO_HOST}" Enter
    # window 3: crane (local)
    tmux new-window -t main -n crane
    CRANE_PROMPT=$(generate_prompt "crane" "cyan" "$SHELL_SETTING")
    tmux send-keys -t main:crane "cd \"$(pwd)\" && export PS1='${CRANE_PROMPT}' && clear" Enter
    tmux set-option -p -t main:crane @agent_id "master_crane"
    tmux set-option -p -t main:crane @model_name "Sonnet"
    tmux set-option -p -t main:crane @current_task ""
    MONITOR_PANE="main:crane"
    log_success "  └─ キョート接続(darkninja/tortoise) + クレイン・ホンジン、コンストラクト完了！ワザマエ！"
else
    # kyoto: main セッション、window "darkninja" にラオモト本体、window "monitor" にmaster_tortoise
    log_war "👑 ラオモトのホンジンをコンストラクト中...イヤーッ！"
    tmux new-session -d -s main -n darkninja -x 200 -y 50 2>/dev/null || true
    SHOGUN_PROMPT=$(generate_prompt "ラオモト" "magenta" "$SHELL_SETTING")
    tmux send-keys -t main:darkninja "cd \"$(pwd)\" && export PS1='${SHOGUN_PROMPT}' && clear" Enter
    tmux select-pane -t main:darkninja -P 'bg=#001520'  # ダークニンジャの Dark Blue
    tmux set-option -p -t main:darkninja @agent_id "darkninja"
    # main:monitor ウィンドウ - master_tortoise監視
    tmux new-window -t main -n monitor
    TORTOISE_PROMPT=$(generate_prompt "tortoise" "cyan" "$SHELL_SETTING")
    tmux send-keys -t main:monitor "cd \"$(pwd)\" && export PS1='${TORTOISE_PROMPT}' && clear" Enter
    tmux set-option -p -t main:monitor @agent_id "master_tortoise"
    tmux set-option -p -t main:monitor @model_name "Sonnet"
    tmux set-option -p -t main:monitor @current_task ""
    MONITOR_PANE="main:monitor"
    log_success "  └─ ラオモトのホンジン（darkninja + monitor）、コンストラクト完了！ワザマエ！"
fi

# NOTE: window-size latest + aggressive-resize on は全ペイン分割完了後に設定する（STEP 5.3）
# 分割前に設定するとクライアントサイズ(132x40等)に縮小されno space for new paneが発生する
echo ""

# pane-base-index を取得（1 の環境ではペインは 1,2,... になる）
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.1: multiagent セッション作成（9ペイン：gryakuza + yakuza1-8）
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    log_war "⚔️ グレーターヤクザ・ヤクザ・ソウカイヤをジェネレート中…9名配備！（neosaitama）"
else
    log_war "⚔️ グレーターヤクザ・ヤクザ・ソウカイヤをジェネレート中…9名配備！"
fi

# 最初のペイン作成
if ! tmux new-session -d -s multiagent -n "agents" -x 200 -y 50 2>/dev/null; then
    echo "" >&2
    echo "  ╔════════════════════════════════════════════════════════════╗" >&2
    echo "  ║  グワーッ！multiagentセッション生成に失敗！              ║" >&2
    echo "  ║  アイエエエ！既存セッションのゴーストが残留している！    ║" >&2
    echo "  ╠════════════════════════════════════════════════════════════╣" >&2
    echo "  ║  ジョウキョウ確認:  tmux ls                              ║" >&2
    echo "  ║  爆発四散させる:   tmux kill-session -t multiagent       ║" >&2
    echo "  ╚════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    exit 1
fi

# neosaitama: "kyoto" ウィンドウ追加（SSH→Kyoto multiagent）
# NOTE: "agents" → "neosaitama" のリネームは multiagent:agents の全操作完了後に実施（STEP 5.2後）
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    # window "kyoto": SSH peer-hostname → Kyoto (plain SSH, manual tmux attach)
    tmux new-window -t multiagent -n kyoto -b
    tmux send-keys -t multiagent:kyoto "ssh -p ${KYOTO_SSH_PORT} ${KYOTO_HOST}" Enter
fi

# DISPLAY_MODE: shout (default) or silent (--silent flag)
if [ "$SILENT_MODE" = true ]; then
    tmux set-environment -t multiagent DISPLAY_MODE "silent"
    echo "  📢 ヒョウジモード: サイレント（ザッケンナコラーの叫びナシ。API節約重点）"
else
    tmux set-environment -t multiagent DISPLAY_MODE "shout"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# エージェント構成（マシンロール依存）
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    # neosaitama フル構成9体: gryakuza + yakuza1-7 + soukaiya = 9 panes
    PANE_LABELS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")
    PANE_COLORS=("red" "blue" "blue" "blue" "blue" "blue" "blue" "blue" "yellow")
    AGENT_IDS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")
    YAKUZA_MAX=7
    if [ "$KESSEN_MODE" = true ]; then
        MODEL_NAMES=("Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus")
    else
        MODEL_NAMES=("Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Opus")
    fi

    # 小型ターミナル（132x40）対応: ペイン分割前に仮想サイズを強制設定
    # window-size latest + aggressive-resize により物理端末サイズに縮小される場合があるため
    tmux resize-window -t "multiagent:agents" -x 220 -y 55

    # 3x3グリッド作成（合計9ペイン）
    tmux split-window -h -t "multiagent:agents"
    tmux split-window -h -t "multiagent:agents"

    { read -r COL1_ID; read -r COL2_ID; read -r COL3_ID; } \
        < <(tmux list-panes -t "multiagent:agents" -F '#{pane_id}')

    tmux select-pane -t "$COL1_ID"
    tmux split-window -v
    tmux split-window -v

    tmux select-pane -t "$COL2_ID"
    tmux split-window -v
    tmux split-window -v

    tmux select-pane -t "$COL3_ID"
    tmux split-window -v
    tmux split-window -v
else
    # kyotoフル構成: gryakuza + yakuza1-7 + soukaiya = 9 panes (現行)
    PANE_LABELS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")
    PANE_COLORS=("red" "blue" "blue" "blue" "blue" "blue" "blue" "blue" "yellow")
    AGENT_IDS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")
    YAKUZA_MAX=7
    if [ "$KESSEN_MODE" = true ]; then
        MODEL_NAMES=("Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus")
    else
        MODEL_NAMES=("Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Opus")
    fi

    # 3x3グリッド作成（合計9ペイン）
    # ペイン番号は pane-base-index に依存（0 または 1）
    # 最初に3列に分割
    tmux split-window -h -t "multiagent:agents"
    tmux split-window -h -t "multiagent:agents"

    # BUG FIX (2026-02-19): pane INDEX はv-split時に位置順で再ナンバリングされるため不安定。
    # h-split直後にpane ID（%N形式・安定）を保存し、v-split時はIDで列頭を指定する。
    { read -r COL1_ID; read -r COL2_ID; read -r COL3_ID; } \
        < <(tmux list-panes -t "multiagent:agents" -F '#{pane_id}')

    tmux select-pane -t "$COL1_ID"
    tmux split-window -v
    tmux split-window -v

    tmux select-pane -t "$COL2_ID"
    tmux split-window -v
    tmux split-window -v

    tmux select-pane -t "$COL3_ID"
    tmux split-window -v
    tmux split-window -v
fi

# CLI Adapter経由でモデル名を動的に上書き
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    for ((i=0; i<${#AGENT_IDS[@]}; i++)); do
        _agent="${AGENT_IDS[$i]}"
        _cli=$(get_cli_type "$_agent")
        case "$_cli" in
            claude)
                _claude_model=$(get_agent_model "$_agent")
                if [[ -n "$_claude_model" ]]; then
                    # haiku→Haiku, opus→Opus, sonnet→Sonnet に正規化（fork不要・bash 3.2+互換）
                    case "$_claude_model" in
                        opus)   MODEL_NAMES[i]="Opus" ;;
                        sonnet) MODEL_NAMES[i]="Sonnet" ;;
                        haiku)  MODEL_NAMES[i]="Haiku" ;;
                        *)  _first=$(echo "${_claude_model:0:1}" | tr '[:lower:]' '[:upper:]')
                            MODEL_NAMES[i]="${_first}${_claude_model:1}" ;;
                    esac
                fi
                ;;
            codex)
                # settings.yamlのmodelを優先表示、なければconfig.tomlのeffort
                _codex_model=$(get_agent_model "$_agent")
                if [[ -n "$_codex_model" ]]; then
                    MODEL_NAMES[i]="codex/${_codex_model}"
                else
                    # grep|head|sed → 単一awk（3 fork → 1 fork）
                    _codex_effort=$(awk -F'"' '/^model_reasoning_effort/{print $2; exit}' ~/.codex/config.toml 2>/dev/null)
                    _codex_effort=${_codex_effort:-high}
                    MODEL_NAMES[i]="codex/${_codex_effort}"
                fi
                ;;
            copilot)
                MODEL_NAMES[i]="Copilot"
                ;;
            kimi)
                MODEL_NAMES[i]="Kimi"
                ;;
        esac
    done
fi

for ((i=0; i<${#AGENT_IDS[@]}; i++)); do
    p=$((PANE_BASE + i))
    tmux select-pane -t "multiagent:agents.${p}" -T "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @agent_id "${AGENT_IDS[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @current_task ""
    PROMPT_STR=$(generate_prompt "${PANE_LABELS[$i]}" "${PANE_COLORS[$i]}" "$SHELL_SETTING")
    tmux send-keys -t "multiagent:agents.${p}" "cd \"$(pwd)\" && export PS1='${PROMPT_STR}' && clear" Enter
done

# @agent_id 割り当て検証（2026-02-18 恒久対策: 誤設定インシデント防止）
# 設定直後に実際値を検証し、ミスマッチがあれば即時修正する
_verify_errors=0
for ((i=0; i<${#AGENT_IDS[@]}; i++)); do
    p=$((PANE_BASE + i))
    _expected="${AGENT_IDS[$i]}"
    _actual=$(tmux show-options -pv -t "multiagent:agents.${p}" @agent_id 2>/dev/null || echo "")
    if [[ "$_actual" != "$_expected" ]]; then
        log_war "  ⚠️  @agent_id誤設定検知: pane${p} actual='${_actual}' expected='${_expected}' → 再設定"
        tmux set-option -p -t "multiagent:agents.${p}" @agent_id "$_expected" 2>/dev/null || true
        _verify_errors=$((_verify_errors + 1))
    fi
done
if [[ $_verify_errors -eq 0 ]]; then
    log_success "  └─ @agent_id全ペイン検証OK。ワザマエ！"
else
    log_war "  ⚠️  @agent_id誤設定を${_verify_errors}件修正。要インシデント記録。"
fi

# pane-border-format でモデル名を常時表示
tmux set-option -t multiagent -w pane-border-status top
tmux set-option -t multiagent -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

# ウィンドウを最大クライアントサイズまで拡張し、ペインを均等配分
tmux resize-window -A -t multiagent:agents
tmux select-layout -t multiagent:agents tiled

# ウィンドウリサイズ時にペインを自動再配置（WezTerm等のリサイズ追従）
tmux set-hook -t multiagent client-resized 'resize-window -A -t multiagent:agents ; select-layout -t multiagent:agents tiled'

log_success "  └─ グレーターヤクザ・ヤクザ・ソウカイヤのジン、コンストラクト完了！ワザマエ！"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.1.1: グローバルオプション設定（全ペイン分割完了後）
#   分割前に設定するとクライアントサイズに縮小されno space for new paneが発生する
# ═══════════════════════════════════════════════════════════════════════════════
tmux set-option -g window-size latest 2>/dev/null || true
tmux set-option -g aggressive-resize on 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.2: multiagent:agents ウィンドウをアクティブに戻す
#   監視エージェント配置は STEP 5 で完了済み
#   （kyoto: main:monitor, neosaitama: main:crane）
# ═══════════════════════════════════════════════════════════════════════════════
tmux select-window -t multiagent:agents
# neosaitama: "agents" → "neosaitama" リネーム（全 multiagent:agents 操作完了後）
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    tmux rename-window -t multiagent:agents "neosaitama"
fi
log_success "  └─ ${MONITOR_AGENT} 監視陣、コンストラクト完了！（${MONITOR_PANE}）ワザマエ！"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Claude Code 起動（-s / --setup-only のときはスキップ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SETUP_ONLY" = false ]; then
    # CLI の存在チェック（Multi-CLI対応）
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _default_cli=$(get_cli_type "")
        if ! validate_cli_availability "$_default_cli"; then
            exit 1
        fi
    else
        if ! command -v claude &> /dev/null; then
            log_war "アイエエエ！claudeコマンドが存在しない！カラテが足りていない！"
            echo "  first_setup.shを実行してカラテを補充せよ:" >&2
            echo "    ./first_setup.sh" >&2
            exit 1
        fi
    fi

    log_war "👑 全エージェントにニンジャソウルをインストール中...イヤーッ！（並列起動モード）"

    # ═════════════════════════════════════════════════════════════
    # 【Phase 1高速化】全エージェント並列起動
    # 削減時間: 40-60秒 → 期待10秒以下
    # ═════════════════════════════════════════════════════════════

    # ダークニンジャ起動（バックグラウンド）（kyoto のみ）
    if [[ "$MACHINE_ROLE" != "neosaitama" && "$MACHINE_ROLE" != "mbp" ]]; then
        _darkninja_extra=""
        if [ "$SHOGUN_NO_THINKING" = true ]; then
            _darkninja_extra="MAX_THINKING_TOKENS=0"
        fi
        ( launch_agent "main:darkninja" "darkninja" "opus" "$_darkninja_extra" ) &
        log_info "  ◆召喚◆ ダークニンジャ…ニンジャソウル覚醒！イヤーッ！"
    fi

    # グレーターヤクザ起動（バックグラウンド）
    ( launch_agent "multiagent:agents.$((PANE_BASE + 0))" "gryakuza" "sonnet" ) &
    log_info "  ◆召喚◆ グレーターヤクザ（所属: ${GRYAKUZA_CORP}）…ニンジャソウル覚醒！イヤーッ！"

    # クローンヤクザ起動（バックグラウンド、YAKUZA_MAX体）
    if [ "$KESSEN_MODE" = true ]; then
        _yakuza_model="opus"
    else
        _yakuza_model="sonnet"
    fi
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        ( launch_agent "multiagent:agents.$((PANE_BASE + i))" "yakuza${i}" "$_yakuza_model" ) &
    done
    if [ "$KESSEN_MODE" = true ]; then
        log_info "  ◆召喚×${YAKUZA_MAX}◆ クローンヤクザ1-${YAKUZA_MAX}（ケッセンの陣）…全員Opus！サツバツ！ザッケンナコラー！"
    else
        log_info "  ◆召喚×${YAKUZA_MAX}◆ クローンヤクザ1-${YAKUZA_MAX}（ヘイジの陣）…ニンジャソウル覚醒！ザッケンナコラー！"
    fi

    # ソウカイヤ起動（バックグラウンド、最後のpane）
    _soukaiya_idx=$((YAKUZA_MAX + 1))
    ( launch_agent "multiagent:agents.$((PANE_BASE + _soukaiya_idx))" "soukaiya" "opus" ) &
    log_info "  ◆召喚◆ ソウカイヤ…戦略カイギ開始！ドーモ"

    # 監視エージェント起動（バックグラウンド）
    ( launch_agent "$MONITOR_PANE" "$MONITOR_AGENT" "sonnet" ) &
    log_info "  ◆召喚◆ ${MONITOR_AGENT}…監視ニューロン覚醒！ドーモ"

    # 全バックグラウンドジョブの完了を待機
    wait
    log_info "  ワザマエ！全エージェント並列起動完了！カラテの速度で展開！"

    if [ "$KESSEN_MODE" = true ]; then
        log_success "✅ ◆実際ケッセンの陣◆ 全軍Opus！カラテが溢れている！！ワッショイ！"
    else
        log_success "✅ ◆実際ヘイジの陣◆ 電脳IRC接続完了！（GrYakuza=Sonnet, Y×${YAKUZA_MAX}=Sonnet, Soukaiya=Opus, ${MONITOR_AGENT}=Sonnet）ワザマエ！"
    fi
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.5: 各エージェントに指示書を読み込ませる
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "📜 各ニンジャにオキテ（シジショ）を読み込ませ中…コトダマ空間展開！"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # 忍者戦士（syntax-samurai/ryu - CC0 1.0 Public Domain）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;35m  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m  │\033[0m                              \033[1;37m【 忍 者 戦 士 】\033[0m  Ryu Hayabusa (CC0 Public Domain)                        \033[1;35m│\033[0m"
    echo -e "\033[1;35m  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘\033[0m"

    cat << 'NINJA_EOF'
...................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░▒▒▒▒          ▒▒▒▒▒▒▒▒░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒                             ...................................
..................................░░░░░░░░░░░░░░▒▒▒▒               ▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                ...................................
..................................░░░░░░░░░░░░░▒▒▒                    ▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                    ...................................
..................................░░░░░░░░░░░░▒                            ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                        ...................................
..................................░░░░░░░░░░░      ░░░░░░░░░░░░░                                      ░░░░░░░░░░░░       ▒          ...................................
..................................░░░░░░░░░░ ▒    ░░░▓▓▓▓▓▓▓▓▓▓▓▓░░                                 ░░░░░░░░░░░░░░░ ░               ...................................
..................................░░░░░░░░░░     ░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░                          ░░░░░░░░░░░░░░░░░░░                ...................................
..................................░░░░░░░░░ ▒  ░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░             ░░▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░  ░   ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░ ░  ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░  ░    ▒        ...................................
..................................░░░░░░░░░▒  ░ ░               ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░                 ░            ...................................
.................................░░░░░░░░░░   ░░░  ░                 ▓▓▓▓▓▓▓▓░▓▓▓▓░░░▓░░░░░░▓▓▓▓▓                    ░ ░   ▒         ..................................
.................................░░░░░░░░▒▒   ░░░░░ ░                  ▓▓▓▓▓▓░▓▓▓▓░░▓▓▓░░░░░░▓▓                    ░  ░ ░  ▒         ..................................
.................................░░░░░░░░▒    ░░░░░░░░░ ░                 ░▓░░▓▓▓▓▓░▓▓▓░░░░░                   ░ ░░ ░░ ░   ▒         ..................................
.................................░░░░░░░▒▒    ░░░░░░░   ░░                    ▓▓▓▓▓▓▓▓▓░░                   ░░    ░ ░░ ░    ▒        ..................................
.................................░░░░░░░▒▒    ░░░░░░░░░░                      ░▓▓▓▓▓▓▓░░░                     ░░░  ░  ░ ░   ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░                         ░░░▓▓▓░▓░░░░      ░                  ░ ░░ ░    ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░░     ▓▓        ▓  ░░ ░░░░░░░░░░░░░  ░   ░░  ▓        █▓       ░  ░ ░   ▒▒       ..................................
..................................░░░░░▒ ▒    ░░░░░░░░  ▓▓██  ▓  ██ ██▓  ▓ ░░░▓░  ░ ░ ░░░░  ▓   ██ ▓█  ▓  ██▓▓  ░░░░  ░ ░    ▒      ...................................
..................................░░░░░▒ ▒▒   ░░░░░░░░░  ▓██  ▓▓  ▓ ██▓  ▓░░░░▓▓░  ░░░░░░░░ ▓  ▓██ ▓   ▓  ██▓▓ ░░░░░░░ ░     ▒      ...................................
..................................░░░░░  ▒░   ░░░░░░░▓░░ ▓███  ▓▓▓▓ ███░  ░░░░▓▓░░░░░░░░░░    ░▓██  ▓▓▓  ███▓ ░░▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░  ▒░    ░░░░▓▓▓▓▓▓░  ███    ██      ░░░░░▓▓▓▓▓░░░░░░░     ███   ████ ░░▓▓▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░ ▒ ░▒    ░░▓▓▓▓▓▓▓▓▓▓ ██████  ▓▓▓░░ ░░░░▓▓▓▓▓▓░░░░░░░░░▓▓▓   █████  ▓▓▓▓▓▓▓░░░░    ▒▒ ▒      ...................................
...................................░░░░ ░ ░░     ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓█░░░░░░░▓▓▓▓▓▓▓░░░░ ░░   ░░▓░▓▓░░░░░░░▓▓▓▓▓▓░░      ▒▒ ▒      ...................................
...................................░░░░ ░ ░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓██  ░░░░░░░▓▓▓▓▓▓▓░░░░  ░░░░░   ░░░░░░░░░▓▓▓▓▓░░ ░    ▒▒  ▒      ...................................
...................................░░░░▒░░▒░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓░░░  ░░░░░░░░░░░░░░░░░░▓▓░░░░      ▒▒  ▒     ....................................
...................................░░░░▒░░ ░░       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓▓▓░░░░  ░░░░░░░░░░░░░░░░░░░░░        ▒▒  ▒     ....................................
...................................░░░░░░░ ▒░▒       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░▓▓▓░░   ░░░░░  ░░░░░░░░░░░░░░░░░░░░         ▒   ▒     ....................................
...................................░░░░░░░░░░░           ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓              ░    ░░░░░░░░░░░░░░░            ▒   ▒     ....................................
....................................░░░░░░░░░░░▒  ▒▒        ▓▓▓▓▓▓▓▓▓▓▓▓▓  ░░░░░░░░░░▒▒                         ▒▒▒▒▒   ▒    ▒    .....................................
....................................░░░░░░░░░░ ░▒ ▒▒▒░░░        ▓▓▓▓▓▓   ░░░░░░░░░░░░░▒▒▒      ▒▒▒▒▒░░░░▒▒    ▒▒▒▒▒▒▒  ▒▒    ▒    .....................................
....................................░░░░░░░░░░ ░░░ ▒▒▒░░░░░░          ░░░░░ ░░░░░░░░░░▒░▒     ▒▒▒▒▒▒░░░░░░▒▒▒▒▒░▒▒▒▒   ▒▒         .....................................
.....................................░░░░░░░░░░ ░░░░░  ▒▒░░░░░░░░░░░░░    ░░░░░░░░░  ▒░▒▒    ▒▒▒▒▒░░░░▒▒▒▒▒▒░░▒▒▒   ▒▒▒         ......................................
.....................................░░░░░░░░░░░░░░░░░░  ▒░░░░░░░░░░░   ░░░░░░░░░░░░░░   ▒   ▒▒▒▒▒▒▒░▒▒▒▒▒▒░░░░▒▒▒   ▒▒          ......................................
.....................................░░░░░░░░░░░ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░      ▒▒▒▒▒▒▒    ▒  ░░░▒▒▒▒  ▒▒▒          ......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ▒░▒▒▒ ▒▒▒    ▒░░░░░░░░░░▒   ▒▒▒▒      ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒  ░░▒▒▒▒▒▒░░░░░░░░░░░░░▒  ░▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒ ▒▒░▒▒▒▒▒▒▒░░░░░░░░░░  ░░▒▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒ ░▒▒▒▒▒▒▒▒▒░░▒░░░░░░ ░░▒▒▒▒▒▒      ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒░░▒░▒▒▒ ▒▒▒▒▒░░░░░░░░░▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒░▒▒▒▒▒     ░░░░░░░░▒▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒░░▒░▒▒▒▒▒▒  ▒░░░░░░░▒▒▒▒▒▒        ▒     .......................................
NINJA_EOF

    echo ""
    echo -e "                                    \033[1;35m「 ドーモ。ニンジャスレイヤーです。 」\033[0m"
    echo ""
    echo -e "                               \033[0;36m[ASCII Art: syntax-samurai/ryu - CC0 1.0 Public Domain]\033[0m"
    echo ""

    # エージェント起動確認（最大10秒待機）【Phase 1高速化: 30秒→10秒】
    if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
        _wait_pane="main:crane"
        echo "  ◆電脳空間同期待機◆ マスター・クレインのニンジャソウル起動を待機中（最大10秒）..."
    else
        _wait_pane="main:darkninja"
        echo "  ◆電脳空間同期待機◆ ラオモトのニンジャソウル起動を待機中（最大10秒）..."
    fi

    for i in {1..10}; do
        if tmux capture-pane -t "$_wait_pane" -p 2>/dev/null | grep -q "bypass permissions"; then
            echo "  └─ 電脳IRC空間起動確認！（${i}秒）ニンジャソウル覚醒！ワザマエ！ワッショイ！"
            break
        fi
        sleep 1
    done

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.5.5: monitor エージェントへ Session Start 初期プロンプト送信
    # 現状: launch_agent後はウェルカム画面で停止。inbox_write+surikenで起動トリガー。
    # ═══════════════════════════════════════════════════════════════════
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" "$MONITOR_AGENT" \
        "Session Start手順を実行せよ。instructions/${MONITOR_AGENT}.mdを読め。" \
        task_assigned yokubari "" P0
    bash "$SCRIPT_DIR/scripts/njslyr_cmd.sh" suriken "$MONITOR_AGENT"
    log_info "  └─ ◆Session Start指示◆ ${MONITOR_AGENT}へ初期プロンプト送信完了！ワザマエ！"
    echo ""

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6: inbox_watcher起動（全エージェント）
    # ═══════════════════════════════════════════════════════════════════
    log_info "📬 ◆IRC監視開始◆ コトダマ空間チャンネル監視プロセスをスタート…ニューロンに接続！"

    # inbox ディレクトリ初期化（シンボリックリンク先のLinux FSに作成）
    mkdir -p "$SCRIPT_DIR/logs"
    for agent in darkninja gryakuza soukaiya "$MONITOR_AGENT"; do
        [ -f "$SCRIPT_DIR/queue/inbox/${agent}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    done
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        [ -f "$SCRIPT_DIR/queue/inbox/yakuza${i}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/yakuza${i}.yaml"
    done

    # 既存のwatcherと孤児inotifywaitをkill（プロジェクト固有パターンで誤kill防止）
    pkill -f "${SCRIPT_DIR}/scripts/inbox_watcher.sh" 2>/dev/null || true
    pkill -f "inotifywait.*${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    pkill -f "fswatch.*${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    sleep 0.3  # 【Phase 1高速化: 1秒→0.3秒】

    # ダークニンジャのwatcher（安全モード: エスカレーション無効、event-drivenのみ）（kyoto のみ）
    if [[ "$MACHINE_ROLE" != "neosaitama" && "$MACHINE_ROLE" != "mbp" ]]; then
        launch_watcher "darkninja" "main:darkninja" \
            "ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0"
    fi

    # FIX-016: pane_id（%N形式）でwatcher起動。INDEXベース廃止。
    # @agent_id属性からpane_idを動的解決することでウィンドウ名変更時の不一致を防ぐ。
    _watcher_pane_map=$(tmux list-panes -a -F '#{@agent_id} #{pane_id}' 2>/dev/null)
    _get_watcher_pane_id() {
        awk -v id="$1" '$1==id{print $2;exit}' <<< "$_watcher_pane_map"
    }

    # グレーターヤクザ・ヤクザ・ソウカイヤのwatcher
    _pid=$(  _get_watcher_pane_id "gryakuza");   [[ -n "$_pid" ]] && launch_watcher "gryakuza" "$_pid"
    for ((i=1; i<=YAKUZA_MAX; i++)); do
        _pid=$(_get_watcher_pane_id "yakuza${i}"); [[ -n "$_pid" ]] && launch_watcher "yakuza${i}" "$_pid"
    done
    _pid=$(  _get_watcher_pane_id "soukaiya");   [[ -n "$_pid" ]] && launch_watcher "soukaiya"  "$_pid"

    # 監視エージェントのwatcher
    _pid=$(_get_watcher_pane_id "$MONITOR_AGENT")
    if [[ -n "$_pid" ]]; then
        launch_watcher "$MONITOR_AGENT" "$_pid"
    else
        launch_watcher "$MONITOR_AGENT" "$MONITOR_PANE"
    fi

    # kyoto: darkninja + gryakuza + yakuzaN + soukaiya + monitor = YAKUZA_MAX + 4
    # neosaitama: gryakuza + yakuzaN + soukaiya + monitor = YAKUZA_MAX + 3
    if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
        _total_watchers=$((YAKUZA_MAX + 3))
    else
        _total_watchers=$((YAKUZA_MAX + 4))
    fi
    log_success "  └─ ◆実際完了◆ ${_total_watchers}エージェント分のIRC監視起動完了！全チャンネル接続！ワザマエ！"

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6.2: watcher_supervisor.sh起動（watcher自動復旧・FIX-007）
    # ═══════════════════════════════════════════════════════════════════
    log_info "🛡️  ◆Watcher監視開始◆ inbox_watcher自動復旧スーパーバイザー起動中…"

    # Kill any existing supervisor before starting a new one
    pkill -f "${SCRIPT_DIR}/scripts/watcher_supervisor.sh" 2>/dev/null || true
    nohup bash "$SCRIPT_DIR/scripts/watcher_supervisor.sh" \
        >> "$SCRIPT_DIR/logs/watcher_supervisor.log" 2>&1 &
    WATCHER_SUPERVISOR_PID=$!

    log_success "  └─ ◆実際完了◆ watcher_supervisor起動完了！PID=${WATCHER_SUPERVISOR_PID}。クラッシュ自動復旧ON。ワザマエ！"
    echo ""

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6.5: monitor_context.sh起動（コンテキスト監視・自動回復）
    # ═══════════════════════════════════════════════════════════════════
    log_info "📊 ◆コンテキスト監視開始◆ ニンジャソウル健康状態監視…ボディ・ガード起動！"

    # monitor_context.shをバックグラウンドで直接起動
    nohup bash "$SCRIPT_DIR/scripts/monitor_context.sh" >> "$SCRIPT_DIR/logs/monitor_context.log" 2>&1 &

    log_success "  └─ ◆実際完了◆ コンテキスト監視起動完了！閾値: 30%警告/20%アラート/10%自動clear。ワザマエ！"
    echo ""

    # STEP 6.7 は廃止 — CLAUDE.md Session Start (step 1: tmux agent_id) で各自が自律的に
    # 自分のinstructions/*.mdを読み込む。検証済み (2026-02-08)。
    log_info "📜 ◆自律実行◆ オキテの読み込みは各ニンジャが自律実行する。カラテは己で磨け"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.7.5: ntfy_inbox 古メッセージ退避（7日より前のprocessed分をアーカイブ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ -f ./queue/ntfy_inbox.yaml ]; then
    _archive_result=$(python3 -c "
import yaml, sys
from datetime import datetime, timedelta, timezone

INBOX = './queue/ntfy_inbox.yaml'
ARCHIVE = './queue/ntfy_inbox_archive.yaml'
DAYS = 7

with open(INBOX) as f:
    data = yaml.safe_load(f) or {}

entries = data.get('inbox', []) or []
if not entries:
    sys.exit(0)

cutoff = datetime.now(timezone(timedelta(hours=9))) - timedelta(days=DAYS)
recent, old = [], []

for e in entries:
    ts = e.get('timestamp', '')
    try:
        dt = datetime.fromisoformat(str(ts))
        if dt < cutoff and e.get('status') == 'processed':
            old.append(e)
        else:
            recent.append(e)
    except Exception:
        recent.append(e)

if not old:
    sys.exit(0)

# Append to archive
try:
    with open(ARCHIVE) as f:
        archive = yaml.safe_load(f) or {}
except FileNotFoundError:
    archive = {}
archive_entries = archive.get('inbox', []) or []
archive_entries.extend(old)
with open(ARCHIVE, 'w') as f:
    yaml.dump({'inbox': archive_entries}, f, allow_unicode=True, default_flow_style=False)

# Write back recent only
with open(INBOX, 'w') as f:
    yaml.dump({'inbox': recent}, f, allow_unicode=True, default_flow_style=False)

print(f'{len(old)}件退避 {len(recent)}件保持')
" 2>/dev/null) || true
    if [ -n "$_archive_result" ]; then
        log_info "📱 ntfy_inbox整理完了: $_archive_result → アーカイブ送り。インガオホー"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.8: ntfy入力リスナー起動
# ═══════════════════════════════════════════════════════════════════════════════
# NTFY_TOPIC は起動時の settings.yaml 読み込みで取得済み（grep|awk|tr → 0 fork）
# ntfy_listener起動: kyoto/neosaitama両方で起動。購読トピックはMACHINE_ROLEに基づきntfy_listener.sh内で決定。
# PIDチェックで二重起動防止。
if [ -n "$NTFY_TOPIC" ] && [[ "$MACHINE_ROLE" == "kyoto" || "$MACHINE_ROLE" == "ryzen" || "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
    if pgrep -f "ntfy_listener.sh" > /dev/null 2>&1; then
        log_info "📱 ntfyリスナー既に起動中。二重起動スキップ (topic: ${NTFY_TOPIC:0:8}...)"
    else
        nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
        disown
        log_info "📱 ◆ntfyリスナー起動◆ ラオモトのスマホからのコトダマを受信する (topic: ${NTFY_TOPIC:0:8}...)"
    fi
    # ntfy_listener supervisor: crash時自動再起動（I-001対策）
    if pgrep -f "ntfy_listener_supervisor.sh" > /dev/null 2>&1; then
        log_info "📱 ntfy_listener supervisorは既に起動中。スキップ"
    else
        nohup bash "$SCRIPT_DIR/scripts/ntfy_listener_supervisor.sh" >> "$SCRIPT_DIR/logs/ntfy_listener.log" 2>&1 &
        disown
        log_info "📱 ntfy_listener supervisor起動 (クラッシュ時30秒以内に自動再起動)"
    fi
elif [ -n "$NTFY_TOPIC" ]; then
    log_info "📱 未知のマシンロール(${MACHINE_ROLE}): ntfyリスナー起動スキップ"
else
    log_info "📱 ntfy未設定。ラオモトのスマホ回線は未接続…ナムアミダブツ"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: 環境確認・完了メッセージ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🔍 ジンヨウを最終確認中…アイサツの前のマナーだ"
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📺 Tmuxジンヨウ (Active Sessions)                        │"
echo "  └──────────────────────────────────────────────────────────┘"
tmux list-sessions | sed 's/^/     /'
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📋 フジンズ (Battle Formation)                           │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    echo "     【mainセッション】クレイン・ホンジン"
    echo "     ┌─────────────────────────────────┐"
    echo "     │  main:crane — master_crane       │  ← 監視エージェント"
    echo "     └─────────────────────────────────┘"
else
    echo "     【mainセッション】ラオモトのホンジン"
    echo "     ┌──────────────┬────────────────────┐"
    echo "     │ darkninja    │ monitor            │"
    echo "     │ ラオモト(CEO) │ master_tortoise    │"
    echo "     └──────────────┴────────────────────┘"
fi
echo ""
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
    echo "     【multiagent:agents】neosaitama フル構成（9ペイン）"
    echo "     ┌──────────┬─────────┬─────────┐"
    echo "     │ gryakuza │ yakuza3 │ yakuza6 │"
    echo "     │(GrYakuza)│  (Y3)   │  (Y6)   │"
    echo "     ├──────────┼─────────┼─────────┤"
    echo "     │ yakuza1  │ yakuza4 │ yakuza7 │"
    echo "     │   (Y1)   │  (Y4)   │  (Y7)   │"
    echo "     ├──────────┼─────────┼─────────┤"
    echo "     │ yakuza2  │ yakuza5 │soukaiya │"
    echo "     │   (Y2)   │  (Y5)   │(Soukaiya)│"
    echo "     └──────────┴─────────┴─────────┘"
else
    echo "     【multiagent:agents】kyotoフル構成（9ペイン）"
    echo "     ┌──────────┬─────────┬─────────┐"
    echo "     │ gryakuza │ yakuza3 │ yakuza6 │"
    echo "     │(GrYakuza)│  (Y3)   │  (Y6)   │"
    echo "     ├──────────┼─────────┼─────────┤"
    echo "     │ yakuza1  │ yakuza4 │ yakuza7 │"
    echo "     │   (Y1)   │  (Y4)   │  (Y7)   │"
    echo "     ├──────────┼─────────┼─────────┤"
    echo "     │ yakuza2  │ yakuza5 │soukaiya │"
    echo "     │   (Y2)   │  (Y5)   │(Soukaiya)│"
    echo "     └──────────┴─────────┴─────────┘"
fi
echo ""
echo "     監視エージェント: ${MONITOR_AGENT} → ${MONITOR_PANE}"
echo ""

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  ◆ ドーモ。ネオサイタマ・デプロイメント完了。イヤーッ！ ◆            ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    echo "  ⚠️  セットアップ・オンリー: Claude Codeは未起動。手動でショウカンせよ"
    echo ""
    echo "  手動でショウカンするには:"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  # ダークニンジャをショウカン                                              │"
    echo "  │  tmux send-keys -t main:darkninja \\                      │"
    echo "  │    'claude --dangerously-skip-permissions' Enter         │"
    echo "  │                                                          │"
    echo "  │  # グレーターヤクザ・ヤクザを一斉ショウカン                                  │"
    echo "  │  for p in \$(seq $PANE_BASE $((PANE_BASE+8))); do                                 │"
    echo "  │      tmux send-keys -t multiagent:agents.\$p \\            │"
    echo "  │      'claude --dangerously-skip-permissions' Enter       │"
    echo "  │  done                                                    │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
fi

echo "  ◆ ツギノ・アクション:"
echo "  ┌──────────────────────────────────────────────────────────┐"
if [[ "$MACHINE_ROLE" == "neosaitama" || "$MACHINE_ROLE" == "mbp" ]]; then
echo "  │  クレイン・ホンジンにアタッチ（監視開始）:                          │"
echo "  │     tmux attach-session -t main        (または: css)     │"
else
echo "  │  ラオモトのホンジンにアタッチしてメイレイを開始:                    │"
echo "  │     tmux attach-session -t main        (または: css)     │"
fi
echo "  │                                                          │"
echo "  │  グレーターヤクザ・ヤクザのジンを確認する:                            │"
echo "  │     tmux attach-session -t multiagent   (または: csm)    │"
echo "  │                                                          │"
echo "  │  ※ 各ニンジャはオキテを読み込み済み。                    │"
echo "  │    ラオモトのメイレイを待っている。イヤーッ！             │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ════════════════════════════════════════════════════════════"
echo "   ドーモ。ニンジャスレイヤーです。 (Domo. I am Ninja Slayer.)"
echo "  ════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Windows Terminal でタブを開く（-t オプション時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$OPEN_TERMINAL" = true ]; then
    log_info "📺 Windows Terminalでタブを展開中…ニューロンにジャックイン！"

    # Windows Terminal が利用可能か確認
    if command -v wt.exe &> /dev/null; then
        wt.exe -w 0 new-tab wsl.exe -e bash -c "tmux attach-session -t main" \; new-tab wsl.exe -e bash -c "tmux attach-session -t multiagent"
        log_success "  └─ ターミナルタブ展開完了！ワザマエ！"
    else
        log_info "  └─ アイエエエ！wt.exeが見つからない。手動でジャックインせよ"
    fi
    echo ""
fi
