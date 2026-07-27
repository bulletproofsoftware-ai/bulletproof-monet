#!/bin/bash
# monet-cron.sh — Runs scheduled agent jobs (cron-jobs.json) that are due now.
# Cron: every minute, flock-guarded (mirrors monet-remind.sh). For each due job
# it runs the job PROMPT through Claude and delivers the result to the chat.
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"

SCHED="${MONET_HOME}/monet_sched.py"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
LOCK_FILE="${MONET_HOME}/.monet-cron.lock"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
JOB_TIMEOUT=240

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] CRONJOB $*" >> "$LOG_FILE"; }

# Prevent overlapping runs (a long job must not block the next minute's tick)
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

: "${BOT_TOKEN:?BOT_TOKEN not set}"

DUE=$(python3 "$SCHED" due 2>>"$LOG_FILE")
[ -z "$DUE" ] && exit 0

SYS_PROMPT="You are Monet running an UNATTENDED scheduled job for ${MONET_OWNER_NAME:-the operator} — there is no human in the loop right now. Produce the requested output directly and concisely, ready to read on Telegram. Use memory_recall and web tools as needed to be accurate and current. Do not ask questions; do not include meta-commentary about being scheduled. If you cannot complete it, say briefly why."

while IFS=$'\t' read -r CHAT_ID JOB_ID PROMPT; do
    [ -z "$CHAT_ID" ] && continue
    [ -z "$JOB_ID" ] && continue
    [ -z "$PROMPT" ] && continue
    log "START job=$JOB_ID chat=$CHAT_ID prompt=\"${PROMPT:0:60}\""

    RAW=$(timeout "$JOB_TIMEOUT" claude -p --model "$MODEL" --max-turns 15 \
        --dangerously-skip-permissions --disable-slash-commands \
        --output-format json --append-system-prompt "$SYS_PROMPT" \
        "$PROMPT" 2>>"$LOG_FILE")
    RC=$?

    if [ $RC -ne 0 ] || [ -z "$RAW" ]; then
        log "FAIL job=$JOB_ID rc=$RC (timeout/empty)"
        echo "⚠️ Scheduled job '${JOB_ID}' failed to run (timeout or error)." \
            | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
        python3 "$SCHED" mark-run "$JOB_ID" error 2>>"$LOG_FILE"
        continue
    fi

    RESULT=$(printf '%s' "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
    if [ -z "$RESULT" ]; then
        log "FAIL job=$JOB_ID (no result in claude output)"
        python3 "$SCHED" mark-run "$JOB_ID" error 2>>"$LOG_FILE"
        continue
    fi

    printf '%s' "$RESULT" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    python3 "$SCHED" mark-run "$JOB_ID" ok 2>>"$LOG_FILE"
    log "DELIVERED job=$JOB_ID chat=$CHAT_ID len=${#RESULT}"
done <<< "$DUE"
