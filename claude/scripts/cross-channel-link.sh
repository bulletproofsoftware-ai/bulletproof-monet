#!/bin/bash
# Cross-channel session linking for Monet
# Links TG and SMS sessions so context carries over when user switches channels
# Usage: cross-channel-link.sh <channel> <session_id> [check|link]

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../../lib/monet-env.sh"
CHANNEL="$1"
SESSION_ID="$2"
ACTION="${3:-check}"
LINK_FILE="${MONET_HOME}/data/session-links.json"

if [ -z "$CHANNEL" ] || [ -z "$SESSION_ID" ]; then
    echo "Usage: cross-channel-link.sh <channel> <session_id> [check|link]" >&2
    exit 1
fi

case "$CHANNEL" in
    tg)  OTHER_CHANNEL="sms" ;;
    sms) OTHER_CHANNEL="tg" ;;
    *)   echo "Error: channel must be tg or sms" >&2; exit 1 ;;
esac

mkdir -p "$MONET_HOME"/data

if [ ! -f "$LINK_FILE" ]; then
    echo '[]' > "$LINK_FILE"
fi

NOW=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$ACTION" = "link" ]; then
    # Mark previous entries for this channel as active: false, then add new entry
    UPDATED=$(jq --arg ch "$CHANNEL" --arg sid "$SESSION_ID" --arg ts "$NOW_ISO" \
        '[.[] | if .channel == $ch then .active = false else . end] + [{"channel": $ch, "session_id": $sid, "timestamp": $ts, "active": true}]' \
        "$LINK_FILE" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$UPDATED" ]; then
        echo "$UPDATED" > "$LINK_FILE"
    fi

elif [ "$ACTION" = "check" ]; then
    # Look for active sessions on the OTHER channel within 30 minutes
    RESULT=$(python3 -c "
import json, sys, os
from datetime import datetime, timezone

link_file = '$LINK_FILE'
other_channel = '$OTHER_CHANNEL'
now = int('$NOW')

try:
    with open(link_file) as f:
        entries = json.load(f)
except:
    sys.exit(0)

# Find active entry for the other channel
active = [e for e in entries if e.get('channel') == other_channel and e.get('active') is True]
if not active:
    sys.exit(0)

latest = active[-1]
ts_str = latest.get('timestamp', '')
try:
    ts = datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    elapsed = now - int(ts.timestamp())
except:
    sys.exit(0)

if elapsed < 1800:
    minutes = elapsed // 60
    sid = latest.get('session_id', 'unknown')
    print(f'Active {other_channel} session (ID: {sid}, {minutes}min ago) — context may carry over.')
" 2>/dev/null)

    if [ -n "$RESULT" ]; then
        echo "$RESULT"
    fi
fi
