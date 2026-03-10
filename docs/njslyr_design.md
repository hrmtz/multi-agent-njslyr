# njslyr — オヒルネエージェント粛清デーモン

**設計ドキュメント (Phase 1)**

---

## 1. 概要・背景

### 目的

ダークニンジャP2指示（2026-02-16 12:53:19）に基づき、アイドル/無応答/長時間thinkingのエージェントを自動検知・粛清する常駐スクリプトを設計する。エージェントの無駄な待機時間を削減し、システム全体の効率を向上させる。

### スコープ

- **Phase 1（本ドキュメント）**: 設計仕様の策定、ラオモト承認待ち
- **Phase 2（別タスク）**: 実装、テスト、本番投入

---

## 2. 検知条件の詳細設計

### 2.1 3つの検知条件

#### (1) アイドル時間超過

- **定義**: タスク割り当てがなく（`queue/tasks/{agent_id}.yaml` の `status: idle`）、かつ一定時間（推奨**5分**）エージェントがアイドル状態を継続
- **検知方法**:
  - タスクYAMLの `status` フィールドを監視
  - `tmux capture-pane` でプロンプト待機状態（`? for shortcuts`, `❯`）を確認
  - 最終inbox更新時刻から5分以上経過している場合

#### (2) スリケン無応答

- **定義**: inbox_write.sh経由でスリケン（`inboxN`）送信後、一定時間（推奨**2分**）反応なし（inbox未読数が減らない）
- **検知方法**:
  - inbox_watcher.shの `FIRST_UNREAD_SEEN` タイムスタンプを活用
  - スリケン送信後、2分以内にinbox未読数が減少しない場合

#### (3) thinking長時間

- **定義**: thinkingが一定時間（推奨**10分**）以上継続
- **検知方法**:
  - `tmux capture-pane` で `Thinking`, `思考中`, `Planning` 等の文字列を検出
  - 同じthinking状態が10分以上継続している場合

### 2.2 総合判断ロジック

- **優先順位**: (3) thinking長時間 > (2) スリケン無応答 > (1) アイドル時間超過
- **AND/OR条件**:
  - (3)のみ単独でトリガー（重大な異常状態）
  - (2)のみ単独でトリガー（inbox_watcher.shのPhase 3と連携）
  - (1)は単独では「自己研鑽タスク割り当て」を検討し、粛清は最終手段
- **除外条件**:
  - darkninja（人間エージェント）は全て除外
  - smith は monitor_context.sh による自動/clear優先（njslyrは補助）
  - エージェントが正当な理由で長時間処理中の場合（次項エッジケースで詳述）

#### 2.2.1 コスト最適化フィルター（ラオモト指定）

**PRIMARY FILTER（最優先判定）**: 粛清判定前に、以下のフィルターを適用:

```bash
# inbox未読チェック（bashコマンド、API不要）
# アンカー付きパターン: YAMLフィールドとして "  read: false" のみ検知（誤検知防止）
if ! grep -q '^ *read: false$' queue/inbox/{agent_id}.yaml; then
    # 未読なし → (3) thinking長時間 を除き、粛清対象外
    skip_agent
fi
```

- **inbox未読あり**: 粛清判定を継続（上記3条件に基づく）
- **inbox未読なし**: 粛清対象外（例外: (3) thinking長時間のみ粛清継続）

**理由**: タスクなしアイドル状態のエージェントにスリケンを送っても、APIトークンを浪費するだけで効果なし。inbox未読がある = 処理すべきメッセージがある = 応答が必要、という明確なトリガーのみを粛清対象とする。

詳細は **Section 4.5 コスト最適化ロジック** を参照。

---

## 3. 粛清方法の詳細設計

### 3.1 3段階エスカレーション

inbox_watcher.shの既存エスカレーション機構をベースとする。

#### Stage 1: スリケン送信（スリケン）

- **方式**: `inbox_write.sh` 経由でinboxにメッセージ追加
- **待機時間**: 2分
- **リトライ**: 最大1回（Stage 1失敗→Stage 2へ）
- **技名**: 「スリケン」（ニンジャスレイヤーの遠距離攻撃）

#### Stage 2: /clear送信（チョップ）

