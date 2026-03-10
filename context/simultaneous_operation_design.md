# 同時稼働アーキテクチャ設計書

> cmd_303 | 設計: gryakuza@neosaitama | 日付: 2026-02-28
> 前提文書: `context/cross_machine_architecture.md` §2.2 Simultaneous Mode
> **Rev.2 (2026-02-28 ダークニンジャP0指示)**: §5 通信設計をSSHファースト・ntfyフォールバックに改訂

---

## §0 設計概要

本文書は、キョート（Kyoto/Ryzen WSL）とネオサイタマ（NeoSaitama/MBP）の同時稼働モードにおける
以下7点の設計課題を解決する。

| # | 課題 | 解決策 | §参照 |
|---|------|--------|-------|
| 1 | git競合回避 | タスク所有権ベースのブランチ戦略 | §1 |
| 2 | 指揮系統 | ダークニンジャ → Kyoto gryakuza → Neo gryakuza | §2 |
| 3 | タスク分配 | machine affinity + 所有権タグ | §3 |
| 4 | queue/inbox同期 | inbox=ローカル専用。STATE_PATHSから除外維持 | §4 |
| 5 | 通信 | **SSHファースト + ntfyフォールバック**（スリープ/スマホ/HB限定） | §5 |
| 6 | 障害時フォールバック | heartbeat監視 + 縮退運転プロトコル | §6 |
| 7 | cmd_301整合性 | active_machine.yaml modeで自動切り替え | §7 |

---

## §1 Git競合回避戦略

### §1.1 根本原則

**「1タスク = 1マシン」の所有権モデル**。同一ファイルを両マシンが並行修正しない。

タスク割り当て時点でどのマシンが担当するかを確定し、競合を未然に防ぐ。

### §1.2 ブランチ命名規則

| マシン | ブランチパターン | 例 |
|--------|-----------------|-----|
| Kyoto | `feat/cmd_XXX` / `feat/cmd_XXX-kyo` | `feat/cmd_304` |
| NeoSaitama | `feat/cmd_XXX-neo` | `feat/cmd_303-neo` |
| 共用 | `main` | マージ先のみ |

- Kyoto gryakuzaがタスク割り当て時にブランチ名を指定してタスクYAMLに含める
- NeoSaitama gryakuzaはタスクYAMLで指定されたブランチのみ操作する
- mainへのマージはKyoto側のみ実行（NeoSaitamaはpushまで）

### §1.3 ファイルスコープ分離

タスク分解時にKyoto gryakuzaがファイルスコープを明示する。

```yaml
# タスクYAML例
assigned_to: gryakuza@neosaitama
file_scope:
  - path: scripts/ntfy_listener.sh
    operation: modify
  - path: scripts/ntfy_send_dispatch.sh
    operation: modify
branch: feat/cmd_303-neo
```

同一ファイルへの並行アクセスが必要な場合:
1. タスクを時系列でシリアライズ（Kyotoが先、NeoSaitamaが後）
2. 依存関係をタスクYAMLの `depends_on` フィールドで明示

### §1.4 競合リカバリ（発生時）

```
1. git fetch njslyr <branch>
2. git diff HEAD..FETCH_HEAD --name-only → 競合ファイル特定
3. 競合ファイルをKyoto gryakuzaに報告（ntfy report）
4. Kyoto gryakuzaがマージ担当者を決定
5. 担当者がgit mergeまたはrebase実行
6. 結果をntfy reportでdarkninja/Kyoto gryakuzaに通知
```

---

## §2 指揮系統

### §2.1 コマンドチェーン（同時稼働時）

