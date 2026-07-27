#!/bin/bash
# monet-remind.sh — Cron checker for due reminders
# Runs every minute via cron. Delivers due reminders via tg-send.sh
# and removes them from the JSON file.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

REMIND_FILE="${MONET_HOME}/reminders.json"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
LOCK_FILE="${MONET_HOME}/.monet-remind.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] REMIND $*" >> "$LOG_FILE"; }

# Prevent overlapping runs
exec 8>"$LOCK_FILE"
flock -n 8 || exit 0

: "${BOT_TOKEN:?BOT_TOKEN not set}"

[ -f "$REMIND_FILE" ] || exit 0
[ -s "$REMIND_FILE" ] || exit 0

NOW=$(date +%s)

# Find due reminders and collect their IDs
RESULT=$(NOW_TS="$NOW" REMIND_FILE="$REMIND_FILE" python3 << 'PYEOF'
import json, os

f = os.environ['REMIND_FILE']
now = int(os.environ['NOW_TS'])

try:
    with open(f) as fh:
        reminders = json.load(fh)
except (json.JSONDecodeError, FileNotFoundError):
    exit(0)

if not reminders:
    exit(0)

due = [r for r in reminders if r['due_ts'] <= now]
remaining = [r for r in reminders if r['due_ts'] > now]

if not due:
    exit(0)

# Write remaining back
with open(f, 'w') as fh:
    json.dump(remaining, fh, indent=2)

# Output due reminders as chat_id|message lines
for r in due:
    # Escape pipes in message
    msg = r['message'].replace('|', '\\|')
    print(f"{r['chat_id']}|{r['message']}")
PYEOF
)

[ -z "$RESULT" ] && exit 0

# Deliver each due reminder
while IFS='|' read -r CHAT_ID MESSAGE; do
    [ -z "$CHAT_ID" ] && continue
    [ -z "$MESSAGE" ] && continue
    echo "Reminder: ${MESSAGE}" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    log "DELIVERED chat=$CHAT_ID msg=\"${MESSAGE:0:60}\""
done <<< "$RESULT"
