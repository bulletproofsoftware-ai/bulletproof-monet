#!/bin/bash
# monet-reminder-nudge.sh — Nudge about stale reminders
# Runs daily. Finds reminders set >7 days ago that haven't fired yet
# and sends a silent TG nudge asking if they're still wanted.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
set -uo pipefail

REMIND_FILE="${MONET_HOME}/reminders.json"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] NUDGE $*" >> "$LOG_FILE"; }

: "${BOT_TOKEN:?BOT_TOKEN not set}"

if [ ! -f "$REMIND_FILE" ]; then
    exit 0
fi

# Find stale reminders (created >7 days ago, not yet fired)
NUDGES=$(python3 << 'PYEOF'
import json, os, time
from datetime import datetime

now = int(time.time())
stale_threshold = 7 * 86400

try:
    reminders = json.load(open(os.path.join(os.environ.get('MONET_HOME', '/opt/monet'), 'reminders.json')))
except:
    reminders = []

for r in reminders:
    created = r.get('created_ts', 0)
    due = r.get('due_ts', 0)
    age_days = (now - created) / 86400
    # Only nudge if created >7 days ago and still pending (due in the future)
    if age_days >= 7 and due > now:
        due_dt = datetime.fromtimestamp(due).strftime('%Y-%m-%d %H:%M')
        days_until = int((due - now) / 86400)
        age_d = int(age_days)
        chat_id = r.get('chat_id', '')
        msg = r.get('message', '')
        print(f"{chat_id}|{age_d}|{days_until}|{due_dt}|{msg}")
PYEOF
)

if [ -z "$NUDGES" ]; then
    exit 0
fi

log "START found=$(echo "$NUDGES" | wc -l | tr -d ' ') stale reminders"

while IFS='|' read -r CHAT_ID AGE_DAYS DAYS_UNTIL DUE_DT REMIND_MSG; do
    [ -z "$CHAT_ID" ] && continue
    NUDGE_TEXT="Stale reminder check:
\"${REMIND_MSG}\"
Set ${AGE_DAYS} days ago, fires ${DUE_DT} (in ${DAYS_UNTIL}d).
Still want it? Reply /reminders to review all."

    echo "$NUDGE_TEXT" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" --silent 2>/dev/null
    log "SENT chat=$CHAT_ID msg=\"${REMIND_MSG:0:50}\""
done <<< "$NUDGES"

log "DONE"
