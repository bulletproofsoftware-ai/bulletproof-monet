# Monet — Installation

Monet is a self-hosted assistant that runs on a single Linux VPS. By convention the
tree is deployed to `/opt/monet` and runs under a dedicated `monet` service user, but
any absolute path works as long as it is consistent across the scripts, cron entries,
and `.env`.

> Paths below use the default install root `/opt/monet`. Any directory works — set
> `MONET_HOME` to your checkout and substitute it wherever `/opt/monet` appears.

> This guide covers the components that ship in this repository. Channel credentials
> (Telegram, Twilio) and the outbound e-mail/SMS relays are provided by you via
> environment variables — Monet does not bundle any accounts or keys.

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Linux host | Tested on AlmaLinux / RHEL-family; any modern distro works. |
| Docker + Docker Compose | For Qdrant, n8n, Postgres, and the HTML→Markdown proxy. |
| Node.js ≥ 18 | To build the memory MCP server (`mcp/claude-memory-mcp`). |
| Python ≥ 3.11 | For the management API, memory governor, and utility scripts. |
| Ollama | Provides embeddings (`nomic-embed-text`) and light generation (`llama3.2:3b`). |
| Claude Code CLI | The `claude` binary the bot handlers drive. |
| Telegram bot token | From @BotFather. |
| Twilio account (optional) | Only if you want the SMS channel. |

## 2. Clone and place the tree

```bash
sudo git clone https://github.com/bulletproofsoftware-ai/bulletproof-monet.git /opt/monet
sudo useradd --system --home-dir /opt/monet --shell /usr/sbin/nologin monet
sudo chown -R monet:monet /opt/monet
```

If you deploy somewhere other than `/opt/monet`, the scripts locate themselves — each
one resolves `MONET_HOME` from the position of `lib/monet-env.sh`, so no edits are
needed. Only the files that cannot do shell expansion carry an `@MONET_HOME@` token you
must substitute: the `.service.template` units, `cron/monet-crontab.example`,
`claude/settings.json.template`, and the n8n workflow JSON. Export `MONET_HOME`
explicitly if you want to override the detected value.

## 3. Configure environment

```bash
cd /opt/monet
cp .env.example .env
$EDITOR .env          # fill in every value
```

Key variables (see `.env.example` for the full list):

| Variable | Purpose |
|----------|---------|
| `BOT_TOKEN` | Telegram bot token. |
| `TG_AUTHORIZED_USER_ID` | The only Telegram user allowed to talk to the bot. |
| `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_FROM`, `SMS_AUTHORIZED_NUMBER` | SMS channel (optional). |
| `QDRANT_API_KEY` | Qdrant service API key — **required**, no default is baked into the code. |
| `POSTGRES_*`, `N8N_*`, `WEBHOOK_*` | n8n stack + webhook ingest. |
| `SMTP_USER`, `SMTP_PASS`, `SMTP_HOST` | Outbound e-mail relay. |
| `MONET_API_KEY`, `MONET_API_PORT` | Management API bearer token + port. |
| `OLLAMA_URL`, `EMBED_MODEL` | Ollama endpoint and embedding model. |
| `BRIEFING_*` | Daily briefing. Ships disabled and empty — see step 9. |
| `TTS_*` | Spoken output via `edge-tts`. Ships disabled; no API key needed. |

No third-party content or model API keys appear in this list, and none is needed:
Monet bundles no external providers.

Generate secrets with `openssl rand -hex 32`.

## 4. Bring up the Docker stack

There is **one** `.env`, at the repo root — the one you filled in above. The
top-level `docker-compose.yml` pulls in both sub-stacks with the Compose Spec
`include:` key, so a single command brings up everything:

```bash
cd "$MONET_HOME"
docker compose up -d
```

This requires **Docker Compose 2.20.0 or newer** (`include:` was added in 2.20).
`install.sh` checks this at preflight and fails with a clear message on older
versions; on Compose < 2.20 the file silently resolves to a single service.

Confirm the merged stack is what you expect before starting it:

```bash
docker compose config --services   # markdown-converter, n8n, ollama, postgres, qdrant
```

Ollama sits behind an opt-in profile so it does not collide with a host Ollama.
Start the containerized one only if you do not already run Ollama on the host:

```bash
docker compose --profile ollama up -d
```

All service ports are bound to `127.0.0.1` only:

