<div align="center">

# multi-agent-njslyr

**AIコーディング軍団統率システム — ネオサイタマ・シンジケート方式**

コマンド1つで10体のAIエージェントが並列稼働 — **Claude Code / OpenAI Codex / GitHub Copilot / Kimi Code** 混成軍

**Talk Coding — スマホに話すだけでAIが実行**

[![GitHub Stars](https://img.shields.io/github/stars/hrmtz/multi-agent-njslyr?style=social)](https://github.com/hrmtz/multi-agent-njslyr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.5 Yakuza Tengu](https://img.shields.io/badge/v3.5-Yakuza_Tengu-ff6600?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHRleHQgeD0iMCIgeT0iMTIiIGZvbnQtc2l6ZT0iMTIiPuKalTwvdGV4dD48L3N2Zz4=)](https://github.com/hrmtz/multi-agent-njslyr)
[![Shell](https://img.shields.io/badge/Shell%2FBash-100%25-green)]()

[English](README.md) | [日本語](README_ja.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="ダークニンジャペインでの最新半透過セッションキャプチャ" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="ダークニンジャペインでの自然言語コマンド入力" width="420">
  <img src="images/company-creed-all-panes.png" alt="ヤマヒロとクローンヤクザが全ペインで並列反応する様子" width="520">
</p>

<p align="center"><i>ヤマヒロ（マネージャー）がクローンヤクザ7体+ソウカイヤ幹部1体を統率 — 実際の稼働画面、モックデータなし</i></p>

---

> **これは [multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) の[ニンジャスレイヤー](https://diehardtales.com/n/ndb78a66e0e79) MODです。**
> オリジナルは戦国武将ヒエラルキー（将軍→家老→足軽）。本フォークは命名体系を **ソウカイ・シンジケート** に全面書き換え: ダークニンジャ→ヤマヒロ（グレーターヤクザ）→クローンヤクザ。インストラクション、スクリプト、テスト、ドキュメントすべて対応済み。アーキテクチャと機能は同一です。

## これは何？

**multi-agent-njslyr** は、複数のAIコーディングCLIインスタンスを同時に実行し、ソウカイ・シンジケートの組織構造で統率するシステムです。**Claude Code**、**OpenAI Codex**、**GitHub Copilot**、**Kimi Code** の4CLIに対応。

**なぜ使うのか？**
- 1つの命令で7体のAIワーカー+1体のソウカイヤ幹部が並列実行
- 待ち時間なし — タスクがバックグラウンドで実行中も次の命令を出せる
- AIがセッションを跨いであなたの好みを記憶（Memory MCP）
- ダッシュボードでリアルタイム進捗確認
- 自動回復: 監視デーモンがクラッシュしたエージェントを蘇生＋緊急スーパーバイザーを自動spawn

```
      あなた（ラオモト）
           │
           ▼ 命令を出す
    ┌─────────────┐
    │ ダークニンジャ│  ← 命令を受け取り、即座に委任
    └──────┬──────┘
           │  YAML + tmux
    ┌──────▼──────┐               ┌────────────────┐
    │  ヤマヒロ    │──過負荷─────▶│  ヤクザ天狗     │
    │ (Gryakuza)  │◀──引き継ぎ──│ (緊急スーパー)  │
    └──────┬──────┘               └────────────────┘
           │                        ↕ タスク配分
  ┌─┬─┬─┬─┴─┬─┬─┬─┬──────────┐
  │1│2│3│4│5│6│7│ ソウカイヤ │  ← 7体のワーカー + 1体の参謀
  └─┴─┴─┴─┴─┴─┴─┴──────────┘
     クローンヤクザ  ソウカイヤ幹部
```

---

## なぜこのシステムなのか？

ほとんどのマルチエージェントフレームワークは、エージェント間の調整にAPIトークンを浪費する。このシステムはしない。

| | Claude Code `Task`ツール | LangGraph | CrewAI | **multi-agent-njslyr** |
|---|---|---|---|---|
| **アーキテクチャ** | 単一プロセス内のサブエージェント | グラフ型ステートマシン | ロールベースエージェント | tmuxによるシンジケート階層 |
| **並列性** | 逐次（1タスクずつ） | 並列ノード（v0.2+） | 限定的 | **8体の独立エージェント** |
| **調整コスト** | Taskごとにapi呼び出し | API+インフラ（Postgres/Redis） | API+CrewAIプラットフォーム | **ゼロ**（YAML+tmux） |
| **可観測性** | Claudeログのみ | LangSmith連携 | OpenTelemetry | **ライブtmuxペイン**+ダッシュボード |
| **自己回復** | なし | 手動再起動 | なし | **3段階エスカレーション+ヤクザ天狗** |
| **スキル発見** | なし | なし | なし | **ボトムアップ自動提案** |
| **セットアップ** | Claude Code内蔵 | 重い（インフラ必要） | pip install | シェルスクリプト |

### 何が違うのか

**調整コストゼロ** — エージェント間通信はディスク上のYAMLファイル。APIコールは実際の作業のみに使用。8体のエージェントを動かしても、支払いは8体分の作業コストだけ。

**完全な透明性** — 全エージェントが見えるtmuxペインで動作。全インストラクション・レポート・意思決定がプレーンなYAMLファイルで、閲覧・差分・バージョン管理可能。ブラックボックスなし。

**実戦検証済みの階層構造** — ダークニンジャ→ヤマヒロ→クローンヤクザの指揮系統が設計段階から衝突を防止: 明確な責任範囲、エージェント専用ファイル、イベント駆動通信、ポーリングなし。

**自己回復** — njslyr監視デーモンが全エージェントを監視。無応答エージェントにはスリケン→強制クリア→キル＆リスポーンの3段階エスカレーション。マネージャー（ヤマヒロ）が過負荷の時はヤクザ天狗が自動spawnしてタスクを配分。

---

## なぜCLI（APIではなく）？

多くのAIコーディングツールはトークン課金。8体のOpusエージェントをAPIで回すと **時給$100超**。CLIサブスクなら定額:

| | API（トークン課金） | CLI（定額制） |
|---|---|---|
| **8体×Opus** | ~$100+/時間 | ~$200/月 |
| **コスト予測** | スパイクが読めない | 月額固定 |
| **使用不安** | 1トークンが重い | 無制限 |
| **実験予算** | 制約あり | 自由にデプロイ |

**「AIを遠慮なく使え」** — 定額CLIサブスクなら、8体のエージェントを躊躇なくデプロイ。1時間稼働でも24時間稼働でもコストは同じ。

### マルチCLI対応

単一ベンダーにロックインされない。4つのCLIツールをサポート:

| CLI | 強み | デフォルトモデル |
|-----|------|----------------|
| **Claude Code** | tmux統合実績、Memory MCP、専用ファイルツール（Read/Write/Edit/Glob/Grep） | Claude Sonnet 4.5 |
| **OpenAI Codex** | サンドボックス実行、JSONL構造化出力、`codex exec`ヘッドレスモード | gpt-5.3-codex / **gpt-5.3-codex-spark** |
| **GitHub Copilot** | 内蔵GitHub MCP、4つの特化エージェント（Explore/Task/Plan/Code-review） | Claude Sonnet 4.5 |
| **Kimi Code** | 無料枠あり、多言語サポート | Kimi k2 |

統一インストラクション・ビルドシステムが共有テンプレートからCLI固有の設定ファイルを自動生成:

```
instructions/
├── common/              # 共有ルール（全CLI共通）
├── cli_specific/        # CLI固有ツール記述
│   ├── claude_tools.md
│   └── copilot_tools.md
└── roles/               # ロール定義（darkninja, gryakuza, yakuza, soukaiya）
    ↓ ビルド
CLAUDE.md / AGENTS.md / copilot-instructions.md  ← CLI別に生成
```

単一の真実のソース。同期ズレなし。ルールを1箇所変えれば全CLIに反映。

---

## クイックスタート

### Windows (WSL2)

<table>
<tr>
<td width="60">

**Step 1**

</td>
<td>

**リポジトリをダウンロード**

[ZIPダウンロード](https://github.com/hrmtz/multi-agent-njslyr/archive/refs/heads/main.zip) → `C:\tools\multi-agent-njslyr` に展開

*またはgit:* `git clone https://github.com/hrmtz/multi-agent-njslyr.git C:\tools\multi-agent-njslyr`

</td>
</tr>
<tr>
<td>

**Step 2**

</td>
<td>

**`install.bat` を実行**

右クリック→「管理者として実行」（WSL2未インストールの場合）。WSL2+Ubuntuを自動セットアップ。

</td>
</tr>
<tr>
<td>

**Step 3**

</td>
<td>

**Ubuntuを開いて実行**（初回のみ）

```bash
cd /mnt/c/tools/multi-agent-njslyr
./first_setup.sh
```

</td>
</tr>
<tr>
<td>

**Step 4**

</td>
<td>

**デプロイ！**

```bash
./yokubari.sh
```

</td>
</tr>
</table>

#### 初回のみ: 認証

`first_setup.sh` 実行後、1回だけ認証:

```bash
# 1. PATHを反映
source ~/.bashrc

# 2. OAuthログイン + Bypass Permissions承認（1コマンド）
claude --dangerously-skip-permissions
#    → ブラウザが開く → Anthropicアカウントでログイン → CLIに戻る
#    → "Bypass Permissions" → 「Yes, I accept」を選択（↓で選択肢2、Enter）
#    → /exit で終了
```

認証情報は `~/.claude/` に保存 — 以降は不要。

#### 日常の起動

**Ubuntuターミナル**（WSL）で:

```bash
cd /mnt/c/tools/multi-agent-njslyr
./yokubari.sh
```

### モバイルアクセス（どこからでもコマンド）

スマホからAI軍団を指揮 — ベッド、カフェ、バスルーム。

**必要なもの（全て無料）:**

| 名前 | 一言で | 役割 |
|------|--------|------|
| [Tailscale](https://tailscale.com/) | どこからでも自宅への道 | スマホから自宅PCに接続 |
| SSH | その道を歩く足 | Tailscale経由で自宅PCにログイン |
| [Termux](https://termux.dev/) | スマホの黒い画面 | SSHに必要 — インストールするだけ |

**セットアップ:**

1. WSLとスマホ両方にTailscaleをインストール
2. WSLで（authキー方式 — ブラウザ不要）:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscaled &
   sudo tailscale up --authkey tskey-auth-XXXXXXXXXXXX
   sudo service ssh start
   ```
3. スマホのTermuxで:
   ```sh
   pkg update && pkg install openssh
   ssh youruser@your-tailscale-ip
   css    # ダークニンジャに接続
   ```
4. 新しいTermuxウィンドウ（+ボタン）でワーカー閲覧:
   ```sh
   ssh youruser@your-tailscale-ip
   csm    # 全9ペインを表示
   ```

**切断:** Termuxウィンドウをスワイプして閉じるだけ。tmuxセッションは生存 — エージェントは稼働し続ける。

**音声入力:** スマホの音声キーボードで命令を話す。ダークニンジャは自然言語を理解するので、音声認識の誤字は問題ない。

**もっと簡単に:** ntfyを設定すれば、ntfyアプリから直接通知を受け取りコマンドを送信 — SSH不要。

---

<details>
<summary> <b>Linux / macOS</b>（クリックで展開）</summary>

### 初回セットアップ

```bash
# 1. クローン
git clone https://github.com/hrmtz/multi-agent-njslyr.git ~/multi-agent-njslyr
cd ~/multi-agent-njslyr

# 2. 実行権限を付与
chmod +x *.sh

# 3. 初回セットアップ
./first_setup.sh
```

### 日常の起動

```bash
cd ~/multi-agent-njslyr
./yokubari.sh
```

</details>

<details>
<summary><b>WSL2とは？なぜ必要？</b>（クリックで展開）</summary>

**WSL2 (Windows Subsystem for Linux)** はWindows内でLinuxを動かす機能。このシステムは `tmux`（Linuxツール）で複数AIエージェントを管理するため、WindowsではWSL2が必要。

まだ入れていなくても大丈夫！ `install.bat` がWSL2+Ubuntuを自動インストールしてガイドします。

**クイックインストール**（PowerShellを管理者で実行）:
```powershell
wsl --install
```

再起動後、再度 `install.bat` を実行。

</details>

---

### セットアップ完了後

どの方法でも、**10体のAIエージェント** が自動的に起動:

| エージェント | 役割 | 数 |
|-------------|------|-----|
| ダークニンジャ | 最高指揮官 — あなたの命令を受ける | 1 |
| ヤマヒロ（Gryakuza） | マネージャー — タスク配分、品質管理、ダッシュボード | 1 |
| クローンヤクザ | ワーカー — 実装タスクを並列実行 | 7 |
| ソウカイヤ幹部 | 参謀 — 分析、評価、設計 | 1 |

2つのtmuxセッションが作成:
- `darkninja` — ここに接続して命令を出す
- `multiagent` — ヤマヒロ、クローンヤクザ、ソウカイヤがバックグラウンドで稼働

---

## 使い方

### Step 1: ダークニンジャに接続

`yokubari.sh` 実行後、全エージェントはインストラクションを読み込み済みで準備完了。

```bash
tmux attach-session -t darkninja
```

### Step 2: 最初の命令を出す

ダークニンジャは初期化済み — そのまま命令を入力:

```
JavaScriptフレームワーク上位5つを調査して比較表を作成せよ
```

ダークニンジャは:
1. タスクをYAMLファイルに書く
2. ヤマヒロ（マネージャー）に通知
3. 即座にあなたにコントロールを返す — 待ち時間なし！

ヤマヒロがクローンヤクザにタスクを配分して並列実行。

### Step 3: 進捗を確認

`dashboard.md` をエディタで開くとリアルタイムで状況が見える:

```markdown
## 進行中
| ワーカー | タスク | 状態 |
|---------|--------|------|
| Yakuza 1 | React調査 | 実行中 |
| Yakuza 2 | Vue調査 | 実行中 |
| Yakuza 3 | Angular調査 | 完了 |
```

### 詳細フロー

```
あなた: 「MCPサーバー上位5つを調査して比較表を作れ」
```

ダークニンジャがinbox（`queue/inbox/gryakuza.yaml`）経由でヤマヒロにタスクを送信し、ヤマヒロを起動。コントロールは即座にあなたに戻る。

ヤマヒロがサブタスクに分解:

| ワーカー | 割り当て |
|---------|---------|
| Yakuza 1 | Notion MCP調査 |
| Yakuza 2 | GitHub MCP調査 |
| Yakuza 3 | Playwright MCP調査 |
| Yakuza 4 | Memory MCP調査 |
| Yakuza 5 | Sequential Thinking MCP調査 |

5体のクローンヤクザが同時に調査。リアルタイムで作業を見られる:

<p align="center">
  <img src="images/company-creed-all-panes.png" alt="クローンヤクザがtmuxペインで並列作業中" width="900">
</p>

完了次第、結果が `dashboard.md` に反映。

---

## 主要機能

### 1. 並列実行

1つの命令で最大8つの並列タスク:

```
あなた: 「MCPサーバー5つを調査」
→ 5体のクローンヤクザが同時に調査開始
→ 数時間かかる作業が数分で完了
```

### 2. ノンブロッキング・ワークフロー

ダークニンジャは即座に委任し、コントロールをあなたに返す:

```
あなた: 命令 → ダークニンジャ: 委任 → あなた: すぐ次の命令を出せる
                                       ↓
                       ワーカー: バックグラウンドで実行
                                       ↓
                       ダッシュボード: 結果を表示
```

### 3. セッション横断メモリ（Memory MCP）

AIがあなたの好みを記憶:

```
セッション1: 「シンプルなアプローチが好き」と伝える
              → Memory MCPに保存

セッション2: AIが起動時にメモリを読み込む
              → 複雑な解決策を提案しなくなる
```

### 4. イベント駆動通信（ゼロポーリング）

エージェント間通信はYAMLファイルの書き込み — メモを渡すようなもの。**ポーリングなし、APIコール無駄遣いなし。**

```
ヤマヒロがクローンヤクザ3を起こしたい:

Step 1: メッセージを書く         Step 2: エージェントを起こす
┌──────────────────────┐       ┌──────────────────────────┐
│ inbox_write.sh       │       │ inbox_watcher.sh         │
│                      │       │                          │
│ 完全なメッセージを   │ ファ  │ ファイル変更を検知       │
│ yakuza3.yamlに書く   │─イル─▶│ (inotifywait、ポーリング │
│ flock（競合防止）    │ 変更  │  ではない)               │
└──────────────────────┘       │                          │
                               │ エージェント起床:        │
                               │  1. 自己監視（スキップ） │
                               │  2. tmux send-keys       │
                               │     (短いスリケンのみ)   │
                               └──────────────────────────┘

Step 3: エージェントが自分のinboxを読む
┌──────────────────────────────────┐
│ クローンヤクザ3がyakuza3.yamlを │
│ 読む → 未読メッセージを発見     │
│     → 処理 → 既読にマーク      │
└──────────────────────────────────┘
```

**設計のポイント:**
- **メッセージ内容はtmuxを経由しない** — 短い「メールあり」スリケンのみ。エージェントは自分のファイルを読む。文字化けや送信ハングを排除。
- **待機中CPU使用率ゼロ** — `inotifywait` がカーネルイベントでブロック（ポーリングループではない）。
- **配信保証** — ファイル書き込みが成功すればメッセージはそこにある。メッセージロスなし。

### 5. njslyr — エージェント監視デーモン

3段階エスカレーションと緊急スーパーバイザーspawnによる、自動エージェント健全性監視。手動介入不要。

**3段階エスカレーション:**

| ステージ | トリガー | アクション | 目的 |
|---------|---------|----------|------|
| **Stage 1: スリケン** | inbox無視2分超 | tmux経由で軽いスリケン送信 | 注意散漫なエージェントを起床 |
| **Stage 2: チョップ** | 4分後も無応答 | `/clear` で強制セッションリセット | コンテキスト過負荷を解消 |
| **Stage 3: スレイ** | 6分後も無応答 | `kill -9` + 自動再起動 + 赤ペイン | クラッシュしたエージェントを終了＆蘇生 |

**ヤクザ天狗 — 緊急スーパーバイザー:**

ヤマヒロ（マネージャー）が過負荷 — タスクが山積み、アイドルのクローンヤクザが待ちぼうけ — の時、njslyrが自動的に**ヤクザ天狗**をspawn。一時的なSonnetスーパーバイザー。

```
通常運用:
  ヤマヒロがタスクを配分 → クローンヤクザが実行

ヤマヒロ過負荷（inboxが溜まり、アイドルのヤクザが待機中）:
  njslyrが過負荷を検知
    → 最もアイドルの長いクローンヤクザペインを選択
    → ヤクザ天狗としてrespawn（ダークピンクペイン、Sonnet）
    → ヤマヒロの山積みinboxを読み取り
    → アイドルのクローンヤクザにタスク配分
    → ヤマヒロ復帰 → ヤクザ天狗が引き継ぎしてdespawn
    → 元のクローンヤクザを復元
```

ヤクザ天狗は、ニンジャスレイヤー本編で絶体絶命のヤマヒロの前に押し売りのように駆けつける「神々の使者」にインスパイア。ダークピンクペイン（`#3a0025`）で一目でわかる。

**コスト最適化:** njslyrは**未読inboxがあるエージェントのみ**にスリケンを送る（`grep 'read: false'` — pure bash、APIコールゼロ）。アイドルのエージェントは放置。

### 6. Bloom分類法 → エージェント・ルーティング

認知的複雑度でタスクを分類し、適切なエージェントにルーティング:

| レベル | カテゴリ | ルーティング先 |
|-------|---------|--------------|
| L1–L3 | 記憶 / 理解 / 適用 | **クローンヤクザ**（Sonnet） |
| L4–L6 | 分析 / 評価 / 創造 | **ソウカイヤ幹部**（Opus） |

最初から適切なエージェントが適切なタスクを受け取る — セッション中のモデル切り替え不要。

### 7. ボトムアップ・スキル発見

クローンヤクザがタスクを実行する中で、**再利用可能なパターンを自動的に特定**し、スキル候補として提案。ヤマヒロが `dashboard.md` に集約し、あなたが昇格を決定。

```
クローンヤクザがタスク完了
    ↓
気づき: 「このパターン、3つのプロジェクトで同じことをやった」
    ↓
YAMLでレポート: skill_candidate:
                   found: true
                   name: "api-endpoint-scaffold"
                   reason: "3プロジェクトで同じREST雛形パターンを使用"
    ↓
dashboard.mdに掲載 → あなたが承認 → .claude/commands/ にスキル作成
    ↓
どのエージェントでも /api-endpoint-scaffold を呼び出せる
```

スキルは実際の作業から有機的に生まれる — テンプレートライブラリからではなく。

### 8. スマホ通知（ntfy）

スマホとダークニンジャの双方向通信 — SSH不要、Tailscale不要、サーバー不要。

| 方向 | 仕組み |
|------|-------|
| **スマホ → ダークニンジャ** | ntfyアプリからメッセージ送信 → `ntfy_listener.sh` が受信 → ダークニンジャが自動処理 |
| **ヤマヒロ → スマホ** | ヤマヒロが `dashboard.md` 更新時、`scripts/ntfy.sh` 経由で直接プッシュ通知 |

```
📱 あなた（ベッドから）     🏯 ダークニンジャ
    │                          │
    │ 「React 19を調査」       │
    ├─────────────────────────►│
    │   (ntfyメッセージ)       │  → ヤマヒロに委任 → ヤクザが作業
    │                          │
    │ 「✅ cmd_042 完了」      │
    │◄─────────────────────────┤
    │   (プッシュ通知)         │
```

**セットアップ:**
1. `config/settings.yaml` に `ntfy_topic: "darkninja-yourname"` を追加
2. スマホに [ntfyアプリ](https://ntfy.sh) をインストールし同じトピックを購読
3. `yokubari.sh` がリスナーを自動起動 — 追加の手順は不要

無料、アカウント不要、サーバー維持不要。[ntfy.sh](https://ntfy.sh) を使用。

> **セキュリティ:** トピック名がパスワード。知っている人は通知を読め、ダークニンジャにメッセージを送れる。推測しにくい名前を選び、**公開しないこと**。

<p align="center">
  <img src="images/screenshots/masked/ntfy_saytask_rename.jpg" alt="スマホ双方向通信" width="300">
  &nbsp;&nbsp;
  <img src="images/screenshots/masked/ntfy_cmd043_progress.jpg" alt="進捗通知" width="300">
</p>
<p align="center"><i>左: スマホ↔ダークニンジャ双方向通信 · 右: リアルタイム進捗レポート</i></p>

### 9. その他の機能

| 機能 | 説明 |
|------|------|
| **ペインボーダー・タスク表示** | 各tmuxペインのボーダーに `yakuza1 (Sonnet) API調査` と表示 — 9ペインを一目で確認 |
| **シャウトモード** | クローンヤクザがタスク完了時に雄叫びを上げる。`yokubari.sh --silent` で無効化 |
| **スクリーンショット連携** | `config/settings.yaml` にスクリーンショットパスを設定、ダークニンジャに「最新のスクリーンショットを確認」と伝える |
| **タスク依存関係** | タスクYAMLの `blockedBy` フィールド — ヤマヒロが前提タスク完了時に依存タスクを自動解放 |
| **コンテキスト管理** | 4層アーキテクチャ: Memory MCP（永続）→ プロジェクトファイル → YAMLキュー → セッションコンテキスト |
| **Stop Hookインボックス** | Claude Codeエージェントがターン終了時にinboxを自動チェック — send-keys割り込みを排除 |

---

## SayTask — タスク管理嫌いのためのタスク管理

**スマホに話すだけ。** タイピングなし、アプリ起動なし、摩擦なし。

1. [ntfyアプリ](https://ntfy.sh)をインストール（無料、アカウント不要）
2. スマホに話す: *「明日歯医者」*、*「金曜までに請求書」*
3. AIが自動整理 → 朝の通知: *「今日の予定はこちら」*

```
 🗣️ 「牛乳買う、明日歯医者、金曜に請求書」
       │
       ▼
 ┌──────────────────┐
 │ ntfy → ダークニンジャ│ AIが自動分類、日付解析、優先度設定
 └────────┬─────────┘
          │
          ▼
 ┌──────────────────┐
 │   tasks.yaml     │  構造化保存（ローカル、データは外に出ない）
 └────────┬─────────┘
          │
          ▼
 📱 朝の通知:
    「今日: 🐸 請求書 · 🦷 歯医者 15:00 · 🛒 牛乳」
```

**Eat the Frog 🐸**: 毎朝AIが最も手強いタスク — やりたくないやつ — を選ぶ。最初に片づけるか無視するか。

**ストリーク追跡**: 連続達成日数をカウント — 損失回避バイアスでモメンタムを維持。

| Before (v1) | After (v2) |
|:-----------:|:----------:|
| ![タスクリストv1](images/screenshots/masked/ntfy_tasklist_v1_before.jpg) | ![タスクリストv2](images/screenshots/masked/ntfy_tasklist_v2_aligned.jpg) |
| 生のタスクダンプ | 整理された日次サマリー |

---

## モデル設定

| エージェント | デフォルトモデル | 思考 | 役割 |
|-------------|----------------|------|------|
| ダークニンジャ | Opus | **有効（高）** | ラオモトへの戦略アドバイザー。`--darkninja-no-thinking` でリレーのみモード |
| ヤマヒロ（Gryakuza） | Sonnet | 有効 | タスク配分、QC、ダッシュボード管理 |
| ソウカイヤ幹部 | Opus | 有効 | 深い分析、設計レビュー、アーキテクチャ評価 |
| クローンヤクザ 1–7 | Sonnet | 有効 | 実装: コード、調査、ファイル操作 |
| ヤクザ天狗 | Sonnet | 有効 | 緊急スーパーバイザー — 一時的、ヤマヒロ過負荷時にnjslyrがspawn |

**認知的複雑度**でタスクを振り分ける設計。クローンヤクザが実装（L1–L3）、ソウカイヤ幹部が深い推論（L4–L6）を担当。ヤクザ天狗はタスク配分オーバーフローを処理する一時的Sonnetスーパーバイザー。

---

## 設定

### 言語

```yaml
# config/settings.yaml
language: ja   # 忍殺語のみ
language: en   # 忍殺語 + 英語翻訳
```

### スクリーンショット連携

```yaml
# config/settings.yaml
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

ダークニンジャに「最新のスクリーンショットを確認」と伝えるだけ。（Windows: `Win+Shift+S`）

### ntfy（スマホ通知）

```yaml
# config/settings.yaml
ntfy_topic: "darkninja-yourname"
```

スマホの [ntfyアプリ](https://ntfy.sh) で同じトピックを購読。リスナーは `yokubari.sh` で自動起動。

<details>
<summary><b>ntfy認証（セルフホストサーバー）</b></summary>

公開ntfy.shインスタンスは**認証不要** — 上記の設定だけでOK。

セルフホストntfyサーバーでアクセス制御を有効にしている場合:

```bash
cp config/ntfy_auth.env.sample config/ntfy_auth.env
# 認証情報を編集
```

| 方式 | 設定 | 用途 |
|------|------|------|
| **Bearerトークン**（推奨） | `NTFY_TOKEN=tk_your_token_here` | トークン認証のセルフホストntfy |
| **Basic認証** | `NTFY_USER=username` + `NTFY_PASS=password` | ユーザー/パスワード認証 |
| **なし**（デフォルト） | ファイルを空のまま | 公開ntfy.sh — 認証不要 |

</details>

---

## 上級者向け

<details>
<summary><b>スクリプトリファレンス</b>（クリックで展開）</summary>

| スクリプト | 目的 | 実行タイミング |
|-----------|------|--------------|
| `install.bat` | Windows: WSL2 + Ubuntuセットアップ | 初回のみ |
| `first_setup.sh` | tmux、Node.js、Claude Code CLI + Memory MCP設定 | 初回のみ |
| `yokubari.sh` | tmuxセッション作成 + Claude Code起動 + インフラ起動 | 毎日 |

</details>

<details>
<summary><b>yokubari.shオプション</b>（クリックで展開）</summary>

```bash
./yokubari.sh                       # フルスタートアップ（デフォルト）
./yokubari.sh -s, --setup-only      # セッション作成のみ（Claude未起動）
./yokubari.sh -c, --clean           # タスクキューをクリーン
./yokubari.sh -k, --kessen          # 決戦陣形: 全ヤクザをOpusに
./yokubari.sh -S, --silent          # 雄叫びを無効化
./yokubari.sh -t, --terminal        # Windows Terminalタブを開く
./yokubari.sh --darkninja-no-thinking  # ダークニンジャ・リレーのみモード
./yokubari.sh -h, --help            # ヘルプ表示
```

</details>

<details>
<summary><b>スクリプト・アーキテクチャ</b>（クリックで展開）</summary>

```
┌─────────────────────────────────────────────────────────────────────┐
│                    初回セットアップ（1回のみ）                         │
├─────────────────────────────────────────────────────────────────────┤
│  install.bat (Windows)                                              │
│      ├── WSL2インストール確認/ガイド                                  │
│      └── Ubuntuインストール確認/ガイド                                │
│                                                                     │
│  first_setup.sh (Ubuntu/WSLで手動実行)                               │
│      ├── tmuxインストール確認                                         │
│      ├── Node.js v20+インストール確認（nvm経由）                       │
│      ├── Claude Code CLIインストール確認（ネイティブ版）                │
│      └── Memory MCPサーバー設定                                       │
├─────────────────────────────────────────────────────────────────────┤
│                    日常起動（毎日）                                    │
├─────────────────────────────────────────────────────────────────────┤
│  yokubari.sh                                                        │
│      ├──▶ tmuxセッション作成                                          │
│      │     • "darkninja" セッション（1ペイン）                         │
│      │     • "multiagent" セッション（9ペイン、3x3グリッド）            │
│      ├──▶ キューファイルとダッシュボードをリセット                       │
│      ├──▶ 全エージェントでClaude Code起動                              │
│      ├──▶ inbox_watcher.sh起動（10インスタンス、エージェント毎）         │
│      └──▶ njslyr.sh起動（監視デーモン）                                │
└─────────────────────────────────────────────────────────────────────┘
```

</details>

<details>
<summary><b>よくあるワークフロー</b>（クリックで展開）</summary>

**通常の日常利用:**
```bash
./yokubari.sh          # 全て起動
tmux attach-session -t darkninja     # 接続して命令
```

**デバッグモード（手動制御）:**
```bash
./yokubari.sh -s       # セッション作成のみ

# 特定エージェントでClaude Codeを手動起動
tmux send-keys -t darkninja:0 'claude --dangerously-skip-permissions' Enter
tmux send-keys -t multiagent:0.0 'claude --dangerously-skip-permissions' Enter
```

**クラッシュ後の再起動:**
```bash
# 既存セッションを終了
tmux kill-session -t darkninja
tmux kill-session -t multiagent

# 新規起動
./yokubari.sh
```

</details>

<details>
<summary><b>便利なエイリアス</b>（クリックで展開）</summary>

`first_setup.sh` が自動的に `~/.bashrc` に追加:

```bash
alias csst='cd /mnt/c/tools/multi-agent-njslyr && ./yokubari.sh'
alias css='tmux attach-session -t darkninja'      # ダークニンジャに接続
alias csm='tmux attach-session -t multiagent'  # ヤマヒロ+ヤクザに接続
```

</details>

---

## ファイル構成

<details>
<summary><b>クリックで展開</b></summary>

```
multi-agent-njslyr/
│
│  ┌──────────────── セットアップスクリプト ─────────┐
├── install.bat               # Windows: 初回セットアップ
├── first_setup.sh            # Ubuntu/Mac: 初回セットアップ
├── yokubari.sh               # 日常デプロイ
│  └──────────────────────────────────────────────┘
│
├── instructions/             # エージェント行動定義
│   ├── darkninja.md          # ダークニンジャ・インストラクション
│   ├── gryakuza.md           # ヤマヒロ（Gryakuza）インストラクション
│   ├── yakuza.md             # クローンヤクザ・インストラクション
│   ├── soukaiya.md           # ソウカイヤ幹部・インストラクション
│   ├── yakuzatengu.md        # ヤクザ天狗（緊急スーパーバイザー）インストラクション
│   ├── common/               # 共有ルール（全CLI共通）
│   └── cli_specific/         # CLI固有ツール記述
│
├── lib/
│   ├── cli_adapter.sh        # マルチCLIアダプタ（Claude/Codex/Copilot/Kimi）
│   └── ntfy_auth.sh          # ntfy認証ヘルパー
│
├── scripts/                  # ユーティリティスクリプト
│   ├── inbox_write.sh        # エージェントinboxへのメッセージ書き込み
│   ├── inbox_watcher.sh      # inbox変更監視（inotifywait/fswatch）
│   ├── njslyr.sh             # 監視デーモン（3段階エスカレーション+ヤクザ天狗）
│   ├── ntfy.sh               # スマホへのプッシュ通知
│   └── ntfy_listener.sh      # スマホからのメッセージ受信
│
├── config/
│   ├── settings.yaml         # 言語、ntfy、その他設定
│   ├── ntfy_auth.env.sample  # ntfy認証テンプレート
│   └── projects.yaml         # プロジェクト登録簿
│
├── queue/                    # 通信ファイル（真実のソース）
│   ├── inbox/                # エージェント別inboxファイル
│   │   ├── darkninja.yaml
│   │   ├── gryakuza.yaml
│   │   ├── yakuza{1-7}.yaml
│   │   └── soukaiya.yaml
│   ├── tasks/                # ワーカー別タスクファイル
│   ├── reports/              # ワーカーレポート
│   └── ntfy_inbox.yaml       # スマホからの受信メッセージ
│
├── saytask/                  # SayTask（音声タスク管理）
│   └── streaks.yaml          # ストリーク追跡
│
├── templates/                # レポート・コンテキストテンプレート
├── memory/                   # Memory MCP永続ストレージ
├── dashboard.md              # リアルタイムステータスボード
├── CLAUDE.md                 # システムインストラクション（Claude Code自動読み込み）
├── AGENTS.md                 # システムインストラクション（GitHub Copilot自動読み込み）
└── tests/                    # BATSテストスイート
```

</details>

---

## 設計思想

### なぜ階層構造（ダークニンジャ→ヤマヒロ→クローンヤクザ）？

1. **即時応答**: ダークニンジャが即座に委任、コントロールをあなたに返す
2. **並列実行**: ヤマヒロが複数のクローンヤクザに同時配分
3. **単一責任**: 各ロールが明確に分離 — 混乱なし
4. **スケーラビリティ**: クローンヤクザを増やしても構造は壊れない
5. **障害分離**: 1体のクローンヤクザがダウンしても他に影響なし
6. **自己回復**: njslyrが全体を監視、ヤクザ天狗がマネージャー過負荷を処理

### なぜメールボックスシステム？

| ダイレクトメッセージの問題 | メールボックスの解決策 |
|--------------------------|---------------------|
| エージェントクラッシュ → メッセージ消失 | YAMLファイルは再起動で生存 |
| ポーリングがAPIコールを浪費 | `inotifywait` はイベント駆動（待機中CPU使用率ゼロ） |
| エージェントが互いを割り込む | エージェント毎に専用inboxファイル — クロストークなし |
| デバッグが困難 | `.yaml` ファイルを開けば正確なメッセージ履歴が見える |
| 並行書き込みでデータ破壊 | `flock` が自動的に書き込みを直列化 |
| 配信失敗（文字化け） | メッセージ内容はファイルに残り、tmux経由は短いスリケンのみ |

### なぜヤマヒロだけがダッシュボードを更新するのか

1. **単一ライター**: 更新を1エージェントに限定して競合防止
2. **情報集約**: ヤマヒロが全クローンヤクザのレポートを受け取る → 全体像を把握
3. **一貫性**: 全ての更新が単一の品質ゲートを通過

---

## トラブルシューティング

<details>
<summary><b>npm版のClaude Code CLIを使っている？</b></summary>

npm版は公式に非推奨。`first_setup.sh` を再実行するとネイティブ版への移行を検出・案内。

</details>

<details>
<summary><b>MCPツールが読み込まれない？</b></summary>

MCPツールは遅延読み込み。先に検索してから使用:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

<details>
<summary><b>ワーカーがスタック？</b></summary>

```bash
tmux attach-session -t multiagent
# Ctrl+B → 0-8 でペイン切り替え
```

njslyrがスタックしたエージェントを自動回復するはず。動いていない場合: `bash scripts/njslyr.sh &`

</details>

<details>
<summary><b>エージェントがクラッシュ？</b></summary>

**既存tmuxセッション内で `css`/`csm` エイリアスを使わないこと** — セッションのネストが発生。

```bash
# 方法1: ペインで直接claudeを実行
claude --model opus --dangerously-skip-permissions

# 方法2: respawn-paneで強制再起動
tmux respawn-pane -t darkninja:0.0 -k 'claude --model opus --dangerously-skip-permissions'
```

</details>

---

## tmuxクイックリファレンス

| コマンド | 説明 |
|---------|------|
| `tmux attach -t darkninja` | ダークニンジャに接続 |
| `tmux attach -t multiagent` | ワーカーに接続 |
| `Ctrl+B` → `0`–`8` | ペイン切り替え |
| `Ctrl+B` → `d` | デタッチ（エージェントは稼働継続） |
| `tmux kill-session -t darkninja` | ダークニンジャセッション停止 |
| `tmux kill-session -t multiagent` | ワーカーセッション停止 |

マウスサポートは `first_setup.sh` で自動設定（`set -g mouse on`）。クリックでペイン切り替え、マウスホイールでスクロール、ボーダーをドラッグでリサイズ。

---

## 更新履歴

### v3.5 — ヤクザ天狗、エージェント命名

- **ヤクザ天狗** — ヤマヒロ過負荷時に自動spawnする緊急スーパーバイザー。アイドルのクローンヤクザペインを選び、ダークピンクペイン（`#3a0025`）のSonnetスーパーバイザーとしてrespawn。タスク配分後、ヤマヒロ復帰時にdespawn
- **エージェント命名** — Gryakuzaに正式名: **ヤマヒロ**。コード上のIDは変更なし
- **ヤクザ・ペルソナ強制** — クローンヤクザが `/clear` リカバリー後も忍殺語+ヤクザスラングの口調を維持
- **サムライ語禁止** — サムライ語（ゴザル、拙者等）の明示的な禁止 — ヤクザはヤクザであってサムライではない
- **macOSサポート改善** — fswatch対応inbox監視、BSD互換スクリプト

### v3.4 — Bloom→エージェント・ルーティング、E2Eテスト、Stop Hook

- **Bloom→エージェント・ルーティング** — 動的モデル切り替えをエージェントレベルのルーティングに置換。L1–L3→クローンヤクザ（Sonnet）、L4–L6→ソウカイヤ（Opus）
- **ソウカイヤ幹部のファーストクラスエージェント化** — ペイン8の戦略アドバイザー。深い分析、設計レビュー、アーキテクチャ評価を担当
- **E2Eテストスイート（19テスト、7シナリオ）** — モックCLIフレームワークで分離tmuxセッション内のエージェント挙動をシミュレート
- **Stop Hookインボックス配信** — Claude Codeエージェントがターン終了時にinboxを自動チェック
- **モデルデフォルト更新** — Gryakuza: Opus→Sonnet、ソウカイヤ: Opus

### v3.3.2 — GPT-5.3-Codex-Sparkサポート

- **Codex `--model`フラグ対応** — `gpt-5.3-codex-spark` および将来のCodexモデルをサポート
- **個別レートリミット** — Sparkは専用クォータ。両モデルを並列実行でスループット2倍

### v3.0 — マルチCLI

- **マルチCLIアーキテクチャ** — `lib/cli_adapter.sh` がエージェント毎にCLIを動的選択（Claude/Codex/Copilot/Kimi）
- **OpenAI Codex CLI統合** — GPT-5.3-codexの自律実行
- **ハイブリッドアーキテクチャ** — コマンド層はClaude Code、ワーカー層はCLI非依存
- **コミュニティ貢献CLIアダプタ** — [@yuto-ts](https://github.com/yuto-ts)、[@circlemouth](https://github.com/circlemouth)、[@koba6316](https://github.com/koba6316) に感謝

<details>
<summary><b>v2.0</b></summary>

- ntfy双方向通信
- SayTask通知（ストリーク、Eat the Frog）
- ペインボーダー・タスク表示
- シャウトモード
- エージェント自己監視+3段階エスカレーション
- エージェント自己識別（`@agent_id`）
- 決戦モード（`-k`フラグ）
- タスク依存関係システム（`blockedBy`）

</details>

---

## コントリビュート

Issue・Pull Requestを歓迎します。

- **バグ報告**: 再現手順を添えてIssueを開いてください
- **機能アイデア**: まずDiscussionを開いてください
- **スキル**: スキルは設計上パーソナルなものであり、このリポジトリには含まれません

## クレジット

[Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication) by Akira-Papa をベースにしています。

## ライセンス

[MIT](LICENSE)

---

<div align="center">

**コマンド1つ。8体のエージェント。調整コストゼロ。**

役に立ったらStarをお願いします — 他の人が見つけやすくなります。

</div>
