<div align="center">

# multi-agent-njslyr

**AIエージェント10体。ターミナル1つ。調整コストゼロ。**

Claude Code / OpenAI Codex / GitHub Copilot / Kimi Code を並列稼働 — ソウカイ・シンジケートの指揮系統でtmux上に統率

[![GitHub Stars](https://img.shields.io/github/stars/hrmtz/multi-agent-njslyr?style=social)](https://github.com/hrmtz/multi-agent-njslyr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v4.0 Infra Overhaul](https://img.shields.io/badge/v4.0-Infra_Overhaul-ff6600?style=flat-square)](https://github.com/hrmtz/multi-agent-njslyr)
[![BATS 46/46](https://img.shields.io/badge/BATS-46%2F46_PASS-brightgreen?style=flat-square)]()

[English](README.md) | [日本語](README_ja.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="tmuxペインで10体のエージェントが並列稼働" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="自然言語でコマンド入力" width="420">
  <img src="images/company-creed-all-panes.png" alt="ヤマヒロとクローンヤクザが並列作業中" width="520">
</p>

<p align="center"><i>ヤマヒロ（マネージャー）がクローンヤクザ7体＋ソウカイヤ幹部1体を統率 — 実際の稼働画面、モックデータなし</i></p>

---

> **[multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) の[ニンジャスレイヤー](https://diehardtales.com/n/ndb78a66e0e79) MOD。** オリジナルは戦国武将ヒエラルキー（将軍/家老/足軽）。本フォークは命名体系を**ソウカイ・シンジケート**に全面書き換え: ダークニンジャ/ヤマヒロ（グレーターヤクザ）/クローンヤクザ。アーキテクチャは同一、世界観が違う。

## これは何？

tmux上で10体のAIコーディングエージェントを並列稼働させ、YAMLファイルでAPIオーバーヘッドゼロで統率するシステム。

```
      あなた（ラオモト）
           |
           v
    +--------------+
    | ダークニンジャ|  命令を受け取り、即座に委任
    +------+-------+
           |
    +------v-------+               +------------------+
    |  ヤマヒロ     |--過負荷----->| ヤクザ天狗        |
    |（マネージャー）|<--引き継ぎ--| (緊急スーパー)    |
    +------+-------+               +------------------+
           |
    +-+-+-+-+-+-+-+----------+
    |1|2|3|4|5|6|7| ソウカイヤ|   7体のワーカー + 1体の参謀
    +-+-+-+-+-+-+-+----------+
```

**なぜ使うのか？**
- 1つの命令で8体のAIワーカーが並列実行
- 待ち時間なし — バックグラウンド実行中も次の命令を出せる
- 自動回復: 監視デーモンがクラッシュしたエージェントを蘇生＋緊急スーパーバイザーを自動spawn
- 通信はすべてディスク上のYAML — 完全に透明、差分管理、バージョン管理可能

---

## APIベースのマルチエージェントFWと何が違う？

| | Claude Code `Task` | LangGraph | CrewAI | **njslyr** |
|---|---|---|---|---|
| **並列性** | 逐次 | グラフノード | 限定的 | **8体の独立エージェント** |
| **調整コスト** | Taskごとにapi呼び出し | API+インフラ(Postgres/Redis) | API+プラットフォーム | **ゼロ**（YAML+tmux） |
| **可観測性** | ログのみ | LangSmith | OpenTelemetry | **ライブtmuxペイン** |
| **自己回復** | なし | 手動 | なし | **3段階エスカレーション+ヤクザ天狗** |
| **コスト（Opus8体）** | 〜$100+/時間(API) | 〜$100+/時間(API) | 〜$100+/時間(API) | **〜$200/月**（CLI定額） |

CLIサブスクリプションにより、24時間マルチエージェント運用が経済的に成立する。1時間でも24時間でもコストは同じ。

---

## クイックスタート

### Windows (WSL2)

| ステップ | 操作 |
|---------|------|
| 1 | `git clone https://github.com/hrmtz/multi-agent-njslyr.git C:\tools\multi-agent-njslyr` |
| 2 | `install.bat` を右クリック→管理者として実行 |
| 3 | Ubuntuで: `cd /mnt/c/tools/multi-agent-njslyr && ./first_setup.sh` |
| 4 | `./yokubari.sh` |

初回認証: `claude --dangerously-skip-permissions` → ブラウザログイン → 承認 → `/exit`

### Linux / macOS

```bash
git clone https://github.com/hrmtz/multi-agent-njslyr.git ~/multi-agent-njslyr
cd ~/multi-agent-njslyr && chmod +x *.sh
./first_setup.sh   # 初回のみ
./yokubari.sh      # 毎日の起動
```

### セットアップ完了後

2つのtmuxセッションに10体のエージェントが自動起動:

| セッション | エージェント | 接続 |
|-----------|------------|------|
| `darkninja` | ダークニンジャ（あなたの窓口） | `tmux attach -t darkninja` |
| `multiagent` | ヤマヒロ＋クローンヤクザ7体＋ソウカイヤ | `tmux attach -t multiagent` |

---

## 使い方

**1. 命令を出す** — ダークニンジャに自然言語で話す。

**2. ダークニンジャが委任** — タスクYAMLを書いてヤマヒロに通知。コントロールは即座にあなたに戻る。

**3. ヤマヒロが配分** — サブタスクに分解し、クローンヤクザに並列アサイン。

**4. ワーカーが実行** — 各クローンヤクザが独立したtmuxペインで作業。リアルタイムで確認可能。

**5. 結果が返る** — クローンヤクザ → ソウカイヤ（QC）→ ヤマヒロ（ダッシュボード）→ ダークニンジャ → あなた。

```
あなた: 「MCPサーバー5つを調査して比較表を作れ」
  |
  v  ダークニンジャが委任
  |
  +-> クローンヤクザ1: Notion MCP    \
  +-> クローンヤクザ2: GitHub MCP     |
  +-> クローンヤクザ3: Playwright MCP +-> 5体が同時に調査
  +-> クローンヤクザ4: Memory MCP     |
  +-> クローンヤクザ5: Seq. Thinking /
  |
  v  結果がdashboard.mdに反映
```

---

## 主要機能

### イベント駆動通信（ゼロポーリング）

エージェント間通信はディスク上のYAMLファイル。ポーリングなし、APIコール浪費なし。

```
ヤマヒロがqueue/inbox/yakuza3.yamlに書き込み（flock保護）
  -> inbox_watcherがファイル変更を検知（inotifywait/fswatch）
  -> エージェントのtmuxペインに短いスリケン送信
  -> エージェントが自分のinboxを読んで処理
```

メッセージ内容はtmuxを経由しない — 短い起床シグナルのみ。待機中CPU使用率ゼロ。

### njslyr — 監視デーモン

3段階エスカレーションによるエージェント自動回復:

| ステージ | トリガー | アクション |
|---------|---------|----------|
| **スリケン** | inbox無視2分超 | tmux経由で軽いスリケン送信 |
| **チョップ** | 4分後も無応答 | `/clear` で強制セッションリセット |
| **スレイ** | 6分後も無応答 | `kill -9` + 自動再起動 |

ヤマヒロが過負荷のとき、**ヤクザ天狗**（緊急スーパーバイザー）が自動spawn: アイドルのクローンヤクザペインを乗っ取り、山積みタスクを配分、ヤマヒロ復帰後にdespawn。

### njslyr_cmd.sh — オペレーションコマンド

ワンコマンドでインフラ操作:

```bash
bash scripts/njslyr_cmd.sh suriken yakuza3       # エージェントを起床
bash scripts/njslyr_cmd.sh chop gryakuza          # 強制/clear
bash scripts/njslyr_cmd.sh slay yakuza2 "crashed"  # kill + 再起動
bash scripts/njslyr_cmd.sh spawn_tengu yakuza7 "オーバーフロー支援"
bash scripts/njslyr_cmd.sh despawn_tengu
bash scripts/njslyr_cmd.sh detox yakuza3           # Opus → Sonnet
```

### バリキドリンク（Opus投与）

SonnetエージェントをOpusに一時昇格。ペインが紫色（`#1a002e`）に変わる。タスク完了後に自動解毒（Sonnet復帰）。

### モンジュ — Opus3体相互批判QC

アルファ/ベータ版スクリプトに対し、Opus3体が独立にコードレビュー → 相互批判 → バグ修正。「三人寄れば文殊の知恵」から命名。

### Bloom分類法ルーティング

| 認知レベル | ルーティング先 |
|-----------|--------------|
| L1-L3: 記憶/理解/適用 | **クローンヤクザ**（Sonnet） |
| L4-L6: 分析/評価/創造 | **ソウカイヤ幹部**（Opus） |

### マルチCLI対応

| CLI | 強み | デフォルトモデル |
|-----|------|----------------|
| **Claude Code** | tmux統合、Memory MCP、専用ファイルツール | Claude Sonnet 4.5 |
| **OpenAI Codex** | サンドボックス実行、`codex exec`ヘッドレスモード | gpt-5.3-codex |
| **GitHub Copilot** | 内蔵GitHub MCP、4つの特化エージェント | Claude Sonnet 4.5 |
| **Kimi Code** | 無料枠、多言語サポート | Kimi k2 |

### セッション横断メモリ（Memory MCP）

好み、ルール、教訓がセッションを跨いで永続化。一度伝えれば、AIは永遠に覚えている。

### スマホからの指揮（ntfy）

スマホとダークニンジャの双方向通信 — SSH不要:

```
スマホ(ntfyアプリ) --> ntfy_listener.sh --> ダークニンジャが処理
ヤマヒロ更新 --> ntfy.sh --> スマホにプッシュ通知
```

設定: `config/settings.yaml` に `ntfy_topic: "darkninja-yourname"` を追加し、[ntfyアプリ](https://ntfy.sh)で同じトピックを購読。

### モバイルSSH（Tailscale + Termux）

tmuxの完全操作をスマホから:

1. ホストとスマホ両方に[Tailscale](https://tailscale.com/)をインストール
2. スマホに[Termux](https://termux.dev/)をインストール
3. `ssh user@tailscale-ip` → `tmux attach -t darkninja`

---

## モデル設定

| エージェント | モデル | 役割 |
|-------------|-------|------|
| ダークニンジャ | Opus | 最高指揮官、あなたの命令を受ける |
| ヤマヒロ（Gryakuza） | Sonnet | タスク配分、QC、ダッシュボード |
| ソウカイヤ幹部 | Opus | 深い分析、設計レビュー |
| クローンヤクザ 1-7 | Sonnet | 実装: コード、調査、ファイル操作 |
| ヤクザ天狗 | Sonnet | 緊急スーパーバイザー（一時的） |

---

## 設定

```yaml
# config/settings.yaml
language: ja          # 忍殺語
language: en          # ＋英語翻訳

screenshot:
  path: "/path/to/screenshots"

ntfy_topic: "darkninja-yourname"
```

<details>
<summary><b>yokubari.shオプション</b></summary>

```bash
./yokubari.sh                          # フルスタートアップ
./yokubari.sh -s, --setup-only         # セッション作成のみ
./yokubari.sh -c, --clean              # タスクキューをクリーン
./yokubari.sh -k, --kessen             # 決戦陣形: 全ヤクザをOpusに
./yokubari.sh -S, --silent             # 雄叫び無効化
./yokubari.sh --darkninja-no-thinking  # ダークニンジャ・リレーのみモード
```

</details>

---

## ファイル構成

```
multi-agent-njslyr/
├── yokubari.sh                # 日常デプロイ
├── first_setup.sh             # 初回セットアップ
├── install.bat                # Windows WSL2セットアップ
│
├── instructions/              # エージェント行動定義
│   ├── darkninja.md
│   ├── gryakuza.md
│   ├── yakuza.md
│   ├── soukaiya.md
│   ├── yakuzatengu.md
│   ├── common/                # 共有ルール
│   └── cli_specific/          # CLI固有ツール記述
│
├── scripts/
│   ├── njslyr.sh              # 監視デーモン
│   ├── njslyr_cmd.sh          # オペレーションコマンド
│   ├── njslyr_lib.sh          # 共有ライブラリ
│   ├── inbox_write.sh         # メッセージ書き込み
│   ├── inbox_watcher.sh       # inbox変更検知
│   ├── watcher_supervisor.sh  # watcherライフサイクル管理
│   ├── ntfy.sh                # プッシュ通知
│   └── ntfy_listener.sh       # スマホメッセージ受信
│
├── queue/                     # 通信ファイル（真実のソース）
│   ├── inbox/                 # エージェント別inbox
│   ├── tasks/                 # タスク割り当て
│   └── reports/               # 完了レポート
│
├── skills/                    # 再利用可能なオペレーションパターン
│   ├── opus-3body-review/     # モンジュ: Opus3体相互批判
│   ├── pipeline-runner/       # 多段パイプライン実行
│   ├── tengu-spawn/           # ヤクザ天狗ライフサイクル
│   └── skill-creator/         # メタ: 新スキル作成
│
├── tests/                     # BATSテストスイート（46テスト）
├── config/                    # 設定、プロジェクト、認証
├── CLAUDE.md                  # Claude Code自動読み込み
├── AGENTS.md                  # GitHub Copilot自動読み込み
└── dashboard.md               # リアルタイムステータスボード
```

---

## 設計思想

**なぜ階層構造？** ダークニンジャが即座に委任（待ち時間なし）。ヤマヒロが複数ワーカーに配分（並列実行）。各ロールが単一責任。1体の障害が他に影響しない。

**なぜYAMLメールボックス？** ファイルはエージェントクラッシュを生存。`inotifywait` はイベント駆動（待機中CPUゼロ）。エージェント毎に専用inbox（クロストークなし）。`flock` で並行書き込み破壊を防止。全メッセージがプレーンテキストで検査可能。

**なぜダッシュボード更新はヤマヒロだけ？** 単一ライター＝競合なし。一貫した品質ゲート。完全な情報集約。

---

## トラブルシューティング

<details>
<summary><b>ワーカーがスタック？</b></summary>

njslyrが自動回復するはず。動いていない場合: `bash scripts/njslyr.sh &`

手動介入:
```bash
bash scripts/njslyr_cmd.sh suriken yakuza3   # 軽い起床
bash scripts/njslyr_cmd.sh chop yakuza3      # 強制/clear
bash scripts/njslyr_cmd.sh slay yakuza3      # kill + 再起動
```

</details>

<details>
<summary><b>エージェントがクラッシュ？</b></summary>

```bash
# エージェントのペインで:
claude --dangerously-skip-permissions

# または強制再起動:
tmux respawn-pane -t multiagent:0.X -k 'claude --dangerously-skip-permissions'
```

</details>

<details>
<summary><b>MCPツールが読み込まれない？</b></summary>

MCPツールは遅延読み込み:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

---

## tmuxチートシート

| コマンド | 説明 |
|---------|------|
| `tmux attach -t darkninja` | ダークニンジャに接続 |
| `tmux attach -t multiagent` | ワーカーに接続 |
| `Ctrl+B` → `0`-`8` | ペイン切り替え |
| `Ctrl+B` → `d` | デタッチ（エージェント稼働継続） |

---

## 更新履歴

### v4.0 — インフラ大型改修

- **njslyr_cmd.sh** — ワンコマンドオペレーション: `suriken`、`chop`、`slay`、`spawn_tengu`、`despawn_tengu`、`detox`
- **njslyr_lib.sh** — njslyr.shから共有ライブラリ抽出（resolve_pane_by_agent_id、agent_is_busy）
- **3層自己識別防御** — `/clear` 後にエージェントが自分を誤認するバグを根絶（確認済みインシデント3件を修正）
- **inject_barikidorinkフェイルセーフ** — Opus投与の冪等化、モデルスイッチ後の自動re-nudge、task_yaml_pathオプション
- **idle検知v2** — `/clear` 後のグレースピリオド、inbox未読チェック、タスクステータス認識
- **stale状態ファイル自動クリーンアップ** — STALE_THRESHOLDを超過した古いstateファイルを自動削除
- **長期稼働リフレッシュ** — 4時間間隔の強制stateクリーンアップ（連日稼働対応）
- **orphan watcher自己終了** — ターゲットペイン消失時にinbox_watcherが自動exit
- **watcher_supervisor改善** — 動的ペイン探索、アトミックrescanシグナル、クラッシュwatcher自動再起動
- **BATSテスト46本**（19本から増加） — BUG-IDLE、BUG-STALE、TC-B4、spawn/despawn、slayライフサイクル
- **macOS互換性** — GNU coreutils PATH、BSD date fallback

### v3.5 — ヤクザ天狗

- ヤクザ天狗緊急スーパーバイザー（マネージャー過負荷時に自動spawn）
- エージェント命名（Gryakuza → ヤマヒロ）
- `/clear` 後のクローンヤクザ・ペルソナ維持

### v3.4 — Bloomルーティング、E2Eテスト

- Bloom→エージェント・ルーティング（L1-L3→クローンヤクザ、L4-L6→ソウカイヤ）
- ソウカイヤ幹部のファーストクラス化
- E2Eテストスイート（19テスト、7シナリオ）
- Stop Hookインボックス配信

### v3.0 — マルチCLI

- マルチCLIアーキテクチャ（Claude/Codex/Copilot/Kimi）
- `lib/cli_adapter.sh` 動的CLI選択
- コミュニティCLIアダプタ: [@yuto-ts](https://github.com/yuto-ts)、[@circlemouth](https://github.com/circlemouth)、[@koba6316](https://github.com/koba6316)

<details>
<summary><b>v2.0</b></summary>

- ntfy双方向通信＋SayTask
- ペインボーダー・タスク表示＋シャウトモード
- エージェント自己監視＋3段階エスカレーション
- エージェント自己識別（`@agent_id`）
- 決戦モード（`-k`）、タスク依存関係（`blockedBy`）

</details>

---

## クレジット

[Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication) by Akira-Papa をベースにしています。

[multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) by [@yohey-w](https://github.com/yohey-w) のフォークです。

## ライセンス

[MIT](LICENSE)

---

<div align="center">

**コマンド1つ。10体のエージェント。調整コストゼロ。**

</div>
