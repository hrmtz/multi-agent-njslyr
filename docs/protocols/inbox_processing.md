# Inbox Processing Protocol

> 参照条件: inbox 処理の詳細確認が必要な時のみ。通常は CLAUDE.md の要約で足りる。

---

## 基本フロー

```
inboxN 受信 → inbox 読む → read:false をソート → P0→P3・timestamp順処理 → read:true
```

---

## 詳細手順

### Step 1: inbox ファイル読み込み

```bash
cat queue/inbox/{your_agent_id}.yaml
```

### Step 2: 未読メッセージのフィルタリング

`read: false` のメッセージのみ処理対象。

### Step 3: 優先度ソート

| 優先度 | 内容 |
|--------|------|
| P0 | BLOCKING 問題・Raomoto 指示・緊急障害 |
| P1 | QC 結果・タスク完了報告・重要決定 |
| P2 | 通常タスク割り当て・進捗報告（デフォルト） |
| P3 | 自主学習・非ブロッキング提案 |

ソートキー: `priority` (P0→P3) → `timestamp` (昇順)

### Step 4: メッセージ処理

各メッセージを処理後、**即座に** `read: true` に更新せよ。

```yaml
# 処理前
- id: msg_20260303_abc123
  read: false
  ...

# 処理後
- id: msg_20260303_abc123
  read: true
  ...
```

更新方法（Python）:
```python
import yaml

with open('queue/inbox/{agent_id}.yaml', 'r') as f:
    data = yaml.safe_load(f)

for msg in data['messages']:
    if msg['id'] == target_msg_id:
        msg['read'] = True

with open('queue/inbox/{agent_id}.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
```

---

## メッセージタイプ別処理

| type | 処理 |
|------|------|
| `task_assigned` | `task_yaml_path` のYAMLを読み作業開始 |
| `clear_command` | /clear 実行 → CLAUDE.md 手順でリカバリー |
| `report_received` | レポートYAMLをスキャン、ダッシュボード更新 |
| `system_notice` | 内容を読み適切に対応 |
| `wake_up` / `nudge` | inbox全体をチェック・未処理タスク確認 |
| `redo` | 再作業指示。内容確認し修正実行 |

---

## 重要ルール

### タスク完了後の必須確認

**タスク完了 → idle 前に必ず inbox を確認せよ。**

```bash
cat queue/inbox/{your_id}.yaml | grep -A5 "read: false"
```

未読が残っていれば処理してから idle に入ること。

### Nudge の扱い

Nudge（suriken）受信時:
1. **Step 1-3 完了前は無視**（CLAUDE.md Session Start 手順を完了させてから処理）
2. 起動中の場合: `[STARTUP IN PROGRESS - inbox nudge deferred: inboxN]` と出力

### MANDATORY: read: true 更新の徹底

処理したメッセージを `read: false` のまま放置しない。
未処理メッセージが蓄積すると、再起動時に重複実行が発生する。

---

## Inbox ファイルの場所

```
queue/inbox/{agent_id}.yaml
```

エージェント別:
- `queue/inbox/darkninja.yaml`
- `queue/inbox/gryakuza.yaml`
- `queue/inbox/soukaiya.yaml`
- `queue/inbox/yakuza1.yaml` ～ `queue/inbox/yakuza8.yaml`

---

## スクリプト: inbox_write.sh

```bash
bash scripts/inbox_write.sh <target> "<message>" <type> <from> [task_yaml_path] [priority]
```

詳細は CLAUDE.md「Mailbox System」セクション参照。