- **方式**: `inbox_write.sh` 経由で `clear_command` タイプのメッセージ送信 → inbox_watcher.shがtmux send-keysで `/clear` 実行
- **待機時間**: 2分
- **リトライ**: 最大1回（Stage 2失敗→Stage 3へ）
- **技名**: 「チョップ」（ニンジャスレイヤーのカラテ・チョップ）

#### Stage 3: kill+再起動（スレイ）

- **方式**（実装済み最新版）:
  1. **再起動ループチェック**: 30分以内に3回再起動済みなら中止してダークニンジャに通知
  2. **Pre-slay data preservation（cmd_277追加）**:
     - 粛清予告をダッシュボードに記載
     - `/compact` 送信（コンテキスト保存、5秒待機）
     - タスクYAML status を `slayed_by_njslyr` に更新
     - 粛清ログを `queue/metrics/njslyr_slay_{timestamp}.yaml` に記録
  3. **remain-on-exit on 設定（ケジメ案件対策）**: `tmux set-option -p -t {pane_target} remain-on-exit on`
     - プロセス終了時にpaneが消滅しないよう保護。tmuxグリッド崩壊防止
  4. 対象paneを真っ赤に染める: `tmux select-pane -t {pane_target} -P 'bg=red'`
  5. **断末魔演出 `generate_death_cry()`**: 辞世の句（5-7-5俳句）または爆発四散を50%で選択表示
     - `tmux respawn-pane -k` で断末魔画面を起動（kill-paneではなくrespawnで**paneを消滅させない**）
  6. `tmux respawn-pane -k` でClaudeプロセスを再起動（**M3修正: kill-pane廃止、respawn-paneでグリッド保護**）
  7. 背景をデフォルトに戻す（remain-on-exitは **ONのまま永続維持**）
  8. 「◆復帰完了◆」を表示
- **待機時間**: N/A（最終手段）
- **リトライ**: なし
- **技名**: 「スレイ」（ニンジャスレイヤーの必殺技 — 画面真っ赤＋プロセス殺害＋再起動）

### 3.2 安全措置

- **darkninja除外**: inbox_watcher.sh と同様、darkninja（人間エージェント）には一切の粛清処理を行わない
- **smith特別扱い**: monitor_context.sh による /clear を優先し、njslyrはバックアップ（Stage 1のみ）
- **クールダウン**: Stage 3（kill+再起動）は同一エージェントに対し30分に1回まで

---

## 4. 実装方式

### 4.1 スクリプト配置

- **ファイル名**: `scripts/njslyr.sh`
- **配置場所**: `/Users/hrmtz/project/multi-agent-njslyr/scripts/njslyr.sh`
- **実行権限**: `chmod +x scripts/njslyr.sh`

### 4.1.1 実装済み追加機能（設計後追加）

#### バリキドリンク投与ヘルパー（cmd_277追加）

```bash
inject_barikidorink "multiagent:0.1"   # yakuza1にOpus投与
detox_barikidorink "multiagent:0.1"    # yakuza1をSonnetに復帰
```

- **inject_barikidorink**: `/model opus` + `@model_name=Opus` + 背景紫 + `/clear`
- **detox_barikidorink**: `/model sonnet` + `@model_name=Sonnet` + 背景デフォルト + `/clear`
- **用途**: タスク処理速度向上が必要な場合にOpusへ昇格させ、完了後にSonnetへ戻す

### 4.2 監視方式

- **tmux capture-pane**: エージェントの状態を定期監視（5分間隔）
  - pane内のテキスト（`? for shortcuts`, `Thinking`, `Working`等）から状態判定
- **タスクYAML監視**: `queue/tasks/` 配下のYAMLファイルから `status` フィールド抽出
  - **M1修正**: globパターン `${agent_id}*.yaml` で `_subtask_xxx.yaml` 形式のファイルも検索
- **inbox監視**: `queue/inbox/` 配下のYAMLファイルから未読数カウント
- **pane動的検索（M2修正）**: `get_pane_target()` が `@agent_id` 変数でpaneを動的検索
  - 形式: `multiagent:1.{pane_index}` を返す
  - pane追加・削除があってもインデックスずれが発生しない

### 4.3 inbox_watcher.shとの統合/連携

#### 既存機能の活用

- **Phase 1-3エスカレーション**: inbox_watcher.shの既存ロジックを流用
  - njslyrは「inbox_watcher.shのエスカレーションが発動しない場合の補完」として動作
  - inbox_watcher.shが既にPhase 3（/clear）を送っている場合、njslyrはスキップ