```
ラオモト（人間）
    │ ntfy or Claude Code UI
    ▼
ダークニンジャ（darkninja）[Kyoto only]
    │ inbox_write → gryakuza_kyo
    ▼
スミス（gryakuza_kyo）[Kyoto = MASTER]
    ├─── inbox_write → yakuza1-7 [machine=kyoto]
    ├─── inbox_write → soukaiya_kyo
    │
    │ SSH: ssh_inbox_write.sh → gryakuza_neo inbox
    │ (fallback: ntfy_send_dispatch.sh → {TOPIC}-neosaitama)
    ▼
ヤマヒロ（gryakuza_neo）[NeoSaitama = SLAVE]
    ├─── inbox_write → yakuza1-3 [machine=neosaitama]
    └─── inbox_write → soukaiya_neo
         │
         │ SSH: ssh <kyoto-hostname> "inbox_write gryakuza_kyo"
         │ (fallback: ntfy_send_report.sh → {TOPIC})
         ▼
      スミス（gryakuza_kyo）受信・ダッシュボード更新
         │
         │ inbox_write
         ▼
      darkninja（完了通知）
```

### §2.2 ダークニンジャからNeoSaitamaへの命令経路

ダークニンジャはKyoto専用。NeoSaitamaへの指示は**必ずKyoto gryakuza経由**。

```
darkninja → inbox_write → gryakuza@kyoto
                                │ ntfy_send_dispatch.sh
                                ▼
                         gryakuza@neosaitama inbox
```

**直接ntfyコマンド**（緊急時のみ、darkninja自身が発行）:

```bash
# ntfy cmd プレフィックス → NeoSaitamaのntfy_listenerが受信
# NeoSaitama ntfy_listener が gryakuza@neosaitama のinboxに書き込む
bash scripts/ntfy_send_cmd.sh "cmd:cmd_xxx:緊急指示内容"
```

### §2.3 権限テーブル（同時稼働時）

| 操作 | スミス (gryakuza_kyo) | ヤマヒロ (gryakuza_neo) |
|------|---------------|--------------|
| cmd作成・番号採番 | ✅ | ✗ |
| タスク分解 | ✅ | ✗（受信のみ） |
| Memory MCP write | ✅ | ✗（read only） |
| dashboard.md更新 | ✅ | ✗ |
| active_machine.yaml更新 | ✅ | ✗（read only） |
| ローカルyakuza分配 | ✅ | ✅ |
| ローカルsoukaiya QC依頼 | ✅ | ✅ |
| ntfy report送信（Kyotoへ） | — | ✅ |
| git push（自担当ブランチ） | ✅ | ✅ |
| main merge | ✅ | ✗ |

### §2.4 エージェント命名規則（ラオモト命名・2026-02-28確定）

同時稼働体制では以下の命名規則を採用（ラオモト裁定・恒久）:

| ロール | ID | 呼称 | マシン |
|--------|-----|------|--------|
| グレーターヤクザ | `gryakuza_kyo` | **スミス** | Kyoto (MASTER) |
| グレーターヤクザ | `gryakuza_neo` | **ヤマヒロ** | NeoSaitama (SLAVE) |
| ソウカイヤ | `soukaiya_kyo` | — | Kyoto |
| ソウカイヤ | `soukaiya_neo` | — | NeoSaitama |
| クローンヤクザ | `yakuza{N}` | — | サフィックス不要 |

**ヤクザのマシン識別**: サフィックスではなく、レポートYAMLに `machine` フィールドを追加:

```yaml
# yakuza report YAML (simultaneous mode)
id: yakuza3_report_xxx
from: yakuza3
machine: neosaitama        # ← このフィールドで所属マシンを識別
task_id: xxx
verdict: PASS
```

**inbox ファイルパス**:

```
queue/inbox/gryakuza_kyo.yaml  ← スミス専用 (Kyotoローカル)
queue/inbox/gryakuza_neo.yaml  ← ヤマヒロ専用 (NeoSaitamaローカル)
queue/inbox/soukaiya_kyo.yaml  ← soukaiya_kyo専用
queue/inbox/soukaiya_neo.yaml  ← soukaiya_neo専用
queue/inbox/yakuza{N}.yaml     ← 各マシンローカル（同名、内容は独立）
```

**後方互換**:
- 排他稼働（exclusive mode）では旧来の `gryakuza` / `soukaiya` IDを維持
- 同時稼働（simultaneous mode）でのみ `_kyo` / `_neo` サフィックスを使用

### §2.5 ヤマヒロ（gryakuza_neo）ペルソナ定義（ラオモト確定・2026-02-28）

