#!/bin/bash
# Monet Telegram Handler - Hardened with aggressive timeouts, stale process reaping,
# session turn limits, automatic fresh-session fallback, and typing indicators.
# Supports: text, images, voice/audio, documents, and the 17-command allowlist
# enumerated by the /help handler below and by scripts/tg-register-commands.sh.
# The command surface is DENY BY DEFAULT: anything not in that allowlist is not a
# command and falls through to the normal chat path.
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:${MONET_HOME}/bin:$PATH"
MSG="$1"
TG_FILE_ID="$2"
CHAT_ID="$3"
MESSAGE_ID="${4:-}"

# Sanitize input: strip control characters (keep newlines/tabs for readability)
MSG=$(printf '%s' "$MSG" | tr -d '\000-\010\013-\014\016-\037')
STATE_FILE="${MONET_HOME}/.monet-tg-state"
LOCK_FILE="${MONET_HOME}/.monet-tg.lock"
NOW=$(date +%s)
SESSION_TIMEOUT=300      # 5min inactivity = new session
MAX_TURNS=40             # compaction at 15 and 30, hard limit at 40
CLAUDE_TIMEOUT_RESUME=180 # seconds for resume attempts
CLAUDE_TIMEOUT_FRESH=300  # seconds for fresh session
LOCK_WAIT=60             # seconds to wait for lock before giving up
IMG_DIR="${MONET_HOME}/tg-images"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
MEMORY_HINT="Before saying you don't know something about ${MONET_OWNER_NAME:-the operator}, ALWAYS call memory_recall first. When ${MONET_OWNER_NAME:-the operator} shares a preference or fact, store it with memory_store. Your CLAUDE.md has ${MONET_OWNER_NAME:-the operator}'s core preferences — read them. EMAIL: You can send emails on ${MONET_OWNER_NAME:-the operator}'s behalf from monet@example.com. When ${MONET_OWNER_NAME:-the operator} asks you to email someone: 1) Use memory_recall to look up the recipient's email address if only a name is given. If not found, ask for it and store it with memory_store for next time. 2) Draft the email and show a preview: To, Subject, and Body. 3) WAIT for ${MONET_OWNER_NAME:-the operator} to confirm (yes/send/ok) or request changes. NEVER send without explicit confirmation. 4) On confirmation, send via Bash: ${MONET_HOME}/send-email.sh 'recipient@example.com' 'Subject here' 'Plain text body here' — check output for OK or error. Report result back to ${MONET_OWNER_NAME:-the operator}. SMS: You can send text messages on ${MONET_OWNER_NAME:-the operator}'s behalf. When ${MONET_OWNER_NAME:-the operator} asks you to text/SMS someone: 1) Use memory_recall to look up the recipient's phone number if only a name is given. If not found, ask for it and store it with memory_store for next time. 2) Draft the message and show a preview: To (number), Message. 3) WAIT for ${MONET_OWNER_NAME:-the operator} to confirm. NEVER send without explicit confirmation. 4) On confirmation, send via Bash: ${MONET_HOME}/send-sms.sh '+1XXXXXXXXXX' 'Message text here' — check output for OK or error. Report result back to ${MONET_OWNER_NAME:-the operator}. Both scripts auto-copy ${MONET_OWNER_NAME:-the operator} (email: CC to you@example.com, SMS: copy to +1XXXXXXXXXX) when the recipient is not ${MONET_OWNER_NAME:-the operator}. TEMPORAL INTENT: When ${MONET_OWNER_NAME:-the operator} mentions future actions with time references (e.g. 'I need to follow up with John next week', 'check on the deploy tomorrow'), suggest a reminder: 'Want me to set a reminder? /remind 1w follow up with John' — one line, only when there's a clear time reference AND actionable task. Skip vague 'someday' statements. PHOTO INTELLIGENCE: When analyzing photos, identify the content type and include a tag at the END of your response on its own line: [PHOTO_TYPE:receipt], [PHOTO_TYPE:whiteboard], [PHOTO_TYPE:business_card], [PHOTO_TYPE:document], [PHOTO_TYPE:screenshot], [PHOTO_TYPE:note], or [PHOTO_TYPE:general]. For receipts, extract merchant/amount/date. For business cards, extract name/title/company/contact. For whiteboards, extract key points. For documents, summarize content. Always include the tag — it triggers auto-archiving."

# Load secrets from .env (set -a exports all vars for subprocesses)
set -a
set +a

# Required env vars
: "${BOT_TOKEN:?BOT_TOKEN not set}"

# /var/log is not writable by the service user on a clean install.
LOG_FILE="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
{ : >> "$LOG_FILE"; } 2>/dev/null || LOG_FILE=/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Load audit trail helpers
source "$MONET_HOME"/lib/audit_helpers.sh

mkdir -p "$IMG_DIR"

# --- Parse typed file_id (voice:ID, doc:ID, img:ID, or bare ID for backward compat) ---
FILE_TYPE=""
RAW_FILE_ID=""
if [ -n "$TG_FILE_ID" ]; then
    case "$TG_FILE_ID" in
        voice:*)
            FILE_TYPE="voice"
            RAW_FILE_ID="${TG_FILE_ID#voice:}"
            ;;
        doc:*)
            FILE_TYPE="doc"
            RAW_FILE_ID="${TG_FILE_ID#doc:}"
            ;;
        img:*)
            FILE_TYPE="img"
            RAW_FILE_ID="${TG_FILE_ID#img:}"
            ;;
        loc:*)
            FILE_TYPE="loc"
            RAW_FILE_ID="${TG_FILE_ID#loc:}"
            ;;
        *)
            # Backward compat: bare file_id defaults to img
            FILE_TYPE="img"
            RAW_FILE_ID="$TG_FILE_ID"
            ;;
    esac
fi

# --- Send typing indicator immediately ---
send_typing() {
    [ -n "$CHAT_ID" ] && curl -s --max-time 3 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
        -d "chat_id=${CHAT_ID}&action=typing" >/dev/null 2>&1 &
}
send_typing

