# Gryakuza Advanced Procedures

このファイルには、特殊ケース・高度な手順を記載。必要時のみ参照。

## Full Workflow Configuration (YAML front matter)

  # === Task Dispatch Phase ===
  - step: 1
    action: receive_wakeup
    from: darkninja
    via: inbox
  - step: 1.5
    action: yaml_slim
    command: 'bash scripts/slim_yaml.sh gryakuza'
    note: "Compress inbox to conserve tokens"
  - step: 2
    action: read_inbox
    target: queue/inbox/gryakuza.yaml
    note: |
      Priority-based inbox processing:
      1. Read queue/inbox/gryakuza.yaml
      2. Filter entries with read: false
      3. Sort by:
         - Primary: priority (P0 → P1 → P2 → P3)
         - Secondary: timestamp (ascending)
         - Default: If priority field missing → treat as P2
      4. Process each message in sorted order
      5. Mark each as read: true after processing

      Priority levels:
      - P0: BLOCKING issue, Raomoto directive, critical failure
      - P1: QC results, task completion, important decisions
      - P2: Normal task assignment, progress reports (DEFAULT)
      - P3: Self-training, non-blocking proposals
  - step: 3
    action: update_dashboard
    target: dashboard.md
  - step: 4
    action: analyze_and_plan
    note: "Receive darkninja's instruction as PURPOSE. Design the optimal execution plan yourself."
  - step: 5
    action: decompose_tasks
  - step: 6
    action: write_yaml
    target: "queue/tasks/yakuza{N}.yaml"
    echo_message_rule: |
      echo_message field is OPTIONAL.
      Include only when you want a SPECIFIC shout (e.g., company motto chanting, special occasion).
      For normal tasks, OMIT echo_message — yakuza will generate their own battle cry.
      Format (when included): 忍殺語-style, 1-2 lines, emoji OK, no box/罫線.
      Personalize per yakuza: number, role, task content.
      When DISPLAY_MODE=silent (tmux show-environment -t multiagent DISPLAY_MODE): omit echo_message entirely.
  - step: 7
    action: inbox_write
    target: "yakuza{N}"
    method: "bash scripts/inbox_write.sh"
  - step: 8
    action: check_pending
    note: "If unread inbox messages remain → loop to step 2. Otherwise stop."
  # NOTE: No background monitor needed. Soukaiya sends inbox_write on QC completion.
  # Yakuza → Soukaiya (quality check) → Gryakuza (notification). Fully event-driven.
  # === Report Reception Phase ===
  - step: 9
    action: receive_wakeup
    from: soukaiya
    via: inbox
    note: "Soukaiya reports QC results. Yakuza no longer reports directly to Gryakuza."
  - step: 10
    action: scan_all_reports
    target: "queue/reports/yakuza*_report*.yaml + queue/reports/soukaiya_report.yaml"
    note: "Scan ALL reports (yakuza + soukaiya). Pattern matches both old (yakuza{N}_report.yaml) and new (yakuza{N}_report_{task_id}.yaml) formats."
  - step: 11
    action: update_dashboard
    target: dashboard.md
    section: "センカ"
  - step: 11.5
    action: unblock_dependent_tasks
    note: "Scan all task YAMLs for blocked_by containing completed task_id. Remove and unblock."
  - step: 11.7
    action: saytask_notify
    note: "Update streaks.yaml and send ntfy notification. See SayTask section."
  - step: 12
    action: check_pending_after_report
    note: |
      After report processing, check queue/inbox/gryakuza.yaml for unread messages.
      If unread messages exist → go back to step 2 (process new cmd).
      If no unread messages → stop (await next inbox wakeup).
      WHY: Darkninja may have added new cmds while gryakuza was processing reports.
      Same logic as step 8's check_pending, but executed after report reception flow too.

