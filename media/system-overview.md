# bulletproof-monet Technical Briefing Report

### 1. System Overview and Core Purpose
`bulletproof-monet` is a hardened, personal AI assistant architecture designed for deployment on a single Linux Virtual Private Server (VPS). The system functions as a persistent, context-aware interface accessible via Telegram, utilizing the **Claude Code CLI** as its primary reasoning and execution engine. 

High-level capabilities include:
*   **Multi-Channel Interaction**: Full support for text, images (auto-tagged via Gemini), voice notes (transcribed), documents, and location data.
*   **Two-Layer Persistent Memory**: Integration of a local file-based hot context and a deep Qdrant vector-memory backend.
*   **Automated Workflows**: A suite of cron-driven jobs for an opt-in daily briefing, financial monitoring, and "skill-harvesting" loops.
*   **Optional Agent Library**: `bin/ask-agent` dispatches to persona definitions you supply in `$MONET_AGENTS_DIR`. None ship with the repository.

> This repository serves as the **operational source tree** for the assistant. It contains the primary bot handlers, scheduled automation logic, memory pipeline hooks, management API, static dashboard, and the Model Context Protocol (MCP) server source. It is a deployable system intended to reside at `/opt/monet`.

---

### 2. Architecture and Service Topology
The system is optimized for a **Single-Host** deployment, ensuring all data remains within a hardened perimeter. The **Claude Code CLI** serves as the core binary engine, driven by shell-based handlers that manage session state and context injection.

#### Service Topology
| Component | How it runs | Port |
| :--- | :--- | :--- |
| Management API (`monet_api.py`) | systemd (`monet-api.service`) | 127.0.0.1:8091 |
| Qdrant | Docker (`docker/claude-memory`) | 127.0.0.1:6334 |
| n8n | Docker (`docker/claude-memory`) | 127.0.0.1:5679 |
| Postgres | Docker (`docker/claude-memory`) | Internal |
| HTML→Markdown proxy | Docker (`docker/markdown-for-agents`) | 127.0.0.1:8090 |
| Ollama | Host Service | 127.0.0.1:11434 |
| Bot Handlers | Invoked per-message by n8n / cron | N/A |

#### Docker Stack Configuration
| Service | Host binding | Container port |
| :--- | :--- | :--- |
| Qdrant | 127.0.0.1:6334 | 6333 |
| n8n | 127.0.0.1:5679 | 5678 |
| Postgres | Internal only | 5432 |

---

### 3. Functional Core Components
The system distributes logic across specialized shell scripts and a conductor CLI to manage the lifecycle of AI sessions.

*   **Bot Handlers (`monet-tg.sh` and `monet-sms.sh`)**: The Telegram handler is a **58K shell script** that manages complex interactions including images and voice. Both handlers implement `flock`-based locking to prevent race conditions and use state files to track session IDs and turn counts. They support session resumption with context compaction at 15 and 30 turns, enforcing a hard limit of 40 turns.
*   **Auxiliary Scripts**:
    *   `monet-bg-runner.sh`: A detached executor for long-running background tasks with a 30-minute timeout.
    *   `monet-watchdog.sh`: A maintenance utility that reaps "stuck" Claude processes (6-minute threshold) and manages background job state.
*   **Conductor CLI (`ask-agent`)**: A host-side binary that dispatches queries to whatever agent personas you place in `$MONET_AGENTS_DIR`, without maintaining a full chat session. Not wired to any Telegram command.

---

### 4. The Two-Layer Memory System
The architecture employs a tiered memory model to balance immediate operational awareness with deep historical reference.

#### Layer 1: Hot Context
Utilizes a project-scoped `MEMORY.md` file loaded automatically by Claude Code. This contains the server's identity, connectivity rules, MCP configuration "gotchas," and frequently accessed facts required for every turn.

#### Layer 2: Deep Reference
Powered by a Qdrant vector database containing **55+ collections**, including `claude_memories`, `world_model`, `digital_twin`, `trajectories`, and `episodes`.
*   **Embedding Model**: Ollama `nomic-embed-text` (persistent).
*   **Generation Model**: Ollama `llama3.2:3b` (used for summarization and skill detection).
*   **MCP Server**: Exposes **60+ tools** (e.g., `memory_boost`, `memory_trace`, `procedure`, `context_budget`) to the Claude engine.

#### Memory Hooks Pipeline
| Event | Script | Purpose |
| :--- | :--- | :--- |
| UserPromptSubmit | `prompt-memory-recall.sh` | Hybrid search (BM25 + Vector) with a **6000-character injection limit**. |
| PreToolUse (Grep/Glob) | `memory-first-gate.sh` | Blocks local file searches until memory recall is verified. |
| Session End | `auto-skill-detect.sh` | Extracts reusable patterns from "pheromone trails" in Qdrant. |
| Session Resume | `session-summarize.sh` | Generates an LLM summary of the prior session via `llama3.2:3b`. |
| Channel Switch | `cross-channel-link.sh` | Links Telegram and SMS sessions within a 30-minute window. |

#### Memory Search Features
*   **Hybrid Search**: Merges BM25 full-text results with vector similarity using Reciprocal Rank Fusion (RRF).
*   **Polarity-Aware Injection**: Prioritizes corrections and negative feedback (marked with `[!]`) during recall to prevent hallucination persistence.

---

### 5. Interaction and Usage Models
Interactions are routed through natural language or a structured set of slash commands.

#### Slash Command Reference

The command surface is **deny by default** — these 18 are all of it, and every one runs
against local data with no third-party API key. Anything else is ordinary conversation.

**Conversation**
| Command | Description |
| :--- | :--- |
| /help | List every command. |
| /new | Start a fresh conversation session. |
| /export | Export the current session as a summary. |

