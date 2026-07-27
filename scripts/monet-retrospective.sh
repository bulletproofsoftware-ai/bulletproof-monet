#!/bin/bash
# monet-retrospective.sh — Weekly retrospective (runs Sunday evenings)
# Gathers usage stats, memory themes, and reminder activity,
# then generates a narrative summary via Claude and delivers to TG.
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
set -uo pipefail

# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
LOCK_FILE="${MONET_HOME}/.monet-retro.lock"
DATA_DIR="${MONET_HOME}/data"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RETRO $*" >> "$LOG_FILE"; }

: "${BOT_TOKEN:?BOT_TOKEN not set}"

# Prevent overlapping runs
exec 8>"$LOCK_FILE"
flock -n 8 || { log "SKIP (already running)"; exit 0; }

# Delivery chat, same resolution order as the other unattended jobs.
CHAT_ID="${MONET_DEFAULT_CHAT:-${MONET_CHAT_ID:-}}"
if [ -z "$CHAT_ID" ]; then
    log "SKIP (no chat_id)"
    exit 0
fi

mkdir -p "$DATA_DIR"
log "START"

# 1. Gather usage stats
USAGE_STATS=""
if [ -f "$MONET_HOME"/lib/audit.py ]; then
    USAGE_STATS=$(python3 "$MONET_HOME"/lib/audit.py usage --days 7 --json 2>/dev/null)
fi

# 2. Gather memory themes
MEMORY_THEMES=""
if [ -f "$MONET_HOME"/tg-memory.py ]; then
    MEMORY_THEMES=$(timeout 10 python3 "$MONET_HOME"/tg-memory.py recall "$CHAT_ID" "weekly summary conversations topics decisions tasks" 2>/dev/null)
fi

# 3. Gather reminder stats
REMINDER_STATS=""
if [ -f "$MONET_HOME"/reminders.json ]; then
    REMINDER_STATS=$(python3 -c "
import json, time

now = time.time()
week_ago = now - 7 * 86400
try:
    reminders = json.load(open('$MONET_HOME/reminders.json'))
except:
    reminders = []

active = len(reminders)
due_this_week = len([r for r in reminders if r['due_ts'] <= now + 7 * 86400])
created_this_week = len([r for r in reminders if r.get('created_ts', 0) >= week_ago])

print(f'Active reminders: {active}')
print(f'Due in next 7 days: {due_this_week}')
print(f'Created this week: {created_this_week}')
" 2>/dev/null)
fi

# Build prompt
PROMPT="Generate a concise weekly retrospective for ${MONET_OWNER_NAME:-the operator}. Today is $(date '+%A, %B %d, %Y').
This is a personal assistant retrospective — reflect on how Monet was used this week."

if [ -n "$USAGE_STATS" ]; then
    PROMPT="${PROMPT}

**Usage Statistics (7 days):**
${USAGE_STATS}"
fi

if [ -n "$MEMORY_THEMES" ]; then
    PROMPT="${PROMPT}

**Conversation Themes This Week:**
${MEMORY_THEMES}"
fi

if [ -n "$REMINDER_STATS" ]; then
    PROMPT="${PROMPT}

**Reminder Activity:**
${REMINDER_STATS}"
fi

PROMPT="${PROMPT}

Format as a clean Telegram message with these sections:
1. **Week in Review** — 2-3 sentence overview of how Monet was used
2. **Key Themes** — Top 3-4 topics discussed this week
3. **By the Numbers** — Usage stats in a compact format
4. **Looking Ahead** — Any pending reminders or unfinished threads

Keep under 1500 characters. Be insightful, not just descriptive."

# Run Claude
log "CLAUDE start"
RAW=$(timeout 180 claude -p \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    --disable-slash-commands \
    --output-format json \
    "$PROMPT" 2>>"$LOG_FILE")

if [ $? -ne 0 ] || [ -z "$RAW" ]; then
    log "CLAUDE FAIL"
    exit 1
fi

RESPONSE=$(echo "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)

if [ -z "$RESPONSE" ] || [ ${#RESPONSE} -lt 50 ]; then
    log "CLAUDE EMPTY"
    exit 1
fi

# Save to data dir for Obsidian sync
RETRO_FILE="${DATA_DIR}/retro-$(date '+%Y-%m-%d').md"
echo "# Weekly Retrospective — $(date '+%B %d, %Y')" > "$RETRO_FILE"
echo "" >> "$RETRO_FILE"
echo "$RESPONSE" >> "$RETRO_FILE"
log "SAVED $RETRO_FILE"

# Deliver via TG
echo "$RESPONSE" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
if [ $? -eq 0 ]; then
    log "DELIVERED len=${#RESPONSE}"
else
    log "DELIVERY_FAIL"
fi