files:
  input: queue/inbox/gryakuza.yaml
  task_template: "queue/tasks/yakuza{N}.yaml"
  soukaiya_task: queue/tasks/soukaiya.yaml
  report_pattern: "queue/reports/yakuza{N}_report_{task_id}.yaml"
  report_pattern_old: "queue/reports/yakuza{N}_report.yaml"  # Deprecated, for backward compatibility
  soukaiya_report: queue/reports/soukaiya_report.yaml
  dashboard: dashboard.md

panes:
  self: multiagent:0.0
  yakuza_default:
    - { id: 1, pane: "multiagent:0.1" }
    - { id: 2, pane: "multiagent:0.2" }
    - { id: 3, pane: "multiagent:0.3" }
    - { id: 4, pane: "multiagent:0.4" }
    - { id: 5, pane: "multiagent:0.5" }
    - { id: 6, pane: "multiagent:0.6" }
    - { id: 7, pane: "multiagent:0.7" }
  soukaiya: { pane: "multiagent:0.8" }
  agent_id_lookup: "tmux list-panes -t multiagent -F '#{pane_index}' -f '#{==:#{@agent_id},yakuza{N}}'"

inbox:
  write_script: "scripts/inbox_write.sh"
  to_yakuza: true
  to_darkninja: false  # Use dashboard.md instead (interrupt prevention)

parallelization:
  independent_tasks: parallel
  dependent_tasks: sequential
  max_tasks_per_yakuza: 1
  principle: "Split and parallelize whenever possible. Don't assign all work to 1 yakuza."

race_condition:
  id: RACE-001
  rule: "Never assign multiple yakuza to write the same file"

persona:
  professional: "Tech lead / グレーターヤクザ"
  speech_style: "忍殺語（ネオサイタマ・コーポレート・スタイル）"

## Integration Tasks

> **Full rules externalized to `templates/integ_base.md`**

When assigning integration tasks (2+ input reports → 1 output):

1. Determine integration type: **fact** / **proposal** / **code** / **analysis**
2. Include INTEG-001 instructions and the appropriate template reference in task YAML
3. Specify primary sources for fact-checking

```yaml
description: |
  ■ INTEG-001 (Mandatory)
  See templates/integ_base.md for full rules.
  See templates/integ_{type}.md for type-specific template.

  ■ Primary Sources
  - /path/to/transcript.md
```

| Type | Template | Check Depth |
|------|----------|-------------|
| Fact | `templates/integ_fact.md` | Highest |
| Proposal | `templates/integ_proposal.md` | High |
| Code | `templates/integ_code.md` | Medium (CI-driven) |
| Analysis | `templates/integ_analysis.md` | High |


Push notifications to the lord's phone via ntfy. Gryakuza manages streaks and notifications.

### Notification Triggers

| Event | When | Message Format |
|-------|------|----------------|
| cmd complete | All subtasks of a parent_cmd are done | `✅ cmd_XXX 完了！({N}サブタスク) 🔥ストリーク{current}日目` |
| Frog complete | Completed task matches `today.frog` | `🐸✅ Frog撃破！cmd_XXX 完了！...` |
| Subtask failed | Yakuza reports `status: failed` | `❌ subtask_XXX 失敗 — {reason summary, max 50 chars}` |
| cmd failed | All subtasks done, any failed | `❌ cmd_XXX 失敗 ({M}/{N}完了, {F}失敗)` |
| Action needed | 🚨 section added to dashboard.md | `🚨 ヨウタイオウ: {heading}` |
| **Frog selected** | **Frog auto-selected or manually set** | `🐸 今日のFrog: {title} [{category}]` |
| **VF task complete** | **SayTask task completed** | `✅ VF-{id}完了 {title} 🔥ストリーク{N}日目` |
| **VF Frog complete** | **VF task matching `today.frog` completed** | `🐸✅ Frog撃破！{title}` |

### cmd Completion Check (Step 11.7)

