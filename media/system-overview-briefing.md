# Monet Personal AI Assistant: Comprehensive Briefing

## Executive Summary

Monet is a hardened, self-hostable personal AI assistant architecture designed for single-user operation on a Linux host. It functions by driving the Claude Code CLI as a subprocess, utilizing the model's reasoning capabilities to interact with local files, history, and tools. The system is accessible primarily via Telegram, with optional outbound SMS capabilities.

The architecture emphasizes persistent, context-aware intelligence through a two-layer memory system—combining local file-based "hot context" with a deep Qdrant vector-memory backend. Beyond conversational interaction, Monet manages automated workflows, including scheduled briefings, "skill-harvesting" loops, and reminder systems. Security is foundational to the design, employing a "deny-by-default" command surface, a single-chat-ID authorization model, and a pre-LLM prompt-injection filter.

## System Architecture and Service Topology

Monet is optimized for single-host deployment to ensure data remains within a controlled perimeter. All internal service ports are bound strictly to `127.0.0.1`, requiring a reverse proxy (such as nginx) for external communication.

### Core Service Topology

| Component | Execution Method | Port/Binding |
| :--- | :--- | :--- |
| **Management API** | systemd (`monet-api.service`) | 127.0.0.1:8091 |
| **Qdrant (Vector DB)** | Docker | 127.0.0.1:6334 |
| **n8n (Orchestration)** | Docker | 127.0.0.1:5679 |
| **Postgres (n8n DB)** | Docker | Internal only |
| **HTML→Markdown Proxy** | Docker | 127.0.0.1:8090 |
| **Ollama (Embeddings)** | Host Service | 127.0.0.1:11434 |
| **Bot Handlers** | Triggered by n8n/cron | N/A |

### Primary Components
*   **Claude Code CLI:** The central reasoning engine.
*   **Telegram Handler (`bridges/monet-tg.sh`):** A canonical shell script managing session state, image/document handling, and slash command routing.
*   **Management Surface:** A read-only REST API and static HTML dashboard providing insights into system health, usage, and memory statistics.
*   **Memory MCP Server:** A TypeScript-based Model Context Protocol server that exposes memory tools to the Claude engine.

## The Two-Layer Memory Model

Monet's memory system balances immediate operational awareness with long-term historical reference through a tiered approach.

### Layer 1: Hot Context
This layer consists of a project-scoped `MEMORY.md` file loaded automatically by Claude Code. It contains essential "always-on" information:
*   Server identity and connectivity rules.
*   MCP configuration details.
*   Frequently accessed facts required for every interaction.

### Layer 2: Deep Reference (Vector Storage)
Powered by Qdrant and Ollama (`nomic-embed-text`), this layer stores long-term memories, procedures, and session transcripts across 55+ collections.

*   **Hybrid Recall:** Merges BM25 full-text search with vector similarity using Reciprocal Rank Fusion (RRF).
*   **Injection Pipeline:** Injects relevant memories into prompts under a 6,000-character budget.
*   **Polarity Awareness:** Prioritizes corrections and negative feedback (marked with `[!]`) during recall to prevent the persistence of hallucinations.

### Memory Hooks and Maintenance
| Event | Action | Purpose |
| :--- | :--- | :--- |
| **User Prompt** | `prompt-memory-recall.sh` | Performs hybrid search and context injection. |
| **Pre-Tool Use** | `memory-first-gate.sh` | Ensures memory is checked before local file searches. |
| **Session End** | `auto-skill-detect.sh` | Extracts reusable patterns for future use. |
| **Session Resume** | `session-summarize.sh` | Generates a summary of the prior session via `llama3.2:3b`. |

## Operational Automation and Scheduling

System maintenance and recurring tasks are driven by a specialized crontab. The system's "heartbeat" is managed through several scripts:

### Scheduled Jobs (UTC)
| Schedule | Job | Purpose |
| :--- | :--- | :--- |
| Every minute | `monet-watchdog.sh` | Kills stuck processes; manages background jobs. |
| Every minute | `monet-remind.sh` | Delivers due reminders to the user. |
| `BRIEFING_TIME` | `monet-pulse.sh` | **Opt-in** daily briefing (Telegram). |
| 17:00 (every 6h) | `monet-skill-harvest.sh` | Learning/skill-harvest loop. |
| 07:00 | `monet-research-overnight.sh`| Drains the overnight research queue. |
| Weekly (Mon) | `scripts/n8n-cost.py` | Weekly cost and execution digest. |

