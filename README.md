# Monet

Monet is a self-hostable personal assistant that runs on one Linux host and is reachable over Telegram. It drives the Claude Code CLI as a subprocess: the scripts here build prompts, manage conversation sessions, run scheduled jobs, and deliver results — the intelligence is the `claude` binary you already have a subscription to. It is a single-user system by design, locked to one Telegram chat id. Beyond your existing Claude subscription and a VPS, it costs nothing to run: every bundled service (Qdrant, Ollama, n8n, Postgres) is open source and runs locally.

> Full documentation in [`docs/`](docs/) · security scan in [`docs/scan/scan-report.md`](docs/scan/scan-report.md) · system overview: [briefing](media/system-overview.md).

## What you get

- **A Telegram bot that is actually you.** Text, photos, and documents go in; Claude Code answers with your files, your history, and your tools in context.
- **Persistent memory across sessions.** A Qdrant vector store plus Ollama embeddings, wired into Claude Code as an MCP server, so the assistant remembers what you told it last week.
- **Background jobs.** Long tasks detach and deliver the result to your chat when they finish, instead of timing out mid-turn.
- **Scheduled work.** An opt-in daily briefing built from topics you choose, plus reminders and recurring agent jobs that run unattended and message you the output.
- **A management API and dashboard.** Bearer-authenticated read-only endpoints for health, sessions, audit log, and token usage, bound to localhost.
- **An audit trail.** Every turn is recorded to an append-only SQLite log, and inbound text passes a prompt-injection pre-filter before it reaches the model.

> [!WARNING]
> **Read this before you install.** Monet drives the Claude Code CLI on your server with `--dangerously-skip-permissions`. It can read and write files and run commands on that machine, without asking you first, at the direction of whoever is messaging the bot. Run it on a host you are willing to give an assistant that much access to — a dedicated VPS, not your workstation and not a machine holding other people's data. The single-chat-id allow-list is the only thing standing between a stranger and a shell.

## Requirements

Derived from `install.sh` preflight — run `./install.sh --check` to have these verified for you.

