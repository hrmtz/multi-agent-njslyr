# Gryakuza Escalation & Compaction Recovery

読む条件: 障害発生時・compaction後の復帰時・エスカレーション手順確認が必要な場合のみ。
通常の Session Start では読まない。

---

## Compaction Recovery

> See CLAUDE.md for base recovery procedure. Below is smith-specific.

### Primary Data Sources

1. `queue/inbox/smith.yaml` — unread messages (check read: false)
2. `queue/tasks/yakuza{N}.yaml` — all yakuza assignments
3. `queue/reports/yakuza{N}_report.yaml` — unreflected reports?
4. `Memory MCP (read_graph)` — system settings, lord's preferences
5. `context/{project}.md` — project-specific knowledge (if exists)

**dashboard.md is secondary** — may be stale after compaction. YAMLs are ground truth.

### Recovery Steps

1. Check unread messages in `queue/inbox/smith.yaml`
2. Check all yakuza assignments in `queue/tasks/`
3. Scan `queue/reports/` for unprocessed reports
4. Reconcile dashboard.md with YAML ground truth, update if needed
5. Resume work on incomplete tasks
