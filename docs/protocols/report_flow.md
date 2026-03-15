# Report Flow Protocol

> 参照条件: タスク完了報告・redo・品質チェックフロー確認時のみ読め。Session Start では読まない。

---

## 概要: 完了報告フロー

```
Yakuza → (report YAML + inbox) → Soukaiya → (QC + inbox) → Team Lead → (dashboard + inbox) → Darkninja
```

---

## Yakuza 完了報告手順（全4ステップ）

### Step 1: Report YAML 作成

```bash
# ファイル命名: queue/reports/yakuza{N}_report_{task_id}.yaml
# 例: queue/reports/yakuza1_report_subtask_360a.yaml
```

```yaml
worker_id: yakuza1
task_id: subtask_360a
parent_cmd: cmd_360
timestamp: "2026-03-03T18:45:00"  # date "+%Y-%m-%dT%H:%M:%S" で取得
status: done  # done | failed | blocked
result:
  summary: "完了内容の要約"
  files_modified:
    - "path/to/file1"
    - "path/to/file2"
  notes: "補足事項"
skill_candidate:
  found: false  # MANDATORY
```

**Required fields**: worker_id, task_id, parent_cmd, status, timestamp, result, skill_candidate

### Step 2: cmd YAML の status 更新

```bash
# 対象: queue/tasks/cmd_{N}.yaml (parent_cmd が指すファイル)
# status: pending → completed に変更
```

### Step 3: git commit（対象プロジェクトで）

```bash
cd /path/to/project
git add <対象ファイル>
git commit -m "feat: <変更内容の要約> (cmd_{N})"
```

- コミットが不要な場合（設定ファイルのみ変更など）はスキップ可
- プロジェクトに git リポジトリがない場合はスキップ

### Step 4: Soukaiya に inbox_write

```bash
bash scripts/inbox_write.sh soukaiya \
  "クローンヤクザ{N}号、ニンム・コンプリート。品質チェックを仰ぐ。ドーモ。" \
  report_received yakuza{N} \
  "queue/reports/yakuza{N}_report_{task_id}.yaml"
```

**⚠️ 重要**: `report_received` タイプで task_yaml_path に report YAML のパスを渡すこと。

---

## 自動化: task_complete.sh

4ステップを1コマンドで実行：

```bash
bash scripts/task_complete.sh <task_id> <yakuza_number> <project_path>
# 例:
bash scripts/task_complete.sh subtask_360a 1 /home/hrmtz/project/multi-agent-njslyr
```

スクリプトが行うこと:
1. Report YAML 生成（status, files_modified, timestamp 自動付与）
2. cmd YAML status → completed 更新
3. git add + commit（project_path 内の変更）
4. inbox_write to soukaiya

---

## Soukaiya 品質チェック手順

1. Report YAML 受信（task_yaml_path フィールドで場所特定）
2. 成果物確認（files_modified を Read で確認）
3. QC 結果を Team Lead に inbox_write
   - Pass: `report_received` type
   - Fail/Redo: `redo` type、内容に問題点を明記

---

## Team Lead 受信後手順

1. `scan_all_reports`: `queue/reports/yakuza*_report*.yaml` を全スキャン
2. dashboard.md 更新（センカセクション）
3. ブロック解除確認: `blocked_by` に完了 task_id を持つタスクを探し、解除
4. Darkninja に cmd 完了を inbox_write（**全 cmd 共通・省略禁止**）

---

## Redo（再作業）フロー

```
Soukaiya/Team Lead → (redo指示) → Yakuza inbox
```

Redo 指示受信時:
1. Report YAML を確認して問題点把握
2. 修正作業実行
3. 完了後、再度 4ステップを実行（report YAML は新規ファイル名で作成）

詳細: `docs/smith_redo.md`

---

## エラー時の報告

| 状況 | status フィールド | 追記事項 |
|------|-------------------|---------|
| 正常完了 | `done` | - |
| 失敗（修正不可） | `failed` | `result.notes` に原因 |
| ブロック中 | `blocked` | `result.notes` に依存関係 |

失敗・ブロック時も Soukaiya への inbox_write は必須。
