#!/bin/bash
# monet-pulse.sh — Daily briefing generator.
# Runs via cron at BRIEFING_TIME in BRIEFING_TIMEZONE (see
# cron/monet-crontab.example). Composes a briefing from YOUR configuration and
# delivers it via tg-send.sh.
#
# Opt-in and empty by default. The briefing ships DISABLED (BRIEFING_ENABLED=false)
# with no topics and no prompt, and it bundles no news feeds, weather sources or
# intel providers -- whatever you put in BRIEFING_TOPICS and BRIEFING_PROMPT is
# the entire content. With BRIEFING_ENABLED=false this script is a no-op.
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
# Can also be triggered on-demand via: monet-pulse.sh --now
set -uo pipefail

REMIND_FILE="${MONET_HOME}/reminders.json"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
LOCK_FILE="${MONET_HOME}/.monet-pulse.lock"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] PULSE $*" >> "$LOG_FILE"; }

: "${BOT_TOKEN:?BOT_TOKEN not set}"

# Prevent overlapping runs
exec 8>"$LOCK_FILE"
flock -n 8 || { log "SKIP (already running)"; exit 0; }

# Opt-in gate. --now is the manual override for testing; everything else
# requires BRIEFING_ENABLED to be explicitly turned on.
ENABLED="${BRIEFING_ENABLED:-false}"
if [ "$ENABLED" != "true" ] && [ "$ENABLED" != "1" ] && [ "${1:-}" != "--now" ]; then
    log "SKIP (BRIEFING_ENABLED is not true)"
    exit 0
fi

CHAT_ID="${MONET_DEFAULT_CHAT:-${MONET_CHAT_ID:-}}"
if [ -z "$CHAT_ID" ]; then
    log "SKIP (no chat id: set MONET_CHAT_ID)"
    exit 0
fi

# Only telegram is implemented. Refuse loudly on anything else rather than
# silently delivering somewhere the user did not ask for.
DELIVER_TO="${BRIEFING_DELIVER_TO:-telegram}"
if [ "$DELIVER_TO" != "telegram" ]; then
    log "SKIP (BRIEFING_DELIVER_TO=$DELIVER_TO is not supported; only 'telegram' is)"
    exit 0
fi