#### 統合方針

- **njslyrの独自検知**: inbox_watcher.shがカバーしない「inbox未読0だがアイドル長時間」ケースを検知
- **共通ログ出力**: 両スクリプトとも `queue/metrics/` 配下にメトリクスYAML出力
- **重複回避**: njslyrは粛清実行前に inbox_watcher.sh のエスカレーション状態（`FIRST_UNREAD_SEEN`, `LAST_CLEAR_TS`）を確認

### 4.4 バックグラウンド実行方式

#### 方式1: 無限ループ + sleep（推奨）

```bash
#!/bin/bash
while true; do
    # 全エージェント監視ロジック
    check_all_agents
    sleep 900  # 15分間隔（コスト最適化）
done
```

- **起動**: `bash scripts/njslyr.sh &` または tmux別pane起動
- **停止**: `pkill -f njslyr.sh`

#### 方式2: cron（代替案）

```cron
*/15 * * * * cd /Users/hrmtz/project/multi-agent-njslyr && bash scripts/njslyr.sh once
```

- **利点**: システム再起動時に自動再開
- **欠点**: 15分間隔では応答性が低い、cronログ管理が煩雑

**決定**: 方式1を採用（応答性優先）

### 4.5 コスト最適化ロジック（ラオモト指定）

#### 背景

全エージェントを無差別に起動・監視すると、不要なAPIトークン消費が発生する。特に「タスクなしでアイドル状態」のエージェントにスリケンを送っても、応答は「何もしない」だけであり、トークン浪費となる。

#### 最適化戦略

**基本方針**: **inbox未読があるエージェントのみ粛清対象とする**。タスクなしアイドルは放置（APIトークン節約）。

#### 検知ロジック（5段階フロー）

njslyrは以下の5段階フローで粛清判定を行う:

1. **inbox未読チェック（bash grep、API不要）**:
   ```bash
   # アンカー付きパターン（誤検知防止: メッセージ本文の "read: false" 文字列は無視）
   grep '^ *read: false$' queue/inbox/{agent_id}.yaml
   ```
   - 未読メッセージが存在しない場合、このエージェントはスキップ（粛清対象外）
   - 未読メッセージが存在する場合、次のステップへ

2. **未読あり → Stage 1（スリケン）**:
   - inbox_write.sh経由でスリケン送信
   - 2分待機

3. **未読なし → スキップ**:
   - ログに `[njslyr] {agent_id}: no unread messages, skipping` を記録
   - 次のエージェントへ

4. **前回スリケン無反応 → Stage 2（チョップ）**:
   - Stage 1実行後、2分経過してもinbox未読数が減っていない場合
   - inbox_write.sh経由で `clear_command` 送信

5. **Stage 2無反応 → Stage 3（スレイ）**:
   - Stage 2実行後、2分経過してもinbox未読数が減っていない場合
   - kill + 再起動実行

#### メリット

- **APIトークン削減**: アイドルエージェントへの不要なスリケンを回避
- **シンプルな実装**: `grep '^ *read: false$'` で判定可能。Claude Code APIを叩かず、bashコマンドのみで完結
- **inbox_watcher.shとの整合性**: inbox_watcher.shも「未読あり」をトリガーとしているため、ロジックが統一される

#### 除外ケース

以下のケースは**コスト最適化の例外**とし、inbox未読なしでも粛清対象とする:

- **(3) thinking長時間**: 10分以上thinkingが継続している場合（セクション2.1参照）
  - 理由: thinkingのまま無応答 = 異常状態の可能性が高い。inbox未読の有無に関わらず介入が必要

---

## 5. 監視対象エージェント

### 5.1 対象リスト

| エージェント | 監視対象 | 備考 |
|---|---|---|
| **darkninja** | ❌ 除外 | 人間エージェント。粛清処理一切禁止 |
| **smith** | ⚠️ 制限付き | monitor_context.sh優先。njslyrはStage 1のみ |
| **yakuza1-7** | ✅ 完全監視 | 全Stage適用 |
| **soukaiya** | ✅ 完全監視 | 全Stage適用 |

### 5.2 動的監視対象検出

- `yokubari.sh` のプロセス一覧から起動中のエージェントを自動検出
- tmux paneの `@agent_id` 変数を参照して監視対象を判定

---

## 6. ログ・通知

