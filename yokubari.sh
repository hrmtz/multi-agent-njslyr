#!/bin/bash
# 🏯 multi-agent-shogun ネオサイタマ・デプロイメント・スクリプト（毎日の起動用）
# Daily Deployment Script for Multi-Agent Orchestration System
#
# 使用方法:
#   ./shutsujin_departure.sh           # 全エージェント起動（前回の状態を維持）
#   ./shutsujin_departure.sh -c        # キューをリセットして起動（クリーンスタート）
#   ./shutsujin_departure.sh -s        # セットアップのみ（Claude起動なし）
#   ./shutsujin_departure.sh -h        # ヘルプ表示

set -e

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# macOS (Darwin): GNU coreutils via Homebrew gnubin
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
fi

# 言語設定を読み取り（デフォルト: ja）
LANG_SETTING="ja"
if [ -f "./config/settings.yaml" ]; then
    LANG_SETTING=$(grep "^language:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "ja")
fi

# シェル設定を読み取り（デフォルト: bash）
SHELL_SETTING="bash"
if [ -f "./config/settings.yaml" ]; then
    SHELL_SETTING=$(grep "^shell:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "bash")
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
    echo -e "\033[1;31m【カラテ】\033[0m $1"
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
                echo "グワーッ！ -shell オプションには bash または zsh を指定せよ"
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
            echo "  ./shutsujin_departure.sh --darkninja-no-thinking  # ラオモトのthinkingを無効化（中継特化）"
            echo "  ./shutsujin_departure.sh -S           # サイレントモード（echo表示なし）"
            echo ""
            echo "モデル構成:"
            echo "  ラオモト:      Opus（デフォルト。--darkninja-no-thinkingで無効化）"
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
            echo "エイリアス:"
            echo "  csst  → cd /mnt/c/tools/multi-agent-shogun && ./shutsujin_departure.sh"
            echo "  css   → tmux attach-session -t darkninja"
            echo "  csm   → tmux attach-session -t multiagent"
            echo ""
            exit 0
            ;;
        *)
            echo "アイエエエ！不明なオプション: $1"
            echo "./shutsujin_departure.sh -h でヘルプを表示せよ"
            exit 1
            ;;
    esac
done

# シェル設定のオーバーライド（コマンドラインオプション優先）
if [ -n "$SHELL_OVERRIDE" ]; then
    if [[ "$SHELL_OVERRIDE" == "bash" || "$SHELL_OVERRIDE" == "zsh" ]]; then
        SHELL_SETTING="$SHELL_OVERRIDE"
    else
        echo "グワーッ！ -shell には bash か zsh を指定せよ（指定値: $SHELL_OVERRIDE）。ケジメ案件！"
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

    # タイトルバナー（色付き）
    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███╗   ██╗     ██╗███████╗██╗  ██╗   ██╗██████╗                          \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m████╗  ██║     ██║██╔════╝██║  ╚██╗ ██╔╝██╔══██╗                         \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔██╗ ██║     ██║███████╗██║   ╚████╔╝ ██████╔╝                         \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║╚██╗██║██   ██║╚════██║██║    ╚██╔╝  ██╔══██╗                         \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██║ ╚████║╚█████╔╝███████║███████╗██║   ██║  ██║                         \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚═╝  ╚═══╝ ╚════╝ ╚══════╝╚══════╝╚═╝   ╚═╝  ╚═╝                         \033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m       \033[1;37mドーモ。ニンジャスレイヤーです。\033[0m    \033[1;36m⚔\033[0m    \033[1;35mイヤーッ！\033[0m                          \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # クローンヤクザ隊列（ヤクザAA）
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;34m  ╔═════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m                \033[1;37m【 クローンヤクザ隊列 ・ 七名 + 幹部 配備 】\033[0m                  \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚═════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo "⣿⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⢛⣛⣛⣛⣛⣛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⣿"
    echo "⣿⠀⠀⠀⠀⠀⠀⣠⠴⠊⠉⠁⠈⠀⠀⢀⡡⣿⣿⣶⣤⡀⠀⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠰⡮⡀⠀⠀⠀⢀⣀⠔⠊⢁⡠⠟⢿⣿⣿⣿⠆⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⢳⢬⣴⣶⠞⠋⣃⠔⠚⠉⠀⠀⢸⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⠘⡇⠑⢿⡤⠎⠁⠀⠀⣠⢠⢀⣼⣿⡿⢿⡇⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⢀⡇⢄⠠⠀⢠⠎⢀⢄⣀⣼⣶⣿⣿⣝⢁⡇⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⠘⡉⣷⣷⣷⡵⠲⣿⣿⣿⣿⡏⠀⡡⢮⣼⡅⠀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⠀⠡⣿⣿⣿⠟⢂⢿⣿⡿⡟⠡⢲⠁⣯⡈⠳⣀⠀⠀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⠀⠀⠹⡟⠣⡠⡴⠛⠡⠀⢸⠁⠂⠀⣿⢀⡔⠈⢧⡀⠀⠀⠀⣿"
    echo "⣿⠀⠀⠀⠀⠀⠀⠀⢀⡵⡐⢩⡧⣄⡐⠂⡨⢃⠀⡾⡤⠊⠀⠀⠈⢻⣖⠤⡀⣿"
    echo "⣿⠀⠀⠀⠀⢀⣠⠖⣱⡷⢿⠆⠀⠀⠀⡩⠖⢁⡼⠊⠀⠀⠀⠀⠀⣾⣿⣷⣆⣿"
    echo "⣿⠀⡀⠠⣒⡵⣡⣾⡟⠀⢎⠫⡻⡋⣉⠠⠚⠁⠀⠀⠀⠀⠀⠀⣸⣿⣿⣿⣿⣿"
    echo "⣿⣭⣶⣿⡟⣾⣿⡏⠀⢀⣴⣇⢠⢎⠅⣤⡀⠀⠀⠀⠀⢀⠠⡾⣿⣿⣿⣿⣿⣿"
    echo "⣿⣿⣿⣟⣾⢿⣿⠀⣠⣺⣿⣿⣿⣿⣿⣿⣿⢦⡀⠔⠈⠁⡔⣰⣿⣿⣿⣿⣿⣿"
    echo "⣿⣿⣿⣿⣵⣿⣿⣼⣥⣤⣿⣿⣿⣿⣿⣯⣥⣬⣭⣦⣤⣾⣿⣿⣿⣿⣿⣿⣿⣿"
    echo ""
    echo -e "                    \033[1;36m「「「 ザッケンナコラー！！ 」」」\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # システム情報
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m🏯 multi-agent-shogun\033[0m  〜 \033[1;36mネオサイタマ・マルチエージェント統率システム\033[0m 〜           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35mラオモト\033[0m: 統括  \033[1;31mグレーターヤクザ\033[0m: カンリ  \033[1;33mソウカイヤ\033[0m: 戦略(Opus)  \033[1;34mヤクザ\033[0m: ジッコウ×7  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# バナー表示実行
show_battle_cry

echo -e "  \033[1;33mドーモ。陣立てを開始する。イヤーッ！\033[0m (Setting up the battlefield)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: 既存セッションクリーンアップ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 既存セッションをサツバツ！と破壊する..."
tmux kill-session -t multiagent 2>/dev/null && log_info "  └─ multiagent…サヨナラ！爆発四散！" || log_info "  └─ multiagent…存在セズ。ナムアミダブツ"
tmux kill-session -t darkninja 2>/dev/null && log_info "  └─ darkninja…サヨナラ！爆発四散！" || log_info "  └─ darkninja…存在セズ。ナムアミダブツ"

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

    # 既存の dashboard.md 判定の後に追加
    if [ -f "./queue/darkninja_to_gryakuza.yaml" ]; then
        if grep -q "id: cmd_" "./queue/darkninja_to_gryakuza.yaml" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    if [ "$NEED_BACKUP" = true ]; then
        mkdir -p "$BACKUP_DIR" || true
        cp "./dashboard.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/reports" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/tasks" "$BACKUP_DIR/" 2>/dev/null || true
        cp "./queue/darkninja_to_gryakuza.yaml" "$BACKUP_DIR/" 2>/dev/null || true
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
    INBOX_LINUX_DIR="$HOME/.local/share/multi-agent-shogun/inbox"
    if [ ! -L ./queue/inbox ]; then
        mkdir -p "$INBOX_LINUX_DIR"
        [ -d ./queue/inbox ] && cp ./queue/inbox/*.yaml "$INBOX_LINUX_DIR/" 2>/dev/null && rm -rf ./queue/inbox
        ln -sf "$INBOX_LINUX_DIR" ./queue/inbox
        log_info "  └─ inbox → Linux FS ($INBOX_LINUX_DIR) にシンボリックリンク作成。ワザマエ"
    fi
fi

if [ "$CLEAN_MODE" = true ]; then
    log_info "📜 前回のYAMLキューを破棄する…サヨナラ！"

    # ヤクザタスクファイルリセット
    for i in {1..7}; do
        cat > ./queue/tasks/yakuza${i}.yaml << EOF
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
    for i in {1..7}; do
        cat > ./queue/reports/yakuza${i}_report.yaml << EOF
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
    for agent in darkninja gryakuza yakuza{1..7} soukaiya; do
        echo "messages:" > "./queue/inbox/${agent}.yaml"
    done

    log_success "✅ ゼンカイのデータ、全て爆発四散！クリーンスタート！ワザマエ！"
else
    log_info "📜 ゼンカイのジョウタイを維持してデプロイする。カラテの蓄積はムダにしない"
    log_success "✅ キュー・レポートYAML、ゼンカイのデータを引き継ぐ。ワザマエ！"
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
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  アイエエエ！tmuxが存在しない！ナムアミダブツ！       ║"
    echo "  ║  [ERROR] tmux not found!                              ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║  カラテが足りていない。まずfirst_setup.shを実行せよ:  ║"
    echo "  ║     ./first_setup.sh                                  ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: darkninja セッション作成（1ペイン・window 0 を必ず確保）
# ═══════════════════════════════════════════════════════════════════════════════
log_war "👑 ラオモトのホンジンをコンストラクト中...イヤーッ！"

# darkninja セッションがなければ作る（-s 時もここで必ず darkninja が存在するようにする）
# window 0 のみ作成し -n main で名前付け（第二 window にするとアタッチ時に空ペインが開くため 1 window に限定）
if ! tmux has-session -t darkninja 2>/dev/null; then
    tmux new-session -d -s darkninja -n main
fi

# スマホ等の小画面クライアント対策: aggressive-resize + latest
# css関数がスマホ用に専用ウィンドウを作るので、PCのウィンドウに干渉しない
tmux set-option -g window-size latest
tmux set-option -g aggressive-resize on

# ダークニンジャペインはウィンドウ名 "main" で指定（base-index 1 環境でも動く）
SHOGUN_PROMPT=$(generate_prompt "ラオモト" "magenta" "$SHELL_SETTING")
tmux send-keys -t darkninja:main "cd \"$(pwd)\" && export PS1='${SHOGUN_PROMPT}' && clear" Enter
tmux select-pane -t darkninja:main -P 'bg=#001520'  # ダークニンジャの Dark Blue
tmux set-option -p -t darkninja:main @agent_id "darkninja"

log_success "  └─ ラオモトのホンジン、コンストラクト完了！ワザマエ！"
echo ""

# pane-base-index を取得（1 の環境ではペインは 1,2,... になる）
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.1: multiagent セッション作成（9ペイン：gryakuza + yakuza1-8）
# ═══════════════════════════════════════════════════════════════════════════════
log_war "⚔️ グレーターヤクザ・ヤクザ・ソウカイヤをジェネレート中…9名配備！"

# 最初のペイン作成
if ! tmux new-session -d -s multiagent -n "agents" 2>/dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════════╗"
    echo "  ║  グワーッ！multiagentセッション生成に失敗！              ║"
    echo "  ║  アイエエエ！既存セッションのゴーストが残留している！    ║"
    echo "  ╠════════════════════════════════════════════════════════════╣"
    echo "  ║  ジョウキョウ確認:  tmux ls                              ║"
    echo "  ║  爆発四散させる:   tmux kill-session -t multiagent       ║"
    echo "  ╚════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# DISPLAY_MODE: shout (default) or silent (--silent flag)
if [ "$SILENT_MODE" = true ]; then
    tmux set-environment -t multiagent DISPLAY_MODE "silent"
    echo "  📢 ヒョウジモード: サイレント（ザッケンナコラーの叫びナシ。API節約重点）"
else
    tmux set-environment -t multiagent DISPLAY_MODE "shout"
fi

# 3x3グリッド作成（合計9ペイン）
# ペイン番号は pane-base-index に依存（0 または 1）
# 最初に3列に分割
tmux split-window -h -t "multiagent:agents"
tmux split-window -h -t "multiagent:agents"

# 各列を3行に分割
tmux select-pane -t "multiagent:agents.${PANE_BASE}"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+3))"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+6))"
tmux split-window -v
tmux split-window -v

# ペインラベル設定（プロンプト用: モデル名なし）
PANE_LABELS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")
# ペインタイトル設定（tmuxタイトル用: モデル名付き）
if [ "$KESSEN_MODE" = true ]; then
    PANE_TITLES=("Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus")
else
    PANE_TITLES=("Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Opus")
fi
# 色設定（gryakuza: 赤, yakuza: 青, soukaiya: 黄）
PANE_COLORS=("red" "blue" "blue" "blue" "blue" "blue" "blue" "blue" "yellow")

AGENT_IDS=("gryakuza" "yakuza1" "yakuza2" "yakuza3" "yakuza4" "yakuza5" "yakuza6" "yakuza7" "soukaiya")

# モデル名設定（pane-border-format で常時表示するため）
# デフォルト（Claude用）
if [ "$KESSEN_MODE" = true ]; then
    MODEL_NAMES=("Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus" "Opus")
else
    MODEL_NAMES=("Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Sonnet" "Opus")
fi

# CLI Adapter経由でモデル名を動的に上書き
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    for i in {0..8}; do
        _agent="${AGENT_IDS[$i]}"
        _cli=$(get_cli_type "$_agent")
        case "$_cli" in
            claude)
                _claude_model=$(get_agent_model "$_agent")
                if [[ -n "$_claude_model" ]]; then
                    # haiku→Haiku, opus→Opus, sonnet→Sonnet に正規化
                    MODEL_NAMES[$i]=$(echo "$_claude_model" | sed 's/^./\U&/')
                fi
                ;;
            codex)
                # settings.yamlのmodelを優先表示、なければconfig.tomlのeffort
                _codex_model=$(get_agent_model "$_agent")
                if [[ -n "$_codex_model" ]]; then
                    MODEL_NAMES[$i]="codex/${_codex_model}"
                else
                    _codex_effort=$(grep '^model_reasoning_effort' ~/.codex/config.toml 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/')
                    _codex_effort=${_codex_effort:-high}
                    MODEL_NAMES[$i]="codex/${_codex_effort}"
                fi
                ;;
            copilot)
                MODEL_NAMES[$i]="Copilot"
                ;;
            kimi)
                MODEL_NAMES[$i]="Kimi"
                ;;
        esac
    done
fi

for i in {0..8}; do
    p=$((PANE_BASE + i))
    tmux select-pane -t "multiagent:agents.${p}" -T "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @agent_id "${AGENT_IDS[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @current_task ""
    PROMPT_STR=$(generate_prompt "${PANE_LABELS[$i]}" "${PANE_COLORS[$i]}" "$SHELL_SETTING")
    tmux send-keys -t "multiagent:agents.${p}" "cd \"$(pwd)\" && export PS1='${PROMPT_STR}' && clear" Enter
done

# グレーターヤクザ・ソウカイヤペインの背景色（ヤクザとの視覚的区別）
# 注: グループセッションで背景色が引き継がれない問題があるため、コメントアウト（2026-02-14）
# tmux select-pane -t "multiagent:agents.${PANE_BASE}" -P 'bg=#501515'          # グレーターヤクザ: 赤
# tmux select-pane -t "multiagent:agents.$((PANE_BASE+8))" -P 'bg=#454510'      # ソウカイヤ: 金

# pane-border-format でモデル名を常時表示
tmux set-option -t multiagent -w pane-border-status top
tmux set-option -t multiagent -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

# ウィンドウを最大クライアントサイズまで拡張し、ペインを均等配分
tmux resize-window -A -t multiagent:agents
tmux select-layout -t multiagent:agents tiled

log_success "  └─ グレーターヤクザ・ヤクザ・ソウカイヤのジン、コンストラクト完了！ワザマエ！"
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
            log_info "アイエエエ！claudeコマンドが存在しない！カラテが足りていない！"
            echo "  first_setup.shを実行してカラテを補充せよ:"
            echo "    ./first_setup.sh"
            exit 1
        fi
    fi

    log_war "👑 全エージェントにClaude Codeをインストール中...イヤーッ！"

    # ダークニンジャ: CLI Adapter経由でコマンド構築
    _darkninja_cli_type="claude"
    _darkninja_cmd="claude --model opus --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _darkninja_cli_type=$(get_cli_type "darkninja")
        _darkninja_cmd=$(build_cli_command "darkninja")
    fi
    tmux set-option -p -t "darkninja:main" @agent_cli "$_darkninja_cli_type"
    if [ "$SHOGUN_NO_THINKING" = true ] && [ "$_darkninja_cli_type" = "claude" ]; then
        tmux send-keys -t darkninja:main "MAX_THINKING_TOKENS=0 $_darkninja_cmd"
        tmux send-keys -t darkninja:main Enter
        log_info "  └─ ラオモト（${_darkninja_cli_type} / thinking無効）…ニンジャソウル覚醒！"
    else
        tmux send-keys -t darkninja:main "$_darkninja_cmd"
        tmux send-keys -t darkninja:main Enter
        log_info "  └─ ラオモト（${_darkninja_cli_type}）…ニンジャソウル覚醒！"
    fi

    # 少し待機（安定のため）
    sleep 1

    # グレーターヤクザ（pane 0）: CLI Adapter経由でコマンド構築（デフォルト: Sonnet）
    p=$((PANE_BASE + 0))
    _gryakuza_cli_type="claude"
    _gryakuza_cmd="claude --model sonnet --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _gryakuza_cli_type=$(get_cli_type "gryakuza")
        _gryakuza_cmd=$(build_cli_command "gryakuza")
    fi
    # Codex等の初期プロンプト付加（サジェストUI停止問題対策）
    _startup_prompt=$(get_startup_prompt "gryakuza" 2>/dev/null)
    if [[ -n "$_startup_prompt" ]]; then
        _gryakuza_cmd="$_gryakuza_cmd \"$_startup_prompt\""
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_gryakuza_cli_type"
    tmux send-keys -t "multiagent:agents.${p}" "$_gryakuza_cmd"
    tmux send-keys -t "multiagent:agents.${p}" Enter
    log_info "  └─ ${GRYAKUZA_CORP}のグレーターヤクザ（${_gryakuza_cli_type}）…配備完了！"

    if [ "$KESSEN_MODE" = true ]; then
        # 決戦の陣: CLI Adapter経由（claudeはOpus強制）
        for i in {1..7}; do
            p=$((PANE_BASE + i))
            _yakuza_cli_type="claude"
            _yakuza_cmd="claude --model opus --dangerously-skip-permissions"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _yakuza_cli_type=$(get_cli_type "yakuza${i}")
                if [ "$_yakuza_cli_type" = "claude" ]; then
                    _yakuza_cmd="claude --model opus --dangerously-skip-permissions"
                else
                    _yakuza_cmd=$(build_cli_command "yakuza${i}")
                fi
            fi
            # Codex等の初期プロンプト付加（サジェストUI停止問題対策）
            _startup_prompt=$(get_startup_prompt "yakuza${i}" 2>/dev/null)
            if [[ -n "$_startup_prompt" ]]; then
                _yakuza_cmd="$_yakuza_cmd \"$_startup_prompt\""
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_yakuza_cli_type"
            tmux send-keys -t "multiagent:agents.${p}" "$_yakuza_cmd"
            tmux send-keys -t "multiagent:agents.${p}" Enter
        done
        log_info "  └─ ヤクザ1-7（ケッセンの陣）…全員Opus！ニンジャソウル覚醒！サツバツ！"
    else
        # 平時の陣: CLI Adapter経由（デフォルト: 全ヤクザ=Sonnet）
        for i in {1..7}; do
            p=$((PANE_BASE + i))
            _yakuza_cli_type="claude"
            _yakuza_cmd="claude --model sonnet --dangerously-skip-permissions"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _yakuza_cli_type=$(get_cli_type "yakuza${i}")
                _yakuza_cmd=$(build_cli_command "yakuza${i}")
            fi
            # Codex等の初期プロンプト付加（サジェストUI停止問題対策）
            _startup_prompt=$(get_startup_prompt "yakuza${i}" 2>/dev/null)
            if [[ -n "$_startup_prompt" ]]; then
                _yakuza_cmd="$_yakuza_cmd \"$_startup_prompt\""
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_yakuza_cli_type"
            tmux send-keys -t "multiagent:agents.${p}" "$_yakuza_cmd"
            tmux send-keys -t "multiagent:agents.${p}" Enter
        done
        log_info "  └─ ヤクザ1-7（ヘイジの陣）…生成完了！"
    fi

    # ソウカイヤ（pane 8）: Opus Thinking — 戦略立案・設計判断専任
    p=$((PANE_BASE + 8))
    _soukaiya_cli_type="claude"
    _soukaiya_cmd="claude --model opus --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _soukaiya_cli_type=$(get_cli_type "soukaiya")
        _soukaiya_cmd=$(build_cli_command "soukaiya")
    fi
    # Codex等の初期プロンプト付加（サジェストUI停止問題対策）
    _startup_prompt=$(get_startup_prompt "soukaiya" 2>/dev/null)
    if [[ -n "$_startup_prompt" ]]; then
        _soukaiya_cmd="$_soukaiya_cmd \"$_startup_prompt\""
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_soukaiya_cli_type"
    tmux send-keys -t "multiagent:agents.${p}" "$_soukaiya_cmd"
    tmux send-keys -t "multiagent:agents.${p}" Enter
    log_info "  └─ ソウカイヤ（${_soukaiya_cli_type} / Opus Thinking）…ニンジャソウル覚醒！ドーモ"

    if [ "$KESSEN_MODE" = true ]; then
        log_success "✅ ケッセンの陣でデプロイ！全軍Opus！カラテが溢れている！！"
    else
        log_success "✅ ヘイジの陣でデプロイ完了！（グレーターヤクザ=Sonnet, Y=Sonnet, ソウカイヤ=Opus）ワザマエ！"
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

    echo "  ラオモトのClaude Code起動を待機中（最大30秒）..."

    # ダークニンジャの起動を確認（最大30秒待機）
    for i in {1..30}; do
        if tmux capture-pane -t darkninja:main -p | grep -q "bypass permissions"; then
            echo "  └─ ラオモト起動確認！（${i}秒）ニンジャソウル覚醒！ワザマエ！"
            break
        fi
        sleep 1
    done

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6: inbox_watcher起動（全エージェント）
    # ═══════════════════════════════════════════════════════════════════
    log_info "📬 IRCチャンネル監視プロセスをスタート…ニューロンに接続！"

    # inbox ディレクトリ初期化（シンボリックリンク先のLinux FSに作成）
    mkdir -p "$SCRIPT_DIR/logs"
    for agent in darkninja gryakuza yakuza{1..7} soukaiya; do
        [ -f "$SCRIPT_DIR/queue/inbox/${agent}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    done

    # 既存のwatcherと孤児inotifywaitをkill
    pkill -f "inbox_watcher.sh" 2>/dev/null || true
    pkill -f "inotifywait.*queue/inbox" 2>/dev/null || true
    pkill -f "fswatch.*queue/inbox" 2>/dev/null || true
    sleep 1

    # ダークニンジャのwatcher（ntfy受信の自動起床に必要）
    # 安全モード: phase2/phase3エスカレーションは無効、timeout周期処理も無効（event-drivenのみ）
    _darkninja_watcher_cli=$(tmux show-options -p -t "darkninja:main" -v @agent_cli 2>/dev/null || echo "claude")
    nohup env ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0 \
        bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" darkninja "darkninja:main" "$_darkninja_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_darkninja.log" 2>&1 &
    disown

    # グレーターヤクザのwatcher
    _gryakuza_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${PANE_BASE}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" gryakuza "multiagent:agents.${PANE_BASE}" "$_gryakuza_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_gryakuza.log" 2>&1 &
    disown

    # ヤクザのwatcher
    for i in {1..7}; do
        p=$((PANE_BASE + i))
        _yakuza_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "yakuza${i}" "multiagent:agents.${p}" "$_yakuza_watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_yakuza${i}.log" 2>&1 &
        disown
    done

    # ソウカイヤのwatcher
    p=$((PANE_BASE + 8))
    _soukaiya_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "soukaiya" "multiagent:agents.${p}" "$_soukaiya_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_soukaiya.log" 2>&1 &
    disown

    log_success "  └─ 10エージェント分のIRC監視起動完了！全チャンネル接続！ワザマエ！"

    # STEP 6.7 は廃止 — CLAUDE.md Session Start (step 1: tmux agent_id) で各自が自律的に
    # 自分のinstructions/*.mdを読み込む。検証済み (2026-02-08)。
    log_info "📜 オキテの読み込みは各ニンジャが自律実行する。カラテは己で磨け"
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
NTFY_TOPIC=$(grep 'ntfy_topic:' ./config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
if [ -n "$NTFY_TOPIC" ]; then
    pkill -f "ntfy_listener.sh" 2>/dev/null || true
    [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
    nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
    disown
    log_info "📱 ntfyリスナー起動…ラオモトのスマホからのコトダマを受信する (topic: $NTFY_TOPIC)"
else
    log_info "📱 ntfy未設定。ラオモトのスマホ回線は未接続。ナムアミダブツ"
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
echo "     【darkninjaセッション】ラオモトのホンジン"
echo "     ┌─────────────────────────────────┐"
echo "     │  Pane 0: ラオモト (DARKNINJA)    │  ← メガコーポCEO・プロジェクト統括"
echo "     └─────────────────────────────────┘"
echo ""
echo "     【multiagentセッション】グレーターヤクザ・ヤクザ・ソウカイヤのジン（3x3 = 9ペイン）"
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
    echo "  │  # ラオモトをショウカン                                              │"
    echo "  │  tmux send-keys -t darkninja:main \\                      │"
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
echo "  │  ラオモトのホンジンにアタッチしてメイレイを開始:                    │"
echo "  │     tmux attach-session -t darkninja   (または: css)     │"
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
        wt.exe -w 0 new-tab wsl.exe -e bash -c "tmux attach-session -t darkninja" \; new-tab wsl.exe -e bash -c "tmux attach-session -t multiagent"
        log_success "  └─ ターミナルタブ展開完了！ワザマエ！"
    else
        log_info "  └─ アイエエエ！wt.exeが見つからない。手動でジャックインせよ"
    fi
    echo ""
fi
