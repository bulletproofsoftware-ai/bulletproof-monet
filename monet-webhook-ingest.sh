#!/bin/bash
# monet-webhook-ingest.sh — Accept webhook POSTs from external services and forward to Telegram
# Called by nginx or n8n webhook. Validates WEBHOOK_SECRET header.
# Usage: monet-webhook-ingest.sh <json_payload>
# JSON payload: {"secret":"...", "chat_id":"...", "message":"...", "silent": false}
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WEBHOOK $*" >> "$LOG_FILE"; }

: "${BOT_TOKEN:?BOT_TOKEN not set}"
: "${WEBHOOK_SECRET:?WEBHOOK_SECRET not set}"

PAYLOAD="${1:-}"
if [ -z "$PAYLOAD" ]; then
    # Try reading from stdin
    PAYLOAD=$(cat)
fi

if [ -z "$PAYLOAD" ]; then
    echo '{"ok":false,"error":"no payload"}'
    exit 1
fi

# Parse JSON payload
PARSED=$(PAYLOAD="$PAYLOAD" python3 << 'PYEOF'
import os, json, sys
try:
    d = json.loads(os.environ['PAYLOAD'])
    print(json.dumps({
        "secret": d.get("secret", ""),
        "chat_id": str(d.get("chat_id", "")),
        "message": d.get("message", ""),
        "silent": d.get("silent", False)
    }))
except Exception as e:
    print(json.dumps({"error": str(e)}))
PYEOF
)

ERROR=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
if [ -n "$ERROR" ]; then
    log "REJECT parse_error=$ERROR"
    echo '{"ok":false,"error":"invalid payload"}'
    exit 1
fi

SECRET=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin)['secret'])" 2>/dev/null)
CHAT_ID=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin)['chat_id'])" 2>/dev/null)
MESSAGE=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin)['message'])" 2>/dev/null)
SILENT=$(echo "$PARSED" | python3 -c "import sys,json;print('--silent' if json.load(sys.stdin)['silent'] else '')" 2>/dev/null)

# Validate secret
if [ "$SECRET" != "$WEBHOOK_SECRET" ]; then
    log "REJECT invalid_secret chat=$CHAT_ID"
    echo '{"ok":false,"error":"unauthorized"}'
    exit 1
fi

if [ -z "$CHAT_ID" ] || [ -z "$MESSAGE" ]; then
    log "REJECT missing_fields chat=$CHAT_ID msg_len=${#MESSAGE}"
    echo '{"ok":false,"error":"missing chat_id or message"}'
    exit 1
fi

# Forward via tg-send.sh
echo "$MESSAGE" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" $SILENT 2>/dev/null # intentionally unquoted: $SILENT is either --silent or empty
RESULT=$?

if [ $RESULT -eq 0 ]; then
    log "DELIVERED chat=$CHAT_ID msg_len=${#MESSAGE}"
    echo '{"ok":true}'
else
    log "FAIL chat=$CHAT_ID result=$RESULT"
    echo '{"ok":false,"error":"send failed"}'
    exit 1
fi
