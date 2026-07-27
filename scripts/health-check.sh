#!/bin/bash
# Health check for the Monet stack — alerts via Telegram if anything is down.
# Run via cron: */5 * * * * $MONET_HOME/scripts/health-check.sh

# shellcheck source=../lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"

ALERT_STATE="$MONET_DATA_DIR/.health-alert-state"

# Telegram chat that receives alerts. No placeholder default: without a real chat
# id there is nowhere to deliver, so exit rather than POST to a bogus id.
CHAT_ID="${HEALTH_CHECK_CHAT_ID:-${MONET_CHAT_ID:-}}"
if [ -z "$CHAT_ID" ] || [ -z "${BOT_TOKEN:-}" ]; then
    echo "health-check: MONET_CHAT_ID and BOT_TOKEN must be set to deliver alerts; exiting." >&2
    exit 0
fi

mkdir -p "$MONET_DATA_DIR"
FAILURES=""

check() {
    local name="$1" url="$2" expect="$3"
    local resp
    if ! resp=$(curl -sf --max-time 5 "$url" 2>/dev/null); then
        FAILURES="${FAILURES}${name}: unreachable\n"
        return 1
    fi
    if [ -n "$expect" ] && ! echo "$resp" | grep -q "$expect"; then
        FAILURES="${FAILURES}${name}: unexpected response\n"
        return 1
    fi
    return 0
}

check_docker() {
    local name="$1"
    local status
    status=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    if [ "$status" != "true" ]; then
        FAILURES="${FAILURES}${name}: container not running\n"
        return 1
    fi
    return 0
}

# --- Run checks ---
check "Qdrant" "http://localhost:6334/healthz" ""
check "Ollama" "http://localhost:11434/api/tags" "models"
check "n8n" "http://localhost:5679/healthz" "ok"
check_docker "claude_backend_qdrant"
check_docker "claude_backend_n8n"
check_docker "claude_backend_postgres"

# Check nginx separately (it returns 444 for unauthorized, but should be running)
if ! pgrep -x nginx >/dev/null 2>&1; then
    FAILURES="${FAILURES}nginx: process not running\n"
fi

# Check disk space (alert if >90%)
DISK_PCT=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_PCT" -gt 90 ]; then
    FAILURES="${FAILURES}disk: ${DISK_PCT}% used\n"
fi

# --- Alert logic ---
if [ -n "$FAILURES" ]; then
    # Only alert if this is a new failure (avoid spam)
    CURRENT_HASH=$(echo -e "$FAILURES" | md5sum | cut -d' ' -f1)
    LAST_HASH=$(cat "$ALERT_STATE" 2>/dev/null)
    if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        MSG=$(printf "⚠️ Monet Health Alert (%s)\n\n%b\nChecked: %s" \
            "$(hostname -s 2>/dev/null || echo host)" "$FAILURES" "$(date '+%H:%M %Z')")
        curl -s --max-time 10 -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${MSG}" >/dev/null 2>&1
        echo "$CURRENT_HASH" > "$ALERT_STATE"
    fi
else
    # All clear — remove alert state so next failure triggers alert
    rm -f "$ALERT_STATE"
fi
