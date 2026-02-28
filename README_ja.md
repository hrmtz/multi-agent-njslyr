<div align="center">

# multi-agent-njslyr

**AIエージェント10体。ターミナル1つ。調整コストゼロ。**

ソウカイ・シンジケートの指揮系統でtmux上に統率 — クロスマシン排他運用対応

[![GitHub Stars](https://img.shields.io/github/stars/hrmtz/multi-agent-njslyr?style=social)](https://github.com/hrmtz/multi-agent-njslyr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v5.0 Cross-Machine](https://img.shields.io/badge/v5.0-Cross--Machine-ff6600?style=flat-square)](https://github.com/hrmtz/multi-agent-njslyr)
[![BATS 243/243](https://img.shields.io/badge/BATS-243%2F243_PASS-brightgreen?style=flat-square)]()

[English](README.md) | [日本語](README_ja.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="tmuxペインで10体のエージェントが並列稼働" width="940">
</p>

<p align="center"><i>ヤマヒロ（マネージャー）がクローンヤクザ7体＋ソウカイヤを統率 — 実際の稼働画面、モックデータなし</i></p>

---

> **[multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) のニンジャスレイヤーMOD。** オリジナルの戦国武将ヒエラルキーを**ソウカイ・シンジケート**に全面書き換え。アーキテクチャは同一、世界観が違う。

## これは何？

tmux上で最大10体のAIコーディングエージェントを並列稼働させ、YAMLファイルでAPIオーバーヘッドゼロで統率するシステム。Kyoto（Ryzen WSL）とNeoSaitama（MBP）の**クロスマシン排他運用**に対応。

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

    [master_tortoise]  [master_crane]   ← 監視エージェント（各マシン常駐）
     Kyoto 予防監視     NeoSaitama 事後分析
```

**なぜ使うのか？**
- 1つの命令で最大8体のAIワーカーが並列実行
- 待ち時間なし — バックグラウンド実行中も次の命令を出せる
- 自動回復: 3段階エスカレーション＋ヤクザ天狗の緊急スーパーバイザー
- 通信はすべてディスク上のYAML — 完全に透明、差分管理、バージョン管理可能
- **2マシン排他運用**: Kyoto ↔ NeoSaitama をntfy経由でシームレスに切り替え

---

## APIベースのマルチエージェントFWと何が違う？

| | Claude Code `Task` | LangGraph | CrewAI | **njslyr** |
|---|---|---|---|---|
| **並列性** | 逐次 | グラフノード | 限定的 | **8体の独立エージェント** |
| **調整コスト** | Taskごとにapi呼び出し | API+インフラ | API+プラットフォーム | **ゼロ**（YAML+tmux） |
| **可観測性** | ログのみ | LangSmith | OpenTelemetry | **ライブtmuxペイン** |
| **自己回復** | なし | 手動 | なし | **3段階エスカレーション+ヤクザ天狗** |
| **コスト（Opus8体）** | 〜$100+/時間(API) | 〜$100+/時間(API) | 〜$100+/時間(API) | **〜$200/月**（CLI定額） |

CLIサブスクリプションにより、24時間マルチエージェント運用が経済的に成立する。1時間でも24時間でもコストは同じ。

---

## クイックスタート

### Linux / macOS

```bash
git clone https://github.com/hrmtz/multi-agent-njslyr.git ~/multi-agent-njslyr
cd ~/multi-agent-njslyr && chmod +x *.sh
./first_setup.sh   # 初回のみ
./yokubari.sh      # 毎日の起動
```

### Windows (WSL2)

| ステップ | 操作 |
|---------|------|
| 1 | `git clone https://github.com/hrmtz/multi-agent-njslyr.git C:\tools\multi-agent-njslyr` |
| 2 | `install.bat` を右クリック→管理者として実行 |
| 3 | Ubuntuで: `cd /mnt/c/tools/multi-agent-njslyr && ./first_setup.sh` |
| 4 | `./yokubari.sh` |

初回認証: `claude --dangerously-skip-permissions` → ブラウザログイン → 承認 → `/exit`

### セットアップ完了後

2つのtmuxセッションに10体のエージェントが自動起動:

| セッション | エージェント | 接続 |
|-----------|------------|------|
| `darkninja` | ダークニンジャ（あなたの窓口）＋master_tortoise | `tmux attach -t darkninja` |
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

## エージェント構成

| エージェント | モデル | 役割 | 常駐マシン |
|-------------|-------|------|-----------|
| **ダークニンジャ** | Opus | ラオモトの右腕、命令受信・委任 | 両マシン |
| **ヤマヒロ（Gryakuza）** | Sonnet | タスク配分・QC・ダッシュボード | 両マシン |
| **ソウカイヤ** | Sonnet | 品質管理参謀、レポート集約 | 両マシン |
| **クローンヤクザ 1-7** | Haiku/Sonnet | 実装: コード・調査・ファイル操作 | 両マシン |
| **ヤクザ天狗** | Sonnet | 緊急スーパーバイザー（自動spawn/despawn） | 両マシン |
| **master_tortoise** | Sonnet | Kyoto常駐監視（予防監視・未来視） | Kyoto |
| **master_crane** | Sonnet | NeoSaitama常駐監視（事後分析・過去視） | NeoSaitama |

---

## 主要機能

### イベント駆動通信（ゼロポーリング）

エージェント間通信はディスク上のYAMLファイル。ポーリングなし、APIコール浪費なし。

```
ヤマヒロがqueue/inbox/yakuza3.yamlに書き込み（flock保護）
  -> inbox_watcherがファイル変更を検知（inotifywait）
  -> エージェントのtmuxペインに短いスリケン送信
  -> エージェントが自分のinboxを読んで処理
```

メッセージ内容はtmuxを経由しない — 短い起床シグナルのみ。待機中CPU使用率ゼロ。

### モニタリングエージェント（master_tortoise / master_crane）

各マシンに常駐するSonnetエージェントが、システムの健全性を異なる視点で監視:

| エージェント | 常駐マシン | 視点 | 主な役割 |
|-------------|-----------|------|---------|
| **master_tortoise** | Kyoto | 予防監視（未来視） | コンテキスト溢れ予測、応答パターン分析 |
| **master_crane** | NeoSaitama | 事後分析（過去視） | 障害原因特定、再発防止策、パターンDB蓄積 |

60秒サイクルでハートビート交換（ntfy `{base_topic}-heartbeat` トピック）。コード編集・タスク分配・エージェント停止は禁止。

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
bash scripts/njslyr_cmd.sh suriken yakuza3           # エージェントを起床
bash scripts/njslyr_cmd.sh chop gryakuza             # 強制/clear
bash scripts/njslyr_cmd.sh slay yakuza2 "crashed"    # kill + 再起動
bash scripts/njslyr_cmd.sh spawn_tengu yakuza7 "オーバーフロー支援"
bash scripts/njslyr_cmd.sh despawn_tengu
bash scripts/njslyr_cmd.sh detox yakuza3             # Opus → Sonnet 解毒
```

### クロスマシン運用（v5.0）

KyotoとNeoSaitamaの**排他稼働**。片方が稼働中、もう片方は待機。

```
Kyoto (Ryzen WSL)  ←---ntfy---→  NeoSaitama (MBP)
  Primary/Master                   Secondary/Slave
  全エージェント起動                全エージェント起動
  master_tortoise常駐              master_crane常駐

切り替えコマンド: handover:neosaitama / handover:kyoto
```

- **Tailscale** でSSH認証済み（kyoto ↔ peer-hostname）
- **rsync** でリポジトリ同期
- **通信2層構造**:
  - Tier1: **ntfy** (プッシュ通知) — 通常のクロスマシン通知・コマンド送信
  - Tier2: **SSH** (Tailscale経由) — ntfy障害時のフォールバック・手動同期
- **suriken双方向対応**: `njslyr_cmd.sh suriken` はKyoto/NeoSaitama間でも機能。エージェント起床信号をクロスマシン配信
- `queue/active_machine.yaml` で現在の稼働マシンを管理

### バリキドリンク（Opus投与）

SonnetエージェントをOpusに一時昇格。ペインが紫色（`#1a002e`）に変わる。タスク完了後にヤマヒロが解毒（Sonnet復帰）。

### モンジュ — Opus3体相互批判QC

アルファ/ベータ版スクリプトに対し、Opus3体が独立にコードレビュー → 相互批判 → バグ修正。「三人寄れば文殊の知恵」から命名。

### スマホからの指揮（ntfy）

スマホとダークニンジャの双方向通信 — SSH不要:

```
スマホ(ntfyアプリ) --> ntfy_listener.sh --> ダークニンジャが処理
ヤマヒロ更新 --> ntfy.sh --> スマホにプッシュ通知
```

設定: `config/settings.yaml` に `ntfy_topic: "your-topic"` を追加し、[ntfyアプリ](https://ntfy.sh)で同じトピックを購読。

### セッション横断メモリ（Memory MCP）

好み・ルール・教訓がセッションを跨いで永続化。一度伝えれば、AIは永遠に覚えている。

### モバイルSSH（Tailscale + Termux）

tmuxの完全操作をスマホから:

1. ホストとスマホ両方に[Tailscale](https://tailscale.com/)をインストール
2. スマホに[Termux](https://termux.dev/)をインストール
3. `ssh user@tailscale-ip` → `tmux attach -t darkninja`

---

## 設定

```yaml
# config/settings.yaml
language: ja          # 忍殺語
language: en          # ＋英語翻訳

machine:
  role: kyoto         # kyoto（Ryzen WSL/Primary） | neosaitama（MBP/Secondary）
  peer_host: peer-hostname  # Tailscaleホスト名

ntfy_topic: "your-ntfy-topic"
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
│   ├── master_tortoise.md
│   ├── master_crane.md
│   ├── common/                # 共有ルール
│   └── cli_specific/          # CLI固有ツール記述
│
├── scripts/
│   ├── njslyr.sh              # 監視デーモン
│   ├── njslyr_cmd.sh          # オペレーションコマンド
│   ├── njslyr_lib.sh          # 共有ライブラリ
│   ├── inbox_write.sh         # メッセージ書き込み（flock保護）
│   ├── inbox_watcher.sh       # inbox変更検知（inotifywait）
│   ├── watcher_supervisor.sh  # watcherライフサイクル管理
│   ├── cross_sync.sh          # クロスマシン同期
│   ├── ntfy.sh                # プッシュ通知送信
│   ├── ntfy_listener.sh       # スマホメッセージ受信
│   ├── ntfy_send_dispatch.sh  # ntfy送信ディスパッチャー
│   └── ntfy_send_report.sh   # NeoSaitama→Kyotoレポート送信
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
├── tests/                     # BATSテストスイート（243テスト）
├── config/                    # 設定・プロジェクト・認証
├── CLAUDE.md                  # Claude Code自動読み込み
├── AGENTS.md                  # GitHub Copilot自動読み込み
└── dashboard.md               # リアルタイムステータスボード
```

---

## 設計思想

**なぜ階層構造？** ダークニンジャが即座に委任（待ち時間なし）。ヤマヒロが複数ワーカーに配分（並列実行）。各ロールが単一責任。1体の障害が他に影響しない。

**なぜYAMLメールボックス？** ファイルはエージェントクラッシュを生存。`inotifywait` はイベント駆動（待機中CPUゼロ）。エージェント毎に専用inbox（クロストークなし）。`flock` で並行書き込み破壊を防止。全メッセージがプレーンテキストで検査可能。

**なぜクロスマシン排他稼働？** CLIトークン上限を2マシンで分散。片方で長期タスク実行中、もう片方でプロトタイプ。確実なhandoverプロトコルでデータ損失なし。

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
<summary><b>クロスマシン同期が失敗？</b></summary>

```bash
# Tailscale接続確認
tailscale status

# 手動同期
bash scripts/cross_sync.sh

# active_machine確認
cat queue/active_machine.yaml
```

</details>

<details>
<summary><b>MCPツールが読み込まれない？</b></summary>

MCPツールは遅延読み込み:
```
mcp__memory__read_graph()
```

</details>

---

## tmuxチートシート

| コマンド | 説明 |
|---------|------|
| `tmux attach -t darkninja` | ダークニンジャに接続 |
| `tmux attach -t multiagent` | ワーカーに接続 |
| `Ctrl+B` → `0`-`9` | ペイン切り替え |
| `Ctrl+B` → `d` | デタッチ（エージェント稼働継続） |

---

## 更新履歴

### v5.0 — クロスマシン運用

- **クロスマシン排他稼働**: Kyoto（Ryzen WSL）↔ NeoSaitama（MBP）
- **master_tortoise / master_crane**: 各マシン常駐の監視エージェント（60秒ハートビート）
- **マシンコードネーム確定**: kyoto（旧ryzen）、neosaitama（旧mbp）
- **ntfy双方向クロスマシン通信**: `handover:{target}` コマンドで排他切り替え
- **cross_sync.sh**: Tailscale+rsyncによるリポジトリ同期
- **ntfy_send_dispatch.sh**: クロスマシン対応ntfy送信ディスパッチャー
- **BATSテスト243本**

### v4.0 — インフラ大型改修

- **njslyr_cmd.sh** — ワンコマンドオペレーション: `suriken`、`chop`、`slay`、`spawn_tengu`、`despawn_tengu`、`detox`
- **njslyr_lib.sh** — 共有ライブラリ抽出（resolve_pane_by_agent_id、agent_is_busy）
- **3層自己識別防御** — `/clear` 後のエージェント誤認バグを根絶
- **idle検知v2** — `/clear` 後のグレースピリオド、inbox未読チェック
- **watcher_supervisor改善** — 動的ペイン探索、クラッシュwatcher自動再起動
- **BATSテスト46本**、macOS互換性

### v3.5 — ヤクザ天狗

- ヤクザ天狗緊急スーパーバイザー（マネージャー過負荷時に自動spawn）
- エージェント命名（Gryakuza → ヤマヒロ）
- `/clear` 後のクローンヤクザ・ペルソナ維持

<details>
<summary><b>v3.4 以前</b></summary>

### v3.4 — Bloomルーティング、E2Eテスト

- Bloom→エージェント・ルーティング（L1-L3→クローンヤクザ、L4-L6→ソウカイヤ）
- E2Eテストスイート（19テスト、7シナリオ）

### v3.0 — マルチCLI

- マルチCLIアーキテクチャ（Claude/Codex/Copilot/Kimi）
- `lib/cli_adapter.sh` 動的CLI選択

</details>

---

## クレジット

[multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) by [@yohey-w](https://github.com/yohey-w) のフォークです。

## ライセンス

[MIT](LICENSE)

---

<div align="center">

**コマンド1つ。10体のエージェント。クロスマシン。調整コストゼロ。**

</div>