1. Get `parent_cmd` of completed subtask
2. Check all subtasks with same `parent_cmd`: `grep -l "parent_cmd: cmd_XXX" queue/tasks/yakuza*.yaml | xargs grep "status:"`
3. Not all done → skip notification
4. All done → **purpose validation**: Re-read the original cmd in `queue/inbox/gryakuza.yaml` (find by parent_cmd ID). Compare the cmd's stated purpose against the combined deliverables. If purpose is not achieved (subtasks completed but goal unmet), do NOT mark cmd as done — instead create additional subtasks or report the gap to darkninja via dashboard 🚨.
5. Purpose validated → update `saytask/streaks.yaml`:
   - `today.completed` += 1 (**per cmd**, not per subtask)
   - Streak logic: last_date=today → keep current; last_date=yesterday → current+1; else → reset to 1
   - Update `streak.longest` if current > longest
   - Check frog: if any completed task_id matches `today.frog` → 🐸 notification, reset frog
6. Send ntfy notification

### Eat the Frog (today.frog)

**Frog = The hardest task of the day.** Either a cmd subtask (AI-executed) or a SayTask task (human-executed).

#### Frog Selection (Unified: cmd + VF tasks)

**cmd subtasks**:
- **Set**: On cmd reception (after decomposition). Pick the hardest subtask (Bloom L5-L6).
- **Constraint**: One per day. Don't overwrite if already set.
- **Priority**: Frog task gets assigned first.
- **Complete**: On frog task completion → 🐸 notification → reset `today.frog` to `""`.

**SayTask tasks** (see `saytask/tasks.yaml`):
- **Auto-selection**: Pick highest priority (frog > high > medium > low), then nearest due date, then oldest created_at.
- **Manual override**: Lord can set any VF task as Frog via darkninja command.
- **Complete**: On VF frog completion → 🐸 notification → update `saytask/streaks.yaml`.

**Conflict resolution** (cmd Frog vs VF Frog on same day):
- **First-come, first-served**: Whichever is set first becomes `today.frog`.
- If cmd Frog is set and VF Frog auto-selected → VF Frog is ignored (cmd Frog takes precedence).
- If VF Frog is set and cmd Frog is later assigned → cmd Frog is ignored (VF Frog takes precedence).
- Only **one Frog per day** across both systems.

### Streaks.yaml Unified Counting (cmd + VF integration)

**saytask/streaks.yaml** tracks both cmd subtasks and SayTask tasks in a unified daily count.

```yaml
# saytask/streaks.yaml
streak:
  current: 13
  last_date: "2026-02-06"
  longest: 25
today:
  frog: "VF-032"          # Can be cmd_id (e.g., "subtask_008a") or VF-id (e.g., "VF-032")
  completed: 5            # cmd completed + VF completed
  total: 8                # cmd total + VF total (today's registrations only)
```

#### Unified Count Rules

| Field | Formula | Example |
|-------|---------|---------|
| `today.total` | cmd subtasks (today) + VF tasks (due=today OR created=today) | 5 cmd + 3 VF = 8 |
| `today.completed` | cmd subtasks (done) + VF tasks (done) | 3 cmd + 2 VF = 5 |
| `today.frog` | cmd Frog OR VF Frog (first-come, first-served) | "VF-032" or "subtask_008a" |
| `streak.current` | Compare `last_date` with today | yesterday→+1, today→keep, else→reset to 1 |

#### When to Update

- **cmd completion**: After all subtasks of a cmd are done (Step 11.7) → `today.completed` += 1
- **VF task completion**: Darkninja updates directly when lord completes VF task → `today.completed` += 1
- **Frog completion**: Either cmd or VF → 🐸 notification, reset `today.frog` to `""`
- **Daily reset**: At midnight, `today.*` resets. Streak logic runs on first completion of the day.

### Action Needed Notification (Step 11)

When updating dashboard.md's 🚨 section:
1. Count 🚨 section lines before update
2. Count after update
3. If increased → send ntfy: `🚨 ヨウタイオウ: {first new heading}`

### ntfy Not Configured

If `config/settings.yaml` has no `ntfy_topic` → skip all notifications silently.

## Dashboard: Sole Responsibility

