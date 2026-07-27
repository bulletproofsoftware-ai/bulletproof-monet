#!/bin/bash
# monet-voice.sh <chat_id> <text|@file> — convert a briefing to a short spoken
# audio message via edge-tts and deliver it to Telegram (PRD #35).
# edge-tts drives Microsoft Edge's free online neural voices: no API key, no
# account. Same engine as monet-tts.sh; see requirements-tts.txt to install it.
# Condenses the text to a natural ~60-90s script first (strips markdown/emoji),
# synthesizes MP3, and sends via Telegram sendAudio (no ffmpeg needed).
# Best-effort: never blocks/breaks the caller; exits 0 on any soft failure.
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"

CHAT_ID="${1:?usage: monet-voice.sh <chat_id> <text|@file>}"
RAW="${2:?usage: monet-voice.sh <chat_id> <text|@file>}"
LOG="/var/log/monet-tg.log"
MODEL="${VOICE_SCRIPT_MODEL:-claude-haiku-4-5}"
# Any edge-tts short name; list them with `edge-tts --list-voices`.
VOICE="${TTS_VOICE:-en-US-AriaNeural}"
RATE="${TTS_RATE:-+0%}"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] VOICE $*" >> "$LOG"; }

# Spoken output is opt-in and ships OFF. Soft-exit rather than erroring: this
# script is called best-effort from the briefing path.
if [ "${TTS_ENABLED:-false}" != "true" ] && [ "${TTS_ENABLED:-false}" != "1" ]; then
    log "skip (TTS_ENABLED is not true)"
    exit 0
fi
if ! command -v edge-tts >/dev/null 2>&1; then
    log "skip (edge-tts not installed; see requirements-tts.txt)"
    exit 0
fi

# Accept text directly or @file
if [ "${RAW:0:1}" = "@" ]; then TEXT=$(cat "${RAW:1}" 2>/dev/null); else TEXT="$RAW"; fi
[ -z "$TEXT" ] && { log "empty text"; exit 0; }

WORK=$(mktemp -d /tmp/monet-voice.XXXXXX); trap 'rm -rf "$WORK"' EXIT

# 1. Condense to a natural spoken script (no markdown/emoji/URLs)
SCRIPT=$(timeout 60 claude -p --model "$MODEL" --max-turns 1 \
    --dangerously-skip-permissions --disable-slash-commands \
    "Rewrite the following briefing as a natural, friendly spoken script of about 60-90 seconds for a text-to-speech voice. Plain prose only: no markdown, no emoji, no URLs, no bullet characters, no headings. Start with a brief greeting. Keep it scannable when heard.

BRIEFING:
$TEXT" 2>>"$LOG")
[ -z "$SCRIPT" ] && SCRIPT="$TEXT"

# 2. Synthesize MP3 via edge-tts
if ! timeout 90 edge-tts --voice "$VOICE" --rate "$RATE" \
        --text "$SCRIPT" --write-media "$WORK/pulse.mp3" 2>>"$LOG"; then
    log "TTS failed (edge-tts error) voice=$VOICE"
    exit 0
fi
if [ ! -s "$WORK/pulse.mp3" ]; then
    log "TTS failed (empty audio file) voice=$VOICE"
    exit 0
fi

# 3. Deliver via Telegram sendAudio
OK=$(curl -s -m 60 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendAudio" \
    -F "chat_id=${CHAT_ID}" \
    -F "audio=@${WORK}/pulse.mp3;type=audio/mpeg;filename=pulse.mp3" \
    -F "title=Monet Briefing" \
    -F "caption=🎧 Your briefing" 2>>"$LOG" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
log "DELIVERED chat=$CHAT_ID ok=$OK bytes=$(stat -c%s "$WORK/pulse.mp3" 2>/dev/null)"
