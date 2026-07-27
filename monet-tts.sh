#!/bin/bash
# monet-tts.sh — Convert text to audio and send to Telegram via edge-tts
# Usage: monet-tts.sh <chat_id> <text> [voice]
# edge-tts drives Microsoft Edge's free online neural voices: no API key, no
# account. Install it with requirements-tts.txt.
# Voice: argv[3], else $TTS_VOICE, else en-US-AriaNeural. Speed: $TTS_RATE.
# Designed to run inline or in background (fast, ~3-5s for typical text)
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"

CHAT_ID="${1:?usage: monet-tts.sh <chat_id> <text> [voice]}"
TEXT="${2:?usage: monet-tts.sh <chat_id> <text> [voice]}"
VOICE="${3:-${TTS_VOICE:-en-US-AriaNeural}}"
RATE="${TTS_RATE:-+0%}"
LOG="/var/log/monet-tg.log"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] TTS $*" >> "$LOG"; }

: "${BOT_TOKEN:?BOT_TOKEN not set}"

# Generate audio
TMPFILE=$(mktemp /tmp/monet-tts-XXXXXX.mp3)
trap 'rm -f "$TMPFILE"' EXIT

log "START chat=$CHAT_ID voice=$VOICE rate=$RATE len=${#TEXT}"

if ! edge-tts --voice "$VOICE" --rate "$RATE" --text "$TEXT" --write-media "$TMPFILE" 2>>"$LOG"; then
    log "FAIL edge-tts error"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}&text=TTS failed — edge-tts error." >/dev/null 2>&1
    exit 1
fi

if [ ! -s "$TMPFILE" ]; then
    log "FAIL empty output file"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}&text=TTS failed — empty audio file." >/dev/null 2>&1
    exit 1
fi

# Send audio to Telegram
RESULT=$(curl -s --max-time 30 -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendAudio" \
    -F chat_id="$CHAT_ID" \
    -F audio=@"$TMPFILE" \
    -F title="Monet TTS" \
    -F performer="$VOICE")

OK=$(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)

if [ "$OK" = "True" ]; then
    log "DELIVERED chat=$CHAT_ID voice=$VOICE"
else
    ERR=$(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('description','unknown'))" 2>/dev/null)
    log "FAIL sendAudio: $ERR"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}&text=TTS audio send failed: ${ERR}" >/dev/null 2>&1
    exit 1
fi