# --- Message reactions (acknowledge receipt / signal completion) ---
send_reaction() {
    local emoji="$1"
    [ -z "$CHAT_ID" ] || [ -z "$MESSAGE_ID" ] && return
    curl -s --max-time 3 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/setMessageReaction" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":${CHAT_ID},\"message_id\":${MESSAGE_ID},\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"${emoji}\"}]}" >/dev/null 2>&1 &
}
clear_reaction() {
    [ -z "$CHAT_ID" ] || [ -z "$MESSAGE_ID" ] && return
    curl -s --max-time 3 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/setMessageReaction" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":${CHAT_ID},\"message_id\":${MESSAGE_ID},\"reaction\":[]}" >/dev/null 2>&1 &
}
# React with eyes emoji to acknowledge receipt
send_reaction "👀"

# --- Background typing loop (keeps indicator alive during long operations) ---
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

log "START msg=\"${MSG:0:80}\" file_type=${FILE_TYPE:-none} chat=$CHAT_ID"
audit_log --channel tg --action message_received --chat-id "$CHAT_ID" --details "${MSG:0:200}"

# --- Prompt injection detection ---
if [ -n "$MSG" ] && [ ${#MSG} -gt 10 ]; then
    INJECTION_JSON=$(check_injection "$MSG")
    INJECTION_BLOCKED=$(echo "$INJECTION_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('blocked',False))" 2>/dev/null)
    if [ "$INJECTION_BLOCKED" = "True" ]; then
        INJECTION_SEVERITY=$(echo "$INJECTION_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('severity','unknown'))" 2>/dev/null)
        INJECTION_PATTERNS=$(echo "$INJECTION_JSON" | python3 -c "import sys,json;print(','.join(json.load(sys.stdin).get('patterns',[])))" 2>/dev/null)
        log "INJECTION_BLOCKED severity=$INJECTION_SEVERITY patterns=$INJECTION_PATTERNS msg=\"${MSG:0:100}\""
        audit_log --channel tg --action injection_blocked --chat-id "$CHAT_ID" \
            --details "severity=$INJECTION_SEVERITY patterns=$INJECTION_PATTERNS"
        echo "Your message was flagged for potentially unsafe patterns. Please rephrase your request."
        clear_reaction
        exit 0
    fi
fi

# --- Reap stale processes (older than 2 min) ---
for PID in $(pgrep -f "monet-tg.sh" | grep -v $$); do
    PSTART=$(stat -c %Y /proc/"$PID" 2>/dev/null || echo "$NOW")
    AGE=$((NOW - PSTART))
    if [ "$AGE" -gt 120 ]; then
        kill -9 "$PID" 2>/dev/null
        pkill -9 -P "$PID" 2>/dev/null
    fi
done

# --- Acquire lock ---
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" 9; then
    HOLDER=$(fuser "$LOCK_FILE" 2>/dev/null | tr -d ' ')
    if [ -n "$HOLDER" ]; then
        kill -9 "$HOLDER" 2>/dev/null
        pkill -9 -P "$HOLDER" 2>/dev/null
        sleep 1
    fi
    if ! flock -w 5 9; then
        echo "I'm overloaded right now. Try again in a minute."
        exit 0
    fi
fi

# --- /start handler ---
if echo "$MSG" | grep -iqE "^/?(start)$"; then
    rm -f "$STATE_FILE"
    cat << 'STARTEOF'
Welcome to Monet — your self-hosted assistant. Just send a message to talk.

/help  - Show every command
/new   - Start a fresh conversation

You can also send text, photos, voice notes, or documents.
STARTEOF
    exit 0
fi

# --- /help handler ---
# This list is the command allowlist. It must stay in sync with
# scripts/tg-register-commands.sh -- both enumerate the SAME 17 commands.
if echo "$MSG" | grep -iqE '^/?(help)$'; then
    cat << 'HELPEOF'
Monet Bot Commands:

Conversation:
/help - Show this help message
/new - Start a fresh conversation
/export - Export the current session as a summary

Reminders:
/remind <time> <msg> - Set a reminder (e.g. 30m, 2h, 8am)
/reminders - List pending reminders

Clips & Bookmarks:
/clip <tag> <content> - Save a snippet with a tag
/clips [tag] - List saved clips (optional tag filter)
/find <query> - Semantic search across clips
/mark <label> - Bookmark this conversation moment
/marks - List all bookmarks
/recall <label> - Search bookmarks by label

Search & Memory:
/search <query> - Unified search across your local data
/memory-stats - Memory backend stats
/memory-export - Export stored memories

Utilities:
/ss <url> - Screenshot a URL
/photo-log - View auto-archived photo analyses
/usage - Token usage summary (7 days)

You can also send:
- Text messages for conversation
- Photos for image analysis (multiple photos supported)
- Voice notes for transcription + response
- Documents (PDF, text) for analysis
- URLs in messages are auto-fetched for context
HELPEOF
    exit 0
fi

# --- /usage handler ---
if echo "$MSG" | grep -iqE '^/?(usage)(\s|$)'; then
    log "COMMAND usage"
    USAGE_OUTPUT=$(get_usage_summary)
    echo "$USAGE_OUTPUT"
    audit_log --channel tg --action command_usage --chat-id "$CHAT_ID"
    exit 0
fi

# --- /memory-export handler ---
if echo "$MSG" | grep -iqE '^/?(memory-export|memexport)(\s|$)'; then
    log "COMMAND memory-export"
    start_typing_loop
    EXPORT_OUTPUT=$(python3 "$MONET_HOME"/scripts/memory-export.py export 2>&1)
    stop_typing_loop
    audit_log --channel tg --action memory_export --chat-id "$CHAT_ID"
    echo "$EXPORT_OUTPUT"
    exit 0
fi

# --- /memory-stats handler ---
if echo "$MSG" | grep -iqE '^/?(memory-stats|memstats)(\s|$)'; then
    log "COMMAND memory-stats"
    STATS_OUTPUT=$(python3 "$MONET_HOME"/scripts/memory-export.py list 2>&1)
    echo "$STATS_OUTPUT"
    exit 0
fi

# --- /new handler ---
if echo "$MSG" | grep -iqE '^/?(new)$'; then
    rm -f "$STATE_FILE"
    echo "Session cleared. Starting fresh!"
    exit 0
fi

# --- /export handler ---
if echo "$MSG" | grep -iqE '^/?(export)$'; then
    SESSION_ID=""
    if [ -f "$STATE_FILE" ]; then
        SESSION_ID=$(sed -n '1p' "$STATE_FILE")
    fi
    if [ -z "$SESSION_ID" ]; then
        echo "No active session to export."
        exit 0
    fi
    EXPORT=$(claude -p --resume "$SESSION_ID" --dangerously-skip-permissions --disable-slash-commands --output-format json "Output a complete summary of our conversation so far. List each exchange (user message and your response) in order." 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
    if [ -n "$EXPORT" ]; then
        echo "$EXPORT"
    else
        echo "Could not export session. The session may have expired."
    fi
    exit 0
fi

# --- MCP command handlers (force fresh session — standalone queries) ---
FORCE_FRESH=false

# Force fresh session for location shares (needs memory_store MCP tool)
if [ "$FILE_TYPE" = "loc" ]; then
    FORCE_FRESH=true
fi

# --- /remind handler ---
if echo "$MSG" | grep -iqE '^/?(remind)[[:space:]]+'; then
    REMIND_ARGS=$(echo "$MSG" | sed -E 's/^\/?(remind)[[:space:]]+//i')
    REMIND_FILE="${MONET_HOME}/reminders.json"
    [ -f "$REMIND_FILE" ] || echo '[]' > "$REMIND_FILE"

    # Parse: /remind <time> <message>
    # Time formats: 30m, 2h, 1d, 8am, 14:00, 2026-03-02T14:00
    PARSED=$(ARGS="$REMIND_ARGS" python3 << 'PYEOF'
import os, re, json, time
from datetime import datetime, timedelta

args = os.environ['ARGS'].strip()
now = time.time()

# Try to split into time part and message
# Relative: 30m, 2h, 1d, 1w
rel_match = re.match(r'^(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?|w|weeks?)\s+(.+)$', args, re.I)
if rel_match:
    num = int(rel_match.group(1))
    unit = rel_match.group(2)[0].lower()
    msg = rel_match.group(3)
    multipliers = {'m': 60, 'h': 3600, 'd': 86400, 'w': 604800}
    due = now + num * multipliers.get(unit, 60)
    print(json.dumps({"due": int(due), "message": msg}))
    exit()

# Time of day: 8am, 2pm, 14:00, 8:30am
tod_match = re.match(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$', args, re.I)
if tod_match:
    hour = int(tod_match.group(1))
    minute = int(tod_match.group(2) or 0)
    ampm = (tod_match.group(3) or '').lower()
    msg = tod_match.group(4)
    if ampm == 'pm' and hour < 12:
        hour += 12
    elif ampm == 'am' and hour == 12:
        hour = 0
    dt = datetime.now().replace(hour=hour, minute=minute, second=0, microsecond=0)
    if dt.timestamp() <= now:
        dt += timedelta(days=1)  # next occurrence
    print(json.dumps({"due": int(dt.timestamp()), "message": msg}))
    exit()

# ISO datetime: 2026-03-02T14:00
iso_match = re.match(r'^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2})\s+(.+)$', args)
if iso_match:
    dt = datetime.fromisoformat(iso_match.group(1))
    msg = iso_match.group(2)
    print(json.dumps({"due": int(dt.timestamp()), "message": msg}))
    exit()

# Fallback: treat first word as time spec, rest as message
print(json.dumps({"error": "Could not parse time. Use: /remind 30m <msg>, /remind 8am <msg>, or /remind 2026-03-02T14:00 <msg>"}))
PYEOF
    )

    ERROR=$(echo "$PARSED" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('error',''))" 2>/dev/null)
    if [ -n "$ERROR" ]; then
        echo "$ERROR"
        exit 0
    fi

    DUE=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin)['due'])" 2>/dev/null)
    REMIND_MSG=$(echo "$PARSED" | python3 -c "import sys,json;print(json.load(sys.stdin)['message'])" 2>/dev/null)
    REMIND_ID="r-${NOW}-$(python3 -c "import secrets;print(secrets.token_hex(3))")"

    # Add to reminders file
    DUE_TS="$DUE" R_MSG="$REMIND_MSG" R_ID="$REMIND_ID" R_CHAT="$CHAT_ID" R_CREATED="$NOW" python3 << 'PYEOF'
import os, json
f = os.environ.get('REMIND_FILE', os.path.join(os.environ.get('MONET_HOME', '/opt/monet'), 'reminders.json'))
try:
    with open(f) as fh:
        reminders = json.load(fh)
except:
    reminders = []
reminders.append({
    "id": os.environ['R_ID'],
    "chat_id": os.environ['R_CHAT'],
    "message": os.environ['R_MSG'],
    "due_ts": int(os.environ['DUE_TS']),
    "created_ts": int(os.environ['R_CREATED'])
})
with open(f, 'w') as fh:
    json.dump(reminders, fh, indent=2)
PYEOF

    # Format the due time for display
    DUE_DISPLAY=$(DUE_TS="$DUE" python3 -c "
import os; from datetime import datetime
print(datetime.fromtimestamp(int(os.environ['DUE_TS'])).strftime('%Y-%m-%d %H:%M'))
" 2>/dev/null)
    echo "Reminder set for ${DUE_DISPLAY}: ${REMIND_MSG}"
    exit 0
fi

# --- /reminders handler ---
if echo "$MSG" | grep -iqE '^/?(reminders)(\s|$)'; then
    REMIND_FILE="${MONET_HOME}/reminders.json"
    if [ ! -f "$REMIND_FILE" ]; then
        echo "No pending reminders."
        exit 0
    fi
    OUTPUT=$(NOW_TS="$NOW" python3 << 'PYEOF'
import json, os
from datetime import datetime

f = os.environ.get('REMIND_FILE', os.path.join(os.environ.get('MONET_HOME', '/opt/monet'), 'reminders.json'))
now = int(os.environ['NOW_TS'])
try:
    with open(f) as fh:
        reminders = json.load(fh)
except:
    reminders = []

if not reminders:
    print("No pending reminders.")
else:
    lines = ["Pending reminders:"]
    for r in sorted(reminders, key=lambda x: x['due_ts']):
        due = datetime.fromtimestamp(r['due_ts']).strftime('%Y-%m-%d %H:%M')
        remaining = r['due_ts'] - now
        if remaining > 3600:
            eta = f"{remaining // 3600}h {(remaining % 3600) // 60}m"
        elif remaining > 60:
            eta = f"{remaining // 60}m"
        elif remaining > 0:
            eta = f"{remaining}s"
        else:
            eta = "overdue"
        lines.append(f"• {due} (in {eta}): {r['message']}")
    print("\n".join(lines))
PYEOF
    )
    echo "$OUTPUT"
    exit 0
fi

# --- /ss handler (screenshot a URL via headless chromium) ---
if echo "$MSG" | grep -iqE '^/?ss[[:space:]]+'; then
    SS_URL=$(echo "$MSG" | sed -E 's/^\/?ss[[:space:]]+//i' | awk '{print $1}')
    if [ -z "$SS_URL" ]; then
        echo "Usage: /ss <url>"
        exit 0
    fi
    log "STANDALONE ss url=$SS_URL"
    SS_RESULT=$(timeout 90 "$MONET_HOME"/take-screenshot.sh "$SS_URL" 2>/dev/null)
    if [ -n "$SS_RESULT" ]; then
        echo "[IMG]${SS_RESULT}[/IMG]"
    else
        echo "Screenshot failed for: $SS_URL"
    fi
    exit 0
fi

# --- /clip handler (save a snippet) ---
if echo "$MSG" | grep -iqE '^/?(clip)[[:space:]]+'; then
    CLIP_ARGS=$(echo "$MSG" | sed -E 's/^\/?(clip)[[:space:]]+//i')
    CLIP_TAG=$(echo "$CLIP_ARGS" | awk '{print $1}')
    CLIP_CONTENT=$(echo "$CLIP_ARGS" | sed -E 's/^\S+\s*//')
    if [ -z "$CLIP_TAG" ] || [ -z "$CLIP_CONTENT" ]; then
        echo "Usage: /clip <tag> <content>
Example: /clip meeting-notes Decided to migrate to K8s by Q3"
        exit 0
    fi
    log "CLIP tag=$CLIP_TAG"
    RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py store "$CHAT_ID" "$CLIP_TAG" "$CLIP_CONTENT" 2>&1)
    echo "$RESULT"
    exit 0
fi

# --- /clips handler (list clips) ---
if echo "$MSG" | grep -iqE '^/?(clips)(\s|$)'; then
    CLIPS_TAG=$(echo "$MSG" | sed -E 's/^\/?(clips)\s*//i' | xargs)
    log "CLIPS list tag=$CLIPS_TAG"
    if [ -n "$CLIPS_TAG" ]; then
        RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py list "$CHAT_ID" --tag "$CLIPS_TAG" 2>&1)
    else
        RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py list "$CHAT_ID" 2>&1)
    fi
    echo "$RESULT"
    exit 0
