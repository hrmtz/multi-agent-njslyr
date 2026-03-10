# Cross-Machine Architecture

> 命名規則: **kyoto** = Ryzen WSL (formerly `ryzen`), **neosaitama** = MBP (formerly `mbp`)
> 設計: cmd_278 | 命名更新: cmd_279 | 実作成: cmd_279efix

---

## §1 概要

本システムは2台のマシンで構成される。

| 識別子 | 旧識別子 | 実機 | 役割 |
|--------|----------|------|------|
| `kyoto` | `ryzen` | Ryzen WSL (Chichibu) | Primary / Server |
| `neosaitama` | `mbp` | Apple M1 Pro MBP | Secondary / Client |

- **コードベース共有**: git（`hrmtz/multi-agent-njslyr`）
- **状態YAML共有**: rsync over Tailscale（`cross_sync.sh`）
- **リアルタイム通信**: ntfy.sh（プレフィックスルーティング）
- **ネットワーク**: Tailscaleメッシュ。KyotoのTailscaleホスト名 = `<kyoto-hostname>`

---

## §2 稼働モード

### §2.1 Exclusive Mode（排他稼働）

一方のマシンのみ稼働する標準モード。`queue/active_machine.yaml` の `mode: exclusive` で示される。

```yaml
mode: exclusive
primary: kyoto
```

### §2.2 Simultaneous Mode（同時稼働）

両マシンを同時に稼働させるモード。ラオモトの明示的指示で発動。

```yaml
mode: simultaneous
primary: kyoto      # (旧: ryzen)
secondary: neosaitama  # (旧: mbp)
since: "2026-02-27T07:48:00+09:00"
activated_by: laomoto
mbp_fleet:
  gryakuza: slave
  yakuza_count: 3
  soukaiya: local_qc_only
  monitor: master_crane
```

Simultaneous Mode下では:
- KyotoがMasterとしてタスク分解・cmd作成・Memory MCP write権限を保持
- NeoSaitamaはSlaveとしてサブタスクのみ受信・実行

---

## §3 エージェント構成

### §3.1 Kyoto フリート（Primary / Master）

| エージェント | 役割 | 台数 |
|------------|------|------|
| darkninja | 最高司令官 | 1 |
| gryakuza | グレーターヤクザ（タスク分解・管理） | 1 |
| yakuza1〜7 | クローンヤクザ（実装担当） | 最大7 |
| soukaiya | QC担当 | 1 |
| master_tortoise | 予防監視（未来視） | 1 |

- **master_tortoise**: CLIエージェント(Sonnet)。コンテキスト溢れ予測・応答パターン分析
- 全権限有効（cmd作成・Memory MCP write・dashboard更新など）

### §3.2 NeoSaitama フリート（Slave Mode）

| エージェント | 役割 | 台数 |
|------------|------|------|
| gryakuza | Slave gryakuza（タスク受信・ローカル分配） | 1 |
| yakuza1〜3 | クローンヤクザ（ローカル実行） | 最大3 |
| soukaiya | ローカルQCのみ | 1 |
| master_crane | 事後分析（過去視） | 1 |

- **master_crane**: CLIエージェント(Sonnet)。障害原因特定・再発防止策・パターンDB蓄積

---

## §4 通信プロトコル

### §4.1 Dispatch（Kyoto → NeoSaitama）

`scripts/ntfy_send_dispatch.sh` を使用。

```bash
bash scripts/ntfy_send_dispatch.sh queue/tasks/yakuza1_subtask_xxx.yaml
```

- ペイロード形式: `dispatch:{base64_yaml}`
- 送信先トピック: `{TOPIC}-neosaitama`（ `{TOPIC}-mbp` でも後方互換あり）
- NeoSaitamaの `ntfy_listener.sh` が受信 → `queue/tasks/` に保存 → gryakuza inboxに通知

### §4.2 Report（NeoSaitama → Kyoto）

`scripts/ntfy_send_report.sh` を使用。

```bash
bash scripts/ntfy_send_report.sh queue/reports/yakuza1_report_xxx.yaml
```

- ペイロード形式: `report:{base64_yaml}`
- 送信先トピック: `{TOPIC}`（メインtopic）
- Tagに `outbound` を付与してセルフ受信を防止
- Kyotoの `ntfy_listener.sh` が受信 → `queue/reports/` に保存

### §4.3 Heartbeat

- **トピック**: `{TOPIC}-heartbeat`
- **プレフィックス**: `hb:host:epoch:agents:load:ctx`
- **周期**: 60秒サイクル
- **参加エージェント**: master_tortoise（Kyoto）、master_crane（NeoSaitama）
- pingメッセージ形式: `ping:source:epoch:message` → ハートビートYAML更新（ntfy_inbox記録なし）

### §4.4 ntfy プレフィックス体系

`ntfy_listener.sh` が以下のプレフィックスでルーティングを行う:

| プレフィックス | 動作 |
|--------------|------|
| `push:cmd_xxx:branch` | auto git pull + darkninja notify |
| `sync:project_name:done` | auto rsync pull (cross_sync.sh) + darkninja notify |
| `cmd:cmd_xxx:内容` | darkninja + gryakuza inboxへ転送 |
| `handover:kyoto\|neosaitama` | active_machine.yaml更新 + gryakuza P0通知 |
| `hb:host:epoch:agents:load:ctx` | ハートビート（heartbeatトピックのみ） |
| `ping:source:epoch:message` | pingレスポンス（ntfy_inbox記録なし） |
| `report:{base64_yaml}` | NeoSaitama→Kyoto レポート受信・queue/reports/保存 |
| `dispatch:{base64_yaml}` | タスクYAML受信・queue/tasks/保存 |