## Interaction and Command Surface

Monet utilizes a "deny-by-default" command model. Only 17 specific slash commands are supported; all other inputs are treated as natural language conversation.

### Slash Command Reference
| Category | Commands |
| :--- | :--- |
| **Conversation** | `/help`, `/new` (fresh session), `/export` (session summary). |
| **Reminders** | `/remind <time> <msg>`, `/reminders` (list pending). |
| **Clips & Search** | `/clip`, `/clips`, `/find` (semantic search), `/search` (unified). |
| **Bookmarks** | `/mark`, `/marks`, `/recall`. |
| **Utility/Stats** | `/ss` (screenshot URL), `/photo-log`, `/usage`, `/memory-stats`. |

**Note on Background Jobs:** Long-running tasks are automatically detached to `monet-bg-runner.sh` with a 30-minute timeout. Currently, these cannot be queried via slash commands; status must be checked via logs or the file system.

## Security Posture and Hardening

Monet assumes a high-risk environment because the Claude CLI operates with `--dangerously-skip-permissions`, granting it full read/write/execute access to the host at the model's discretion.

### Defensive Layers
1.  **Authorization:** A single-chat-ID allowlist. The system silently drops any communication from unauthorized IDs.
2.  **Inbound Filtering:** A prompt-injection pre-filter scores inbound text before it reaches the Claude model.
3.  **Network Isolation:** All Docker ports are bound to `127.0.0.1`. The recommended nginx configuration drops all non-webhook traffic (Status 444).
4.  **Audit Integrity:** Every turn is recorded in an append-only SQLite audit trail using WAL mode.
5.  **Memory Integrity:** A "Dedup Gate" blocks any new memory storage attempts that have a $\ge 0.92$ similarity score to existing records.

## Key Insights and Important Quotes

### On Security and Host Access
> "Monet drives the Claude Code CLI on your server with `--dangerously-skip-permissions`. It can read and write files and run commands on that machine, without asking you first... The single-chat-id allow-list is the only thing standing between a stranger and a shell."

**Context:** This warning from the documentation emphasizes the critical importance of the `TG_AUTHORIZED_USER_ID` and the risk of deploying on a non-dedicated host.

### On Privacy and Messaging
> "Telegram's docs state bots receive 'all messages from private chats' regardless of privacy mode — it only restricts what a bot sees in group chats. Disabling it grants Monet nothing in a DM and only widens its read access if the bot is ever added to a group."

**Context:** Explains why "Privacy Mode" should remain enabled, debunking common tutorials that suggest disabling it for bot functionality.

### On Memory Reliability
> "Polarity-Aware Injection: Prioritizes corrections and negative feedback (marked with [!]) during recall to prevent hallucination persistence."

**Context:** Highlights the technical mechanism used to ensure that when a user corrects the AI, the correction takes precedence over the original (potentially incorrect) memory.

## Actionable Insights for Administrators

*   **Session Maintenance:** If a channel appears "stuck," administrators should check for `.monet-*.lock` and `.monet-*-state` files. While the watchdog reaps stuck processes every 6 minutes, these files can be cleared manually to force a reset.
*   **Daily Briefing Configuration:** The daily briefing (`monet-pulse.sh`) is empty and disabled by default. It requires the administrator to set `BRIEFING_ENABLED=true` and provide specific topics or prompts, as Monet does not bundle external news or weather feeds.
*   **Memory Management:** Administrators should not touch Qdrant directly. Memory should be managed through the `claude-memory` MCP tools or through n8n workflows that handle tasks like TTL sweeps and hierarchical abstraction.
*   **Hardware Responsibility:** The repository does not provide host-level hardening (Firewall, Fail2Ban, TLS certificates). These must be configured independently by the user to maintain the system's security posture.
*   **Functional Gaps:** Users should be aware that voice notes are not transcribed in this build (unless sent with a caption), and there is no inbound channel for email or SMS; these are outbound-only features.