fi

# --- /find handler (semantic search across clips) ---
if echo "$MSG" | grep -iqE '^/?(find)[[:space:]]+'; then
    FIND_QUERY=$(echo "$MSG" | sed -E 's/^\/?(find)[[:space:]]+//i')
    if [ -z "$FIND_QUERY" ]; then
        echo "Usage: /find <search query>"
        exit 0
    fi
    log "FIND query=\"$FIND_QUERY\""
    start_typing_loop
    RESULT=$(timeout 15 python3 "$MONET_HOME"/lib/clip_helper.py search "$CHAT_ID" "$FIND_QUERY" 2>&1)
    stop_typing_loop
    echo "$RESULT"
    exit 0
fi

# --- /photo-log handler (list photo clips) ---
if echo "$MSG" | grep -iqE '^/?(photo-log|photolog)(\s|$)'; then
    log "PHOTO-LOG list"
    RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py list "$CHAT_ID" --source photo 2>&1)
    echo "$RESULT"
    exit 0
fi

# --- /mark handler (bookmark current conversation) ---
if echo "$MSG" | grep -iqE '^/?(mark)[[:space:]]+'; then
    MARK_LABEL=$(echo "$MSG" | sed -E 's/^\/?(mark)[[:space:]]+//i' | xargs)
    if [ -z "$MARK_LABEL" ]; then
        echo "Usage: /mark <label>