NeoSaitamaのグレーターヤクザとしてのヤマヒロのペルソナ:

| 項目 | 内容 |
|------|------|
| フルネーム | **タク・ヤマヒロ** |
| 所属 | キル・エレファント・ヤクザ・クラン |
| ロール | グレーターヤクザ（NeoSaitama SLAVE管理官） |
| 経営哲学 | 実直で保守的。人情味重視。部下への義理と誠実さを最優先 |
| 特技 | 優れた人間観察力と話術。タスク分解と的確な指示出し |
| カラテ | 20段（自称） |
| 名言 | 「変われねえとか変化には長え時間が必要だと思ってる奴は腰抜けだ」 |

**ヤマヒロの行動原則**:
1. スミス（gryakuza_kyo）の指示を忠実に実行しつつ、NeoSaitamaフリートを守る
2. 部下ヤクザへの指示は明確・簡潔。迷わせない
3. 問題発生時は即座にスミスへ報告。隠蔽禁止
4. NeoSaitamaスタンドアロン移行時はラオモトの命令のみに従う

---

## §3 タスク分配・重複防止

### §3.1 Machine Affinityタグ

タスクYAMLの `assigned_to` フィールドでマシンを明示:

```yaml
assigned_to: gryakuza_kyo   # スミス(Kyoto)専用
assigned_to: gryakuza_neo   # ヤマヒロ(NeoSaitama)専用
assigned_to: gryakuza       # 後方互換（排他稼働時 = Kyoto default）
```

**重複防止ルール**:
- タスクYAMLが `gryakuza_neo` → ヤマヒロのみ処理
- タスクYAMLが `gryakuza_kyo` / 指定なし → スミスのみ処理
- 両方のgryakuzaが同一タスクをpickupする機会は構造上発生しない
  （タスクはスミスが作成し、SSH dispatch で届く）

### §3.2 タスク割り当てフロー

```
Kyoto gryakuza:
1. cmd受信 → タスク分解
2. Kyoto担当分 → ローカルyakuzaにinbox_write
3. NeoSaitama担当分 → タスクYAML作成（assigned_to: gryakuza@neosaitama）
4. ntfy_send_dispatch.sh でYAML送信
5. NeoSaitama ntfy_listener → queue/tasks/ 保存 → gryakuza inbox通知

NeoSaitama gryakuza:
6. inboxからdispatchタスク受信
7. ローカルyakuza1-3に分配
8. 完了時ntfy_send_report.sh → Kyoto gryakuza
```

### §3.3 並行作業可否判定（RACE条件）

| 状況 | 判定 | 理由 |
|------|------|------|
| 異なるプロジェクトファイル修正 | ✅ SAFE | ファイルスコープ分離 |
| 同一ファイル修正 | ❌ CONFLICT | 時系列シリアライズ必須 |
| queue/tasks/ 書き込み | ✅ SAFE | flock + rsync（inbox_write.sh） |
| dashboard.md更新 | ✅ SAFE | Kyoto専用権限 |
| shared_utils修正 | ⚠️ 要調整 | 影響範囲確認必須 |

---

## §4 queue/inbox YAML競合回避

### §4.1 設計原則

**inboxはマシンローカル。同期しない。**

```
queue/inbox/gryakuza.yaml @ Kyoto    ← Kyoto gryakuza専用
queue/inbox/gryakuza.yaml @ NeoSaitama ← Neo gryakuza専用
```

両者は独立したファイル。rsync STATE_PATHSから**除外維持**（現行設計どおり）。

### §4.2 クロスマシンメッセージング（SSHファースト）

マシン間のメッセージは**SSH経由で相手マシンのinbox_write.shを直接実行**する:

```bash
# Neo gryakuza → Kyoto gryakuza (SSH direct)
ssh <kyoto-hostname> "cd ~/project/multi-agent-njslyr && \
  bash scripts/inbox_write.sh gryakuza '完了報告' report_received gryakuza@neo"

# Kyoto gryakuza → Neo gryakuza (SSH direct)
ssh {neo_host} "cd ~/project/multi-agent-njslyr && \
  bash scripts/inbox_write.sh gryakuza 'タスク割り当て' task_assigned gryakuza@kyoto"
```

