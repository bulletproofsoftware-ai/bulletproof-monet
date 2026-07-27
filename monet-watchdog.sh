#!/bin/bash
# Monet Watchdog - kills stuck monet/claude processes, manages background jobs
# Run via cron every minute: * * * * * "$MONET_HOME"/monet-watchdog.sh
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
NOW=$(date +%s)
export PATH="/usr/local/bin:$PATH"
MAX_AGE=360  # 6 minutes (allows time for research agent / subagent workflows)
BG_MAX_AGE=2100  # 35 minutes (30min bg timeout + 5min buffer)
BG_DIR="${MONET_HOME}/bg-jobs"


for PROC in "monet-tg.sh" "monet-sms.sh"; do
    for PID in $(pgrep -f "$PROC"); do
        PSTART=$(stat -c %Y /proc/"$PID" 2>/dev/null || echo "$NOW")
        AGE=$((NOW - PSTART))
        if [ "$AGE" -gt "$MAX_AGE" ]; then
            logger -t monet-watchdog "Killing stuck $PROC (PID $PID, age ${AGE}s)"
            kill -9 "$PID" 2>/dev/null
            pkill -9 -P "$PID" 2>/dev/null
        fi
    done
done

# Kill orphaned claude processes not attached to a monet script or bg-runner
for PID in $(pgrep -f "claude -p.*--output-format json"); do
    PARENT_PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
    if [ -z "$PARENT_PID" ] || [ "$PARENT_PID" = "1" ]; then
        # Check if this claude process belongs to a bg-runner (don't kill those)
        IS_BG=false
        if [ -d "$BG_DIR" ]; then
            for PID_FILE in "$BG_DIR"/*/pid; do
                [ -f "$PID_FILE" ] || continue
                BG_PID=$(cat "$PID_FILE" 2>/dev/null)
                if [ -n "$BG_PID" ] && kill -0 "$BG_PID" 2>/dev/null; then
                    # Check if this claude process is a child of the bg-runner
                    CLAUDE_PARENT=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
                    if [ "$CLAUDE_PARENT" = "$BG_PID" ]; then
                        IS_BG=true
                        break
                    fi
                fi
            done
        fi
        if ! $IS_BG; then
            PSTART=$(stat -c %Y /proc/"$PID" 2>/dev/null || echo "$NOW")
            AGE=$((NOW - PSTART))
            if [ "$AGE" -gt "$MAX_AGE" ]; then
                logger -t monet-watchdog "Killing orphaned claude (PID $PID, age ${AGE}s)"
                kill -9 "$PID" 2>/dev/null
            fi
        fi
    fi
done

# --- Background job management ---
if [ -d "$BG_DIR" ]; then
    for JOB_PATH in "$BG_DIR"/bg-*; do
        [ -d "$JOB_PATH" ] || continue
        JOB_STATUS=$(cat "$JOB_PATH/status" 2>/dev/null)
        [ "$JOB_STATUS" != "running" ] && continue

        PID_FILE="$JOB_PATH/pid"
        [ ! -f "$PID_FILE" ] && continue

        BG_PID=$(cat "$PID_FILE" 2>/dev/null)
        [ -z "$BG_PID" ] && continue
        JOB_NAME=$(basename "$JOB_PATH")

        # Check if process is actually running
        if ! kill -0 "$BG_PID" 2>/dev/null; then
            # Process dead but status still "running" — crashed
            echo "killed" > "$JOB_PATH/status"
            echo "Process disappeared" > "$JOB_PATH/error"
            date +%s > "$JOB_PATH/finished"
            rm -f "$PID_FILE"

            CHAT_ID=$(cat "$JOB_PATH/chat_id" 2>/dev/null)
            if [ -n "$CHAT_ID" ] && [ -n "${BOT_TOKEN:-}" ]; then
                echo "Background job ${JOB_NAME} died unexpectedly." | \
                    "$MONET_HOME"/tg-send.sh "$CHAT_ID" --silent 2>/dev/null &
            fi
            logger -t monet-watchdog "Cleaned up dead bg job $JOB_NAME (PID $BG_PID gone)"
            continue
        fi

        # Check age — kill if over BG_MAX_AGE
        PSTART=$(stat -c %Y /proc/"$BG_PID" 2>/dev/null || echo "$NOW")
        AGE=$((NOW - PSTART))
        if [ "$AGE" -gt "$BG_MAX_AGE" ]; then
            logger -t monet-watchdog "Killing stale bg job $JOB_NAME (PID $BG_PID, age ${AGE}s)"

            # Kill claude subprocess first, then the runner
            pkill -9 -P "$BG_PID" 2>/dev/null
            kill -9 "$BG_PID" 2>/dev/null

            echo "killed" > "$JOB_PATH/status"
            echo "Killed by watchdog after ${AGE}s" > "$JOB_PATH/error"
            date +%s > "$JOB_PATH/finished"
            rm -f "$PID_FILE"

            CHAT_ID=$(cat "$JOB_PATH/chat_id" 2>/dev/null)
            if [ -n "$CHAT_ID" ] && [ -n "${BOT_TOKEN:-}" ]; then
                echo "Background job ${JOB_NAME} was killed (exceeded time limit)." | \
                    "$MONET_HOME"/tg-send.sh "$CHAT_ID" --silent 2>/dev/null &
            fi
        fi
    done

    # Cleanup old completed job directories (older than 24 hours)
    find "$BG_DIR" -maxdepth 1 -type d -name "bg-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null
fi
