#!/bin/bash
# Cron retry wrapper with exponential backoff
# Usage: cron-retry.sh <max_retries> <script> [args...]
# Example: cron-retry.sh 3 "$MONET_HOME"/monet-pulse.sh
#
# Backoff schedule: 60s, 120s, 240s (doubles each retry)
# On persistent failure: alert via tg-send.sh
# All attempts logged to audit DB

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -o pipefail

MAX_RETRIES="${1:?Usage: cron-retry.sh <max_retries> <script> [args...]}"
shift
SCRIPT="$1"
shift
SCRIPT_NAME=$(basename "$SCRIPT" .sh)

AUDIT_PY="${MONET_HOME}/lib/audit.py"
TG_SEND="${MONET_HOME}/tg-send.sh"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-cron-retry.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null

# Load env for BOT_TOKEN (needed for tg-send.sh)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron-retry] $*" >> "$LOG_FILE"; }

BACKOFF=60
ATTEMPT=0

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    START_MS=$(($(date +%s%N) / 1000000))

    log "ATTEMPT $ATTEMPT/$MAX_RETRIES script=$SCRIPT_NAME"

    OUTPUT=$("$SCRIPT" "$@" 2>&1)
    EXIT_CODE=$?

    END_MS=$(($(date +%s%N) / 1000000))
    DURATION_MS=$((END_MS - START_MS))

    if [ $EXIT_CODE -eq 0 ]; then
        log "SUCCESS attempt=$ATTEMPT duration=${DURATION_MS}ms"
        python3 "$AUDIT_PY" log \
            --channel cron \
            --action "cron_success" \
            --details "$SCRIPT_NAME attempt=$ATTEMPT duration=${DURATION_MS}ms" \
            --duration-ms "$DURATION_MS" &>/dev/null &
        exit 0
    fi

    log "FAIL attempt=$ATTEMPT exit=$EXIT_CODE duration=${DURATION_MS}ms output=${OUTPUT:0:200}"
    python3 "$AUDIT_PY" log \
        --channel cron \
        --action "cron_retry" \
        --details "$SCRIPT_NAME attempt=$ATTEMPT/$MAX_RETRIES exit=$EXIT_CODE" \
        --duration-ms "$DURATION_MS" &>/dev/null &

    if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "BACKOFF ${BACKOFF}s before retry $((ATTEMPT + 1))"
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
    fi
done

# All retries exhausted — alert
log "EXHAUSTED script=$SCRIPT_NAME after $MAX_RETRIES attempts"
python3 "$AUDIT_PY" log \
    --channel cron \
    --action "cron_failure" \
    --details "$SCRIPT_NAME exhausted $MAX_RETRIES retries" &>/dev/null &

# Send alert via Telegram
CHAT_ID="${TG_AUTHORIZED_USER_ID:-YOUR_CHAT_ID}"
ALERT_MSG="Cron job failed: $SCRIPT_NAME
Retries: $MAX_RETRIES exhausted
Last exit code: $EXIT_CODE
Last output: ${OUTPUT:0:300}"

if [ -x "$TG_SEND" ]; then
    echo "$ALERT_MSG" | "$TG_SEND" "$CHAT_ID" --plain 2>/dev/null
fi

exit 1
