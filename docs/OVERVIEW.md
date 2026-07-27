# Monet — Overview

Monet is a personal AI assistant that runs on a single hardened VPS and is reachable
over **Telegram** and **SMS**. It is built around the Claude Code CLI, backed by a
persistent vector-memory system (Qdrant + Ollama), n8n workflow orchestration, and a
memory-hooks pipeline that injects relevant context into every conversation.

This repository is the **operational source tree** of that assistant: the bot handlers,
scheduled jobs, memory pipeline, management API, dashboard, MCP server source, and the
Docker/n8n configuration that runs the stack. It is not a library you `pip install` — it
is a deployable system that lives (by convention) at `/opt/monet` on the host.

> Paths below use the default install root `/opt/monet`. Any directory works — set
> `MONET_HOME` to your checkout and substitute it wherever `/opt/monet` appears.

## What it does

- **Telegram chat** — the bot handler forwards inbound messages to Claude Code CLI
  sessions and streams replies back. Text, images, documents, locations, and an
  17-command deny-by-default slash-command allowlist.
- **Persistent memory** — conversations and facts are embedded (Ollama
  `nomic-embed-text`) and stored in Qdrant. A hybrid search pipeline (BM25 + vector,
  merged with Reciprocal Rank Fusion) injects the most relevant memories into each
  prompt, under a fixed token budget, with corrections sorted first.
- **Scheduled automation** — cron-driven jobs deliver an opt-in daily briefing built
  from topics you configure, check reminders every minute, run a learning/skill-harvest
  loop, and produce weekly cost and workflow-health digests.
- **Agent personas (optional, host-side)** — `bin/ask-agent` dispatches questions to
  persona definitions you supply in `$MONET_AGENTS_DIR`. None are bundled, and no
  Telegram command depends on them.
- **Management surface** — a read-only REST API and a static dashboard expose health,
  sessions, audit history, usage, and memory statistics.

## High-level architecture

```
              Telegram Bot API
                       │
                       ▼
              nginx (TLS, drops non-webhook traffic)
                       │
                       ▼
        api/monet_webhook.py  (or n8n workflow entry point)
                       │
                       ▼
        bridges/monet-tg.sh
          → Claude Code CLI sessions
          → memory-hooks pipeline
          → SQLite audit trail
                       │
        ┌──────────────┼───────────────┐
        ▼              ▼                ▼
     Qdrant         Ollama          n8n + REST API
   (vectors)     (embeddings)      (orchestration /
                                    management)
```

## Core components

| Area | Path | What it is |
|------|------|------------|
| Telegram handler | `bridges/monet-tg.sh` | The single canonical bot handler. Session resume/fresh fallback, `flock` locking, turn limits and compaction, and routing for the 17-command allowlist. |
| Background runner | `monet-bg-runner.sh` | Detached executor for long-running jobs (30-minute timeout). |
| Watchdog | `monet-watchdog.sh` | Kills stuck sessions and manages background-job lifecycle. |
| Scheduled jobs | `monet-pulse.sh`, `monet-remind.sh`, `monet-cron.sh`, `scripts/*` | Opt-in daily briefing, reminders, agent-scheduled jobs, cost/health digests. |
| Memory hooks | `claude/scripts/` | Per-prompt recall, memory-first gate, cross-channel linking, session summarization, skill detection. |
| Management API | `api/monet_api.py` | Read-only REST API (port 8091, bearer auth). |
| Dashboard | `dashboard/index.html` | Static SPA consuming the API. |
| Memory MCP server | `mcp/claude-memory-mcp/` | TypeScript MCP server exposing Qdrant/Ollama memory tools. |
| Shared libraries | `lib/` | Audit trail, prompt-injection filter, unified search, clip store, path safety. |
| Infrastructure | `docker/`, `n8n/workflows/` | Qdrant + n8n + Postgres compose, an HTML→Markdown proxy, and n8n workflow exports. |
| CLI tools | `bin/` | `ask-agent`, `ask-n8n-*`, `google`, `reindex-obsidian`, and others. Host-side only — none backs a Telegram command. |

## Memory model

Monet uses a two-layer memory design:

- **Layer 1 — file-based hot context**: a small project-scoped memory file loaded every
  session (server identity, connectivity rules, frequently accessed facts).
- **Layer 2 — Qdrant vector storage**: the deep reference store (long-term memories,
  short-term/working memory, learnings, procedures, trajectories, episodes, and
  Telegram session transcripts), searched with the hybrid recall pipeline.

See [HOW-TO-USE.md](HOW-TO-USE.md) for day-to-day usage, [INSTALL.md](INSTALL.md) for
deployment, and [ADMINISTRATOR.md](ADMINISTRATOR.md) for operations. The dependency
inventory is in [SBOM.md](SBOM.md) and the latest security scan in
[scan/scan-report.md](scan/scan-report.md).

> Note on scope: this repository documents the components that ship in the tree. Some
> runtime pieces referenced by the handlers (for example the Twilio SMS relay and the
> outbound e-mail relay) are host-specific and are configured via environment variables
> rather than shipped as code.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