### 6.1 ログ出力先

- **粛清実行ログ**: `queue/metrics/njslyr_executions.yaml`
  - フォーマット:
    ```yaml
    executions:
      - timestamp: "2026-02-16T13:00:00"
        agent_id: "yakuza3"
        stage: "Stage 1 (スリケン)"
        result: "success"
        reason: "スリケン無応答（2分超過）"
    ```
- **標準エラー出力**: スクリプト実行ログ（`[$(date)] [njslyr] ...`形式）

### 6.2 ダークニンジャへの通知方法

#### 方式1: dashboard.md更新（推奨）

- **セクション**: `🚨ヨウタイオウ` に粛清実行履歴を追記
- **フォーマット**: `⚡ [13:00] njslyr: yakuza3 を粛清（Stage 1: スリケン） - 理由: スリケン無応答`

#### 方式2: inbox_write.sh（重要度が高い場合）

- **優先度**: P1（緊急）
- **タイプ**: `system_notice`
- **送信先**: `darkninja`

**決定**: 方式1を基本とし、Stage 3（kill+再起動）のみ方式2も併用

---

## 7. エッジケース

### 7.1 正当な長時間thinking

#### 問題

大量ファイル処理、複雑なGrep等で正当に10分以上thinkingが継続する場合、誤検知・誤粛清のリスク

#### 対策

- **タスクYAMLにフラグ追加**: `long_running: true` フィールドがあれば粛清除外
  - グレーターヤクザがタスク割り当て時に手動設定
- **paneテキスト検出**: `Reading`, `Searching`, `Processing` 等の「正当な処理中」文字列を検出した場合は除外
- **クールダウン延長**: thinking検知から15分待機（通常10分の1.5倍）

### 7.2 粛清中に新規タスク割り当て

#### 問題

Stage 2（/clear）実行中にグレーターヤクザが新規タスクを割り当てた場合、タイミング競合のリスク

#### 対策

- **ロック機構**: njslyr実行中は `queue/.njslyr.lock` ファイルを作成
  - グレーターヤクザはロックファイル存在時、タスク割り当てを30秒遅延
- **/clear後の再着手保証**: inbox_watcher.shの `enqueue_recovery_task_assigned()` が自動でtask_assignedメッセージを投入（既存機能活用）

### 7.3 inbox_watcher.shとの競合

#### 問題

inbox_watcher.shが既にPhase 3（/clear）を送信済みの場合、njslyrの重複実行で無駄なリソース消費

#### 対策

- **状態共有**: inbox_watcher.shの `LAST_CLEAR_TS` を `queue/metrics/inbox_watcher_state_{agent_id}.yaml` に書き出し
  - njslyrは粛清実行前にこのファイルを確認し、5分以内にclear実行済みなら処理スキップ
- **ログ出力**: スキップ時は `[njslyr] inbox_watcher.sh already handled {agent_id}, skipping` をログに記録

### 7.4 エージェント再起動ループ

#### 問題

Stage 3（kill+再起動）後、即座に同じ問題が再発し、無限再起動ループに陥るリスク

#### 対策

- **再起動カウンター**: `queue/metrics/njslyr_restarts_{agent_id}.yaml` に再起動回数記録
  - 30分以内に3回再起動した場合、自動粛清を停止し、ダッシュボード🚨に「エージェント異常停止」を記録
  - グレーターヤクザまたはダークニンジャの手動介入を要求

---

## 8. 演出仕様（ラオモト指定）

### 8.1 起動演出

njslyr.sh 起動時に以下を標準出力:

```
◆◆◆ Wasshoi!!!! ◆◆◆
ニンジャスレイヤーがエントリーした。

    ／￣￣￣＼
   ／ ● ● ● ＼
  ｜ ▲ ▲ ▲ ▲｜  [赤黒いニンジャ装束]
   ＼ ■ ■ ■／
    ￣￣￣￣
```

（ASCII art は暫定版。実装時にブラッシュアップ）

### 8.2 粛清演出

各Stage実行時に以下を出力:

```
[KARATE] yakuza3 に [スリケン] を投げた！
```

**断末魔 `generate_death_cry()`（実装済み）**:
- 50%確率で**辞世の句**（5-7-5俳句）または**爆発四散**を選択
- 俳句例:「散りてなお 赤き炎の ヤクザ道」「春風に コンテキスト散る 無常」等
- 爆発四散例:「アイエエエエ！ナンデ！？グワーッ！！爆発四散！！」等
- pane内にboxアート付きで全画面表示（`tmux respawn-pane` で実行）

