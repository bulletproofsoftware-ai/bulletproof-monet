#!/bin/bash
# monet-bg-runner.sh — Execute a background Claude job and deliver results via Telegram
# Usage: monet-bg-runner.sh <job-id>
# Called by monet-tg.sh via nohup, runs fully detached. Does NOT hold the main lock.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working directory.
# Without this, sessions land in a stray slug dir and later --resume fails with
# "No conversation found" on a transcript that exists.
set -uo pipefail

JOB_ID="${1:-}"
QUEUE_DIR="${MONET_QUEUE_DIR:-${MONET_HOME}/queue}"
if [ -d "$QUEUE_DIR/${JOB_ID}" ]; then
    JOB_DIR="$QUEUE_DIR/${JOB_ID}"
else
    JOB_DIR="${MONET_HOME}/bg-jobs/${JOB_ID}"
fi
BG_TIMEOUT=1800  # 30 minutes
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [bg:${JOB_ID}] $*" >> "$LOG_FILE"; }

# --- Validate job ---
if [ -z "$JOB_ID" ] || [ ! -d "$JOB_DIR" ]; then
    echo "Invalid job ID or directory not found" >&2
    exit 1
fi

log "resolved job dir: $JOB_DIR"
if [ "${MONET_DRYRUN:-0}" = "1" ]; then
    echo "resolved job dir: $JOB_DIR"
    exit 0
fi

# Required only for the real delivery path below; the dry-run above resolves the
# job dir and exits without ever contacting Telegram.
: "${BOT_TOKEN:?BOT_TOKEN not set}"

PROMPT=$(cat "$JOB_DIR/prompt" 2>/dev/null)
CHAT_ID=$(cat "$JOB_DIR/chat_id" 2>/dev/null)

if [ -z "$PROMPT" ] || [ -z "$CHAT_ID" ]; then
    log "ERROR missing prompt or chat_id"
    echo "failed" > "$JOB_DIR/status"
    echo "Missing prompt or chat_id" > "$JOB_DIR/error"
    date +%s > "$JOB_DIR/finished"
    exit 1
fi

# --- Write PID for watchdog ---
echo $$ > "$JOB_DIR/pid"

# --- Typing loop ---
TYPING_LOOP_PID=""
start_typing_loop() {
    [ -z "$CHAT_ID" ] && return
    (
        while true; do
            curl -s --max-time 3 -X POST \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
                -d "chat_id=${CHAT_ID}&action=typing" >/dev/null 2>&1
            sleep 4
        done
    ) &
    TYPING_LOOP_PID=$!
}
stop_typing_loop() {
    if [ -n "$TYPING_LOOP_PID" ]; then
        kill "$TYPING_LOOP_PID" 2>/dev/null
        wait "$TYPING_LOOP_PID" 2>/dev/null
        TYPING_LOOP_PID=""
    fi
}

