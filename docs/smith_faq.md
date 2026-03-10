# Gryakuza FAQ & Troubleshooting

このファイルには、トラブル発生時に参照する手順・リカバリ方法を記載。

## Agent Self-Watch Phase Rules (cmd_107)

- Phase 1: watcherは `process_unread_once` / inotify + timeout fallback を前提に運用する。
- Phase 2: 通常nudge停止（`disable_normal_nudge`）を前提に、割当後の配信確認をnudge依存で設計しない。
- Phase 3: `FINAL_ESCALATION_ONLY` で send-keys が最終復旧限定になるため、通常配信は inbox YAML を正本として扱う。
- 監視品質は `unread_latency_sec` / `read_count` / `estimated_tokens` を参照して判断する。

Normally pane# = yakuza#. But long-running sessions may cause drift.

```bash
# Confirm your own ID
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'

# Reverse lookup: find yakuza3's actual pane
# Window name: kyoto→multiagent:kyoto, neosaitama→multiagent:neosaitama
tmux list-panes -a -F '#{pane_index} #{@agent_id}' | awk '$2=="yakuza3"{print $1}'
```

**When to use**: After 2 consecutive delivery failures. Normally use `multiagent:0.{N}`.

## Session Recovery / Context Reading

> See **CLAUDE.md** for base recovery procedure and **docs/smith_advanced.md § Compaction Recovery** for detailed steps.

Basic recovery workflow:
1. Read CLAUDE.md (auto-loaded) + Memory MCP
2. Check `queue/inbox/smith.yaml` for unread messages
3. Scan `queue/tasks/yakuza*.yaml` and `queue/reports/` for state
4. Reconcile dashboard.md with YAML ground truth
5. Resume work

## バリキドリンク投与・解除手順 (cmd_276)

バリキドリンクとは、クローンヤクザにOpusモデルを一時的に投与する機能。高難度タスク（設計ドキュメント作成、複雑な実装等）で使用する。

### ヘルパー関数

`yokubari.sh` と `njslyr.sh` の両方に実装済み。

```bash
# Opus投与（バリキドリンク投与）
inject_barikidorink "multiagent:0.1"   # yakuza1にOpus投与

# Sonnet復帰（バリキドリンク解除）
detox_barikidorink "multiagent:0.1"    # yakuza1をSonnetに復帰
```

### 内部フロー

**inject_barikidorink(pane)**:
1. `/model opus` 送信 → 0.5s待機
2. `@model_name` を "Opus" に設定
3. pane背景色を紫系 (`bg=#1a002e`) に変更
4. 0.3s待機 → `/clear` 送信（新モデルでセッション開始）

**detox_barikidorink(pane)**:
1. `/model sonnet` 送信 → 0.5s待機
2. `@model_name` を "Sonnet" に設定
3. pane背景色をデフォルトに復帰

### 注意事項
- pane引数は tmux ペインターゲット形式（例: `multiagent:0.1`）
- inject時に `/clear` が走るため、進行中タスクがある場合はタスクYAMLに進捗を保存してから投与すること
- Opus投与中はAPI消費が増大する。タスク完了後は必ず `detox_barikidorink` で復帰すること

## pane消失防止 (2026-02-18 ケジメ案件)

### 問題

`tmux respawn-pane -k` でプロセスを再起動する際、`remain-on-exit` が未設定だとプロセス起動失敗時にpaneが消滅する。消滅したpaneは復元不能で、tmuxグリッド全体が崩壊する。

### 事例

2026-02-18: yakuza5/6/7の3paneが消失。ネット復旧後の手動respawnで `remain-on-exit` 未設定が原因。

### 正しい手順

`njslyr.sh` の `stage3_slay()` には既に実装済み（L530）:

```bash
# Step 0: 必ずrespawn前にremain-on-exitを設定
tmux set-option -p -t "$pane_target" remain-on-exit on

# その後にrespawn
tmux respawn-pane -k -t "$pane_target" "claude --model ${model} --dangerously-skip-permissions"

# 再起動後もremain-on-exitはONのまま維持（Step 6）
# paneが再びクラッシュしても消えない
```

