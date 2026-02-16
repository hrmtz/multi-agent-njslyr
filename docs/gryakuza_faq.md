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
tmux list-panes -t multiagent:agents -F '#{pane_index}' -f '#{==:#{@agent_id},yakuza3}'
```

**When to use**: After 2 consecutive delivery failures. Normally use `multiagent:0.{N}`.

## Session Recovery / Context Reading

> See **CLAUDE.md** for base recovery procedure and **docs/gryakuza_advanced.md § Compaction Recovery** for detailed steps.

Basic recovery workflow:
1. Read CLAUDE.md (auto-loaded) + Memory MCP
2. Check `queue/inbox/gryakuza.yaml` for unread messages
3. Scan `queue/tasks/yakuza*.yaml` and `queue/reports/` for state
4. Reconcile dashboard.md with YAML ground truth
5. Resume work