**Reminders**
| Command | Description |
| :--- | :--- |
| /remind `<time> <msg>` | Set a reminder. |
| /reminders | List pending reminders. |

**Clips, Bookmarks & Search**
| Command | Description |
| :--- | :--- |
| /clip `<tag> <content>` · /clips `[tag]` | Save and list tagged snippets. |
| /find `<query>` | Semantic search across clips. |
| /mark `<label>` · /marks · /recall `<label>` | Bookmark, list, and retrieve conversation moments. |
| /search `<query>` | Unified search across local data. |
| /memory-stats · /memory-export | Memory backend statistics and export. |

**Utilities**
| Command | Description |
| :--- | :--- |
| /ss `<url>` | Screenshot a URL. |
| /photo-log | Auto-archived photo analyses. |
| /usage | View 7-day token consumption and spend. |

#### Reminders vs. Scheduled Jobs
*   **Reminders**: Time-based triggers that echo a fixed user message at a specific UTC time.
*   **Scheduled Jobs**: Recursive AI tasks (e.g., a daily threat brief) that execute a fresh prompt and deliver generated results.

#### Agent Personas (optional, host-side)
`bin/ask-agent` dispatches to persona definitions in `$MONET_AGENTS_DIR`. **None are
bundled** — supply your own directory of agent markdown files, or leave the variable
unset and the tool is a no-op. No Telegram command depends on it.

---

### 6. Operational Automation (Cron & API)
The system's "heartbeat" is maintained via a comprehensive crontab and a Management API.

#### Scheduled Jobs
| Schedule (UTC) | Job Name | Purpose |
| :--- | :--- | :--- |
| Every minute | `monet-watchdog.sh` | Reaps stuck processes; manages BG jobs. |
| Every minute | `monet-cron.sh` | Executes agent-scheduled recursive jobs. |
| `BRIEFING_TIME` | `monet-pulse.sh` | Delivers the daily briefing to Telegram. Opt-in; disabled and empty by default. |
| 17:00 (6h) | `monet-skill-harvest.sh` | Triggers the learning/skill-harvesting loop. |
| 07:00 | `monet-research-overnight.sh` | Drains the overnight research queue. |
| 08:30 | `scripts/skill-score.py` | Nightly skill-usage aggregation. |
| 13:15 (Mon) | `scripts/n8n-cost.py` | Weekly execution-cost digest. |
| 13:30 (Mon) | `scripts/n8n-dead.py` | Detects dead or failing workflows. |

#### Management API (Port 8091)
| Endpoint | Method | Description |
| :--- | :--- | :--- |
| `/health` | GET | Service uptime and dependency status. |
| `/audit` | GET | Filterable audit logs (SQLite WAL-mode). |
| `/usage` | GET | 7-day usage history and breakdown. |
| `/memory/stats` | GET | Qdrant collection point counts and sizes. |

---

### 7. Security Posture and Hardening
`bulletproof-monet` employs a multi-layered defense-in-depth strategy:
*   **Network Hardening**: All Docker ports are bound strictly to `127.0.0.1`. The Nginx frontend is configured to drop all non-webhook traffic (Status 444). Host-level hardening — firewall, fail2ban, intrusion detection — is the deployer's responsibility; this repository installs none of it.
*   **Authentication**: Telegram access is restricted via User-ID allowlist; SMS requires sender authentication. The Management API is protected by a bearer token.
*   **Integrity and Audit**: All actions are logged to an append-only SQLite audit trail.
*   **Inbound Filtering**: A pre-LLM injection filter scores content severity. A **Memory Dedup Gate** blocks any storage attempt with a similarity score ≥ 0.92 to existing records.
*   **Compliance**: The system maintains a **0 critical / 0 high** vulnerability status across automated security scans.

---

### 8. Installation and Deployment Summary
The system is deployed under the `/opt/monet` directory on a Linux VPS (RHEL-family/AlmaLinux recommended).

#### Deployment Sequence
1.  **Clone Source**: Place the tree in `/opt/monet`.
2.  **Environment Setup**: Configure `.env` with API keys and authorized IDs.
3.  **Docker Init**: Launch the Qdrant/n8n/Postgres stack via Docker Compose.
4.  **Model Pull**: Pull `nomic-embed-text` and `llama3.2:3b` via Ollama.
5.  **Build MCP**: Compile the `claude-memory-mcp` TypeScript server.
6.  **DB Init**: Initialize the SQLite audit database.
7.  **Service Start**: Enable and start `monet-api.service`.
8.  **Cron Install**: Apply the production schedule from `crontab.txt`.
9.  **Workflow Import**: Configure n8n Telegram/SMS bridge workflows.
10. **Verification**: Execute `scripts/health-check.sh` and `server-status.sh` to confirm service orchestration.

---

### 9. Troubleshooting and Maintenance

#### Operational Troubleshooting
| Symptom | Check |
| :--- | :--- |
| Bot non-responsive | Tail `/var/log/monet-tg.log`; check `BOT_TOKEN` and n8n status. |
| Session "stuck" | Inspect `.monet-*.lock` or state files; clear manually if watchdog hasn't reaped. |
| Empty memory recall | Verify Qdrant is active and `nomic-embed-text` is loaded in Ollama. |
| MCP tools missing | **Rebuild `mcp/claude-memory-mcp`** and re-register with Claude Code. |
| API 401 Unauthorized | Confirm `MONET_API_KEY` matches the bearer token in the request header. |

#### Session Integrity
The system uses a five-minute inactivity rule to trigger fresh sessions. Administrators should monitor the `.monet-*-state` files (format: `session_id|timestamp|turn_count`) to track real-time activity. If the 30-minute background job threshold or 6-minute watchdog threshold is exceeded, the system will automatically terminate the process to maintain host stability.