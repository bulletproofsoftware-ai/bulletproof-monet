#!/bin/bash
# Context Guard - PostToolUse Counter (Fallback Sensor)
# Counts tool calls as a proxy for context consumption.
# Only writes flags if the statusLine monitor hasn't already.
# Tighter thresholds for SSH-heavy sessions that eat context fast.

COUNTER="/tmp/.claude-context-counter"
FLAG="/tmp/.claude-context-guard"
NOTIFIED="/tmp/.claude-context-guard-notified"

# Increment counter
COUNT=0
[ -f "$COUNTER" ] && COUNT=$(cat "$COUNTER" 2>/dev/null)
COUNT=${COUNT:-0}
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER"

# Check if statusLine monitor is active (has written raw data recently)
# If it is, let it handle the flags - it has actual context % data
if [ -f "/tmp/.claude-context-guard-raw" ]; then
    # Only trust statusline if it's been updated in the last 60 seconds
    AGE=$(( $(date +%s) - $(stat -f %m "/tmp/.claude-context-guard-raw" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 60 ] && exit 0
fi

# Fallback: use tool count as proxy for context consumption
# Relaxed thresholds — let auto-compact handle the hard stop
LEVEL=0
if [ "$COUNT" -ge 80 ]; then
    LEVEL=3
elif [ "$COUNT" -ge 50 ]; then
    LEVEL=2
elif [ "$COUNT" -ge 30 ]; then
    LEVEL=1
fi

[ "$LEVEL" -eq 0 ] && exit 0

# Read current notified level
CURRENT=0
[ -f "$NOTIFIED" ] && CURRENT=$(cat "$NOTIFIED" 2>/dev/null)
CURRENT=${CURRENT:-0}

# Only escalate, never repeat
if [ "$LEVEL" -gt "$CURRENT" ]; then
    echo "$LEVEL" > "$FLAG"
    echo "$LEVEL" > "$NOTIFIED"
fi

exit 0