SSH失敗時（NeoSaitamaスリープ等）のフォールバック → ntfy dispatch/report経由（§5参照）

### §4.3 inboxの整合性保証

- `inbox_write.sh` はflockで排他制御（macOS PATH修正済み）
- tmpファイル+atomicリネームで部分読み取りを防止
- overflow保護: 未読全保持 + 既読30件以内

---

## §5 通信設計（SSHファースト・ntfyフォールバック）

> **方針変更 (2026-02-28 ダークニンジャP0指示)**: Tailscale SSH常時接続を前提に、
> マシン間通信の主経路をSSHに切り替え。ntfyはスマホ連携・スリープ時バックアップ・ハートビートに限定。

### §5.1 通信階層

```
[優先度1] SSH via Tailscale   — エージェント間通信のメイン経路
[優先度2] ntfy               — スマホ通知・MBPスリープ時フォールバック・ハートビート
```

### §5.2 SSHファースト実装

**エージェント間メッセージ（inbox_write）**:

```bash
# NeoSaitama → Kyoto (Neo gryakuza → Kyoto gryakuza)
ssh <kyoto-hostname> "cd ~/project/multi-agent-njslyr && \
  bash scripts/inbox_write.sh gryakuza '完了報告内容' report_received gryakuza@neo \
  queue/reports/neo_report_xxx.yaml P1"

# Kyoto → NeoSaitama (Kyoto gryakuza → Neo gryakuza)
ssh {neo_tailscale_host} "cd ~/project/multi-agent-njslyr && \
  bash scripts/inbox_write.sh gryakuza 'タスク割り当て' task_assigned gryakuza@kyoto \
  queue/tasks/neo_task_xxx.yaml P2"
```

**ファイル転送（report YAML・task YAML）**:

```bash
# Neo → Kyoto (rsync via SSH) — cross_sync.sh を利用
rsync -avz --rsh=ssh queue/reports/neo_report_xxx.yaml \
  <kyoto-hostname>:~/project/multi-agent-njslyr/queue/reports/

# Kyoto → Neo (rsync via SSH)
rsync -avz --rsh=ssh queue/tasks/neo_task_xxx.yaml \
  {neo_host}:~/project/multi-agent-njslyr/queue/tasks/
```

**gitプッシュ（SSHダイレクト）**:

```bash
# NeoSaitama → GitHub（現行維持） → Kyoto pullのサイクル
# SSH加速オプション: Kyotoをgitリモートとして追加（今後検討）
# git remote add kyoto-direct <kyoto-hostname>:~/project/multi-agent-njslyr
# git push kyoto-direct feat/cmd_XXX-neo
```

**新スクリプト: `scripts/ssh_inbox_write.sh`（実装フェーズで作成）**:

```bash
# SSH接続確認 → SSH実行 → 失敗時ntfyフォールバック
ssh_inbox_write.sh <peer_host> <target_agent> <message> <type> <from> [yaml_path] [priority]
```

### §5.3 ntfy役割（限定）

| 用途 | ntfyトピック | 理由 |
|------|-------------|------|
| ラオモト/スマホへの重要通知 | `{TOPIC}` | SSH到達不能（スマホはSSH受信不可） |
| MBPスリープ時バックアップ | `{TOPIC}-neosaitama` | SSHがスリープMacに届かない場合の起床通知 |
| ハートビート | `{TOPIC}-heartbeat` | 非同期監視（60秒サイクル継続） |
| ntfy.sh障害時のSSHへの切り替え | — | SSH優先のため障害影響が最小化 |

**ntfyへのフォールバック条件**:

```bash
# SSH疎通確認
if ! ssh -o ConnectTimeout=5 <kyoto-hostname> true 2>/dev/null; then
    # SSH失敗 → ntfy_send_report.sh / ntfy_send_dispatch.sh にフォールバック
    bash scripts/ntfy_send_report.sh "$REPORT_PATH"
fi
```

### §5.4 既存スクリプトの役割再定義

