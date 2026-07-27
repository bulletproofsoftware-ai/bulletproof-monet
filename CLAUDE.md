# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This repository is **bulletproof-monet**, a self-hostable personal assistant that runs on a single Linux host and is reachable over Telegram. The install root is `$MONET_HOME` (defaults to this checkout; historically `/opt/monet`). Monet drives the Claude Code CLI as a subprocess — the scripts here build prompts, manage sessions, and deliver results; the intelligence is the `claude` binary.

It is a single-user system: authorization is one Telegram chat id, and the handlers invoke `claude` with `--dangerously-skip-permissions`. Treat any change to the authorization path or the prompt-injection filter as security-critical.

## Architecture

Telegram POSTs a webhook to nginx, which proxies the single webhook path to `api/monet_webhook.py` on `127.0.0.1:8093`. That receiver enforces the chat-id allow-list, runs the injection pre-filter, and hands off to the bot handler, which drives a `claude` session and delivers the reply. Long tasks detach to a background runner. Supporting services (Qdrant, Ollama, n8n, Postgres) all bind to localhost.

### Core scripts (all relative to `$MONET_HOME`)

| Script | Purpose |
|--------|---------|
| `bridges/monet-tg.sh` | Telegram bot handler — the single canonical copy. Text, images, docs, and the 17-command allowlist. Manages Claude sessions with resume/fresh fallback, turn limits (40), compaction, typing indicators. Carries the prompt-injection gate and the audit-log call sites; treat both as security-critical. |
| `monet-dispatch.sh` | Decides inline vs. background execution for a turn. Honors `MONET_INLINE_TIMEOUT` and `MONET_ASYNC_DEFAULT`. |
| `monet-bg-runner.sh` | Detached background job executor, invoked via nohup for long-running tasks (30min timeout). Jobs stored in `bg-jobs/`. |
| `monet-pulse.sh` | Daily briefing generator. Runs via cron, delivers via Telegram. Driven entirely by the `BRIEFING_*` variables; ships disabled and empty. |
| `monet-remind.sh` | Cron-based reminder checker (every minute). Reads `reminders.json`, delivers due reminders via Telegram. |
| `monet-schedule.sh` | Create/list/remove recurring agent jobs that run unattended and deliver output to a chat. |
| `monet-watchdog.sh` | Kills stuck monet/claude processes (6min threshold), manages background job lifecycle. |
| `monet-voice.sh` / `monet-tts.sh` | Spoken output via `edge-tts` (Microsoft Edge's free neural voices — no API key, no account). Gated on `TTS_ENABLED`, which ships off. Install the CLI from `requirements-tts.txt`. |

> **Email and SMS are implemented but unconfigured by default.** The system prompt in `bridges/monet-tg.sh` tells the model to execute `$MONET_HOME/send-email.sh` and `$MONET_HOME/send-sms.sh`; both ship in this tree. Each prints exactly `OK` or `ERROR: <reason>` and exits non-zero when its credentials are unset, so an unconfigured install degrades to a clear error rather than a silent failure. Recipient and body arrive from model output, so both scripts validate before sending: email rejects CR/LF in the recipient and subject (header injection) and requires a well-formed address; SMS requires E.164. Credentials reach `python3`/`curl` via the environment and a stdin config respectively, never as argv, so they stay out of the process table.

> **The command surface is deny by default.** 17 commands, enumerated in exactly two places: `scripts/tg-register-commands.sh` and the `/help` handler in `bridges/monet-tg.sh`. They must stay in sync. Adding a command means adding it to BOTH; adding it to only one is a bug. Do not reintroduce commands backed by third-party APIs — this tree deliberately ships none.

### Session management pattern

1. Lock file prevents concurrent execution (`flock`)
2. State file tracks session ID, last activity timestamp, turn count
3. Session timeout (5min inactivity) triggers new session
4. Resume existing session first, fall back to fresh session on failure
5. Compaction at turn thresholds to manage context window

### Support components

| Path | Purpose |
|------|---------|
| `api/monet_webhook.py` | Telegram webhook receiver (`127.0.0.1:8093`). Chat-id allow-list via `MONET_AUTHORIZED_CHAT`, injection pre-filter, `/healthz`. The actual entry point. |
| `api/monet_api.py` | REST management API (port 8091). Read-only: `/health`, `/sessions`, `/audit`, `/usage`, `/usage/today`, `/memory/stats`, `/cron`, `/stats`. Bearer token auth. |
| `api/tg_ui.py` | Telegram UI helpers (keyboards, force-reply). |
| `dashboard/index.html` | Web dashboard consuming the API |
| `bin/` | Standalone CLI tools, none of which back a Telegram command — `ask-agent` (dispatcher for personas you supply), `ask-n8n-*` (n8n helpers), `google`/`gemini` (search wrappers), `reindex-obsidian`, `critic`, `tone-check`, `monet-graph` |
| `bridges/` | Handler entry points used by n8n and by `api/monet_webhook.py`. `bridges/monet-tg.sh` is the canonical router — there is no second copy. |
| `lib/` | Shared libraries — `monet-env.sh` (env + path resolution), `monet_paths.py`, `audit.py`, `audit_helpers.sh`, `injection_filter.py`, `unified_search.py`, `clip_helper.py`, `safe_paths.py` |
| `deploy/` | `register-webhook.sh`, `smoke-test.sh`, `nginx/monet.conf.template` |
| `install.sh` | 17-step installer. `--check` is the no-credential, no-network-write CI mode. |
| `src/` | Queue/worker variants of the dispatch path and their systemd unit templates |
| `docker/` | Per-service compose fragments, included by the top-level `docker-compose.yml` |

### MCP servers (optional integrations)

Only `claude-memory` ships in this repository, as TypeScript source under `mcp/claude-memory-mcp/`. The rest are servers the assistant can use if you configure them yourself in your own Claude Code MCP config.

| Server | Status |
|--------|--------|
| `claude-memory` | **Bundled** — source in `mcp/claude-memory-mcp/`. Qdrant + Ollama vector memory. |
| `n8n-mcp` | Not bundled — configure yourself |
| `gdrive` | Not bundled — configure yourself |
| `youtube-transcript` | Not bundled — configure yourself |
| `playwright` | Not bundled — configure yourself |

### Hooks

Hook scripts ship in `claude/scripts/` and are wired up by `claude/settings.json.template`, which `install.sh` renders. Only scripts that exist in the tree are listed here.

| Event | Script | Purpose |
|-------|--------|---------|
| UserPromptSubmit | `claude/scripts/prompt-memory-recall.sh` | Injects recalled memory context per prompt |
| PreToolUse (Grep/Glob) | `claude/scripts/memory-first-gate.sh` | Enforces memory-before-search rule |
| Session resume | `claude/scripts/session-summarize.sh` | LLM summarization of the prior session |
| Session | `claude/scripts/session-nudge.sh` | Periodic re-injection of standing rules (`MONET_NUDGE_EVERY`) |
| Channel switch | `claude/scripts/cross-channel-link.sh` | Links sessions across channels (30min window) |
| Skill detection | `claude/scripts/auto-skill-detect.sh`, `claude/scripts/skill-usage-hook.sh` | Detects and scores reusable patterns |
| Context guard | `claude/scripts/context-guard/*.sh` | Context budget counter, warning, pre-compact, statusline |

### Agents and skills

`bin/ask-agent` dispatches to agent personas in `$MONET_AGENTS_DIR`. Those persona definitions are **not bundled** — set `MONET_AGENTS_DIR` to your own directory of agent markdown files, or leave it unset and the tool is a no-op. `bin/ask-ref` and `bin/skill-review` work the same way against `$MONET_SKILLS_DIR`. None of these back a Telegram command; they are host-side CLI tools only.

## Commands

```bash
# Verify the checkout is installable (no credentials, no network writes)
./install.sh --check

# Service health
docker compose ps
curl -s http://localhost:11434/api/tags       # Ollama models
curl -s http://localhost:8091/health          # management API

# Memory MCP rebuild
cd mcp/claude-memory-mcp && npm run build

# Webhook lifecycle
./deploy/register-webhook.sh --info
./deploy/smoke-test.sh --local-only

# Telegram bot test (direct invocation)
"$MONET_HOME"/bridges/monet-tg.sh "test message" "" "$MONET_CHAT_ID"
```

## Environment variables

`.env.example` is the complete, authoritative list — it documents every variable the code reads, grouped by required / generated / optional, and records how the list was derived so it can be re-verified. `lib/monet-env.sh` loads `.env` and resolves paths; `lib/monet_paths.py` is the Python equivalent.

The four you must supply by hand: `BOT_TOKEN`, `TG_AUTHORIZED_USER_ID`, `MONET_CHAT_ID`, `MONET_PUBLIC_URL`. Note that `api/monet_webhook.py` reads `MONET_AUTHORIZED_CHAT` for its allow-list, not `TG_AUTHORIZED_USER_ID` — set both to the same id.

## File conventions

- Lock files: `.monet-*.lock` (flock-based, prevents concurrent execution)
- State files: `.monet-*-state` (session tracking: `session_id|timestamp|turn_count`)
- Logs: JSON-structured to `$MONET_LOG_DIR` (defaults to `logs/` under `$MONET_HOME`). Do not write to `/var/log` — the service account is unprivileged.
- Screenshots: `/ss` writes to `/var/www/screenshots/` and emits the public URL wrapped in `[IMG]...[/IMG]` markers. For delivery to work that directory must be served over HTTP by your web server.
- Background jobs: `bg-jobs/<job-id>/` (prompt, output, metadata files)
- Paths in templates: files that cannot do shell expansion (`*.service.template`, `cron/monet-crontab.example`, `claude/settings.json.template`, n8n workflow JSON) carry an `@MONET_HOME@` token that `install.sh` substitutes.

## Memory architecture (two-layer system)

### Layer 1: file-based memory (MEMORY.md — hot context)

Claude Code keeps project-scoped auto-memory under `$MONET_CLAUDE_HOME/projects/<slug>/memory/MEMORY.md`, where `<slug>` is derived from the absolute path of `$MONET_HOME` (path separators become dashes). Do not hardcode a slug — resolve it from the current install root.

- Loaded automatically every session via native Claude Code auto-memory
- **Line limit**: 200 lines visible to context (lines after 200 are truncated)
- **What goes here**: frequently accessed facts, enforced rules, connectivity info — anything needed almost every session
- **What does NOT go here**: procedures, trajectories, deep reference material — those go in Qdrant

### Layer 2: Qdrant vector storage (deep reference)

Qdrant runs locally in Docker at `$QDRANT_URL` (default `http://localhost:6334`, mapped from container port 6333). API key required.

**Primary collections** (operational):

| Collection | Purpose |
|-----------|---------|
| `claude_memories` | Long-term general memories (main store) |
| `short_term_memory` | Session-scoped working context |
| `working_memory` | Active task context |
| `learnings` | Reusable patterns and insights |
| `procedures` | Step-by-step operational procedures |
| `trajectories` | Multi-step success paths |
| `episodes` | Session episode summaries |
| `tg_sessions` | Telegram session transcripts |

**Embedding**: Ollama `$EMBED_MODEL` (default `nomic-embed-text`) at `$OLLAMA_URL`.

### Memory MCP tools

Available via the `claude-memory` MCP server (source in `mcp/claude-memory-mcp/`):

`memory_recall` (semantic search; `limit` must be an integer, not a string), `memory_store` (auto-deduped), `memory_boost`, `memory_impact`, `memory_forget`, `memory_prune`, `memory_organize`, `memory_consolidate`, `memory_verify`, `memory_trace`, plus `procedure`, `trajectory`, `learning`, and `episode`.

### Memory hooks

Memory hooks are optional. If you run the `claude-memory` MCP server, the scripts in `claude/scripts/` inject recalled context per prompt and enforce the memory-first rule. With no MCP server configured, the hooks degrade to no-ops.

### Memory-first rule (CRITICAL)

Before exploring files or spawning agents, call `memory_recall` first. The `memory-first-gate.sh` hook enforces this for Grep/Glob — if you haven't recalled memory yet, the gate blocks file searches.

### Qdrant access (ENFORCED)

**Never curl Qdrant directly for memory queries.** Always use the `memory_recall` MCP tool — the MCP server handles authentication, embedding, and scoring automatically. Direct HTTP to `$QDRANT_URL` fails without the API key and is the wrong approach.

For health/collection debugging only:

```bash
curl -s -H "api-key: $QDRANT_API_KEY" "$QDRANT_URL/collections"
```
