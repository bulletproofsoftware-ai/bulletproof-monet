#!/bin/bash
# monet-dispatch.sh <chat_id> <prompt> [session_id]
# Try inline (<=MONET_INLINE_TIMEOUT s). On timeout, promote to the async queue and ack.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail
export PATH="/usr/local/bin:$PATH"
CHAT_ID="${1:?chat_id}"; PROMPT="${2:?prompt}"; SESSION_ID="${3:-}"
INLINE_T="${MONET_INLINE_TIMEOUT:-75}"
ASYNC="${MONET_ASYNC_DEFAULT:-1}"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
CLAUDE_BIN="${MONET_CLAUDE_BIN:-claude}"
TG_SEND="${MONET_TG_SEND:-${MONET_HOME}/tg-send.sh}"
QUEUE="${MONET_HOME}/src/monet-queue"
# Log under MONET_LOG_DIR by default: /var/log is not writable by the service user
# on a clean install, and an unwritable `2>>"$LOG"` redirect below would make the
# inline run fail with EC=1 before `timeout` ever reports 124 — silently killing
# the promote-to-queue path. Fall back to /dev/null if the dir cannot be created.
LOG="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{ : >> "$LOG"; } 2>/dev/null || LOG=/dev/null
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dispatch] $*" >> "$LOG"; }

run_inline(){
  local args=(-p --model "$MODEL" --max-turns 15 --dangerously-skip-permissions --disable-slash-commands --output-format json)
  [ -n "$SESSION_ID" ] && args+=(--resume "$SESSION_ID")
  RAW=$(timeout "$INLINE_T" "$CLAUDE_BIN" "${args[@]}" "$PROMPT" 2>>"$LOG")
  EC=$?
}

RAW=""; EC=0
run_inline
if [ "$EC" = "124" ] && [ "$ASYNC" = "1" ]; then
    jid=$("$QUEUE" enqueue "$CHAT_ID" "$PROMPT" "$SESSION_ID")
    log "PROMOTE inline timeout -> queued $jid"
    # Send an editable progress message and stash its id so the worker can update it.
    PMID=$("$MONET_HOME"/src/monet-progress.sh send "$CHAT_ID" "⏳ Working on that — this one needs a bit longer. I will update here." 2>/dev/null)
    # Write into the queue dir actually in use, not a hardcoded $MONET_HOME/queue.
    [ -n "$PMID" ] && echo "$PMID" > "${MONET_QUEUE_DIR:-${MONET_HOME}/queue}/$jid/progress_msg_id" 2>/dev/null || true
    exit 0
fi
if [ "$EC" != "0" ] || [ -z "${RAW:-}" ]; then
    log "inline error ec=$EC (async=$ASYNC)"
    printf '%s' "⚠️ I hit an error on that one. Try again?" | "$TG_SEND" "$CHAT_ID" 2>/dev/null || true
    exit 0
fi
echo "$RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null
