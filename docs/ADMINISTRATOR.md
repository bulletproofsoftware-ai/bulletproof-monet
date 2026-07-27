# Monet — Administrator Guide

Day-to-day operation, monitoring, and maintenance of a running Monet deployment.

> Paths below use the default install root `/opt/monet`. Any directory works — set
> `MONET_HOME` to your checkout and substitute it wherever `/opt/monet` appears.

## Service topology

| Component | How it runs | Port |
|-----------|-------------|------|
| Management API (`monet_api.py`) | systemd (`monet-api.service`) | `127.0.0.1:8091` |
| Qdrant | Docker (`docker/claude-memory`) | `127.0.0.1:6334` |
| n8n | Docker (`docker/claude-memory`) | `127.0.0.1:5679` |
| Postgres | Docker (`docker/claude-memory`) | internal |
| HTML→Markdown proxy | Docker (`docker/markdown-for-agents`) | `127.0.0.1:8090` |
| Ollama | host service | `127.0.0.1:11434` |
| Bot handlers | invoked per-message by n8n / cron | n/a |

## Health checks

```bash
# Management API — uptime and dependency statuses
curl -s http://localhost:8091/health

# Docker services
docker ps --format "table {{.Names}}\t{{.Status}}"

# Ollama models loaded
curl -s http://localhost:11434/api/tags

# Qdrant collections (needs QDRANT_API_KEY)
curl -s -H "api-key: $QDRANT_API_KEY" http://localhost:6334/collections
```

`scripts/health-check.sh` bundles a broader service sweep, and `server-status.sh`
prints a status summary.

## Scheduled jobs

Cron drives the recurring work. The template is `cron/monet-crontab.example`, which
`install.sh` renders to `build/monet.crontab`:

| Schedule (UTC) | Job | Purpose |
|----------------|-----|---------|
| every minute | `monet-watchdog.sh` | Kill stuck bot/claude processes; manage background jobs. |
| every minute | `monet-remind.sh` | Deliver due reminders. |
| every minute | `monet-cron.sh` | Run agent-scheduled jobs. |
| `BRIEFING_TIME` in `BRIEFING_TIMEZONE` | `monet-pulse.sh` | Daily briefing to Telegram. **Opt-in**: exits immediately unless `BRIEFING_ENABLED=true`. Defaults to 07:30 UTC. |
| `17 */6 * * *` | `monet-skill-harvest.sh` | Learning / skill-harvest loop. |
| `0 7 * * *` | `monet-research-overnight.sh` | Drain the overnight research queue. |
| `30 8 * * *` | `scripts/skill-score.py` | Nightly skill-usage aggregation. |
| `0 13 1 * *` | `scripts/skill-coverage-audit.py` | Monthly coverage digest to Telegram. |
| `0 14 * * *` | `scripts/budget-watch.py` | Twilio + API spend thresholds. |
| `15 13 * * 1` | `scripts/n8n-cost.py` | Weekly n8n execution-cost digest. |
| `30 13 * * 1` | `scripts/n8n-dead.py` | Weekly dead-workflow detector. |

Logs land in `$MONET_LOG_DIR`, which defaults to `$MONET_HOME/logs/` — per-job
`*.log` files alongside the shared `monet-tg.log`. Set `MONET_LOG_DIR` to move
them, or `MONET_LOG_FILE` to redirect just the shared log. Nothing writes to
`/var/log` any more: the service user the install guide creates cannot write
there, and the failing redirect used to break background dispatch silently.

## Session management

Both bot handlers follow the same pattern, which is worth understanding when debugging:

1. A `flock` lock file (`.monet-*.lock`) prevents concurrent execution per channel.
2. A state file (`.monet-*-state`, format `session_id|timestamp|turn_count`) tracks the
   live session.
3. Five minutes of inactivity starts a fresh session.
4. The handler tries to **resume** the prior session first and falls back to a fresh one
   on failure.
5. Context is compacted at turn thresholds (compaction at 15 and 30, hard limit 40).

If a channel gets "stuck", the watchdog will kill the process after its threshold; you
can also clear the lock/state files manually.

## Memory operations

Memory lives in Qdrant and is normally managed through the `claude-memory` MCP tools,
not by touching Qdrant directly.

```bash
# Backup all collections
python3 scripts/memory-export.py            # or the /memory-export bot command

# Lifecycle management (tier transfer, pruning, decay)
python3 scripts/memory-governor.py

# Re-index the Obsidian vault into Qdrant (content-hash change detection)
python3 scripts/index-obsidian.py
```

n8n workflows in `n8n/workflows/` perform the recurring memory maintenance
(hippocampal consolidation, TTL sweep, tier transfer, hierarchical abstraction,
predictive pattern extraction, compliance report). Import and enable the ones you want.

**Rebuild the memory MCP server** after changing its source:

```bash
cd /opt/monet/mcp/claude-memory-mcp && npm run build
```

## Management API endpoints

All read-only; bearer auth via `MONET_API_KEY`.

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Service health, uptime, dependency statuses. |
| `GET /sessions` | Active sessions (last 24h). |
| `GET /audit` | Filterable audit log (channel, action, limit). |
| `GET /usage` | 7-day usage history + today's totals. |
| `GET /usage/today` | Today's token-usage breakdown. |
| `GET /memory/stats` | Qdrant collection point counts. |
| `GET /cron` | Recent cron execution events. |
| `GET /stats` | Overall system statistics. |

The static dashboard (`dashboard/index.html`) consumes these endpoints.

## Security posture

- **Network**: all Docker ports bind to `127.0.0.1`; front with nginx that drops
  non-webhook traffic. Restrict inbound at the firewall.
- **Auth**: Telegram user-ID allowlist and SMS sender authentication; management API
  behind a bearer token.
- **Audit**: append-only SQLite audit trail (WAL mode) via `lib/audit.py`.
- **Prompt-injection filter**: `lib/injection_filter.py` scores inbound content before
  it reaches the model.
- **Memory dedup gate**: stores that are ≥0.92 similar to an existing memory are blocked.
- **Secrets**: supplied only through `.env`; no credentials are committed to the tree.

The latest automated security scan is summarized in
[scan/scan-report.md](scan/scan-report.md) (0 critical / 0 high).

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Bot silent | `tail -f /var/log/monet-tg.log`; confirm n8n workflow active and `BOT_TOKEN` set. |
| "Session stuck" | Inspect `.monet-*-state` / `.monet-*.lock`; let the watchdog reap or clear manually. |
| Memory recall empty | Verify Qdrant is up and `QDRANT_API_KEY` is set; check Ollama has `nomic-embed-text` loaded. |
| MCP tools missing | Rebuild `mcp/claude-memory-mcp` and confirm the server is registered with Claude Code. |
| API 401 | Bearer token mismatch — confirm `MONET_API_KEY`. |

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