### 手動操作時のルール（恒久）

手動で `respawn-pane` を実行する場合も、**必ず事前に `remain-on-exit on` を設定すること**。省略厳禁。

```bash
# 手動respawnの正しい手順
tmux set-option -p -t multiagent:0.5 remain-on-exit on
tmux respawn-pane -k -t multiagent:0.5 "claude --model sonnet --dangerously-skip-permissions"
```

### pane再作成（消滅してしまった場合）

```bash
tmux split-pane -t $target -v "claude --model sonnet --dangerously-skip-permissions"
tmux set-option -p @agent_id yakuzaN
# select-layout tiled は禁止（175x49で10pane以上は不可能、tiledがpaneを潰す）
```

### 安全上限

175x49のウィンドウでは最大9ペインが安全上限。10ペイン目を作ると `select-layout tiled` が1つ潰す。

## inbox_watcher grep誤検知修正 (subtask_261c)

### 問題

`grep 'read: false'` でinbox未読数を判定する際、メッセージ本文中に `read: false` という文字列が含まれていると誤検知する。

例: タスクYAMLの説明文に `read: false` が含まれる場合、実際には既読済みなのに未読としてカウントされる。

### 修正内容

grepパターンをYAMLフィールドのみにマッチするよう限定:

```bash
# 修正前（誤検知する）
grep -c 'read: false' "$INBOX"

# 修正後（YAMLフィールドのみ判定）
grep -c '^ *read: false$' "$INBOX"
```

`^ *read: false$` は行頭からスペースのみで始まり `read: false` で終わる行のみにマッチ。メッセージ本文中の文字列にはマッチしない。

### 修正済みファイル

- `scripts/stop_hook_inbox.sh` (L61)
- `scripts/njslyr.sh` (L261)

## cmd_275 サムネイル生成フロー（3レイヤー独立構造）

### 概要

従来の1枚サムネイルから、3レイヤー独立構造に根本改善。各レイヤーを個別にキャプチャし、Python側で合成＋アニメーション付与する。

### 3レイヤー構成

| レイヤー | ファイル | 内容 | 透過 |
|---------|---------|------|------|
| bg | `thumbnail_v{N}_{theme}_bg.png` | 不透明背景 | なし |
| title | `thumbnail_v{N}_{theme}_title.png` | タイトルテキスト | アルファ付きPNG |
| fg | `thumbnail_v{N}_{theme}_fg.png` | ずんだもん等前景要素 | アルファ付きPNG |

### ツールチェーン

1. **capture_layers_batch.js**: Puppeteerでレイヤー別にスクリーンショット取得
   - bg: 通常キャプチャ（不透明背景付き）
   - title/fg: `omitBackground: true`（アルファ付きPNG）
   - レイヤー間で `page.reload()` を実施（CSS状態リセット）
   - `deviceScaleFactor: 2` で2倍解像度キャプチャ

2. **generate_thumbnail_batch.py**: 3レイヤーを合成し、アニメーション動画を生成
   - bg → title（パルスアニメ）→ fg（ジッターアニメ）の順で合成
   - titleパルス: `TEXT_PULSE_AMPLITUDE=0.03`（scale 1.0 ↔ 1.03）
   - ずんだもんジッター: 微小な位置振動
   - 出力: `thumbnail_wiggle_v{N}_{theme}.mp4`（1080x1920, 30fps, H.264+AAC）

### ファイル配置

- 中間ファイル: `reel/thumbnail_work/` 配下
- 最終成果物: `reel/` 直下（`thumbnail.png`, `thumbnail_wiggle_*.mp4`）

### 仕様ドキュメント

- 設計書: `DESIGN_3LAYER_THUMBNAIL.md`
- 運用手順: `reel/CLAUDE_THUMBNAIL.md`（リポジトリルート `social-content/reel/` 配下）

### 注意事項
- 中間PNG（title/fg）は各8MB程度と大きい（2倍解像度キャプチャのため）。Python側で1080x1920にリサイズするため機能上問題なし
- 動画目視QCはソウカイヤの技術限界あり。ラオモト直接確認が確実（QCルール準拠）