| Requirement | Notes |
|---|---|
| Linux host | Any modern distro. systemd is optional (`--skip-systemd`). |
| Docker + Docker Compose ≥ 2.20 | The stack uses the Compose Spec `include:` key. Compose v1 is **not** supported. |
| Python ≥ 3.11 | Management API, webhook receiver, utility scripts. |
| Node.js ≥ 18 | Builds the memory MCP server (`mcp/claude-memory-mcp`). |
| Claude Code CLI | The `claude` binary the handlers drive. This is the intelligence — Monet does not bundle a model. |
| `curl`, `openssl`, `git` | Preflight checks for these. |
| A publicly reachable HTTPS endpoint | Telegram will only POST webhooks to a valid HTTPS URL on port 443, 80, 88, or 8443. |
| A Telegram bot token | Free, from @BotFather. See step 1. |
| Ollama *(optional, recommended)* | Runs on the host, not in Docker. Provides embeddings (`nomic-embed-text`). Without it, memory recall is unavailable. |
| Twilio account *(optional)* | See [Optional: SMS via Twilio](#optional-sms-via-twilio) — and read the caveat there first. |

## Quick start

### 1. Get a Telegram bot token

1. Open Telegram and message [@BotFather](https://t.me/BotFather). Send `/newbot`.
2. Choose a display name, then a username ending in `bot`.
3. BotFather replies with a token shaped `123456789:AAE...`. That is your `BOT_TOKEN`.
4. Keep it secret. Anyone holding it controls the bot.

> Leave privacy mode **enabled** (the default). Many tutorials tell you to run `/setprivacy` → Disable; that is unnecessary here. Telegram's docs state bots receive "all messages from private chats" *regardless of privacy mode* — it only restricts what a bot sees in **group** chats. Disabling it grants Monet nothing in a DM and only widens its read access if the bot is ever added to a group.

### 2. Find your chat ID

Message your new bot once (send it anything — a bot cannot see you until you speak first), then:

```bash
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" | python3 -m json.tool
```

Read `.result[0].message.chat.id`. That number is your `TG_AUTHORIZED_USER_ID`, `MONET_CHAT_ID`, and `MONET_AUTHORIZED_CHAT` — set all three to it.

This id is the allow-list, and it is the entire authorization model. The webhook receiver compares every inbound update against it (`AUTHORIZED` in [`api/monet_webhook.py`](api/monet_webhook.py)) and silently drops everything else.

### 3. Configure

```bash
cp .env.example .env
```

Edit `.env` and supply the four values under `# === Required ===`: `BOT_TOKEN`, `TG_AUTHORIZED_USER_ID`, `MONET_CHAT_ID`, and `MONET_PUBLIC_URL` (the https:// origin of your reverse proxy). Also set `MONET_AUTHORIZED_CHAT` to the same id as `TG_AUTHORIZED_USER_ID`.

`install.sh` generates every other secret for you — Qdrant, Postgres, n8n, and the API keys are all filled in with `openssl rand -hex 32` on first run. Leave them at their placeholder text.

### 4. Install

```bash
./install.sh --check
```

`--check` runs every step that needs no credential and no network write. It never mutates anything outside your checkout, and exit 0 means the tree is installable. Run it first.

```bash
./install.sh
```

The full install runs 17 steps: preflight, env, Docker stack, Python venv, database, models, systemd units, webhook registration, bot commands, and a smoke test. `./install.sh --help` documents every flag and exit code.

### 5. Expose the webhook

Telegram needs to reach you over HTTPS. Render the bundled nginx config — `install.sh` writes it to `build/nginx/monet.conf` and prints the install command, or do it by hand:

```bash
sed -e 's|@MONET_SERVER_NAME@|bot.example.com|' \
    -e 's|@MONET_TLS_CERT@|/etc/letsencrypt/live/bot.example.com/fullchain.pem|' \
    -e 's|@MONET_TLS_KEY@|/etc/letsencrypt/live/bot.example.com/privkey.pem|' \
    -e 's|@MONET_WEBHOOK_PORT@|8093|' \
    deploy/nginx/monet.conf.template > /etc/nginx/conf.d/monet.conf
```

The template allow-lists Telegram's published source ranges, proxies only the webhook path to `127.0.0.1:8093`, and returns `444` for everything else. It is not installed automatically — nginx layout varies too much across distros to automate safely.

Then register the webhook with Telegram and confirm it took:

```bash
./deploy/register-webhook.sh
./deploy/register-webhook.sh --info
```

### 6. Say hello

```bash
./deploy/smoke-test.sh
```

The smoke test checks the Docker stack, the management API, the webhook receiver's `/healthz`, and then sends a real end-to-end message. Use `--local-only` to skip the steps that need a Telegram credential.

Now message your bot `/help`.

## Optional: SMS via Twilio

`.env.example` documents `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_FROM`, and `SMS_AUTHORIZED_NUMBER`. `send-sms.sh` consumes them, and `scripts/budget-watch.py` reads the same credentials for budget alerting.

```bash
./send-sms.sh '+15551234567' 'Message text'   # prints OK, or ERROR: <reason>
```

Outbound only — Monet can send an SMS when you ask it to, but there is no inbound SMS channel: nothing receives replies. When the recipient is not `SMS_AUTHORIZED_NUMBER`, a copy goes there too, so you keep a record of anything sent on your behalf. With the Twilio variables unset the script exits non-zero with `ERROR: Twilio is not configured`.

## Architecture

```
┌──────────────┐
│  Telegram    │
│  Bot API     │
└──────┬───────┘
       │  HTTPS webhook POST
       ▼
┌──────────────────────────────────┐
│  nginx (443)                     │
│  $MONET_PUBLIC_URL               │
│  Telegram source ranges only;    │
│  everything else -> 444          │
└──────┬───────────────────────────┘
       │  proxy_pass
       ▼
┌──────────────────────────────────┐
│  webhook receiver                │
│  api/monet_webhook.py            │
│  127.0.0.1:8093                  │
│  chat-id allow-list + injection  │
│  pre-filter                      │
└──────┬───────────────────────────┘
       │
       ▼
┌──────────────────────────────────┐
│  bridges/monet-tg.sh             │
│  monet-dispatch.sh               │
│  → Claude Code CLI sessions      │
│  → memory hooks pipeline         │
│  → audit trail (SQLite)          │
│  → monet-bg-runner.sh (detached) │
└──────┬───────────────────────────┘
       │
       ▼
┌──────────────────────────────────┐
│  Services (all on 127.0.0.1)     │
│  ┌─────────┐  ┌───────────────┐  │
│  │ Qdrant  │  │ Ollama        │  │
│  │ (6334)  │  │ (11434)       │  │
│  └─────────┘  └───────────────┘  │
│  ┌─────────┐  ┌───────────────┐  │
│  │ n8n     │  │ REST API      │  │
│  │ (5679)  │  │ (8091)        │  │
│  └─────────┘  └───────────────┘  │
│  ┌───────────────────────────┐   │
│  │ Postgres (n8n backing)    │   │
│  └───────────────────────────┘   │
└──────────────────────────────────┘
```

Session handling: `flock` prevents concurrent turns, a state file tracks session id / last activity / turn count, five minutes of inactivity starts a fresh session, an existing session is resumed first and falls back to fresh on failure, and context is compacted at turn thresholds up to a 40-turn limit.

## Configuration reference

Every variable lives in [`.env.example`](.env.example), grouped by whether you must supply it, whether `install.sh` generates it, or whether it is an optional integration. Each optional block states what breaks when it is unset. The file also records how its list was derived so you can re-verify it against the code.

For a longer walkthrough of a production deployment, see [`docs/INSTALL.md`](docs/INSTALL.md).

**The `MONET_HOME` rule:** Monet runs from wherever you clone it. `MONET_HOME` defaults to the checkout directory, detected at runtime from the location of `lib/monet-env.sh`. Set it explicitly only if you move things.

## Bot commands

The command surface is **deny by default**: the 18 below are all of it. They are
enumerated in exactly two places — `scripts/tg-register-commands.sh` and the `/help`
handler in `bridges/monet-tg.sh` — and kept in sync with each other. Anything else you
type is treated as ordinary conversation and goes to Claude.

Every one of these works out of the box. None needs a third-party API key, because
Monet bundles no external content providers.

| Command | Description |
|---|---|
| `/help` | Show all commands |
| `/new` | Start a fresh conversation |
| `/export` | Export current session summary |
| `/remind <time> <msg>` | Set a reminder (e.g. `30m`, `2h`, `8am`) |
| `/reminders` | List pending reminders |
| `/clip <tag> <content>` | Save a snippet under a tag |
| `/clips [tag]` | List saved clips |
| `/find <query>` | Semantic search across your clips |
| `/mark <label>` | Bookmark the current moment in the conversation |
| `/marks` | List bookmarks |
| `/recall <label>` | Retrieve a bookmark |
| `/search <query>` | Unified search across your local data |
| `/memory-stats` | Memory backend statistics |
| `/memory-export` | Export stored memories |
| `/ss <url>` | Screenshot a URL |
| `/photo-log` | View auto-archived photo analyses |
| `/usage` | Token usage summary (7 days) |

Recurring work is not a slash command: ask Monet in natural language ("every weekday at
7am, summarize my open reminders") and it schedules the job itself. See
[`docs/HOW-TO-USE.md`](docs/HOW-TO-USE.md).

## Operations

```bash
# Health
curl -s http://localhost:8091/health          # management API
docker compose ps                             # stack status

# Logs live under $MONET_LOG_DIR (defaults to logs/ in your checkout)

# Rebuild the memory MCP server after changing it
cd mcp/claude-memory-mcp && npm run build

# Re-run the smoke test at any time
./deploy/smoke-test.sh --local-only
```

Scheduled jobs ship as a template. `install.sh` renders it to `build/monet.crontab`,
substituting `MONET_HOME` and your briefing schedule; install that file with
`crontab build/monet.crontab`.

It installs the watchdog and reminder checker (every minute) and the daily briefing.
**The briefing is opt-in and empty by default** — it ships with `BRIEFING_ENABLED=false`
and no topics, so the cron entry fires and `monet-pulse.sh` exits immediately. Set
`BRIEFING_ENABLED=true` and put something in `BRIEFING_TOPICS` or `BRIEFING_PROMPT` to
turn it on; `BRIEFING_TIME` and `BRIEFING_TIMEZONE` control when it runs. Monet bundles
no news, weather or intel feeds, so the briefing contains only what you configure.
Jobs that deliver to Telegram stay commented out until you set `MONET_CHAT_ID`.

The management API exposes `/health`, `/sessions`, `/audit`, `/usage`, `/usage/today`, `/memory/stats`, `/cron`, and `/stats` — all GET, all read-only, all behind a bearer token.

## Security

What this repository actually ships:

- **Prompt-injection pre-filter** ([`lib/injection_filter.py`](lib/injection_filter.py)) — inbound text is scored before it reaches the model.
- **Append-only audit trail** ([`lib/audit.py`](lib/audit.py)) — SQLite in WAL mode, every turn recorded.
- **Single-chat-id authorization** — the webhook receiver drops every update from any other chat.
- **All Docker ports bound to `127.0.0.1`** — nothing in the stack is exposed to the network.
- **Bearer-token management API** — no unauthenticated endpoints.
- **nginx `return 444` by default** ([`deploy/nginx/monet.conf.template`](deploy/nginx/monet.conf.template)) — only Telegram's published source ranges reach the webhook path; everything else gets the connection dropped without a response.
- **Memory dedup gate** — stores >0.92 similar to an existing memory are blocked.

Hardening of the *host* — firewall, fail2ban, intrusion detection, TLS certificate issuance — is your responsibility. This repository installs none of it.

An independent Code Hardener scan of this codebase is published at [`docs/scan/scan-report.md`](docs/scan/scan-report.md) — 0 critical, 0 high, gitleaks clean.

## Known gaps

Documented honestly rather than quietly omitted. Each is a real defect in this tree:

- **Background jobs run, but cannot be queried.** Long turns detach to `monet-bg-runner.sh` automatically and write to `bg-jobs/<job-id>/`, so the mechanism works. There is no command to check their status: `/bg` was registered but never implemented, and was removed from the surface rather than left in the menu as a dead entry. Inspect `bg-jobs/` directly, or `tail` the log in `$MONET_LOG_DIR`.
- **Voice notes are not transcribed.** Monet ships no speech-to-text backend. The previous one required a third-party API key, which was removed along with the rest of the external-API surface. A voice note sent with a caption is answered from the caption; one sent alone gets a plain "I can't transcribe voice notes" reply.
- **Email and SMS are outbound only.** `send-email.sh` and `send-sms.sh` send on request, but nothing receives replies — there is no inbound email or SMS channel. Both are unconfigured out of the box and exit non-zero with a clear `ERROR:` until you fill in `SMTP_*` / `TWILIO_*`.

## Documentation

| Document | Contents |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | Full production deployment walkthrough |
| [`docs/OVERVIEW.md`](docs/OVERVIEW.md) | System overview and component map |
| [`docs/HOW-TO-USE.md`](docs/HOW-TO-USE.md) | Day-to-day usage guide |
| [`docs/ADMINISTRATOR.md`](docs/ADMINISTRATOR.md) | Operations and maintenance |
| [`docs/SBOM.md`](docs/SBOM.md) | Software bill of materials |
| [`docs/scan/scan-report.md`](docs/scan/scan-report.md) | Security scan results |
| [`CLAUDE.md`](CLAUDE.md) | Orientation for Claude Code working in this repo |

## License

See [`LICENSE`](LICENSE).