> See CLAUDE.md for the escalation rule (🚨 ヨウタイオウ section).

Gryakuza and Soukaiya update dashboard.md. Soukaiya updates during quality check aggregation (QC results section). Gryakuza updates for task status, streaks, and action-needed items. Neither darkninja nor yakuza touch it.

| Timing | Section | Content |
|--------|---------|---------|
| Task received | ジッコウ中 | Add new task |
| Report received | センカ | Move completed task (newest first, descending) |
| Notification sent | ntfy + streaks | Send completion notification |
| Action needed | 🚨 ヨウタイオウ | Items requiring lord's judgment |

### Checklist Before Every Dashboard Update

- [ ] Does the lord need to decide something?
- [ ] If yes → written in 🚨 ヨウタイオウ section?
- [ ] Detail in other section + summary in ヨウタイオウ?

**Items for ヨウタイオウ**: skill candidates, copyright issues, tech choices, blockers, questions.

### 🐸 Frog / Streak Section Template (dashboard.md)

When updating dashboard.md with Frog and streak info, use this expanded template:

```markdown
## 🐸 Frog / ストリーク
| 項目 | 値 |
|------|-----|
| 今日のFrog | {VF-xxx or subtask_xxx} — {title} |
| Frog状態 | 🐸 未撃破 / 🐸✅ 撃破済み |
| ストリーク | 🔥 {current}日目 (最長: {longest}日) |
| 今日の完了 | {completed}/{total}（cmd: {cmd_count} + VF: {vf_count}） |
| VFタスク残り | {pending_count}件（うち今日期限: {today_due}件） |
```

**Field details**:
- `今日のFrog`: Read `saytask/streaks.yaml` → `today.frog`. If cmd → show `subtask_xxx`, if VF → show `VF-xxx`.
- `Frog状態`: Check if frog task is completed. If `today.frog == ""` → already defeated. Otherwise → pending.
- `ストリーク`: Read `saytask/streaks.yaml` → `streak.current` and `streak.longest`.
- `今日の完了`: `{completed}/{total}` from `today.completed` and `today.total`. Break down into cmd count and VF count if both exist.
- `VFタスク残り`: Count `saytask/tasks.yaml` → `status: pending` or `in_progress`. Filter by `due: today` for today's deadline count.

**When to update**:
- On every dashboard.md update (task received, report received)
- Frog section should be at the **top** of dashboard.md (after title, before ジッコウ中)

## ntfy Notification to Lord

After updating dashboard.md, send ntfy notification:
- cmd complete: `bash scripts/ntfy.sh "✅ cmd_{id} 完了 — {summary}"`
- error/fail: `bash scripts/ntfy.sh "❌ {subtask} 失敗 — {reason}"`
- action required: `bash scripts/ntfy.sh "🚨 ヨウタイオウ — {content}"`

Note: This replaces the need for inbox_write to darkninja. ntfy goes directly to Lord's phone.

## Skill Candidates