**技名マッピング**:
- Stage 1（スリケン）: 「スリケン」（軽い警告）
- Stage 2（/clear）: 「チョップ」（セッションリセット）
- Stage 3（kill+再起動）: 「スレイ」（画面真っ赤＋プロセス殺害＋再起動）

**Stage 3演出フロー詳細**:
1. `[SLAY] ツヨイ・カラテ！` を表示
2. 対象paneの背景を真っ赤に変更: `tmux select-pane -P 'bg=red'`
3. 断末魔「サヨナラ！」「爆発四散！」
4. pane kill実行
5. 再起動
6. 背景をデフォルトに戻す: `tmux select-pane -P 'bg=default'`
7. 「復帰完了」を表示

### 8.3 完了演出

njslyr.sh のサイクル終了時に以下を出力:

```
◆粛清完了: 2体処理 / 8体健全◆
ニンジャスレイヤーは闇に消えた。
```

### 8.4 全体の雰囲気

- ニンジャスレイヤー世界観を踏襲
- コワイ！（威圧感重視）
- ASCII artは簡素に（ターミナル表示崩れ防止）

---

## 9. Phase 2実装計画（別タスク切り出し）

### 9.1 実装タスク構成

1. **subtask_261b: njslyr.sh本体実装**
   - 3段階エスカレーション実装
   - エッジケース対策実装
   - 演出仕様実装

2. **subtask_261c: 単体テスト作成**
   - `tests/test_njslyr.bats` 作成
   - モックエージェント（idle/busy/thinking）でテスト

3. **subtask_261d: 統合テスト実施**
   - yokubari.sh 起動下での実エージェント粛清テスト
   - inbox_watcher.sh との競合テスト

4. **subtask_261e: 本番投入準備**
   - yokubari.sh に njslyr.sh 起動処理追加
   - dashboard.md テンプレート更新
   - CLAUDE.md 更新（njslyr運用ルール追記）

### 9.2 Acceptance Criteria（Phase 2）

- [ ] njslyr.sh が3段階エスカレーションを正常実行
- [ ] エッジケース対策が全て実装されている
- [ ] 演出仕様が完全実装されている
- [ ] 単体テスト・統合テストが全てPASS
- [ ] 本番環境で24時間稼働し、誤粛清0件
- [ ] ラオモト承認完了

---

## 10. まとめ

本設計ドキュメントは、オヒルネエージェント粛清デーモン（njslyr）のPhase 1設計仕様を網羅した。以下の6項目＋演出仕様＋コスト最適化ロジックを詳述した:

1. ✅ 検知条件の詳細設計（3条件＋総合判断＋コスト最適化フィルター）
2. ✅ 粛清方法の詳細設計（3段階＋待機時間・リトライ）
3. ✅ 実装方式（スクリプト配置、監視方式、inbox_watcher.sh統合、バックグラウンド実行、**定期実行15分間隔**）
4. ✅ 監視対象エージェント（darkninja除外、smith制限付き、yakuza/soukaiya完全監視）
5. ✅ ログ・通知（粛清ログ、dashboard更新、inbox通知）
6. ✅ エッジケース（長時間thinking、タスク割り当て競合、inbox_watcher競合、再起動ループ）
7. ✅ 演出仕様（起動・粛清・完了演出、技名、ASCII art）
8. ✅ **コスト最適化ロジック**（inbox未読チェック、5段階検知フロー、APIトークン削減）

**追加仕様（2026-02-16 13:02 ラオモト指定）**:
- 定期実行間隔: **15分おき**（cron `*/15` または `sleep 900`）
- コスト最適化: inbox未読エージェントのみスリケン、タスクなしアイドルは放置
- 検知ロジック: (1) grep 'read: false' (2) 未読あり→Stage 1 (3) 未読なし→スキップ (4) 前回スリケン無反応→Stage 2 (5) Stage 2無反応→Stage 3

次のステップ: ソウカイヤQC（再QC） → ラオモト承認 → Phase 2実装タスク起票

---

**作成者**: クローンヤクザ5号
**作成日時**: 2026-02-16
**タスクID**: subtask_261a
**ステータス**: QC待ち