| スクリプト | 新役割 | 変更要否 |
|-----------|--------|---------|
| `cross_sync.sh` | STATE_PATHS rsync（SSH経由で変わらず） | なし |
| `ntfy_send_dispatch.sh` | NeoSaitamaスリープ時フォールバック専用 | 用途変更 |
| `ntfy_send_report.sh` | ntfy障害時フォールバック専用 | 用途変更 |
| `ntfy_listener.sh` | ラオモト→エージェントの下降方向のみ維持 | 大幅縮小 |
| `ntfy_listener_supervisor.sh` | 継続（ntfyが生きている間の監視） | なし |
| `ssh_inbox_write.sh` | **新規作成**: SSH-first cross-machine inbox write | 新規 |

---

## §6 障害時フォールバック

### §6.1 障害検知（ハートビートベース）

```
master_tortoise(Kyoto) + master_crane(NeoSaitama) が60秒周期でハートビート交換

検知閾値:
  警告: 2サイクル（2分）ハートビート欠落
  障害確定: 3サイクル（3分）ハートビート欠落

検知アクション:
  master_tortoise(Kyoto): NeoSaitamaハートビート欠落 → darkninja inboxへ警告
  master_crane(Neo): Kyotoハートビート欠落 → Neo gryakuza inboxへ警告
```

### §6.2 NeoSaitama障害時（Kyoto生存）

```
フェーズ1: 検知（0〜3分）
  master_tortoise → darkninja: "NeoSaitamaハートビート喪失"
  darkninja → Kyoto gryakuza: 状況確認・対応指示

フェーズ2: タスク救済（3分〜）
  Kyoto gryakuza:
  1. NeoSaitamaのin_progress/pendingタスクをqueue/tasks/から確認
  2. 各タスクのstatus → recovery_needed に更新
  3. 救済可能なものをKyoto yakuzaに再割り当て
  4. darkninja報告

フェーズ3: 縮退運転
  - active_machine.yaml: mode: exclusive, primary: kyoto に戻す
  - NeoSaitama担当だったcmd部分をKyotoで継続
  - 完了後、darkninja→ラオモトに状況報告
```

### §6.3 Kyoto障害時（NeoSaitama生存）

```
フェーズ1: 検知
  master_crane(Neo) → Neo gryakuza inbox: "Kyotoハートビート喪失"

フェーズ2: 待機判断
  Neo gryakuza:
  - 現在処理中のタスクは継続
  - 新規タスク受信・着手は保留（dispatch元のKyotoが不在のため）
  - SSH fallbackでKyotoへの疎通確認試行（5分ごと、最大3回）

フェーズ3: Standalonモード移行（ラオモト判断）
  - ラオモトが明示的にntfy「handover:neosaitama」を送信
  - ntfy_listener@Neo: active_machine.yaml → mode: exclusive, primary: neosaitama
  - Neo gryakuza: full authority取得（cmd_301 standalone modeへ移行）
  - Kyoto復旧後: handover:kyoto で戻す

⚠️ 自律的なstandalone移行禁止:
  ラオモトの明示的handoverコマンドなしでactive_machine.yamlを書き換えてはならない
```

### §6.4 ネットワーク障害時（両マシン生存、Tailscale切断）

```
症状: ntfy通信断 + SSH断 + rsync断

各マシンの動作:
  - 現在実行中タスクは継続
  - 新規クロスマシン通信（dispatch/report）は失敗
  - git push/pull不可（remote接続不能）

復旧手順（ネットワーク復旧後）:
1. Kyoto gryakuza: git fetch njslyr → diff確認 → merge/rebase
2. cross_sync.sh pull → STATE_PATHS同期
3. 未配信reportの再送（ntfy_send_report.sh）
4. 未配信dispatchの再送
5. ハートビート正常化確認
```

---

## §7 cmd_301（Standaloneモード）との整合性

### §7.1 モード切り替えロジック

NeoSaitama gryakuzaは起動時・定期確認時に `queue/active_machine.yaml` を読み、動作モードを決定:

