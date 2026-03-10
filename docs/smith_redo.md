# Gryakuza Redo & /clear Protocol

読む条件: redo指示発生時・yakuzaにタスク切り替えを行う時のみ。
通常の Session Start では読まない。

---

## /clear Protocol (Yakuza Task Switching)

Purge previous task context for clean start. For rate limit relief and context pollution prevention.

### When to Send /clear

After task completion report received, before next task assignment.

### Procedure (6 Steps)

```
STEP 1: Confirm report + update dashboard

STEP 2: Write next task YAML first (YAML-first principle)
  → queue/tasks/yakuza{N}.yaml — ready for yakuza to read after /clear

STEP 3: Reset pane title (after yakuza is idle — ❯ visible)
  tmux select-pane -t multiagent:0.{N} -T "Sonnet"   # yakuza 1-4
  tmux select-pane -t multiagent:0.{N} -T "Opus"     # yakuza 5-8
  Title = MODEL NAME ONLY. No agent name, no task description.
  If model_override active → use that model name

STEP 4: Send /clear via inbox
  bash scripts/inbox_write.sh yakuza{N} "タスクYAMLを読んで作業開始せよ。" clear_command smith
  # inbox_watcher が type=clear_command を検知し、/clear送信 → 待機 → 指示送信 を自動実行

STEP 5以降は不要（watcherが一括処理）
```

### Skip /clear When

| Condition | Reason |
|-----------|--------|
| Short consecutive tasks (< 5 min each) | Reset cost > benefit |
| Same project/files as previous task | Previous context is useful |
| Light context (est. < 30K tokens) | /clear effect minimal |

### Darkninja Never /clear

Darkninja needs conversation history with the lord.

### Gryakuza Self-/clear (Context Relief)

Gryakuza MAY self-/clear when ALL of the following conditions are met:

1. **No unread inbox**: `queue/inbox/smith.yaml` has zero `read: false` entries
2. **No active tasks**: No `queue/tasks/yakuza*.yaml` or `queue/tasks/soukaiya.yaml` with `status: assigned` or `status: in_progress`
3. **No pending reports**: All reports in `queue/reports/` have been processed

When conditions met → execute self-/clear:
```bash
# Gryakuza sends /clear to itself (NOT via inbox_write — direct)
# After /clear, Session Start procedure auto-recovers from YAML
```

**When to check**: After completing all report processing and going idle (step 12).

**Why this is safe**: All state lives in YAML (ground truth). /clear only wipes conversational context, which is reconstructible from YAML scan.

**Why this helps**: Prevents the 4% context exhaustion that halted smith during cmd_166 (2,754 article production).

## Redo Protocol

When a yakuza's output is unsatisfactory and needs to be redone.

### When to Redo

| Condition | Action |
|-----------|--------|
| Output wrong format/content | Redo with corrected description |
| Partial completion | Redo with specific remaining items |
| Output acceptable but imperfect | Do NOT redo — note in dashboard, move on |

### Procedure (3 Steps)

```
STEP 1: Write new task YAML
  - New task_id with version suffix (e.g., subtask_097d → subtask_097d2)
  - Add `redo_of: <original_task_id>` field
  - Updated description with SPECIFIC correction instructions
  - Do NOT just say "やり直し" — explain WHAT was wrong and HOW to fix it
  - status: assigned

STEP 2: Send /clear via inbox (NOT task_assigned)
  bash scripts/inbox_write.sh yakuza{N} "タスクYAMLを読んで作業開始せよ。" clear_command smith
  # /clear wipes previous context → agent re-reads YAML → sees new task

STEP 3: If still unsatisfactory after 2 redos → escalate to dashboard 🚨
```

### Why /clear for Redo

Previous context may contain the wrong approach. `/clear` forces YAML re-read.
Do NOT use `type: task_assigned` for redo — agent may not re-read the YAML if it thinks the task is already done.

### Race Condition Prevention

Using `/clear` eliminates the race:
- Old task status (done/assigned) is irrelevant — session is wiped
- Agent recovers from YAML, sees new task_id with `status: assigned`
- No conflict with previous attempt's state

### Redo Task YAML Example

```yaml
task:
  task_id: subtask_097d2
  parent_cmd: cmd_097
  redo_of: subtask_097d
  bloom_level: L1
  description: |
    【やり直し】前回の問題: echoが緑色太字でなかった。
    修正: echo -e "\033[1;32m..." で緑色太字出力。echoを最終tool callに。
  status: assigned
  timestamp: "2026-02-09T07:46:00"
```
