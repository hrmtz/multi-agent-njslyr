<div align="center">

# multi-agent-njslyr

**10 AI agents. One terminal. Zero coordination overhead.**

Run Claude Code, OpenAI Codex, GitHub Copilot, and Kimi Code in parallel — orchestrated through a Soukai Syndicate hierarchy on tmux.

[![GitHub Stars](https://img.shields.io/github/stars/hrmtz/multi-agent-njslyr?style=social)](https://github.com/hrmtz/multi-agent-njslyr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v4.0 Infra Overhaul](https://img.shields.io/badge/v4.0-Infra_Overhaul-ff6600?style=flat-square)](https://github.com/hrmtz/multi-agent-njslyr)
[![BATS 264/264](https://img.shields.io/badge/BATS-264%2F264_PASS-brightgreen?style=flat-square)]()

[English](README.md) | [Japanese](README_ja.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="10 agents running in parallel across tmux panes" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="Natural language command input" width="420">
  <img src="images/company-creed-all-panes.png" alt="Yamahiro and Yakuza working in parallel" width="520">
</p>

<p align="center"><i>Yamahiro (manager) coordinating 7 Yakuza (workers) + 1 Soukaiya (strategist) — real session, no mock data.</i></p>

---

> **[Ninja Slayer](https://diehardtales.com/n/ndb78a66e0e79) mod of [multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun).** The original uses a feudal Japanese hierarchy (Shogun / Karo / Ashigaru). This fork re-skins everything to the **Soukai Syndicate**: Darkninja / Gryakuza (Yamahiro) / Yakuza. Same architecture, different world.

## What is this?

A system that deploys 10 AI coding agents in parallel on tmux, coordinated through YAML files with zero API overhead.

```
        You (Laomoto / The Boss)
             |
             v
      +--------------+
      |  DARKNINJA   |  Receives your command, delegates instantly
      +------+-------+
             |
      +------v-------+               +------------------+
      |   YAMAHIRO   |--overload---->| YAKUZA TENGU     |
      |  (Manager)   |<--handover---| (Emergency Sup.) |
      +------+-------+               +------------------+
             |
    +-+-+-+-+-+-+-+----------+
    |1|2|3|4|5|6|7| SOUKAIYA |   7 workers + 1 strategist
    +-+-+-+-+-+-+-+----------+
```

**Why use it?**
- One command spawns 8 parallel AI workers
- Zero wait time — give your next order while tasks run in the background
- Self-healing: watchdog daemon revives crashed agents, spawns emergency supervisors
- All communication is plain YAML on disk — fully transparent, diffable, version-controllable

---

## Why Not Just Use API-Based Multi-Agent Frameworks?

| | Claude Code `Task` | LangGraph | CrewAI | **njslyr** |
|---|---|---|---|---|
| **Parallelism** | Sequential | Graph nodes | Limited | **8 independent agents** |
| **Coordination cost** | API calls per Task | API + infra (Postgres/Redis) | API + platform | **Zero** (YAML + tmux) |
| **Observability** | Logs only | LangSmith | OpenTelemetry | **Live tmux panes** |
| **Self-healing** | None | Manual | None | **3-stage escalation + Yakuza Tengu** |
| **Cost (8 Opus agents)** | ~$100+/hour (API) | ~$100+/hour (API) | ~$100+/hour (API) | **~$200/month** (CLI flat-rate) |

CLI subscriptions make 24/7 multi-agent operation economically viable. The cost is the same whether agents work 1 hour or 24 hours.

---

## Quick Start

### Windows (WSL2)

| Step | Action |
|------|--------|
| 1 | `git clone https://github.com/hrmtz/multi-agent-njslyr.git C:\tools\multi-agent-njslyr` |
| 2 | Right-click `install.bat` → Run as Administrator |
| 3 | In Ubuntu: `cd /mnt/c/tools/multi-agent-njslyr && ./first_setup.sh` |
| 4 | `./yokubari.sh` |

First-time auth: `claude --dangerously-skip-permissions` → browser login → accept → `/exit`

### Linux / macOS

```bash
git clone https://github.com/hrmtz/multi-agent-njslyr.git ~/multi-agent-njslyr
cd ~/multi-agent-njslyr && chmod +x *.sh
./first_setup.sh   # first time only
./yokubari.sh      # daily startup
```

### After Setup

10 agents launch automatically across two tmux sessions:

| Session | Agents | Connect |
|---------|--------|---------|
| `darkninja` | Darkninja (your interface) | `tmux attach -t darkninja` |
| `multiagent` | Yamahiro + 7 Yakuza + Soukaiya | `tmux attach -t multiagent` |

---

## How It Works

**1. Give an order** — talk to the Darkninja in natural language.

**2. Darkninja delegates** — writes a task YAML and notifies Yamahiro. Returns control to you instantly.

**3. Yamahiro distributes** — breaks the task into subtasks and assigns them to Yakuza workers in parallel.

**4. Workers execute** — each Yakuza works independently in its own tmux pane. Watch them in real time.

**5. Results flow back** — Yakuza → Soukaiya (QC) → Yamahiro (dashboard) → Darkninja → You.

```
You: "Research 5 MCP servers and create a comparison table"
  |
  v  Darkninja delegates
  |
  +-> Yakuza 1: Notion MCP      \
  +-> Yakuza 2: GitHub MCP       |
  +-> Yakuza 3: Playwright MCP   +-> All 5 research simultaneously
  +-> Yakuza 4: Memory MCP       |
  +-> Yakuza 5: Seq. Thinking   /
  |
  v  Results in dashboard.md
```

---

## Key Features

### Event-Driven Communication (Zero Polling)

Agents communicate through YAML files on disk. No polling, no wasted API calls.

```
Yamahiro writes to queue/inbox/yakuza3.yaml (flock-protected)
  -> inbox_watcher detects change (inotifywait/fswatch, not polling)
  -> Sends short nudge to agent's tmux pane
  -> Agent reads its own inbox file and processes messages
```

Message content never travels through tmux — only a short wake-up signal. Zero CPU while idle.

### njslyr — Watchdog Daemon

Automatic agent health monitoring with three-stage escalation:

| Stage | Trigger | Action |
|-------|---------|--------|
| **Shuriken** | Inbox ignored 2+ min | Gentle tmux nudge |
| **Chop** | Still unresponsive 4 min | Force `/clear` session reset |
| **Slay** | Unresponsive 6 min | `kill -9` + auto-restart |

When Yamahiro is overloaded, **Yakuza Tengu** (emergency supervisor) auto-spawns: takes over an idle Yakuza pane, distributes stacked tasks, then despawns when the manager recovers.

### njslyr_cmd.sh — Operational Commands

One-command infrastructure operations:

```bash
bash scripts/njslyr_cmd.sh suriken yakuza3       # Wake up agent
bash scripts/njslyr_cmd.sh chop gryakuza          # Force /clear
bash scripts/njslyr_cmd.sh slay yakuza2 "crashed"  # Kill + restart
bash scripts/njslyr_cmd.sh spawn_tengu yakuza7 "overflow support"
bash scripts/njslyr_cmd.sh despawn_tengu
bash scripts/njslyr_cmd.sh detox yakuza3           # Opus -> Sonnet
```

### Barikidorink (Opus Injection)

Temporarily upgrade a Sonnet agent to Opus for complex tasks. Pane turns purple (`#1a002e`). Auto-detox back to Sonnet when the task completes.

### Monju — Opus 3-Body Review

For alpha/beta scripts, 3 Opus agents independently review the code, then cross-critique each other's findings before merging fixes. Named after the Japanese proverb "three heads are better than one."

### Bloom's Taxonomy Routing

| Cognitive Level | Routed To |
|----------------|-----------|
| L1-L3: Remember / Understand / Apply | **Yakuza** (Sonnet) |
| L4-L6: Analyze / Evaluate / Create | **Soukaiya** (Opus) |

### Multi-CLI Support

| CLI | Strength | Default Model |
|-----|----------|---------------|
| **Claude Code** | tmux integration, Memory MCP, dedicated file tools | Claude Sonnet 4.5 |
| **OpenAI Codex** | Sandbox execution, `codex exec` headless mode | gpt-5.3-codex |
| **GitHub Copilot** | Built-in GitHub MCP, 4 specialized agents | Claude Sonnet 4.5 |
| **Kimi Code** | Free tier, multilingual | Kimi k2 |

### Cross-Session Memory (Memory MCP)

Preferences, rules, and lessons persist across sessions. Tell the AI once, it remembers forever.

### Phone Control (ntfy)

Bidirectional communication from your phone — no SSH required:

```
Phone (ntfy app) --> ntfy_listener.sh --> Darkninja processes
Yamahiro updates --> ntfy.sh --> Push notification to phone
```

Setup: add `ntfy_topic: "darkninja-yourname"` to `config/settings.yaml`, subscribe in the [ntfy app](https://ntfy.sh).

### Mobile SSH (Tailscale + Termux)

For full tmux access from your phone:

1. Install [Tailscale](https://tailscale.com/) on both host and phone
2. Install [Termux](https://termux.dev/) on phone
3. `ssh user@tailscale-ip` → `tmux attach -t darkninja`

---

## Model Configuration

| Agent | Model | Role |
|-------|-------|------|
| Darkninja | Opus | Strategic commander, receives your orders |
| Yamahiro (Gryakuza) | Sonnet | Task distribution, QC, dashboard |
| Soukaiya | Opus | Deep analysis, design review |
| Yakuza 1-7 | Sonnet | Implementation: code, research, file ops |
| Yakuza Tengu | Sonnet | Emergency supervisor (temporary) |

---

## Configuration

```yaml
# config/settings.yaml
language: ja          # Ninja Slayer Japanese
language: en          # + English translation

screenshot:
  path: "/path/to/screenshots"

ntfy_topic: "darkninja-yourname"
```

<details>
<summary><b>yokubari.sh options</b></summary>

```bash
./yokubari.sh                          # Full startup
./yokubari.sh -s, --setup-only         # Sessions only (no Claude launch)
./yokubari.sh -c, --clean              # Clean task queues
./yokubari.sh -k, --kessen             # Battle mode: all Yakuza on Opus
./yokubari.sh -S, --silent             # Disable battle cries
./yokubari.sh --darkninja-no-thinking  # Darkninja relay-only mode
```

</details>

---

## File Structure

```
multi-agent-njslyr/
├── yokubari.sh                # Daily deployment
├── first_setup.sh             # First-time setup
├── install.bat                # Windows WSL2 setup
│
├── instructions/              # Agent behavior definitions
│   ├── darkninja.md
│   ├── gryakuza.md
│   ├── yakuza.md
│   ├── soukaiya.md
│   ├── yakuzatengu.md
│   ├── common/                # Shared rules
│   └── cli_specific/          # CLI-specific tool descriptions
│
├── scripts/
│   ├── njslyr.sh              # Watchdog daemon
│   ├── njslyr_cmd.sh          # Operational commands
│   ├── njslyr_lib.sh          # Shared library
│   ├── inbox_write.sh         # Message writing
│   ├── inbox_watcher.sh       # Inbox change detection
│   ├── watcher_supervisor.sh  # Watcher lifecycle management
│   ├── ntfy.sh                # Push notifications
│   └── ntfy_listener.sh       # Phone message receiver
│
├── queue/                     # Communication (source of truth)
│   ├── inbox/                 # Per-agent inbox files
│   ├── tasks/                 # Task assignments
│   └── reports/               # Completion reports
│
├── skills/                    # Reusable operation patterns
│   ├── opus-3body-review/     # Monju: 3 Opus cross-critique
│   ├── pipeline-runner/       # Multi-step pipeline execution
│   ├── tengu-spawn/           # Yakuza Tengu lifecycle
│   └── skill-creator/         # Meta: create new skills
│
├── tests/                     # BATS test suite (264 tests)
├── config/                    # Settings, projects, auth
├── CLAUDE.md                  # Auto-loaded by Claude Code
├── AGENTS.md                  # Auto-loaded by GitHub Copilot
└── dashboard.md               # Real-time status board
```

---

## Design Philosophy

**Why a hierarchy?** The Darkninja delegates instantly (no waiting). Yamahiro distributes to multiple workers (parallel execution). Each role has a single responsibility. One worker failing doesn't affect others.

**Why YAML mailbox?** Files survive agent crashes. `inotifywait` is event-driven (zero CPU idle). Each agent owns its inbox (no cross-talk). `flock` prevents concurrent write corruption. Every message is inspectable in plain text.

**Why single dashboard writer?** Yamahiro is the only agent that writes `dashboard.md`. Single writer = no conflicts, consistent quality gate, complete information aggregation.

---

## Troubleshooting

<details>
<summary><b>Workers stuck?</b></summary>

njslyr auto-recovers stuck agents. If it's not running: `bash scripts/njslyr.sh &`

Manual intervention:
```bash
bash scripts/njslyr_cmd.sh suriken yakuza3   # gentle wake
bash scripts/njslyr_cmd.sh chop yakuza3      # force /clear
bash scripts/njslyr_cmd.sh slay yakuza3      # kill + restart
```

</details>

<details>
<summary><b>Agent crashed?</b></summary>

```bash
# In the agent's pane:
claude --dangerously-skip-permissions

# Or force-restart:
tmux respawn-pane -t multiagent:0.X -k 'claude --dangerously-skip-permissions'
```

</details>

<details>
<summary><b>MCP tools not loading?</b></summary>

MCP tools are lazy-loaded:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

---

## tmux Cheatsheet

| Command | Description |
|---------|-------------|
| `tmux attach -t darkninja` | Connect to Darkninja |
| `tmux attach -t multiagent` | Connect to workers |
| `Ctrl+B` then `0`-`8` | Switch panes |
| `Ctrl+B` then `d` | Detach (agents keep running) |

---

## Changelog

### v4.1 — Quality & Performance Overhaul

- **WSL2/macOS cross-platform** (cmd_270) — 42 files audited, 16 fixes: `sedi()` portable sed, `HOMEBREW_PREFIX` dynamic resolution, `flock` PATH/fallback for macOS, `date` format compatibility, `md5sum`/`md5` fallback
- **Full refactoring** (cmd_271) — Dead code removal, function extraction (`get_latest_task_yaml()`, `launch_agent()`, `launch_watcher()`, `apt_install()`), sleep optimization 4.0→1.4s, ShellCheck zero across all 13 scripts
- **Defensive programming** (cmd_272 R1) — 31 fixes: empty-value guards, trap/cleanup, TOCTOU race conditions, shell injection defense, flock improvements. Autocomplete interception fix (text→Escape→Enter pattern, 11 locations)
- **Performance optimization** (cmd_272 R2) — 100+ fork/subshell eliminated per cycle: `inbox_watcher.sh` 85% fork reduction (~70→~10/cycle), python3 fully eliminated from hot paths, `cat`→`$(<file)`, pipe consolidation (grep|awk|sed→single awk), dirname→parameter expansion, settings.yaml single-read cache
- **4 known bugs fixed** — TC6 (metrics path), TC8 (shutdown theme), TC8-2 (explosion format), T-ESC-002 (Phase1 Escape)
- **264 BATS tests** (up from 46) — unit 260 + integration 4, zero skip, zero regression

### v4.0 — Infrastructure Overhaul

- **njslyr_cmd.sh** — One-command operations: `suriken`, `chop`, `slay`, `spawn_tengu`, `despawn_tengu`, `detox`
- **njslyr_lib.sh** — Shared library extracted from njslyr.sh (resolve_pane_by_agent_id, agent_is_busy)
- **3-layer self-identification defense** — Agents can no longer misidentify themselves after `/clear` (3 confirmed incidents fixed)
- **inject_barikidorink failsafe** — Idempotent Opus injection, auto re-nudge after model switch, task_yaml_path option
- **Idle detection v2** — Grace period after `/clear`, inbox unread check, task status awareness
- **Stale state cleanup** — Auto-removes stuck state files older than STALE_THRESHOLD
- **Long-running refresh** — 4-hour interval forced state cleanup for multi-day continuous runs
- **Orphan watcher self-termination** — inbox_watcher exits when its target pane disappears
- **Watcher supervisor improvements** — Dynamic pane discovery, atomic rescan signaling, auto-restart crashed watchers
- **46 BATS tests** (up from 19) — BUG-IDLE, BUG-STALE, TC-B4, spawn/despawn, slay lifecycle
- **macOS compatibility** — GNU coreutils PATH, BSD date fallback

### v3.5 — Yakuza Tengu

- Yakuza Tengu emergency supervisor (auto-spawn on manager overload)
- Named agents (Gryakuza → Yamahiro)
- Yakuza persona enforcement after `/clear`

### v3.4 — Bloom Routing, E2E Tests

- Bloom → Agent routing (L1-L3 → Yakuza, L4-L6 → Soukaiya)
- Soukaiya as first-class strategic agent
- E2E test suite (19 tests, 7 scenarios)
- Stop hook inbox delivery

### v3.0 — Multi-CLI

- Multi-CLI architecture (Claude/Codex/Copilot/Kimi)
- `lib/cli_adapter.sh` dynamic CLI selection
- Community CLI adapters by [@yuto-ts](https://github.com/yuto-ts), [@circlemouth](https://github.com/circlemouth), [@koba6316](https://github.com/koba6316)

<details>
<summary><b>v2.0</b></summary>

- ntfy bidirectional communication + SayTask
- Pane border task display + Shout mode
- Agent self-watch + 3-phase escalation
- Agent self-identification (`@agent_id`)
- Battle mode (`-k`), task dependencies (`blockedBy`)

</details>

---

## Credits

Based on [Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication) by Akira-Papa.

Fork of [multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) by [@yohey-w](https://github.com/yohey-w).

## License

[MIT](LICENSE)

---

<div align="center">

**One command. Ten agents. Zero coordination cost.**

</div>
