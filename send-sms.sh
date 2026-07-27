#!/bin/bash
# send-sms.sh — Send an SMS via the Twilio REST API.
# Usage: send-sms.sh <+E164number> <message>
#
# Prints exactly "OK" on success, or "ERROR: <reason>" on failure, because the
# assistant's system prompt tells the model to check this output for OK or error.
#
# Config: TWILIO_SID, TWILIO_TOKEN, TWILIO_FROM. All three are required; unset
# means SMS is unavailable and this exits non-zero without sending.
#
# When the recipient is not SMS_AUTHORIZED_NUMBER, a copy is sent there so the
# operator keeps a record of anything sent on their behalf. A failed copy does
# not fail the run — the primary message already went out.
#
# The auth token is passed to curl via --netrc-style stdin config, never as an
# argv element, so it does not appear in the process table.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

TO="${1:-}"
BODY="${2:-}"

LOG_DIR="${MONET_LOG_DIR:-${MONET_HOME}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="${LOG_DIR}/monet-sms.log"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] SMS $*" >> "$LOG" 2>/dev/null; }

if [ -z "$TO" ] || [ -z "$BODY" ]; then
    echo "ERROR: usage: send-sms.sh <+E164number> <message>"
    exit 2
fi

if [ -z "${TWILIO_SID:-}" ] || [ -z "${TWILIO_TOKEN:-}" ] || [ -z "${TWILIO_FROM:-}" ]; then
    log "SKIP not configured to=$TO"
    echo "ERROR: Twilio is not configured (set TWILIO_SID, TWILIO_TOKEN, TWILIO_FROM in .env)"
    exit 1
fi

# E.164: leading +, 8-15 digits. Reject anything else rather than letting a
# malformed number reach the API.
if ! printf '%s' "$TO" | grep -qE '^\+[1-9][0-9]{7,14}$'; then
    echo "ERROR: recipient is not a valid E.164 number (expected +15551234567): $TO"
    exit 2
fi

API="https://api.twilio.com/2010-04-01/Accounts/${TWILIO_SID}/Messages.json"

# Sends one message. Body and number go through --data-urlencode, so no value is
# ever interpreted by the shell or by curl's option parser.
send_one(){
    local dest="$1" text="$2"
    curl -s --max-time 30 -X POST "$API" \
        --config <(printf 'user = "%s:%s"\n' "$TWILIO_SID" "$TWILIO_TOKEN") \
        --data-urlencode "To=${dest}" \
        --data-urlencode "From=${TWILIO_FROM}" \
        --data-urlencode "Body=${text}"
}

log "START to=$TO len=${#BODY}"

RESPONSE=$(send_one "$TO" "$BODY")

# Twilio returns a JSON object carrying either "sid" (accepted) or "message"
# (the error text). Parse rather than grepping so a body containing the word
# "sid" cannot fake a success.
PARSED=$(printf '%s' "$RESPONSE" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERROR: unparseable response from Twilio")
    raise SystemExit(0)
if d.get("sid"):
    print("OK %s" % d["sid"])
else:
    print("ERROR: %s" % d.get("message", "unknown Twilio error"))
' 2>/dev/null)

case "$PARSED" in
    OK\ *)
        SID="${PARSED#OK }"
        log "SENT to=$TO sid=$SID"
        # Best-effort copy to the operator; never fails the primary send.
        if [ -n "${SMS_AUTHORIZED_NUMBER:-}" ] && [ "$TO" != "$SMS_AUTHORIZED_NUMBER" ]; then
            if send_one "$SMS_AUTHORIZED_NUMBER" "[copy -> ${TO}] ${BODY}" >/dev/null 2>&1; then
                log "COPY sent to=$SMS_AUTHORIZED_NUMBER"
            else
                log "COPY failed to=$SMS_AUTHORIZED_NUMBER (primary already delivered)"
            fi
        fi
        echo "OK"
        exit 0
        ;;
    *)
        log "FAIL to=$TO: $PARSED"
        echo "${PARSED:-ERROR: send failed}"
        exit 1
        ;;
esac
