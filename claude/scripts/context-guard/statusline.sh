#!/bin/bash
# Context Guard - Status Line Monitor (Primary Sensor)
# Runs after each assistant turn via statusLine config.
# Receives context window data on stdin, writes threshold flags,
# and outputs status text for the status bar.

FLAG="/tmp/.claude-context-guard"
NOTIFIED="/tmp/.claude-context-guard-notified"
RAW="/tmp/.claude-context-guard-raw"

INPUT=$(cat)

# Save raw input for debugging
echo "$INPUT" > "$RAW"

# Extract remaining percentage using python3 (robust JSON parsing)
REMAINING=$(python3 -c "
import json, sys
try:
    d = json.loads('''$(echo "$INPUT" | sed "s/'/\\\\'/g")''')
    # Try various possible paths
    cw = d.get('context_window', d.get('contextWindow', d))
    if isinstance(cw, dict):
        r = cw.get('remaining_percentage',
            cw.get('remainingPercentage',
            cw.get('remaining_percent',
            cw.get('remaining', -1))))
        print(float(r))
    else:
        print(-1)
except:
    print(-1)
" 2>/dev/null)

REMAINING=${REMAINING:--1}

# If we got valid data, use it for precise monitoring
if python3 -c "exit(0 if float('$REMAINING') >= 0 else 1)" 2>/dev/null; then
    # Determine urgency level based on remaining %
    # Level 3 must fire CLOSE to auto-compact (~3% remaining), not 17% before it
    LEVEL=$(python3 -c "
r = float('$REMAINING')
if r < 8: print(3)
elif r < 18: print(2)
elif r < 30: print(1)
else: print(0)
" 2>/dev/null)

    LEVEL=${LEVEL:-0}

    # Read current notified level
    CURRENT=0
    [ -f "$NOTIFIED" ] && CURRENT=$(cat "$NOTIFIED" 2>/dev/null)
    CURRENT=${CURRENT:-0}

    # Only escalate, never repeat
    if [ "$LEVEL" -gt "$CURRENT" ] && [ "$LEVEL" -gt 0 ]; then
        echo "$LEVEL" > "$FLAG"
        echo "$LEVEL" > "$NOTIFIED"
    fi

    # Format status display
    USED=$(python3 -c "print(int(100 - float('$REMAINING')))" 2>/dev/null)
    if [ "$LEVEL" -ge 3 ]; then
        echo "CTX:${USED}% CRITICAL"
    elif [ "$LEVEL" -ge 2 ]; then
        echo "CTX:${USED}%!"
    elif [ "$LEVEL" -ge 1 ]; then
        echo "CTX:${USED}%"
    else
        echo "CTX:${USED}%"
    fi
else
    # No context data available - display nothing, fallback to counter
    echo ""
fi

exit 0