# --- EXIT trap: catch all failure modes ---
cleanup() {
    stop_typing_loop
    rm -f "$JOB_DIR/pid"
    local current_status
    current_status=$(cat "$JOB_DIR/status" 2>/dev/null)
    if [ "$current_status" = "running" ]; then
        echo "killed" > "$JOB_DIR/status"
        echo "Process terminated unexpectedly" > "$JOB_DIR/error"
        date +%s > "$JOB_DIR/finished"
        log "KILLED unexpected exit"
        echo "Background job ${JOB_ID} was terminated unexpectedly." | \
            "$MONET_HOME"/tg-send.sh "$CHAT_ID" --silent 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Start ---
log "START prompt=\"${PROMPT:0:80}\""
start_typing_loop

# --- Recall memory context ---
MEMORY_CTX=""
MEMORY_CTX=$(timeout 8 python3 "$MONET_HOME"/tg-memory.py recall "$CHAT_ID" "$PROMPT" 2>/dev/null) || true

FULL_PROMPT="$PROMPT"
if [ -n "$MEMORY_CTX" ]; then
    FULL_PROMPT="${MEMORY_CTX}
${PROMPT}"
fi

# --- Run Claude ---
log "CLAUDE fresh model=$MODEL timeout=${BG_TIMEOUT}s"
RAW=$(timeout "$BG_TIMEOUT" claude -p --model "$MODEL" --dangerously-skip-permissions --max-turns 30 --output-format json "$FULL_PROMPT" 2>>"$LOG_FILE")
EXIT_CODE=$?

# --- Handle timeout ---
if [ $EXIT_CODE -eq 124 ]; then
    log "TIMEOUT after ${BG_TIMEOUT}s"
    echo "timeout" > "$JOB_DIR/status"
    echo "Timed out after $((BG_TIMEOUT / 60)) minutes" > "$JOB_DIR/error"
    date +%s > "$JOB_DIR/finished"
    stop_typing_loop
    echo "Background job ${JOB_ID} timed out after $((BG_TIMEOUT / 60)) minutes.
Prompt: ${PROMPT:0:100}..." | ${MONET_HOME}/tg-send.sh "$CHAT_ID" 2>/dev/null || true
    trap - EXIT
    rm -f "$JOB_DIR/pid"
    exit 0
fi

# --- Handle error ---
if [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
    log "ERROR exit=$EXIT_CODE raw_len=${#RAW}"
    echo "failed" > "$JOB_DIR/status"
    echo "Claude exited with code $EXIT_CODE" > "$JOB_DIR/error"
    date +%s > "$JOB_DIR/finished"
    stop_typing_loop
    echo "Background job ${JOB_ID} failed (error code $EXIT_CODE).
Prompt: ${PROMPT:0:100}..." | ${MONET_HOME}/tg-send.sh "$CHAT_ID" 2>/dev/null || true
    trap - EXIT
    rm -f "$JOB_DIR/pid"
    exit 0
fi

# --- Extract response ---
SESSION_ID=$(echo "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
RESPONSE=$(echo "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    log "EMPTY response"
    echo "failed" > "$JOB_DIR/status"
    echo "Empty response from Claude" > "$JOB_DIR/error"
    date +%s > "$JOB_DIR/finished"
    stop_typing_loop
    echo "Background job ${JOB_ID} completed but returned no output.
Prompt: ${PROMPT:0:100}..." | ${MONET_HOME}/tg-send.sh "$CHAT_ID" 2>/dev/null || true
    trap - EXIT
    rm -f "$JOB_DIR/pid"
    exit 0
fi

# --- Success ---
log "DONE resp_len=${#RESPONSE} session=$SESSION_ID"
PMID=$(cat "$JOB_DIR/progress_msg_id" 2>/dev/null)
if [ -n "$PMID" ]; then
    "$MONET_HOME"/src/monet-progress.sh edit "$CHAT_ID" "$PMID" "✅ Done — sending the answer below." 2>/dev/null || true
fi
echo "completed" > "$JOB_DIR/status"
echo "$RESPONSE" > "$JOB_DIR/result"
[ -n "$SESSION_ID" ] && echo "$SESSION_ID" > "$JOB_DIR/session_id"
date +%s > "$JOB_DIR/finished"
stop_typing_loop

# --- Deliver result via Telegram ---
# Check for [IMG]url[/IMG] markers
IMG_URL=""
TEXT_RESPONSE="$RESPONSE"
IMG_MATCH=$(echo "$RESPONSE" | grep -oP '\[IMG\](https?://[^\[]+)\[/IMG\]' | head -1) || true
if [ -n "$IMG_MATCH" ]; then
    IMG_URL=$(echo "$IMG_MATCH" | sed 's/\[IMG\]//;s/\[\/IMG\]//')
    TEXT_RESPONSE=$(echo "$RESPONSE" | sed 's/\[IMG\]https\?:\/\/[^\[]*\[\/IMG\]//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

# Prepend job header
DELIVERY_TEXT="[bg:${JOB_ID}] Done

${TEXT_RESPONSE}"

if [ -n "$IMG_URL" ]; then
    echo "$DELIVERY_TEXT" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" --photo "$IMG_URL" 2>/dev/null || true
else
    echo "$DELIVERY_TEXT" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null || true
fi

# --- Store in memory (non-blocking) ---
python3 "$MONET_HOME"/tg-memory.py store "$CHAT_ID" "[bg job] $PROMPT" "$RESPONSE" &>/dev/null &

# --- Clean exit ---
trap - EXIT
rm -f "$JOB_DIR/pid"
log "DELIVERED"