| Service | Host binding | Container port |
|---------|--------------|----------------|
| Qdrant | `127.0.0.1:6334` | 6333 |
| n8n | `127.0.0.1:5679` | 5678 |
| Postgres | internal only | 5432 |

The optional HTML→Markdown proxy (used by the research/agent tooling) runs as a
non-root container:

```bash
cd /opt/monet/docker/markdown-for-agents
docker compose up -d          # binds 127.0.0.1:8090
```

## 5. Pull Ollama models

```bash
ollama pull nomic-embed-text
ollama pull llama3.2:3b
```

## 6. Build the memory MCP server

```bash
cd /opt/monet/mcp/claude-memory-mcp
npm install
npm run build            # emits dist/index.js
```

Register it with Claude Code as an MCP server named `claude-memory` (stdio transport,
command `node /opt/monet/mcp/claude-memory-mcp/dist/index.js`), passing
`QDRANT_URL`, `QDRANT_API_KEY`, and `OLLAMA_URL` in its environment.

## 7. Initialize the audit database

```bash
cd /opt/monet
./scripts/init-db.sh          # creates the SQLite audit DB (path from MONET_AUDIT_DB)
```

## 8. Start the management API

Run `api/monet_api.py` under systemd. The unit ships as a template
(`api/monet-api.service.template`) containing `@MONET_HOME@`, `@MONET_USER@`, and
`@MONET_LOG_DIR@` tokens; substitute them for your install before copying it:

```bash
sed -e "s|@MONET_HOME@|$MONET_HOME|g" \
    -e "s|@MONET_USER@|monet|g" \
    -e "s|@MONET_LOG_DIR@|$MONET_HOME/logs|g" \
    api/monet-api.service.template | sudo tee /etc/systemd/system/monet-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now monet-api
curl -s http://localhost:8091/health
```

The webhook and worker units (`src/monet-webhook.service.template`,
`src/monet-worker@.service.template`) use the same three tokens.

## 9. Install cron jobs

`cron/monet-crontab.example` is a portable template using the same `@MONET_HOME@`
token. `install.sh` already renders it to `build/monet.crontab` with your install
root substituted, so the simplest path is:

```bash
crontab build/monet.crontab
```

To render it by hand instead, substitute the briefing schedule too:

```bash
MONET_HOME=/opt/monet   # or wherever you checked out
sed -e "s|@MONET_HOME@|$MONET_HOME|g" \
    -e "s|@BRIEFING_MIN@|30|g" -e "s|@BRIEFING_HOUR@|7|g" -e "s|@BRIEFING_TZ@|UTC|g" \
    cron/monet-crontab.example | crontab -
```

These jobs cover the watchdog, reminder checker, daily briefing, agent-scheduled
jobs, the learning/skill-harvest loop, and the weekly cost/health digests.

The daily briefing is **opt-in and empty by default**. `install.sh` renders its cron
entry from `BRIEFING_TIME` and `BRIEFING_TIMEZONE`, but `monet-pulse.sh` exits at once
unless `BRIEFING_ENABLED=true`. Set that, then put your own subjects in
`BRIEFING_TOPICS` (comma-separated) and/or a free-text instruction in
`BRIEFING_PROMPT` — those are the entire content of the briefing, because no feeds or
data sources are bundled.

## 10. Wire up the channels

- **Telegram**: the bridge workflow contains `@MONET_HOME@` tokens (n8n does not expand
  shell variables in every node type), so substitute them before importing:

  ```bash
  mkdir -p build
  sed "s|@MONET_HOME@|$MONET_HOME|g" \
      n8n/workflows/monet-telegram-bridge.json > build/monet-telegram-bridge.json
  ```

  Import `build/monet-telegram-bridge.json` into n8n, point the webhook at your bot, and
  set the workflow to invoke `bridges/monet-tg.sh`. Register the bot's slash commands
  with `scripts/tg-register-commands.sh`.

Terminate TLS in front of n8n (nginx is the reference), and restrict inbound traffic to
the webhook paths only.

## Verify

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
curl -s http://localhost:8091/health
"$MONET_HOME"/bridges/monet-tg.sh "hello" "" "$MONET_CHAT_ID"   # direct handler smoke test
```

See [ADMINISTRATOR.md](ADMINISTRATOR.md) for ongoing operations and
[HOW-TO-USE.md](HOW-TO-USE.md) for day-to-day usage.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