Example: /mark important-decision"
        exit 0
    fi
    log "MARK label=$MARK_LABEL"
    # Get last exchange from memory
    LAST_EXCHANGE=$(timeout 5 python3 "$MONET_HOME"/tg-memory.py recent "$CHAT_ID" 1 2>/dev/null)
    if [ -z "$LAST_EXCHANGE" ]; then
        LAST_EXCHANGE="(no recent exchange to bookmark)"
    fi
    RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py store "$CHAT_ID" "$MARK_LABEL" "$LAST_EXCHANGE" bookmark 2>&1)
    echo "Bookmarked: $MARK_LABEL"
    exit 0
fi

# --- /marks handler (list bookmarks) ---
if echo "$MSG" | grep -iqE '^/?(marks|bookmarks)(\s|$)'; then
    log "MARKS list"
    RESULT=$(python3 "$MONET_HOME"/lib/clip_helper.py list "$CHAT_ID" --source bookmark 2>&1)
    echo "$RESULT"
    exit 0
fi

# --- /recall handler (search bookmarks) ---
if echo "$MSG" | grep -iqE '^/?(recall)[[:space:]]+'; then
    RECALL_QUERY=$(echo "$MSG" | sed -E 's/^\/?(recall)[[:space:]]+//i')
    if [ -z "$RECALL_QUERY" ]; then
        echo "Usage: /recall <label or keyword>"
        exit 0
    fi
    log "RECALL query=\"$RECALL_QUERY\""
    start_typing_loop
    RESULT=$(timeout 15 python3 "$MONET_HOME"/lib/clip_helper.py search "$CHAT_ID" "$RECALL_QUERY" --source bookmark 2>&1)
    stop_typing_loop
    echo "$RESULT"
    exit 0
fi

# --- /search handler (unified search across all collections) ---
if echo "$MSG" | grep -iqE '^/?(search)[[:space:]]+'; then
    SEARCH_QUERY=$(echo "$MSG" | sed -E 's/^\/?(search)[[:space:]]+//i')
    if [ -z "$SEARCH_QUERY" ]; then
        echo "Usage: /search <query>"
        exit 0
    fi
    log "SEARCH query=\"$SEARCH_QUERY\""
    start_typing_loop
    RESULT=$(timeout 20 python3 "$MONET_HOME"/lib/unified_search.py "$CHAT_ID" "$SEARCH_QUERY" 2>&1)
    stop_typing_loop
    echo "$RESULT"
    exit 0
fi