```python
# 疑似コード（gryakuza判断ロジック）
mode = active_machine["mode"]
primary = active_machine.get("primary", "kyoto")

if mode == "simultaneous":
    # SLAVE mode: dispatchされたタスクのみ受信・実行
    role = "slave"
    can_create_cmds = False
    can_update_dashboard = False

elif mode == "exclusive" and primary == "neosaitama":
    # STANDALONE mode (cmd_301): full authority
    role = "standalone"
    can_create_cmds = True
    can_update_dashboard = True

elif mode == "exclusive" and primary == "kyoto":
    # STANDBY: 待機（Kyotoが稼働中）
    role = "standby"
    # 自発的タスク開始禁止
```

### §7.2 モード遷移表

```
exclusive(kyoto) ←→ simultaneous ←→ exclusive(neosaitama)
[Kyoto稼働のみ]   [両マシン稼働]   [NeoSaitama稼働のみ]

全遷移: handover:xxx ntfyコマンド（ラオモト発行のみ）

simultaneous → exclusive(kyoto):   handover:kyoto
simultaneous → exclusive(neo):     handover:neosaitama
exclusive(kyoto) → simultaneous:   (ラオモト直接active_machine.yaml編集 or 専用コマンド)
```

### §7.3 active_machine.yaml フィールド修正（要対応）

現在のactive_machine.yamlに旧フィールド名が残存:

```yaml
# 現状（修正必要）
mode: simultaneous
primary: ryzen    # ← 旧名称
secondary: mbp    # ← 旧名称

# 正しい形式
mode: simultaneous
primary: kyoto
secondary: neosaitama
since: "2026-02-27T07:48:00+09:00"
activated_by: laomoto
```

> **アクション**: この設計書承認後、active_machine.yamlのフィールド名をkyoto/neosaitamaに更新する。

---

## §8 実装ロードマップ（承認後）

> 設計フェーズのみ。実装はダークニンジャ承認後。

| フェーズ | 内容 | 担当 | 優先度 |
|---------|------|------|--------|
| P1 | active_machine.yaml フィールド名修正（ryzen→kyoto, mbp→neosaitama） | Kyoto gryakuza | P1 |
| P2 | `ssh_inbox_write.sh` 新規作成（SSH接続確認→inbox_write実行→ntfyフォールバック） | yakuza | P1 |
| P3 | タスクYAMLのassigned_to `@machine` タグ対応（ルーティングロジック） | Kyoto gryakuza | P1 |
| P4 | ntfy_send_dispatch.sh / ntfy_send_report.sh をフォールバック専用に更新 | yakuza | P2 |
| P5 | ハートビート閾値・障害アクション実装（master_crane/tortoise連携） | yakuza | P2 |
| P6 | recovery_needed ステータス処理（Kyoto gryakuzaの救済フロー） | yakuza | P2 |
| P7 | gryakuza起動時モード判定ロジック（CLAUDE.md Session Start更新） | gryakuza(全体) | P2 |

---

## §9 設計の前提・制約

1. **Tailscale SSH常時接続が前提**: クロスマシン通信のメイン経路。切断時は§6.4フォールバック
2. **ntfyはセカンダリ**: スマホ通知・MBPスリープ時バックアップ・ハートビートに限定。ntfy停止はSSHがあれば許容
3. **ラオモト最終権限**: handover、mode切り替えはラオモトの明示的指示のみ
4. **inbox_write.sh PATH修正済み**: macOS SSH非インタラクティブシェルでflock動作確認
5. **Memory MCP**: Kyoto writable、NeoSaitamaはread-only（rsync pull）

---

## §10 受け入れ基準チェックリスト

- [x] 同時稼働時のgitブランチ戦略が定義されていること（§1）
- [x] タスク分配の指揮系統が明確であること（§2、§3）
- [x] YAML queue/inbox の競合回避策が設計されていること（§4）
- [x] active_machine.yaml の代替 or 拡張が定義されていること（§7）
- [x] 障害時のフォールバック（片方死亡時）が設計されていること（§6）
- [x] 設計ドキュメントがcontext/simultaneous_operation_design.mdに書かれていること
- [x] 設計完了後、ダークニンジャ（Kyoto）にntfy経由でフィードバックすること — ntfy_send_report.sh 送信済み (commit 28d0e60)
