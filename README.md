<div align="center">

# multi-agent-njslyr

**Command your AI army like a Neo-Saitama syndicate boss.**

Run 10 AI coding agents in parallel — **Claude Code, OpenAI Codex, GitHub Copilot, Kimi Code** — orchestrated through a Soukai Syndicate hierarchy with zero coordination overhead.

**Talk Coding, not Vibe Coding. Speak to your phone, AI executes.**

[![GitHub Stars](https://img.shields.io/github/stars/hrmtz/multi-agent-njslyr?style=social)](https://github.com/hrmtz/multi-agent-njslyr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.5 Yakuza Tengu](https://img.shields.io/badge/v3.5-Yakuza_Tengu-ff6600?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHRleHQgeD0iMCIgeT0iMTIiIGZvbnQtc2l6ZT0iMTIiPuKalTwvdGV4dD48L3N2Zz4=)](https://github.com/hrmtz/multi-agent-njslyr)
[![Shell](https://img.shields.io/badge/Shell%2FBash-100%25-green)]()

[English](README.md) | [日本語](README_ja.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="Latest translucent command session in the Darkninja pane" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="Quick natural-language command in the Darkninja pane" width="420">
  <img src="images/company-creed-all-panes.png" alt="Gryakuza and Yakuza panes reacting in parallel" width="520">
</p>

<p align="center"><i>Yamahiro (manager) coordinating 7 Yakuza (workers) + 1 Soukaiya (strategist) — real session, no mock data.</i></p>

---

> **This is a [Ninja Slayer](https://diehardtales.com/n/ndb78a66e0e79) mod of [multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun).**
> The original system uses a feudal Japanese hierarchy (Shogun → Karo → Ashigaru). This fork re-skins the entire naming to the **Soukai Syndicate** from Ninja Slayer: Darkninja → Gryakuza (Yamahiro) → Yakuza. All instructions, scripts, tests, and documentation have been rewritten. The underlying architecture and functionality are identical.

## What is this?

**multi-agent-njslyr** is a system that runs multiple AI coding CLI instances simultaneously, orchestrated as a Soukai Syndicate operation. Supports **Claude Code**, **OpenAI Codex**, **GitHub Copilot**, and **Kimi Code**.

**Why use it?**
- One command spawns 7 AI workers + 1 strategist executing in parallel
- Zero wait time — give your next order while tasks run in the background
- AI remembers your preferences across sessions (Memory MCP)
- Real-time progress on a dashboard
- Auto-healing: watchdog daemon revives crashed agents and spawns emergency supervisors

```
        You (ラオモト / The Lord)
             │
             ▼  Give orders
      ┌─────────────┐
      │  DARKNINJA  │  ← Receives your command, delegates instantly
      └──────┬──────┘
             │  YAML + tmux
      ┌──────▼──────┐               ┌────────────────┐
      │  YAMAHIRO   │──overload────▶│ YAKUZA TENGU   │
      │  (Gryakuza) │◀──handover───│ (Emergency Sup.)|
      └──────┬──────┘               └────────────────┘
             │                        ↕ distributes tasks
    ┌─┬─┬─┬─┴─┬─┬─┬─┬──────────┐
    │1│2│3│4│5│6│7│ SOUKAIYA │  ← 7 workers + 1 strategist
    └─┴─┴─┴─┴─┴─┴─┴──────────┘
       YAKUZA     ソウカイヤ幹部
```

---

## Why This System?

Most multi-agent frameworks burn API tokens on coordination. This system doesn't.

| | Claude Code `Task` tool | LangGraph | CrewAI | **multi-agent-njslyr** |
|---|---|---|---|---|
| **Architecture** | Subagents inside one process | Graph-based state machine | Role-based agents | Syndicate hierarchy via tmux |
| **Parallelism** | Sequential (one at a time) | Parallel nodes (v0.2+) | Limited | **8 independent agents** |
| **Coordination cost** | API calls per Task | API + infra (Postgres/Redis) | API + CrewAI platform | **Zero** (YAML + tmux) |
| **Observability** | Claude logs only | LangSmith integration | OpenTelemetry | **Live tmux panes** + dashboard |
| **Self-healing** | None | Manual restart | None | **3-stage escalation + Yakuza Tengu** |
| **Skill discovery** | None | None | None | **Bottom-up auto-proposal** |
| **Setup** | Built into Claude Code | Heavy (infra required) | pip install | Shell scripts |

### What makes this different

**Zero coordination overhead** — Agents talk through YAML files on disk. The only API calls are for actual work, not orchestration. Run 8 agents and pay only for 8 agents' work.

**Full transparency** — Every agent runs in a visible tmux pane. Every instruction, report, and decision is a plain YAML file you can read, diff, and version-control. No black boxes.

**Battle-tested hierarchy** — The Darkninja → Yamahiro → Yakuza chain of command prevents conflicts by design: clear ownership, dedicated files per agent, event-driven communication, no polling.

**Self-healing** — The njslyr watchdog daemon monitors all agents. Unresponsive agents get escalated through shuriken nudge → forced clear → kill & respawn. When the manager (Yamahiro) is overloaded, Yakuza Tengu spawns automatically to distribute stacked tasks.

---

## Why CLI (Not API)?

Most AI coding tools charge per token. Running 8 Opus-grade agents through the API costs **$100+/hour**. CLI subscriptions flip this:

| | API (Per-Token) | CLI (Flat-Rate) |
|---|---|---|
| **8 agents × Opus** | ~$100+/hour | ~$200/month |
| **Cost predictability** | Unpredictable spikes | Fixed monthly bill |
| **Usage anxiety** | Every token counts | Unlimited |
| **Experimentation budget** | Constrained | Deploy freely |

**"Use AI recklessly"** — With flat-rate CLI subscriptions, deploy 8 agents without hesitation. The cost is the same whether they work 1 hour or 24 hours.

### Multi-CLI Support

The system isn't locked to one vendor. It supports 4 CLI tools, each with unique strengths:

| CLI | Key Strength | Default Model |
|-----|-------------|---------------|
| **Claude Code** | Battle-tested tmux integration, Memory MCP, dedicated file tools (Read/Write/Edit/Glob/Grep) | Claude Sonnet 4.5 |
| **OpenAI Codex** | Sandbox execution, JSONL structured output, `codex exec` headless mode, **per-model `--model` flag** | gpt-5.3-codex / **gpt-5.3-codex-spark** |
| **GitHub Copilot** | Built-in GitHub MCP, 4 specialized agents (Explore/Task/Plan/Code-review), `/delegate` to coding agent | Claude Sonnet 4.5 |
| **Kimi Code** | Free tier available, strong multilingual support | Kimi k2 |

A unified instruction build system generates CLI-specific instruction files from shared templates:

```
instructions/
├── common/              # Shared rules (all CLIs)
├── cli_specific/        # CLI-specific tool descriptions
│   ├── claude_tools.md  # Claude Code tools & features
│   └── copilot_tools.md # GitHub Copilot CLI tools & features
└── roles/               # Role definitions (darkninja, gryakuza, yakuza, soukaiya)
    ↓ build
CLAUDE.md / AGENTS.md / copilot-instructions.md  ← Generated per CLI
```

One source of truth, zero sync drift. Change a rule once, all CLIs get it.

---

## Quick Start

### Windows (WSL2)

<table>
<tr>
<td width="60">

**Step 1**

</td>
<td>

**Download the repository**

[Download ZIP](https://github.com/hrmtz/multi-agent-njslyr/archive/refs/heads/main.zip) and extract to `C:\tools\multi-agent-njslyr`

*Or use git:* `git clone https://github.com/hrmtz/multi-agent-njslyr.git C:\tools\multi-agent-njslyr`

</td>
</tr>
<tr>
<td>

**Step 2**

</td>
<td>

**Run `install.bat`**

Right-click → "Run as Administrator" (if WSL2 is not installed). Sets up WSL2 + Ubuntu automatically.

</td>
</tr>
<tr>
<td>

**Step 3**

</td>
<td>

**Open Ubuntu and run** (first time only)

```bash
cd /mnt/c/tools/multi-agent-njslyr
./first_setup.sh
```

</td>
</tr>
<tr>
<td>

**Step 4**

</td>
<td>

**Deploy!**

```bash
./yokubari.sh
```

</td>
</tr>
</table>

#### First-time only: Authentication

After `first_setup.sh`, run these commands once to authenticate:

```bash
# 1. Apply PATH changes
source ~/.bashrc

# 2. OAuth login + Bypass Permissions approval (one command)
claude --dangerously-skip-permissions
#    → Browser opens → Log in with Anthropic account → Return to CLI
#    → "Bypass Permissions" prompt appears → Select "Yes, I accept" (↓ to option 2, Enter)
#    → Type /exit to quit
```

This saves credentials to `~/.claude/` — you won't need to do it again.

#### Daily startup

Open an **Ubuntu terminal** (WSL) and run:

```bash
cd /mnt/c/tools/multi-agent-njslyr
./yokubari.sh
```

### Mobile Access (Command from anywhere)

Control your AI army from your phone — bed, cafe, or bathroom.

**Requirements (all free):**

| Name | In a nutshell | Role |
|------|--------------|------|
| [Tailscale](https://tailscale.com/) | A road to your home from anywhere | Connect to your home PC from anywhere |
| SSH | The feet that walk that road | Log into your home PC through Tailscale |
| [Termux](https://termux.dev/) | A black screen on your phone | Required to use SSH — just install it |

**Setup:**

1. Install Tailscale on both WSL and your phone
2. In WSL (auth key method — browser not needed):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscaled &
   sudo tailscale up --authkey tskey-auth-XXXXXXXXXXXX
   sudo service ssh start
   ```
3. In Termux on your phone:
   ```sh
   pkg update && pkg install openssh
   ssh youruser@your-tailscale-ip
   css    # Connect to Darkninja
   ```
4. Open a new Termux window (+ button) for workers:
   ```sh
   ssh youruser@your-tailscale-ip
   csm    # See all 9 panes
   ```

**Disconnect:** Just swipe the Termux window closed. tmux sessions survive — agents keep working.

**Voice input:** Use your phone's voice keyboard to speak commands. The Darkninja understands natural language, so typos from speech-to-text don't matter.

**Even simpler:** With ntfy configured, you can receive notifications and send commands directly from the ntfy app — no SSH required.

---

<details>
<summary> <b>Linux / macOS</b> (click to expand)</summary>

### First-time setup

```bash
# 1. Clone
git clone https://github.com/hrmtz/multi-agent-njslyr.git ~/multi-agent-njslyr
cd ~/multi-agent-njslyr

# 2. Make scripts executable
chmod +x *.sh

# 3. Run first-time setup
./first_setup.sh
```

### Daily startup

```bash
cd ~/multi-agent-njslyr
./yokubari.sh
```

</details>

<details>
<summary><b>What is WSL2? Why is it needed?</b> (click to expand)</summary>

**WSL2 (Windows Subsystem for Linux)** lets you run Linux inside Windows. This system uses `tmux` (a Linux tool) to manage multiple AI agents, so WSL2 is required on Windows.

No problem if you don't have it! Running `install.bat` will auto-install WSL2 + Ubuntu and guide you through the rest.

**Quick install command** (run PowerShell as Administrator):
```powershell
wsl --install
```

Then restart your computer and run `install.bat` again.

</details>

---

### After Setup

Whichever option you chose, **10 AI agents** are automatically launched:

| Agent | Role | Count |
|-------|------|-------|
| Darkninja | Supreme commander — receives your orders | 1 |
| Yamahiro (Gryakuza) | Manager — distributes tasks, quality checks, dashboard | 1 |
| Yakuza | Workers — execute implementation tasks in parallel | 7 |
| Soukaiya | Strategist — handles analysis, evaluation, and design | 1 |

Two tmux sessions are created:
- `darkninja` — connect here to give commands
- `multiagent` — Yamahiro, Yakuza, and Soukaiya running in the background

---

## How It Works

### Step 1: Connect to the Darkninja

After running `yokubari.sh`, all agents automatically load their instructions and are ready.

```bash
tmux attach-session -t darkninja
```

### Step 2: Give your first order

The Darkninja is already initialized — just give a command:

```
Research the top 5 JavaScript frameworks and create a comparison table
```

The Darkninja will:
1. Write the task to a YAML file
2. Notify Yamahiro (the manager)
3. Return control to you immediately — no waiting!

Meanwhile, Yamahiro distributes tasks to Yakuza workers for parallel execution.

### Step 3: Check progress

Open `dashboard.md` in your editor for a real-time status view:

```markdown
## In Progress
| Worker | Task | Status |
|--------|------|--------|
| Yakuza 1 | Research React | Running |
| Yakuza 2 | Research Vue | Running |
| Yakuza 3 | Research Angular | Completed |
```

### Detailed flow

```
You: "Research the top 5 MCP servers and create a comparison table"
```

The Darkninja sends the task to Yamahiro via inbox (`queue/inbox/gryakuza.yaml`) and wakes Yamahiro. Control returns to you immediately.

Yamahiro breaks the task into subtasks:

| Worker | Assignment |
|--------|-----------|
| Yakuza 1 | Research Notion MCP |
| Yakuza 2 | Research GitHub MCP |
| Yakuza 3 | Research Playwright MCP |
| Yakuza 4 | Research Memory MCP |
| Yakuza 5 | Research Sequential Thinking MCP |

All 5 Yakuza research simultaneously. You can watch them work in real time:

<p align="center">
  <img src="images/company-creed-all-panes.png" alt="Yakuza agents working in parallel across tmux panes" width="900">
</p>

Results appear in `dashboard.md` as they complete.

---

## Key Features

### 1. Parallel Execution

One command spawns up to 8 parallel tasks:

```
You: "Research 5 MCP servers"
→ 5 Yakuza start researching simultaneously
→ Results in minutes, not hours
```

### 2. Non-Blocking Workflow

The Darkninja delegates instantly and returns control to you:

```
You: Command → Darkninja: Delegates → You: Give next command immediately
                                       ↓
                       Workers: Execute in background
                                       ↓
                       Dashboard: Shows results
```

### 3. Cross-Session Memory (Memory MCP)

Your AI remembers your preferences:

```
Session 1: Tell it "I prefer simple approaches"
            → Saved to Memory MCP

Session 2: AI loads memory on startup
            → Stops suggesting complex solutions
```

### 4. Event-Driven Communication (Zero Polling)

Agents talk to each other by writing YAML files — like passing notes. **No polling loops, no wasted API calls.**

```
Yamahiro wants to wake Yakuza 3:

Step 1: Write the message          Step 2: Wake the agent up
┌──────────────────────┐           ┌──────────────────────────┐
│ inbox_write.sh       │           │ inbox_watcher.sh         │
│                      │           │                          │
│ Writes full message  │  file     │ Detects file change      │
│ to yakuza3.yaml      │──change──▶│ (inotifywait, not poll)  │
│ with flock (no race) │           │                          │
└──────────────────────┘           │ Wakes agent via:         │
                                   │  1. Self-watch (skip)    │
                                   │  2. tmux send-keys       │
                                   │     (short nudge only)   │
                                   └──────────────────────────┘

Step 3: Agent reads its own inbox
┌──────────────────────────────────┐
│ Yakuza 3 reads yakuza3.yaml      │
│ → Finds unread messages          │
│ → Processes them                 │
│ → Marks as read                  │
└──────────────────────────────────┘
```

**Key design choices:**
- **Message content is never sent through tmux** — only a short "you have mail" nudge. The agent reads its own file. This eliminates character corruption and transmission hangs.
- **Zero CPU while idle** — `inotifywait` blocks on a kernel event (not a poll loop). CPU usage is 0% between messages.
- **Guaranteed delivery** — If the file write succeeded, the message is there. No lost messages, no retries needed.

### 5. njslyr — Agent Monitoring Daemon

Automatic agent health monitoring with three-stage escalation and emergency supervisor spawning — keeps your AI army responsive without manual intervention.

**Three-Stage Escalation:**

| Stage | Trigger | Action | Purpose |
|-------|---------|--------|---------|
| **Stage 1: Shuriken** | Agent ignores inbox for 2+ min | Send gentle nudge via tmux | Wake up distracted agent |
| **Stage 2: Chop** | Still unresponsive after 4 min | Force `/clear` to reset session | Clear context overload |
| **Stage 3: Slay** | Unresponsive after 6 min | `kill -9` + auto-restart + red pane | Terminate and revive crashed agent |

**Yakuza Tengu — Emergency Supervisor:**

When Yamahiro (the manager) is overloaded — too many stacked tasks, too many idle Yakuza waiting — njslyr automatically spawns **Yakuza Tengu**, a temporary Sonnet supervisor.

```
Normal operation:
  Yamahiro distributes tasks → Yakuza execute

Yamahiro overloaded (inbox piling up, idle Yakuza waiting):
  njslyr detects overload
    → Picks most idle Yakuza pane
    → Respawns as Yakuza Tengu (dark pink pane, Sonnet)
    → Yakuza Tengu reads Yamahiro's stacked inbox
    → Distributes tasks to idle Yakuza
    → Yamahiro recovers → Yakuza Tengu hands over and despawns
    → Original Yakuza restored
```

Yakuza Tengu is inspired by the Ninja Slayer character who shows up uninvited to help Yamahiro in his darkest hour — a pushy benefactor. The dark pink pane (`#3a0025`) makes it instantly recognizable.

**Cost optimization:** njslyr only sends nudges to agents with **unread inbox messages** (`grep 'read: false'` detection — pure bash, zero API calls). Idle agents are left untouched.

### 6. Bloom's Taxonomy → Agent Routing

Tasks are classified by cognitive complexity and routed to the right agent:

| Level | Category | Routed To |
|-------|----------|-----------|
| L1–L3 | Remember / Understand / Apply | **Yakuza** (Sonnet) |
| L4–L6 | Analyze / Evaluate / Create | **Soukaiya** (Opus) |

The right agent gets the right task from the start — no mid-session model switching needed.

### 7. Bottom-Up Skill Discovery

As Yakuza execute tasks, they **automatically identify reusable patterns** and propose them as skill candidates. Yamahiro aggregates these in `dashboard.md`, and you decide what gets promoted to a permanent skill.

```
Yakuza finishes a task
    ↓
Notices: "I've done this pattern 3 times across different projects"
    ↓
Reports in YAML:  skill_candidate:
                     found: true
                     name: "api-endpoint-scaffold"
                     reason: "Same REST scaffold pattern used in 3 projects"
    ↓
Appears in dashboard.md → You approve → Skill created in .claude/commands/
    ↓
Any agent can now invoke /api-endpoint-scaffold
```

Skills grow organically from real work — not from a predefined template library.

### 8. Phone Notifications (ntfy)

Two-way communication between your phone and the Darkninja — no SSH, no Tailscale, no server needed.

| Direction | How it works |
|-----------|-------------|
| **Phone → Darkninja** | Send a message from the ntfy app → `ntfy_listener.sh` receives it → Darkninja processes automatically |
| **Yamahiro → Phone** | When Yamahiro updates `dashboard.md`, it sends push notifications directly via `scripts/ntfy.sh` |

```
📱 You (from bed)          🏯 Darkninja
    │                          │
    │  "Research React 19"     │
    ├─────────────────────────►│
    │    (ntfy message)        │  → Delegates to Yamahiro → Yakuza work
    │                          │
    │  "✅ cmd_042 complete"   │
    │◄─────────────────────────┤
    │    (push notification)   │
```

**Setup:**
1. Add `ntfy_topic: "darkninja-yourname"` to `config/settings.yaml`
2. Install the [ntfy app](https://ntfy.sh) on your phone and subscribe to the same topic
3. `yokubari.sh` automatically starts the listener — no extra steps

Free, no account required, no server to maintain. Uses [ntfy.sh](https://ntfy.sh) — an open-source push notification service.

> **Security:** Your topic name is your password. Anyone who knows it can read your notifications and send messages to your Darkninja. Choose a hard-to-guess name and **never share it publicly**.

<p align="center">
  <img src="images/screenshots/masked/ntfy_saytask_rename.jpg" alt="Bidirectional phone communication" width="300">
  &nbsp;&nbsp;
  <img src="images/screenshots/masked/ntfy_cmd043_progress.jpg" alt="Progress notification" width="300">
</p>
<p align="center"><i>Left: Bidirectional phone ↔ Darkninja communication · Right: Real-time progress report</i></p>

### 9. More Features

| Feature | Description |
|---------|-------------|
| **Pane Border Task Display** | Each tmux pane shows `yakuza1 (Sonnet) API research` on its border — glance at all 9 panes to see who's doing what |
| **Shout Mode** | Yakuza shout battle cries after completing tasks. Disable with `yokubari.sh --silent` |
| **Screenshot Integration** | Set screenshot path in `config/settings.yaml`, tell Darkninja "check the latest screenshot" |
| **Task Dependencies** | `blockedBy` field in task YAML — Yamahiro auto-unblocks dependent tasks when predecessors complete |
| **Context Management** | 4-layer architecture: Memory MCP (persistent) → Project files → YAML Queue → Session context |
| **Stop Hook Inbox** | Claude Code agents auto-check inbox at turn end via Stop hook — eliminates send-keys interruption |

---

## SayTask — Task Management for People Who Hate Task Management

**Just speak to your phone.** No typing, no opening apps, no friction.

1. Install the [ntfy app](https://ntfy.sh) (free, no account needed)
2. Speak to your phone: *"dentist tomorrow"*, *"invoice due Friday"*
3. AI auto-organizes → morning notification: *"here's your day"*

```
 🗣️ "Buy milk, dentist tomorrow, invoice due Friday"
       │
       ▼
 ┌──────────────────┐
 │  ntfy → Darkninja│  AI auto-categorize, parse dates, set priorities
 └────────┬─────────┘
          │
          ▼
 ┌──────────────────┐
 │   tasks.yaml     │  Structured storage (local, never leaves your machine)
 └────────┬─────────┘
          │
          ▼
 📱 Morning notification:
    "Today: 🐸 Invoice due · 🦷 Dentist 3pm · 🛒 Buy milk"
```

**Eat the Frog 🐸**: Every morning, AI picks your hardest task — the one you'd rather avoid. Tackle it first or ignore it.

**Streak tracking**: Consecutive completion days counted — leverages loss aversion to sustain momentum.

| Before (v1) | After (v2) |
|:-----------:|:----------:|
| ![Task list v1](images/screenshots/masked/ntfy_tasklist_v1_before.jpg) | ![Task list v2](images/screenshots/masked/ntfy_tasklist_v2_aligned.jpg) |
| Raw task dump | Clean, organized daily summary |

---

## Model Settings

| Agent | Default Model | Thinking | Role |
|-------|--------------|----------|------|
| Darkninja | Opus | **Enabled (high)** | Strategic advisor to ラオモト. Use `--darkninja-no-thinking` for relay-only mode |
| Yamahiro (Gryakuza) | Sonnet | Enabled | Task distribution, QC, dashboard management |
| Soukaiya | Opus | Enabled | Deep analysis, design review, architecture evaluation |
| Yakuza 1–7 | Sonnet | Enabled | Implementation: code, research, file operations |
| Yakuza Tengu | Sonnet | Enabled | Emergency supervisor — temporary, spawned by njslyr when Yamahiro overloads |

The system splits work by **cognitive complexity**, not model tier. Yakuza handle implementation (L1–L3), while the Soukaiya handles tasks requiring deep reasoning (L4–L6). Yakuza Tengu is a temporary Sonnet supervisor that handles task distribution overflow.

---

## Configuration

### Language

```yaml
# config/settings.yaml
language: ja   # Ninja Slayer Japanese only
language: en   # Ninja Slayer Japanese + English translation
```

### Screenshot integration

```yaml
# config/settings.yaml
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

Tell the Darkninja "check the latest screenshot" and it reads your screen captures. (`Win+Shift+S` on Windows.)

### ntfy (Phone Notifications)

```yaml
# config/settings.yaml
ntfy_topic: "darkninja-yourname"
```

Subscribe to the same topic in the [ntfy app](https://ntfy.sh) on your phone. The listener starts automatically with `yokubari.sh`.

<details>
<summary><b>ntfy Authentication (Self-Hosted Servers)</b></summary>

The public ntfy.sh instance requires **no authentication** — the setup above is all you need.

If you run a self-hosted ntfy server with access control enabled:

```bash
cp config/ntfy_auth.env.sample config/ntfy_auth.env
# Edit with your credentials
```

| Method | Config | When to use |
|--------|--------|-------------|
| **Bearer Token** (recommended) | `NTFY_TOKEN=tk_your_token_here` | Self-hosted ntfy with token auth |
| **Basic Auth** | `NTFY_USER=username` + `NTFY_PASS=password` | Self-hosted ntfy with user/password |
| **None** (default) | Leave file empty | Public ntfy.sh — no auth needed |

</details>

---

## Advanced

<details>
<summary><b>Script Reference</b> (click to expand)</summary>

| Script | Purpose | When to run |
|--------|---------|-------------|
| `install.bat` | Windows: WSL2 + Ubuntu setup | First time only |
| `first_setup.sh` | Install tmux, Node.js, Claude Code CLI + Memory MCP config | First time only |
| `yokubari.sh` | Create tmux sessions + launch Claude Code + start infrastructure | Daily |

</details>

<details>
<summary><b>yokubari.sh Options</b> (click to expand)</summary>

```bash
./yokubari.sh                       # Full startup (default)
./yokubari.sh -s, --setup-only      # Session setup only (no Claude launch)
./yokubari.sh -c, --clean           # Clean task queues
./yokubari.sh -k, --kessen          # Battle formation: All Yakuza on Opus
./yokubari.sh -S, --silent          # Disable battle cries
./yokubari.sh -t, --terminal        # Open Windows Terminal tabs
./yokubari.sh --darkninja-no-thinking  # Darkninja relay-only mode
./yokubari.sh -h, --help            # Show help
```

</details>

<details>
<summary><b>Script Architecture</b> (click to expand)</summary>

```
┌─────────────────────────────────────────────────────────────────────┐
│                    First-Time Setup (run once)                       │
├─────────────────────────────────────────────────────────────────────┤
│  install.bat (Windows)                                              │
│      ├── Check/guide WSL2 installation                              │
│      └── Check/guide Ubuntu installation                            │
│                                                                     │
│  first_setup.sh (run manually in Ubuntu/WSL)                        │
│      ├── Check/install tmux                                         │
│      ├── Check/install Node.js v20+ (via nvm)                      │
│      ├── Check/install Claude Code CLI (native version)             │
│      └── Configure Memory MCP server                                │
├─────────────────────────────────────────────────────────────────────┤
│                    Daily Startup (run every day)                     │
├─────────────────────────────────────────────────────────────────────┤
│  yokubari.sh                                                        │
│      ├──▶ Create tmux sessions                                      │
│      │     • "darkninja" session (1 pane)                           │
│      │     • "multiagent" session (9 panes, 3x3 grid)              │
│      ├──▶ Reset queue files and dashboard                           │
│      ├──▶ Launch Claude Code on all agents                          │
│      ├──▶ Start inbox_watcher.sh (10 instances, one per agent)      │
│      └──▶ Start njslyr.sh (watchdog daemon)                         │
└─────────────────────────────────────────────────────────────────────┘
```

</details>

<details>
<summary><b>Common Workflows</b> (click to expand)</summary>

**Normal daily use:**
```bash
./yokubari.sh          # Launch everything
tmux attach-session -t darkninja     # Connect and give commands
```

**Debug mode (manual control):**
```bash
./yokubari.sh -s       # Create sessions only

# Manually launch Claude Code on specific agents
tmux send-keys -t darkninja:0 'claude --dangerously-skip-permissions' Enter
tmux send-keys -t multiagent:0.0 'claude --dangerously-skip-permissions' Enter
```

**Restart after crash:**
```bash
# Kill existing sessions
tmux kill-session -t darkninja
tmux kill-session -t multiagent

# Fresh start
./yokubari.sh
```

</details>

<details>
<summary><b>Convenient Aliases</b> (click to expand)</summary>

Running `first_setup.sh` automatically adds these aliases to `~/.bashrc`:

```bash
alias csst='cd /mnt/c/tools/multi-agent-njslyr && ./yokubari.sh'
alias css='tmux attach-session -t darkninja'      # Connect to Darkninja
alias csm='tmux attach-session -t multiagent'  # Connect to Yamahiro + Yakuza
```

</details>

---

## File Structure

<details>
<summary><b>Click to expand file structure</b></summary>

```
multi-agent-njslyr/
│
│  ┌──────────────── Setup Scripts ────────────────────┐
├── install.bat               # Windows: First-time setup
├── first_setup.sh            # Ubuntu/Mac: First-time setup
├── yokubari.sh               # Daily deployment
│  └──────────────────────────────────────────────────┘
│
├── instructions/             # Agent behavior definitions
│   ├── darkninja.md          # Darkninja instructions
│   ├── gryakuza.md           # Yamahiro (Gryakuza) instructions
│   ├── yakuza.md             # Yakuza instructions
│   ├── soukaiya.md           # Soukaiya (strategist) instructions
│   ├── yakuzatengu.md        # Yakuza Tengu (emergency supervisor) instructions
│   ├── common/               # Shared rules (all CLIs)
│   └── cli_specific/         # CLI-specific tool descriptions
│
├── lib/
│   ├── cli_adapter.sh        # Multi-CLI adapter (Claude/Codex/Copilot/Kimi)
│   └── ntfy_auth.sh          # ntfy authentication helper
│
├── scripts/                  # Utility scripts
│   ├── inbox_write.sh        # Write messages to agent inbox
│   ├── inbox_watcher.sh      # Watch inbox changes via inotifywait/fswatch
│   ├── njslyr.sh             # Watchdog daemon (3-stage escalation + Yakuza Tengu)
│   ├── ntfy.sh               # Send push notifications to phone
│   └── ntfy_listener.sh      # Stream incoming messages from phone
│
├── config/
│   ├── settings.yaml         # Language, ntfy, and other settings
│   ├── ntfy_auth.env.sample  # ntfy authentication template
│   └── projects.yaml         # Project registry
│
├── queue/                    # Communication files (source of truth)
│   ├── inbox/                # Per-agent inbox files
│   │   ├── darkninja.yaml
│   │   ├── gryakuza.yaml
│   │   ├── yakuza{1-7}.yaml
│   │   └── soukaiya.yaml
│   ├── tasks/                # Per-worker task files
│   ├── reports/              # Worker reports
│   └── ntfy_inbox.yaml       # Incoming messages from phone
│
├── saytask/                  # SayTask (voice task management)
│   └── streaks.yaml          # Streak tracking
│
├── templates/                # Report and context templates
├── memory/                   # Memory MCP persistent storage
├── dashboard.md              # Real-time status board
├── CLAUDE.md                 # System instructions (auto-loaded by Claude Code)
├── AGENTS.md                 # System instructions (auto-loaded by GitHub Copilot)
└── tests/                    # BATS test suite
```

</details>

---

## Design Philosophy

### Why a hierarchy (Darkninja → Yamahiro → Yakuza)?

1. **Instant response**: The Darkninja delegates immediately, returning control to you
2. **Parallel execution**: Yamahiro distributes to multiple Yakuza simultaneously
3. **Single responsibility**: Each role is clearly separated — no confusion
4. **Scalability**: Adding more Yakuza doesn't break the structure
5. **Fault isolation**: One Yakuza failing doesn't affect the others
6. **Self-healing**: njslyr monitors everything, Yakuza Tengu handles manager overload

### Why Mailbox System?

| Problem with direct messaging | How mailbox solves it |
|-------------------------------|----------------------|
| Agent crashes → message lost | YAML files survive restarts |
| Polling wastes API calls | `inotifywait` is event-driven (zero CPU while idle) |
| Agents interrupt each other | Each agent has its own inbox file — no cross-talk |
| Hard to debug | Open any `.yaml` file to see exact message history |
| Concurrent writes corrupt data | `flock` serializes writes automatically |
| Delivery failures (character corruption) | Message content stays in files — only a short nudge sent through tmux |

### Why Yamahiro is the single dashboard writer

1. **Single writer**: Prevents conflicts by limiting updates to one agent
2. **Information aggregation**: Yamahiro receives all Yakuza reports, so it has the full picture
3. **Consistency**: All updates pass through a single quality gate

---

## Troubleshooting

<details>
<summary><b>Using npm version of Claude Code CLI?</b></summary>

The npm version is officially deprecated. Re-run `first_setup.sh` to detect and migrate to the native version.

</details>

<details>
<summary><b>MCP tools not loading?</b></summary>

MCP tools are lazy-loaded. Search first, then use:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

<details>
<summary><b>Workers stuck?</b></summary>

```bash
tmux attach-session -t multiagent
# Ctrl+B then 0-8 to switch panes
```

njslyr should auto-recover stuck agents. If it's not running: `bash scripts/njslyr.sh &`

</details>

<details>
<summary><b>Agent crashed?</b></summary>

**Do NOT use `css`/`csm` aliases inside an existing tmux session** — causes session nesting.

```bash
# Method 1: Run claude directly in the pane
claude --model opus --dangerously-skip-permissions

# Method 2: Force-restart via respawn-pane
tmux respawn-pane -t darkninja:0.0 -k 'claude --model opus --dangerously-skip-permissions'
```

</details>

---

## tmux Quick Reference

| Command | Description |
|---------|-------------|
| `tmux attach -t darkninja` | Connect to the Darkninja |
| `tmux attach -t multiagent` | Connect to workers |
| `Ctrl+B` then `0`–`8` | Switch panes |
| `Ctrl+B` then `d` | Detach (agents keep running) |
| `tmux kill-session -t darkninja` | Stop the Darkninja session |
| `tmux kill-session -t multiagent` | Stop the worker session |

Mouse support is auto-configured by `first_setup.sh` (`set -g mouse on`). Click panes to switch focus, scroll with mouse wheel, drag borders to resize.

---

## Changelog

### v3.5 — Yakuza Tengu, Named Agents

- **Yakuza Tengu** — Emergency supervisor that auto-spawns when Yamahiro is overloaded. Picks an idle Yakuza pane, respawns as Sonnet supervisor with dark pink pane (`#3a0025`), distributes stacked tasks, then despawns when Yamahiro recovers
- **Named agents** — Gryakuza now has a proper name: **Yamahiro** (ヤマヒロ). Code IDs remain unchanged
- **Yakuza persona enforcement** — Clone Yakuza now maintain Ninja Slayer + Yakuza slang speech style even after `/clear` recovery
- **Samurai language ban** — Explicit prohibition of samurai speech (ゴザル, 拙者, etc.) — Yakuza are Yakuza, not samurai
- **macOS support improvements** — fswatch-based inbox watching, BSD-compatible scripts

### v3.4 — Bloom→Agent Routing, E2E Tests, Stop Hook

- **Bloom → Agent routing** — Replaced dynamic model switching with agent-level routing. L1–L3 → Yakuza (Sonnet), L4–L6 → Soukaiya (Opus)
- **Soukaiya as first-class agent** — Strategic advisor on pane 8. Handles deep analysis, design review, architecture evaluation
- **E2E test suite (19 tests, 7 scenarios)** — Mock CLI framework simulates agent behavior in isolated tmux sessions
- **Stop hook inbox delivery** — Claude Code agents auto-check inbox at turn end
- **Model defaults updated** — Gryakuza: Opus → Sonnet. Soukaiya: Opus

### v3.3.2 — GPT-5.3-Codex-Spark Support

- **Codex `--model` flag support** — Supports `gpt-5.3-codex-spark` and future Codex models
- **Separate rate limit** — Spark runs on its own quota. Run both models in parallel to double throughput

### v3.0 — Multi-CLI

- **Multi-CLI architecture** — `lib/cli_adapter.sh` dynamically selects CLI per agent (Claude/Codex/Copilot/Kimi)
- **OpenAI Codex CLI integration** — GPT-5.3-codex with autonomous execution
- **Hybrid architecture** — Command layer on Claude Code, worker layer CLI-agnostic
- **Community-contributed CLI adapters** — Thanks to [@yuto-ts](https://github.com/yuto-ts), [@circlemouth](https://github.com/circlemouth), [@koba6316](https://github.com/koba6316)

<details>
<summary><b>v2.0</b></summary>

- ntfy bidirectional communication
- SayTask notifications (streaks, Eat the Frog)
- Pane border task display
- Shout mode
- Agent self-watch + 3-phase escalation
- Agent self-identification (`@agent_id`)
- Battle mode (`-k` flag)
- Task dependency system (`blockedBy`)

</details>

---

## Contributing

Issues and pull requests are welcome.

- **Bug reports**: Open an issue with reproduction steps
- **Feature ideas**: Open a discussion first
- **Skills**: Skills are personal by design and not included in this repo

## Credits

Based on [Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication) by Akira-Papa.

## License

[MIT](LICENSE)

---

<div align="center">

**One command. Eight agents. Zero coordination cost.**

Star this repo if you find it useful — it helps others discover it.

</div>
