# Pownie

A Claude Code plugin that gives your agent structured attack methodology, persistent memory across context compactions, multi-agent coordination, and full observability, all backed by a Neo4j knowledge graph.

Battle-tested through hundreds of Hack The Box machines, contributing to a **Top #100 global ranking** on the platform.
<img src="https://d0gesec.dev/ranking.png" alt="htb-hall-of-fame" width="300">

---

## ⚠️ Required MCP Servers

**This plugin does not work standalone.** It requires a specific MCP server stack to function. Don't worry, just run `./setup.sh` and it builds and starts everything for you.

| MCP Server | Purpose | Required |
|------------|---------|----------|
| [**mcp-kali**](https://github.com/d0gesec/mcp-kali) | Kali Linux command execution, sessions, background tasks, proxy | **Yes** |
| **neo4j-mcp** | Knowledge graph for attack state, credentials, attempt tracking | **Yes** |
| **playwright** | Browser automation with headed Chromium + noVNC | Optional |

---

## ✨ What the Plugin Adds

| Component | What It Does |
|-----------|--------------|
| **Intel Graph** | Neo4j-backed knowledge graph — tracks targets, credentials, services, vulnerabilities, shells, and flags as structured data that survives context compaction |
| **Pre/Post Hooks** | Automatic tracing on every Kali MCP call — logs commands to Neo4j, extracts credentials and services from output, surfaces prior attempts before execution |
| **Strategic Compaction** | Context management for long offsec sessions — phase-aware compaction with Neo4j state preservation and rich recovery files |
| **Multi-Agent Orchestration** | Spawns parallel teammates after recon or shell access — CVE scouts, code analysts, system enumerators working concurrently |
| **Debrief & Writeup** | Post-challenge writeup generation with structured failure analysis and MEMORY.md updates |

---

## 🚀 Quick Start

### Prerequisites

- Docker (with Docker Compose)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v1.0.33+

### 1. Clone and setup the stack

```bash
git clone https://github.com/d0gesec/pownie.git
cd pownie
./setup.sh
```

The setup wizard will:
- Ask which optional services to enable (browser, telemetry)
- Detect container name conflicts and offer alternatives
- Generate `docker-compose.yml`, `.mcp.json`, and `.claude/settings.local.json`
- Build Docker images and start the stack
- Wait for Neo4j to be healthy

### 2. Install the plugin

**Option A — Marketplace install:**

```shell
/plugin marketplace add d0gesec/pownie
/plugin install pownie@d0gesec
```

**Option B — Direct from cloned repo:**

```bash
claude --plugin-dir ./pownie
```

### 3. Start hacking

The plugin activates automatically. Skills like the intel graph and strategic compaction work in the background. User-invocable skills:

- `/pownie:offsec-debrief` — generate writeup after completing a challenge

---

## 🔧 Setup Options

```bash
./setup.sh              # interactive — choose components
./setup.sh --all        # everything (browser + telemetry)
./setup.sh --core-only  # just kali + neo4j
./setup.sh --bare       # bare Kali/Linux mode (no mcp-kali container)
./setup.sh --down       # stop containers

./cleanup.sh            # stop containers, keep data
./cleanup.sh --volumes  # also wipe neo4j data and workspace
./cleanup.sh --full     # remove everything including generated files
```

### Custom prefix

If you already have `pownie-*` containers running (e.g. from another project), setup detects the conflict and asks for an alternative prefix:

```
! Existing containers found using prefix 'pownie':
  pownie-kali                    (running)
  pownie-neo4j                   (running)

? Choose a different prefix (or press Enter to use 'pownie' anyway): pownie-dev
✓ Using prefix: pownie-dev
```

All generated files — compose, `.mcp.json`, hooks — will use the chosen prefix.

### Bare mode

If you're running Claude Code directly on a Kali/Linux machine instead of through mcp-kali containers:

```bash
./setup.sh --bare
```

This skips the kali container, sets hook matchers to fire on `Bash` tool calls, and only spins up Neo4j in Docker. You still get the full intel graph, strategic compaction, and all skills.

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────┐
│  Claude Code + pownie plugin                        │
│                                                     │
│  skills/          hooks/           .mcp.json        │
│  ├─ intel-graph   ├─ PreToolUse    ├─ kali (stdio)  │
│  ├─ compact       ├─ PostToolUse   ├─ neo4j (stdio) │
│  ├─ offsec-lead   └─ PreCompact    └─ playwright    │
│  ├─ debrief                            (http)       │
│  └─ debrief                                         │
└──────────┬──────────────┬──────────────┬────────────┘
           │              │              │
     ┌─────▼─────┐  ┌────▼────┐  ┌──────▼──────┐
     │ pownie-   │  │ pownie- │  │  pownie-     │
     │ kali      │  │ neo4j   │  │  playwright  │
     │           │  │         │  │              │
     │ mcp-kali  │  │ neo4j   │  │ @playwright/ │
     │ server    │  │ + mcp   │  │ mcp + noVNC  │
     │ 1000+     │  │ bolt    │  │              │
     │ sec tools │  │ :7687   │  │ :3888 :6080  │
     └───────────┘  └─────────┘  └──────────────┘
```

### How the hooks work

Every Kali MCP tool call flows through the hook pipeline:

1. **PreToolUse** (`pre-exec.sh`) — queries Neo4j for prior attempts, known credentials, disproven attack classes, and active strategies on the target IP. Surfaces this as context so the agent avoids repeating failed approaches.

2. **Agent executes command** via mcp-kali

3. **PostToolUse** (`post-exec.sh`) — logs the command and result to Neo4j, auto-extracts credentials and services from output, prompts for phase classification, detects shell acquisition and repeated failures.

4. **PreCompact** (`pre-compact-save.sh`) — before any context compaction, queries Neo4j and writes a rich `compact-state.md` with targets, credentials, failed attempts, and command history for post-compaction recovery.

---

## 🗃️ Plugin Structure

```
pownie/
├── .claude-plugin/
│   └── plugin.json              # plugin manifest
├── skills/
│   ├── offsec-intel-graph/      # neo4j knowledge graph schema + usage
│   │   ├── preToolUse/pre-exec.sh  # pre-execution context retrieval
│   │   └── postToolUse/post-exec.sh # post-execution logging + intel extraction
│   ├── strategy-compact/        # context compaction strategy
│   │   └── pre-compact-save.sh  # neo4j state snapshot before compaction
│   ├── offsec-lead/             # multi-agent orchestrator
│   └── offsec-debrief/          # writeup generation
├── hooks/
│   └── hooks.json               # event hook wiring
├── docker/                      # build-from-source Dockerfiles
│   ├── Dockerfile.kali
│   ├── Dockerfile.neo4j
│   ├── Dockerfile.playwright
│   └── ...
├── setup.sh                     # interactive setup wizard
├── cleanup.sh                   # teardown script
├── LICENSE
└── README.md
```

Generated at runtime by `setup.sh` (gitignored):
- `docker-compose.yml`
- `.mcp.json`
- `.claude/settings.local.json`

---

## 🔍 Telemetry (Optional)

Enable the telemetry profile during setup to get Grafana + Tempo for trace visualization. Useful for debugging skills and hooks during development.

```bash
./setup.sh  # answer 'y' to "Enable trace viewer"
```

Then open Grafana at `http://localhost:3000` → Explore → Tempo → search by `service.name = pownie-pre-hook`.

The hooks emit OTLP spans for every Kali MCP call regardless — telemetry just gives you a UI to browse them. Without it, spans are silently dropped with zero impact on functionality.

---

## ⚠️ Disclaimer

This project is shared for **educational and authorized security testing purposes only**. It orchestrates unrestricted command execution inside a Kali Linux container — use it responsibly and at your own risk. The authors assume no liability for misuse. Always ensure you have proper authorization before testing any target.

---

## 📄 License

MIT
