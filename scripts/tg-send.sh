#!/bin/bash
# tg-send.sh — Send a message to Telegram with markdown-to-HTML conversion + chunking
# Usage: echo "message" | tg-send.sh <chat_id> [--photo URL] [--silent] [--plain]
# Sources BOT_TOKEN from "$MONET_HOME"/.env
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

CHAT_ID="${1:-}"
shift 2>/dev/null || true

if [ -z "$CHAT_ID" ]; then
    echo "Usage: echo 'message' | tg-send.sh <chat_id> [--photo URL] [--silent] [--plain]" >&2
    exit 1
fi

# Parse options
PHOTO_URL=""
SILENT=false
PLAIN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --photo)  PHOTO_URL="${2:-}"; shift 2 ;;
        --silent) SILENT=true; shift ;;
        --plain)  PLAIN=true; shift ;;
        *)        shift ;;
    esac
done

: "${BOT_TOKEN:?BOT_TOKEN not set}"

# Read message from stdin
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SILENT_JSON="False"
$SILENT && SILENT_JSON="True"

# --- Markdown-to-HTML conversion ---
md_to_html() {
    local input="$1"
    MD_INPUT="$input" python3 << 'PYEOF'
import os, re

text = os.environ['MD_INPUT']

# Escape HTML entities first
text = text.replace('&', '&amp;')
text = text.replace('<', '&lt;')
text = text.replace('>', '&gt;')

# Code blocks (```lang\n...\n```) — must come before inline code
text = re.sub(r'```(?:\w+)?\n([\s\S]*?)```', r'<pre>\1</pre>', text)

# Inline code (`text`)
text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)

# Bold (**text** and __text__)
text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
text = re.sub(r'__(.+?)__', r'<b>\1</b>', text)

# Italic (*text* and _text_) with word-boundary guards to avoid matching mid-word
text = re.sub(r'(?<!\w)\*([^*]+?)\*(?!\w)', r'<i>\1</i>', text)
text = re.sub(r'(?<!\w)_([^_]+?)_(?!\w)', r'<i>\1</i>', text)

# Strikethrough (~~text~~)
text = re.sub(r'~~(.+?)~~', r'<s>\1</s>', text)

# Links [text](url)
text = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'<a href="\2">\1</a>', text)

# Headings -> bold (# through ######)
text = re.sub(r'^#{1,6}\s+(.+)$', r'<b>\1</b>', text, flags=re.MULTILINE)

# Bullet lists (- or * at start of line)
text = re.sub(r'^[\s]*[-*]\s+', '• ', text, flags=re.MULTILINE)

print(text, end='')
PYEOF
}

# --- Convert if not --plain ---
if $PLAIN; then
    HTML_TEXT="$INPUT"
else
    HTML_TEXT=$(md_to_html "$INPUT")
fi

# --- Chunking: split text at 4096 chars on paragraph/sentence boundaries ---
chunk_text() {
    local input="$1"
    CHUNK_INPUT="$input" python3 << 'PYEOF'
import os, json

text = os.environ['CHUNK_INPUT']
MAX = 4096
chunks = []

while len(text) > MAX:
    # Try paragraph break first
    idx = text.rfind('\n\n', 0, MAX)
    if idx == -1 or idx < MAX // 4:
        # Try line break
        idx = text.rfind('\n', 0, MAX)
    if idx == -1 or idx < MAX // 4:
        # Try sentence break
        idx = text.rfind('. ', 0, MAX)
        if idx != -1:
            idx += 1  # include the period
    if idx == -1 or idx < MAX // 4:
        # Hard cut
        idx = MAX
    chunks.append(text[:idx].strip())
    text = text[idx:].strip()

if text:
    chunks.append(text)

# Output as JSON array for safe bash consumption
print(json.dumps(chunks))
PYEOF
}

# --- Send a single chunk ---
send_chunk() {
    local text="$1"
    local parse_mode="${2:-HTML}"

    local payload
    if [ "$parse_mode" = "HTML" ]; then
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'chat_id': sys.argv[1],
    'text': sys.stdin.read(),
    'parse_mode': 'HTML',
    'disable_notification': $SILENT_JSON
}))" "$CHAT_ID" <<< "$text")
    else
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'chat_id': sys.argv[1],
    'text': sys.stdin.read(),
    'disable_notification': $SILENT_JSON
}))" "$CHAT_ID" <<< "$text")
    fi

    local result
    result=$(curl -s --max-time 15 -w "\n%{http_code}" -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local http_code="${result##*$'\n'}"

    # If HTML parsing failed (400), retry without parse_mode
    if [ "$http_code" = "400" ] && [ "$parse_mode" = "HTML" ]; then
        send_chunk "$text" "PLAIN"
        return $?
    fi

    [ "$http_code" = "200" ]
}

# --- Send photo with caption ---
send_photo() {
    local caption="$1"
    local url="$2"

    # Telegram photo captions max 1024 chars
    local cap_text="${caption:0:1024}"

    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'chat_id': sys.argv[1],
    'photo': sys.argv[2],
    'caption': sys.stdin.read(),
    'parse_mode': 'HTML',
    'disable_notification': $SILENT_JSON
}))" "$CHAT_ID" "$url" <<< "$cap_text")

    local result
    result=$(curl -s --max-time 30 -w "\n%{http_code}" -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local http_code="${result##*$'\n'}"

    # If HTML parse fails, retry without parse_mode
    if [ "$http_code" = "400" ]; then
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'chat_id': sys.argv[1],
    'photo': sys.argv[2],
    'caption': sys.stdin.read(),
    'disable_notification': $SILENT_JSON
}))" "$CHAT_ID" "$url" <<< "$cap_text")
        curl -s --max-time 30 -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1
    fi
}

# --- Main: chunk and send ---
CHUNKS_JSON=$(chunk_text "$HTML_TEXT")
CHUNK_COUNT=$(echo "$CHUNKS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CHUNK_COUNT" -eq 0 ]; then
    exit 0
fi

# First chunk: send as photo if --photo, otherwise as text
FIRST_CHUNK=$(echo "$CHUNKS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")

if [ -n "$PHOTO_URL" ]; then
    send_photo "$FIRST_CHUNK" "$PHOTO_URL"
else
    send_chunk "$FIRST_CHUNK"
fi

# Remaining chunks: always as text, with 300ms delay
if [ "$CHUNK_COUNT" -gt 1 ]; then
    for i in $(seq 1 $((CHUNK_COUNT - 1))); do
        sleep 0.3
        CHUNK=$(echo "$CHUNKS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i])")
        send_chunk "$CHUNK"
    done
fi