# Your topics, one per line or comma-separated. Empty by default.
TOPICS=""
if [ -n "${BRIEFING_TOPICS:-}" ]; then
    TOPICS=$(BRIEFING_TOPICS="$BRIEFING_TOPICS" python3 -c "
import os, re
raw = os.environ['BRIEFING_TOPICS']
items = [t.strip() for t in re.split(r'[,\n]', raw) if t.strip()]
print('\n'.join(f'- {t}' for t in items))
" 2>/dev/null)
fi

log "START topics=$([ -n "$TOPICS" ] && echo yes || echo none)"

# Load pending reminders for today
REMINDERS=""
if [ -f "$REMIND_FILE" ]; then
    REMINDERS=$(python3 -c "
import json, os
from datetime import datetime
try:
    reminders = json.load(open('$REMIND_FILE'))
    today = datetime.now().strftime('%Y-%m-%d')
    today_reminders = [r for r in reminders if datetime.fromtimestamp(r['due_ts']).strftime('%Y-%m-%d') == today]
    if today_reminders:
        for r in sorted(today_reminders, key=lambda x: x['due_ts']):
            due = datetime.fromtimestamp(r['due_ts']).strftime('%H:%M')
            print(f'- {due}: {r[\"message\"]}')
except:
    pass
" 2>/dev/null)
fi

# Recall recent conversation themes from memory
MEMORY_CTX=""
if [ -f "$MONET_HOME"/tg-memory.py ]; then
    MEMORY_CTX=$(timeout 10 python3 "$MONET_HOME"/tg-memory.py recall "$CHAT_ID" "recent conversations topics tasks decisions" 2>/dev/null)
fi

# Nothing to say? Do not burn a model call producing an empty briefing.
if [ -z "${BRIEFING_PROMPT:-}" ] && [ -z "$TOPICS" ] && [ -z "$REMINDERS" ] && [ -z "$MEMORY_CTX" ]; then
    log "SKIP (nothing configured: set BRIEFING_TOPICS and/or BRIEFING_PROMPT)"
    exit 0
fi

# Build the prompt. Every section below is conditional: the briefing contains
# only what YOU configured. There are no built-in news, weather or intel feeds.
PROMPT="You are generating a daily briefing for ${MONET_OWNER_NAME:-the operator}. Today is $(date '+%A, %B %d, %Y'). Be concise and scannable — use short bullet points, not paragraphs.

Compose a briefing from the sections below. Include only the sections given:"

# Your own free-text instruction, verbatim. Empty by default.
if [ -n "${BRIEFING_PROMPT:-}" ]; then
    PROMPT="${PROMPT}

**Your Briefing**
${BRIEFING_PROMPT}"
fi

if [ -n "$TOPICS" ]; then
    PROMPT="${PROMPT}

**Tracked Topics**
Research the latest developments on each of these topics using web search. For each topic, provide 1-2 bullet points with what's new, and after each bullet include a 'Read more' link to the most relevant source as a plain https:// URL on its own line so it is clickable in Telegram:
${TOPICS}"
fi

if [ -n "$REMINDERS" ]; then
    PROMPT="${PROMPT}

**Today's Reminders**
These reminders are scheduled for today:
${REMINDERS}"
fi

if [ -n "$MEMORY_CTX" ]; then
    PROMPT="${PROMPT}

**Continuing Threads**
Based on recent conversation context, mention any unfinished tasks or follow-ups that might be relevant today. Only include this section if there's something actionable. Here's the recent context:
${MEMORY_CTX}"
fi

PROMPT="${PROMPT}

Format the output as a clean Telegram message. Use bold section headers. Keep the whole briefing under 2000 characters if possible. End with the current date and time."

# Run Claude with full MCP tool access
log "CLAUDE start"
RAW=$(timeout 180 claude -p \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    --disable-slash-commands \
    --output-format json \
    "$PROMPT" 2>>"$LOG_FILE")
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
    log "CLAUDE FAIL exit=$EXIT_CODE"
    echo "Pulse briefing failed to generate. Check logs." | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    exit 1
fi

RESPONSE=$(echo "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)

if [ -z "$RESPONSE" ] || [ ${#RESPONSE} -lt 50 ]; then
    log "CLAUDE EMPTY response"
    echo "Pulse briefing was empty. Check logs." | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    exit 1
fi

# Self-critique pass (PRD #3) — flag weak/unsupported claims before delivery
CRITIC_FOOTER=$(printf '%s' "$RESPONSE" | timeout 70 "$MONET_HOME"/bin/critic "morning pulse" 2>/dev/null)
[ -n "$CRITIC_FOOTER" ] && RESPONSE="${RESPONSE}

${CRITIC_FOOTER}" && log "CRITIC flagged pulse"

# Workflow health (PRD #31) — surface broken n8n workflows in the pulse
WF_HEALTH=$(timeout 20 "$MONET_HOME"/scripts/n8n-health.py --pulse 2>/dev/null)
[ -n "$WF_HEALTH" ] && RESPONSE="${RESPONSE}

${WF_HEALTH}" && log "PULSE workflow-health appended"

# Predictive pre-loading (PRD #50) — proactive day/time nudge, pre-warms topic
PRED_HINT=$("$MONET_HOME"/bin/predictive-hint --warm 2>/dev/null)
[ -n "$PRED_HINT" ] && RESPONSE="${PRED_HINT}

${RESPONSE}" && log "PULSE predictive-hint prepended"

# Deliver the briefing
echo "$RESPONSE" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
RESULT=$?

if [ $RESULT -eq 0 ]; then
    log "DELIVERED len=${#RESPONSE}"
else
    log "DELIVERY_FAIL result=$RESULT"
fi

# Spoken briefing — best-effort, async, only when TTS is switched on.
# monet-voice.sh re-checks TTS_ENABLED itself and soft-exits if it is off.
if [ "${TTS_ENABLED:-false}" = "true" ] || [ "${TTS_ENABLED:-false}" = "1" ]; then
    nohup "$MONET_HOME"/monet-voice.sh "$CHAT_ID" "$RESPONSE" >/dev/null 2>&1 &
    log "VOICE dispatched (async)"
fi