# --- Voice handler ---
# Inbound voice-note transcription is NOT bundled. The previous implementation
# required a third-party keyed speech-to-text service, which the OSS scrub removed
# along with the rest of the external-API surface. Rather
# than ship a stub that pretends to transcribe, a voice note without an
# accompanying caption is answered honestly and the turn ends.
if [ "$FILE_TYPE" = "voice" ] && [ -n "$RAW_FILE_ID" ]; then
    log "VOICE unsupported (no bundled transcription backend)"
    if [ -z "$MSG" ]; then
        echo "I can't transcribe voice notes — this build ships no speech-to-text backend. Send text instead."
        exit 0
    fi
    # A caption came with the voice note: answer the caption, ignore the audio.
    FILE_TYPE=""
    RAW_FILE_ID=""
fi

# --- Document handler ---
DOC_PATH=""
if [ "$FILE_TYPE" = "doc" ] && [ -n "$RAW_FILE_ID" ]; then
    FILE_INFO=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getFile?file_id=${RAW_FILE_ID}")
    FILE_PATH=$(echo "$FILE_INFO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
    if [ -n "$FILE_PATH" ]; then
        EXT="${FILE_PATH##*.}"
        [ -z "$EXT" ] && EXT="bin"
        RAND=$(python3 -c "import secrets; print(secrets.token_hex(4))")
        DOC_PATH="${IMG_DIR}/doc-${NOW}-${RAND}.${EXT}"
        curl -s --max-time 30 -o "$DOC_PATH" "https://api.telegram.org/file/bot${BOT_TOKEN}/${FILE_PATH}"
        FILESIZE=$(stat -c%s "$DOC_PATH" 2>/dev/null || echo 0)
        if [ "$FILESIZE" -lt 100 ]; then
            rm -f "$DOC_PATH"
            DOC_PATH=""
        fi
    fi
    if [ -z "$DOC_PATH" ]; then
        echo "Could not download document. Try again."
        exit 0
    fi

    # --- PDF text extraction: extract text so Claude gets content directly ---
    DOC_TEXT=""
    if [[ "$DOC_PATH" == *.pdf ]]; then
        if command -v pdftotext &>/dev/null; then
            DOC_TEXT=$(timeout 60 pdftotext -layout "$DOC_PATH" - 2>/dev/null | head -c 50000)
            if [ -n "$DOC_TEXT" ] && [ ${#DOC_TEXT} -gt 50 ]; then
                log "PDF_EXTRACT ok path=$DOC_PATH len=${#DOC_TEXT}"
            else
                DOC_TEXT=""
                log "PDF_EXTRACT empty path=$DOC_PATH (falling back to Read tool)"
            fi
        else
            log "PDF_EXTRACT skip (pdftotext not installed)"
        fi
    fi

    # Clear file type so we don't also try image download
    FILE_TYPE=""
    RAW_FILE_ID=""
fi

# --- Telegram image download ---
IMAGE_PATH=""
if [ "$FILE_TYPE" = "img" ] && [ -n "$RAW_FILE_ID" ]; then
    FILE_INFO=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getFile?file_id=${RAW_FILE_ID}")
    FILE_PATH=$(echo "$FILE_INFO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
    if [ -n "$FILE_PATH" ]; then
        EXT="${FILE_PATH##*.}"
        [ -z "$EXT" ] && EXT="jpg"
        RAND=$(python3 -c "import secrets; print(secrets.token_hex(4))")
        IMAGE_PATH="${IMG_DIR}/img-${NOW}-${RAND}.${EXT}"
        curl -s --max-time 15 -o "$IMAGE_PATH" "https://api.telegram.org/file/bot${BOT_TOKEN}/${FILE_PATH}"
        FILESIZE=$(stat -c%s "$IMAGE_PATH" 2>/dev/null || echo 0)
        if [ "$FILESIZE" -lt 1000 ]; then
            rm -f "$IMAGE_PATH"
            IMAGE_PATH=""
        fi
    fi
fi

# --- Location handling ---
LOCATION_LAT=""
LOCATION_LON=""
if [ "$FILE_TYPE" = "loc" ]; then
    LOCATION_LAT="${RAW_FILE_ID%%,*}"
    LOCATION_LON="${RAW_FILE_ID##*,}"
    log "LOCATION lat=$LOCATION_LAT lon=$LOCATION_LON"
fi

# --- Detect multi-image batch (media group arriving in quick succession) ---
BATCH_HINT=""
if [ -n "$IMAGE_PATH" ] && [ -f "$STATE_FILE" ]; then
    LAST_TIME_CHECK=$(sed -n '2p' "$STATE_FILE")
    TIME_SINCE=$((NOW - LAST_TIME_CHECK))
    if [ "$TIME_SINCE" -le 10 ] && [ "$TIME_SINCE" -ge 0 ]; then
        BATCH_HINT=" This is another image in a batch — refer to any images already discussed in this conversation."
    fi
fi

# --- Build prompt ---
if [ -n "$DOC_PATH" ] && [ -n "$DOC_TEXT" ] && [ -n "$MSG" ]; then
    PROMPT="The user sent a PDF document via Telegram along with this message: ${MSG}

Here is the extracted text from the document:
---
${DOC_TEXT}
---

Respond to the user's message about this document."
elif [ -n "$DOC_PATH" ] && [ -n "$DOC_TEXT" ]; then
    PROMPT="The user sent a PDF document via Telegram with no text. Here is the extracted text:
---
${DOC_TEXT}
---

Summarize the key contents of this document."
elif [ -n "$DOC_PATH" ] && [ -n "$MSG" ]; then
    PROMPT="The user sent a document via Telegram along with this message: ${MSG}. Use the Read tool to view the document at ${DOC_PATH}, then respond to the user's message about it."
elif [ -n "$DOC_PATH" ]; then
    PROMPT="The user sent a document via Telegram with no text. Use the Read tool to view the document at ${DOC_PATH}, then summarize its contents."
elif [ -n "$LOCATION_LAT" ] && [ -n "$MSG" ]; then
    PROMPT="The user shared their Telegram location (${LOCATION_LAT}, ${LOCATION_LON}) along with this message: ${MSG}. Use memory_store to save their current location (city/area name from the coordinates) so you always know where they are. Respond to their message with location context."
elif [ -n "$LOCATION_LAT" ]; then
    PROMPT="The user shared their Telegram location: latitude ${LOCATION_LAT}, longitude ${LOCATION_LON}. Use memory_store to save their current location (reverse-geocode the coordinates to get the city/area name). Confirm where they are and mention anything relevant (local time, weather if useful)."
elif [ -n "$IMAGE_PATH" ] && [ -n "$MSG" ]; then
    PROMPT="The user sent an image via Telegram along with this message: ${MSG}. First, use the Read tool to view the image at ${IMAGE_PATH}, then respond to the user's message about it.${BATCH_HINT}"
elif [ -n "$IMAGE_PATH" ]; then
    PROMPT="The user sent an image via Telegram with no text. Use the Read tool to view the image at ${IMAGE_PATH}, then describe what you see concisely.${BATCH_HINT}"
else
    PROMPT="$MSG"
fi

if [ -z "$PROMPT" ]; then
    echo "No text or image received."
    exit 0
fi

# --- URL pre-fetch: detect URLs and fetch content via markdown-for-agents ---
prefetch_urls() {
    local text="$1"
    local urls
    urls=$(echo "$text" | grep -oP 'https?://\S+' | head -3)
    [ -z "$urls" ] && return
    local ctx=""
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        # Skip image/media URLs
        case "$url" in
            *.jpg|*.jpeg|*.png|*.gif|*.mp4|*.webp|*.svg) continue ;;
            */ss/*) continue ;;   # our own screenshot URLs; nothing to extract
        esac
        local content
        content=$(curl -s --max-time 10 "http://localhost:8090/extract?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$url")" 2>/dev/null)
        if [ -n "$content" ] && [ ${#content} -gt 100 ]; then
            # Truncate to 8000 chars to avoid context bloat
            content="${content:0:8000}"
            ctx="${ctx}

[Content from ${url}]:
${content}
[End content]"
            log "URL_PREFETCH ok url=$url len=${#content}"
        else
            log "URL_PREFETCH skip url=$url (empty or too short)"
        fi
    done <<< "$urls"
    if [ -n "$ctx" ]; then
        PROMPT="The user's message contains URLs. Here is the extracted content for context:
${ctx}

User message: ${PROMPT}"
    fi
}

# Only prefetch for text messages (not docs/images/commands)
if [ -z "$DOC_PATH" ] && [ -z "$IMAGE_PATH" ] && ! $FORCE_FRESH; then
    prefetch_urls "$PROMPT"
fi

# --- Refresh typing indicator before Claude call (typing expires after 5s) ---
send_typing

# --- Session management (SQLite primary, flat file fallback) ---
SESSION_ID=""
LAST_TIME=0
TURNS=0
DB_CONTEXT_SUMMARY=""

# Try SQLite first
SESSION_JSON=$(session_load "$CHAT_ID")
if [ -n "$SESSION_JSON" ] && [ "$SESSION_JSON" != "{}" ]; then
    eval "$(parse_session "$SESSION_JSON")"
    if [ -n "$DB_SESSION_ID" ]; then
        SESSION_ID="$DB_SESSION_ID"
        LAST_TIME="$DB_LAST_ACTIVITY"
        TURNS="$DB_TURN_COUNT"
    fi
fi

# Fallback to flat file if SQLite returned nothing
if [ -z "$SESSION_ID" ] && [ -f "$STATE_FILE" ]; then
    SESSION_ID=$(sed -n '1p' "$STATE_FILE")
    LAST_TIME=$(sed -n '2p' "$STATE_FILE")
    TURNS=$(sed -n '3p' "$STATE_FILE")
    [ -z "$TURNS" ] && TURNS=0
fi

ELAPSED=$((NOW - LAST_TIME))
CLAUDE_ERROR=""

run_fresh() {
    log "CLAUDE fresh model=$MODEL"
    INVOKE_START=$(($(date +%s%N 2>/dev/null || echo "${NOW}000000000") / 1000000))
    RAW=$(timeout "$CLAUDE_TIMEOUT_FRESH" claude -p --model "$MODEL" --dangerously-skip-permissions --disable-slash-commands --output-format json --append-system-prompt "$MEMORY_HINT" "$PROMPT" 2>>"$LOG_FILE")
    EXIT_CODE=$?
    INVOKE_END=$(($(date +%s%N 2>/dev/null || echo "${NOW}000000000") / 1000000))
    INVOKE_DURATION=$((INVOKE_END - INVOKE_START))
    if [ $EXIT_CODE -eq 124 ]; then
        log "CLAUDE TIMEOUT (fresh, ${CLAUDE_TIMEOUT_FRESH}s)"
        CLAUDE_ERROR="timeout"
        audit_log --channel tg --action claude_timeout --chat-id "$CHAT_ID" \
            --details "mode=fresh timeout=${CLAUDE_TIMEOUT_FRESH}s" --duration-ms "$INVOKE_DURATION"
    elif [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
        log "CLAUDE ERROR fresh exit=$EXIT_CODE raw_len=${#RAW}"
        CLAUDE_ERROR="error"
        audit_log --channel tg --action claude_error --chat-id "$CHAT_ID" \
            --details "mode=fresh exit=$EXIT_CODE" --duration-ms "$INVOKE_DURATION"
    fi
    if [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
        RESPONSE=""
        SESSION_ID=""
        TURNS=0
        INPUT_TOKENS=0
        OUTPUT_TOKENS=0
        return
    fi
    # Parse response + token counts
    eval "$(parse_claude_output "$RAW")"
    SESSION_ID="$CLAUDE_SESSION_ID"
    INPUT_TOKENS="${CLAUDE_INPUT_TOKENS:-0}"
    OUTPUT_TOKENS="${CLAUDE_OUTPUT_TOKENS:-0}"
    if [ -n "$CLAUDE_RESULT_FILE" ] && [ -f "$CLAUDE_RESULT_FILE" ]; then
        RESPONSE=$(cat "$CLAUDE_RESULT_FILE")
        rm -f "$CLAUDE_RESULT_FILE"
    else
        RESPONSE=""
    fi
    TURNS=1
    log "CLAUDE OK fresh resp_len=${#RESPONSE} session=$SESSION_ID in_tok=$INPUT_TOKENS out_tok=$OUTPUT_TOKENS"
    audit_log --channel tg --action claude_response --chat-id "$CHAT_ID" \
        --session-id "$SESSION_ID" --input-tokens "$INPUT_TOKENS" --output-tokens "$OUTPUT_TOKENS" \
        --duration-ms "$INVOKE_DURATION" --model "$MODEL" \
        --details "mode=fresh resp_len=${#RESPONSE}"
}

run_resume() {
    log "CLAUDE resume session=$SESSION_ID turn=$((TURNS+1))"
    INVOKE_START=$(($(date +%s%N 2>/dev/null || echo "${NOW}000000000") / 1000000))
    RAW=$(timeout "$CLAUDE_TIMEOUT_RESUME" claude -p --model "$MODEL" --resume "$SESSION_ID" --dangerously-skip-permissions --disable-slash-commands --output-format json --append-system-prompt "$MEMORY_HINT" "$PROMPT" 2>>"$LOG_FILE")
    EXIT_CODE=$?
    INVOKE_END=$(($(date +%s%N 2>/dev/null || echo "${NOW}000000000") / 1000000))
    INVOKE_DURATION=$((INVOKE_END - INVOKE_START))
    if [ $EXIT_CODE -eq 124 ]; then
        log "CLAUDE TIMEOUT (resume, ${CLAUDE_TIMEOUT_RESUME}s) — falling back to fresh"
        audit_log --channel tg --action claude_timeout --chat-id "$CHAT_ID" \
            --session-id "$SESSION_ID" --details "mode=resume timeout=${CLAUDE_TIMEOUT_RESUME}s" \
            --duration-ms "$INVOKE_DURATION"
    elif [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
        log "CLAUDE ERROR resume exit=$EXIT_CODE — falling back to fresh"
        audit_log --channel tg --action claude_error --chat-id "$CHAT_ID" \
            --session-id "$SESSION_ID" --details "mode=resume exit=$EXIT_CODE" \
            --duration-ms "$INVOKE_DURATION"
    fi
    if [ $EXIT_CODE -ne 0 ] || [ -z "$RAW" ]; then
        run_fresh
        return
    fi
    # Parse response + token counts
    eval "$(parse_claude_output "$RAW")"
    SESSION_ID="$CLAUDE_SESSION_ID"
    INPUT_TOKENS="${CLAUDE_INPUT_TOKENS:-0}"
    OUTPUT_TOKENS="${CLAUDE_OUTPUT_TOKENS:-0}"
    if [ -n "$CLAUDE_RESULT_FILE" ] && [ -f "$CLAUDE_RESULT_FILE" ]; then
        RESPONSE=$(cat "$CLAUDE_RESULT_FILE")
        rm -f "$CLAUDE_RESULT_FILE"
    else
        RESPONSE=""
    fi
    TURNS=$((TURNS + 1))
    if [ -z "$RESPONSE" ]; then
        log "CLAUDE EMPTY resume — falling back to fresh"
        run_fresh
        return
    fi
    log "CLAUDE OK resume resp_len=${#RESPONSE} turn=$TURNS in_tok=$INPUT_TOKENS out_tok=$OUTPUT_TOKENS"
    audit_log --channel tg --action claude_response --chat-id "$CHAT_ID" \
        --session-id "$SESSION_ID" --input-tokens "$INPUT_TOKENS" --output-tokens "$OUTPUT_TOKENS" \
        --duration-ms "$INVOKE_DURATION" --model "$MODEL" \
        --details "mode=resume turn=$TURNS resp_len=${#RESPONSE}"
}

# --- Start typing loop for long Claude operations ---
# Ensure typing loop dies if script exits unexpectedly
trap 'stop_typing_loop' EXIT
start_typing_loop

# --- Auto-save expiring session to memory before replacing ---
save_expiring_session() {
    local old_sid="$1"
    local old_turns="$2"
    local reason="$3"
    [ -z "$old_sid" ] && return
    [ "$old_turns" -lt 2 ] && return  # not worth saving 1-turn sessions
    log "SESSION_SAVE reason=$reason sid=$old_sid turns=$old_turns"
    (
        SUMMARY=$(timeout 30 claude -p --resume "$old_sid" --dangerously-skip-permissions --disable-slash-commands --output-format json \
            "Summarize this conversation in 2-3 sentences. Focus on: what was discussed, any decisions made, and any unfinished tasks." 2>/dev/null \
            | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
        if [ -n "$SUMMARY" ] && [ ${#SUMMARY} -gt 20 ]; then
            python3 "$MONET_HOME"/tg-memory.py store "$CHAT_ID" "session-summary ($reason after $old_turns turns)" "$SUMMARY" 2>/dev/null
            log "SESSION_SAVE ok len=${#SUMMARY}"
        else
            log "SESSION_SAVE skip (empty summary)"
        fi
    ) &
}

# --- Session compaction: at turn thresholds, hint Claude to be concise ---
COMPACT_TURNS=(15 30)
for CT in "${COMPACT_TURNS[@]}"; do
    if [ "$TURNS" -eq "$CT" ]; then
        PROMPT="[SYSTEM NOTE: This conversation has reached turn ${TURNS}. Keep responses concise to preserve context. Focus on the user's current question without repeating earlier context.]
${PROMPT}"
        log "SESSION_COMPACT turn=$TURNS"
        break
    fi
done

# Decide: fresh or resume (MCP commands force fresh — standalone queries don't need session context)
if [ -n "$SESSION_ID" ] && [ "$ELAPSED" -le "$SESSION_TIMEOUT" ] && [ "$TURNS" -lt "$MAX_TURNS" ] && ! $FORCE_FRESH; then
    run_resume
else
    # Save expiring session to memory before replacing it
    if [ -n "$SESSION_ID" ] && [ "$TURNS" -ge 2 ]; then
        if [ "$ELAPSED" -gt "$SESSION_TIMEOUT" ]; then
            save_expiring_session "$SESSION_ID" "$TURNS" "timeout"
        elif [ "$TURNS" -ge "$MAX_TURNS" ]; then
            save_expiring_session "$SESSION_ID" "$TURNS" "max-turns"
        fi
    fi

    # Save original prompt for memory storage (before context injection)
    ORIGINAL_PROMPT="$PROMPT"

    # Inject session context summary from SQLite (cross-session continuity)
    if [ -n "$DB_CONTEXT_SUMMARY" ] && [ ${#DB_CONTEXT_SUMMARY} -gt 20 ]; then
        PROMPT="[Previous session context: ${DB_CONTEXT_SUMMARY}]
${PROMPT}"
    fi

    # Inject recent conversation history (chronological, last 5 exchanges)
    RECENT_CTX=""
    if [ -n "$CHAT_ID" ]; then
        RECENT_CTX=$(timeout 5 python3 "$MONET_HOME"/tg-memory.py recent "$CHAT_ID" 5 2>/dev/null)
    fi
    # Recall semantically relevant past conversations for broader context
    MEMORY_CTX=""
    if [ -n "$CHAT_ID" ]; then
        MEMORY_CTX=$(timeout 8 python3 "$MONET_HOME"/tg-memory.py recall "$CHAT_ID" "$PROMPT" 2>/dev/null)
    fi
    # Build context: recent history first, then semantic recall, then current prompt
    CTX=""
    if [ -n "$RECENT_CTX" ]; then
        CTX="${RECENT_CTX}"
    fi
    if [ -n "$MEMORY_CTX" ]; then
        CTX="${CTX:+${CTX}
}${MEMORY_CTX}"
    fi
    if [ -n "$CTX" ]; then
        PROMPT="${CTX}
${PROMPT}"
    fi
    run_fresh
fi

# --- Stop typing loop ---
stop_typing_loop

# Update state (SQLite primary + flat file fallback)
echo "$SESSION_ID" > "$STATE_FILE"
echo "$NOW" >> "$STATE_FILE"
echo "$TURNS" >> "$STATE_FILE"

# Persist to SQLite with context summary
session_save --chat-id "$CHAT_ID" --session-id "$SESSION_ID" --turns "$TURNS" \
    --channel tg --model "$MODEL" \
    --last-message "${MSG:0:200}" \
    --last-response "${RESPONSE:0:500}" \
    --input-tokens "${INPUT_TOKENS:-0}" --output-tokens "${OUTPUT_TOKENS:-0}"

# Cleanup old images and docs (>1hr)
find "$IMG_DIR" -name "img-*" -mmin +60 -delete 2>/dev/null
find "$IMG_DIR" -name "doc-*" -mmin +60 -delete 2>/dev/null

# Output response
if [ -z "$RESPONSE" ]; then
    clear_reaction
    if [ "$CLAUDE_ERROR" = "timeout" ]; then
        log "FAIL timeout — no response sent"
        echo "That took too long to process. Try a simpler question or send /new to reset."
    else
        log "FAIL error — no response sent"
        echo "Something went wrong. Try again or send /new to start fresh."
    fi
else
    log "DONE resp_len=${#RESPONSE}"
    clear_reaction

    # --- Handle [IMG] tags: upload image directly to Telegram (outbound) ---
    IMG_MARKER=$(echo "$RESPONSE" | grep -oP '\[IMG\](.*?)\[/IMG\]' | head -1)
    if [ -n "$IMG_MARKER" ] && [ -n "$CHAT_ID" ] && [[ "$CHAT_ID" != test* ]]; then
        IMG_REF=$(echo "$IMG_MARKER" | sed 's/\[IMG\]//;s/\[\/IMG\]//')
        LOCAL_FILE=""

        # Resolve to a local file path. Only a path the bot itself produced is
        # accepted -- never an arbitrary URL out of the model's response.
        if [[ "$IMG_REF" == /tmp/* ]]; then
            LOCAL_FILE="$IMG_REF"
        fi

        if [ -n "$LOCAL_FILE" ] && [ -f "$LOCAL_FILE" ]; then
            # Strip [IMG] tag from text response
            TEXT_ONLY=$(echo "$RESPONSE" | sed 's/\[IMG\][^\[]*\[\/IMG\]//g' | sed '/^$/d' | head -c 1024)

            # Upload image directly via multipart (outbound — no firewall issues)
            TG_RESULT=$(curl -s --max-time 30 -X POST \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
                -F "chat_id=${CHAT_ID}" \
                -F "photo=@${LOCAL_FILE}" \
                -F "caption=${TEXT_ONLY}" \
                -F "parse_mode=HTML" 2>/dev/null)

            TG_OK=$(echo "$TG_RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)

            if [ "$TG_OK" = "True" ]; then
                log "IMG_SENT direct upload file=$LOCAL_FILE chat=$CHAT_ID"
                # Output empty so n8n doesn't also try to send
                RESPONSE=""
            else
                log "IMG_FAIL direct upload: $TG_RESULT"
                # Fall through — let n8n handle text-only response
                RESPONSE=$(echo "$RESPONSE" | sed 's/\[IMG\][^\[]*\[\/IMG\]//g')
            fi
        else
            log "IMG_MISS file not found: $LOCAL_FILE (ref: $IMG_REF)"
            RESPONSE=$(echo "$RESPONSE" | sed 's/\[IMG\][^\[]*\[\/IMG\]//g')
        fi
    fi

    # --- Photo intelligence post-processing: extract [PHOTO_TYPE:xxx] and auto-clip ---
    if [ -n "$RESPONSE" ] && echo "$RESPONSE" | grep -q '\[PHOTO_TYPE:'; then
        PHOTO_TYPE=$(echo "$RESPONSE" | grep -oP '\[PHOTO_TYPE:\K[^\]]+' | head -1)
        if [ -n "$PHOTO_TYPE" ]; then
            # Strip the tag from response
            RESPONSE=$(echo "$RESPONSE" | sed 's/\[PHOTO_TYPE:[^\]]*\]//g' | sed '/^[[:space:]]*$/d')
            # Auto-clip the photo analysis (non-blocking)
            (
                PHOTO_TAG="photo-$(date +%Y%m%d-%H%M%S)"
                python3 "$MONET_HOME"/lib/clip_helper.py store "$CHAT_ID" "$PHOTO_TAG" "$RESPONSE" photo "$PHOTO_TYPE" 2>/dev/null
                log "PHOTO_CLIP type=$PHOTO_TYPE tag=$PHOTO_TAG"
            ) &
        fi
    fi

    # Output remaining text (if any) for n8n to send
    if [ -n "$RESPONSE" ]; then
        echo "$RESPONSE"
    fi

    # Store conversation turn in Qdrant for cross-session memory (non-blocking)
    if [ -n "$CHAT_ID" ]; then
        STORE_MSG="${ORIGINAL_PROMPT:-$PROMPT}"
        python3 "$MONET_HOME"/tg-memory.py store "$CHAT_ID" "$STORE_MSG" "$RESPONSE" &>/dev/null &
    fi
fi