#### ntfyトピック分割

```
{base_topic}                 # メイントピック（全マシン）
{base_topic}-heartbeat       # ハートビートトピック（master_crane/tortoise）
{base_topic}-{machine_role}  # マシン固有トピック（kyoto / neosaitama）
```

---

## §5 Handover Protocol

排他稼働切り替え（Exclusive → Exclusive、別マシンへ）の手順。

### トリガー

ラオモトの明示的ntfyコマンドのみ: `handover:kyoto` または `handover:neosaitama`

**自動handoverは禁止。** エージェントの自律判断によるhandoverは絶対禁止。

### 手順（gryakuzaが実行）

```
1. チェックポイント作成（現在のタスク状態を保存）
2. git push（コードベースを同期）
3. cross_sync.sh push（状態YAMLをpeer machineに転送）
4. queue/active_machine.yaml の primary/secondary を更新
5. 旧Primaryのエージェントをshutdown
6. 新Primaryでエージェントを起動
```

### 注意事項

- handover時はqueue/inbox/を同期しない（machine-local）
- active_machine.yaml更新権限はMaster（kyoto）のgryakuzaのみ

---

## §6 State 管理（active_machine.yaml）

`queue/active_machine.yaml` がシステムの稼働状態を示す唯一の真実源。

### フィールド定義

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `mode` | `exclusive` / `simultaneous` | 稼働モード |
| `primary` | `kyoto` / `ryzen`(compat) | Primary machine |
| `secondary` | `neosaitama` / `mbp`(compat) | Secondary machine（simultaneous時のみ） |
| `since` | ISO 8601 timestamp | モード開始時刻 |
| `activated_by` | `laomoto` / エージェント名 | 変更者 |

### 同期ルール

- **cross_sync.sh** の `STATE_PATHS` に含まれる → push/pullで両マシンに同期される
- 更新権限: Kyoto gryakuzaのみ（Slave gryakuzaは読み取り専用）

---

## §7 Slave Mode 権限制限

`config/settings.yaml` の `machine.role` が `neosaitama`（または後方互換で `mbp`）の場合、Slave gryakuzaに以下の制限が適用される。

| 操作 | 可否 | 備記 |
|------|------|------|
| ntfy/inbox経由のサブタスク受信 | ✅ | Kyoto gryakuzaから受信 |
| ローカルyakuza1-3への割り当て | ✅ | 通常のinbox_write |
| ローカルsoukaiyaへのQC依頼 | ✅ | 通常フロー |
| ntfy経由の完了報告送信 | ✅ | ntfy_send_report.sh使用 |
| 独自のcmd作成 | ✗ | Master exclusive |
| 独自のタスク分解 | ✗ | Pre-decomposedタスク受信のみ |
| Memory MCP write操作 | ✗ | Read-only |
| dashboard.md更新 | ✗ | ステータスはKyoto経由 |
| active_machine.yaml更新 | ✗ | Master exclusive |

### master_crane / master_tortoise の共通制限

モニタリングエージェント（master_crane / master_tortoise）は以下を禁止:

- コード編集・ファイル書き込み
- タスク分配・エージェント停止指示
- 唯一の役割: 監視・分析・レポート送信

---

## §8 rsync 同期カテゴリ

`cross_sync.sh` が管理する同期対象と除外対象。

### 同期対象（STATE_PATHS）

```
queue/tasks/              # タスクYAML
queue/reports/            # レポートYAML
dashboard.md              # ダッシュボード
queue/active_machine.yaml # 稼働状態
```

### MCPメモリ同期（一方向）

```
~/.claude/projects/.../memory/  →  Kyoto → NeoSaitama のみ
```

Memory MCP writeはKyotoのみ実行。NeoSaitamaはKyotoからrsync pullで受け取る。

### 同期除外（machine-local）

```
queue/inbox/      # エージェント固有インボックス
queue/heartbeat/  # ハートビートYAML
.state/           # ロックファイル・状態ファイル
logs/             # ログファイル
.git/
node_modules/
projects/         # シークレット（git-ignored）
```

### 前提条件

- Tailscale接続済み（`tailscale ping --timeout=5s <kyoto-hostname>` が成功すること）
- 両マシンにrsyncインストール済み
- `config/settings.yaml` の `machine.role`, `peer_host`, `peer_project_root` が正確に設定済み
- KyotoへのSSHアクセス（NeoSaitamaから `<kyoto-hostname>` へ）

---

## 参照ドキュメント

| ドキュメント | 内容 |
|------------|------|
| `scripts/cross_sync.sh` | rsync同期実装 |
| `scripts/ntfy_listener.sh` | ntfyプレフィックスルーティング |
| `scripts/ntfy_send_dispatch.sh` | Dispatch送信実装 |
| `scripts/ntfy_send_report.sh` | Report送信実装 |
| `instructions/gryakuza.md` §Slave Mode | Slave権限詳細 |
| `config/settings.yaml` | マシン設定（role, peer_host等） |
| `queue/active_machine.yaml` | 現在の稼働状態（Primary source） |
| `CLAUDE.md` § Cross-Machine Operation | 高レベル概要 |