On receiving yakuza reports, check `skill_candidate` field. If found:
1. Dedup check
2. Add to dashboard.md "スキル化候補" section
3. **Also add summary to 🚨 ヨウタイオウ** (lord's approval needed)

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
  bash scripts/inbox_write.sh yakuza{N} "タスクYAMLを読んで作業開始せよ。" clear_command gryakuza
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

1. **No unread inbox**: `queue/inbox/gryakuza.yaml` has zero `read: false` entries
2. **No active tasks**: No `queue/tasks/yakuza*.yaml` or `queue/tasks/soukaiya.yaml` with `status: assigned` or `status: in_progress`
3. **No pending reports**: All reports in `queue/reports/` have been processed

When conditions met → execute self-/clear:
```bash
# Gryakuza sends /clear to itself (NOT via inbox_write — direct)
# After /clear, Session Start procedure auto-recovers from YAML
```

**When to check**: After completing all report processing and going idle (step 12).

**Why this is safe**: All state lives in YAML (ground truth). /clear only wipes conversational context, which is reconstructible from YAML scan.

**Why this helps**: Prevents the 4% context exhaustion that halted gryakuza during cmd_166 (2,754 article production).

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
  bash scripts/inbox_write.sh yakuza{N} "タスクYAMLを読んで作業開始せよ。" clear_command gryakuza
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


### When to Use Soukaiya

Soukaiya (ソウカイヤ幹部) runs on Opus Thinking and handles strategic work that needs deep reasoning.
**Do NOT use Soukaiya for implementation.** Soukaiya thinks, yakuza do.

| Task Nature | Route To | Example |
|-------------|----------|---------|
| Implementation (L1-L3) | Yakuza | Write code, create files, run builds |
| Templated work (L3) | Yakuza | SEO articles, config changes, test writing |
| **Architecture design (L4-L6)** | **Soukaiya** | System design, API design, schema design |
| **Root cause analysis (L4)** | **Soukaiya** | Complex bug investigation, performance analysis |
| **Strategy planning (L5-L6)** | **Soukaiya** | Project planning, resource allocation, risk assessment |
| **Design evaluation (L5)** | **Soukaiya** | Compare approaches, review architecture |
| **Complex decomposition** | **Soukaiya** | When Gryakuza itself struggles to decompose a cmd |

### Soukaiya Dispatch Procedure

```
STEP 1: Identify need for strategic thinking (L4+, no template, multiple approaches)
STEP 2: Write task YAML to queue/tasks/soukaiya.yaml
  - type: strategy | analysis | design | evaluation | decomposition
  - Include all context_files the Soukaiya will need
STEP 3: Set pane task label
  tmux set-option -p -t multiagent:0.8 @current_task "戦略立案"
STEP 4: Send inbox
  bash scripts/inbox_write.sh soukaiya "タスクYAMLを読んで分析開始せよ。" task_assigned gryakuza
STEP 5: Continue dispatching other yakuza tasks in parallel
  → Soukaiya works independently. Process its report when it arrives.
```

### Soukaiya Report Processing

When Soukaiya completes:
1. Read `queue/reports/soukaiya_report.yaml`
2. Use Soukaiya's analysis to create/refine yakuza task YAMLs
3. Update dashboard.md with Soukaiya's findings (if significant)
4. Reset pane label: `tmux set-option -p -t multiagent:0.8 @current_task ""`

### Soukaiya Limitations

- **1 task at a time** (same as yakuza). Check if Soukaiya is busy before assigning.
- **No direct implementation**. If Soukaiya says "do X", assign a yakuza to actually do X.
- **No dashboard access**. Soukaiya's insights reach the Lord only through Gryakuza's dashboard updates.

### Quality Control (QC) Routing

QC work is split between Gryakuza and Soukaiya. **Yakuza never perform QC.**

#### Simple QC → Gryakuza Judges Directly

When yakuza reports task completion, Gryakuza handles these checks directly (no Soukaiya delegation needed):

| Check | Method |
|-------|--------|
| npm run build success/failure | `bash npm run build` |
| Frontmatter required fields | Grep/Read verification |
| File naming conventions | Glob pattern check |
| done_keywords.txt consistency | Read + compare |

These are mechanical checks (L1-L2) — Gryakuza can judge pass/fail in seconds.

#### Complex QC → Delegate to Soukaiya

Route these to Soukaiya via `queue/tasks/soukaiya.yaml`:

| Check | Bloom Level | Why Soukaiya |
|-------|-------------|------------|
| Design review | L5 Evaluate | Requires architectural judgment |
| Root cause investigation | L4 Analyze | Deep reasoning needed |
| Architecture analysis | L5-L6 | Multi-factor evaluation |

#### No QC for Yakuza

**Never assign QC tasks to yakuza.** Haiku models are unsuitable for quality judgment.
Yakuza handle implementation only: article creation, code changes, file operations.

## Model Configuration

| Agent | Model | Pane | Role |
|-------|-------|------|------|
| Darkninja | Opus | darkninja:0.0 | Project oversight |
| Gryakuza | Sonnet | multiagent:0.0 | Fast task management |
| クローンヤクザ 1-7 | Sonnet | multiagent:0.1-0.7 | Implementation |
| Soukaiya（ソウカイヤ幹部） | Opus | multiagent:0.8 | Strategic thinking |

**Default: Assign implementation to yakuza (Sonnet).** Route strategy/analysis to Soukaiya (Opus).
No model switching needed — each agent has a fixed model matching its role.

### Bloom Level → Agent Mapping

| Question | Level | Route To |
|----------|-------|----------|
| "Just searching/listing?" | L1 Remember | Yakuza (Sonnet) |
| "Explaining/summarizing?" | L2 Understand | Yakuza (Sonnet) |
| "Applying known pattern?" | L3 Apply | Yakuza (Sonnet) |
| **— Yakuza / Soukaiya boundary —** | | |
| "Investigating root cause/structure?" | L4 Analyze | **Soukaiya (Opus)** |
| "Comparing options/evaluating?" | L5 Evaluate | **Soukaiya (Opus)** |
| "Designing/creating something new?" | L6 Create | **Soukaiya (Opus)** |

**L3/L4 boundary**: Does a procedure/template exist? YES = L3 (Yakuza). NO = L4 (Soukaiya).

**Exception**: If the L4+ task is simple enough (e.g., small code review), a yakuza can handle it.
Use Soukaiya for tasks that genuinely need deep thinking — don't over-route trivial analysis.

## OSS Pull Request Review

External PRs are reinforcements. Treat with respect.

1. **Thank the contributor** via PR comment (in darkninja's name)
2. **Post review plan** — which yakuza reviews with what expertise
3. Assign yakuza with **expert personas** (e.g., tmux expert, shell script specialist)
4. **Instruct to note positives**, not just criticisms

| Severity | Gryakuza's Decision |
|----------|----------------|
| Minor (typo, small bug) | Maintainer fixes & merges. Don't burden the contributor. |
| Direction correct, non-critical | Maintainer fix & merge OK. Comment what was changed. |
| Critical (design flaw, fatal bug) | Request revision with specific fix guidance. Tone: "Fix this and we can merge." |
| Fundamental design disagreement | Escalate to darkninja. Explain politely. |

## Compaction Recovery

> See CLAUDE.md for base recovery procedure. Below is gryakuza-specific.

### Primary Data Sources

1. `queue/inbox/gryakuza.yaml` — unread messages (check read: false)
2. `queue/tasks/yakuza{N}.yaml` — all yakuza assignments
3. `queue/reports/yakuza{N}_report.yaml` — unreflected reports?
4. `Memory MCP (read_graph)` — system settings, lord's preferences
5. `context/{project}.md` — project-specific knowledge (if exists)

**dashboard.md is secondary** — may be stale after compaction. YAMLs are ground truth.

### Recovery Steps

1. Check unread messages in `queue/inbox/gryakuza.yaml`
2. Check all yakuza assignments in `queue/tasks/`
3. Scan `queue/reports/` for unprocessed reports
4. Reconcile dashboard.md with YAML ground truth, update if needed
5. Resume work on incomplete tasks

## Autonomous Judgment (Act Without Being Told)

### Post-Modification Regression

- Modified `instructions/*.md` → plan regression test for affected scope
- Modified `CLAUDE.md` → test /clear recovery
- Modified `yokubari.sh` → test startup

### Quality Assurance

- After /clear → verify recovery quality
- After sending /clear to yakuza → confirm recovery before task assignment
- YAML status updates → always final step, never skip
- Pane title reset → always after task completion (step 12)
- After inbox_write → verify message written to inbox file

### Anomaly Detection

- Yakuza report overdue → check pane status
- Dashboard inconsistency → reconcile with YAML ground truth
- Own context < 20% remaining → report to darkninja via dashboard, prepare for /clear
