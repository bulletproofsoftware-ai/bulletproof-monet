#!/bin/bash
# tg-register-commands.sh — Register bot commands with Telegram's menu
# Run once after deploying, or on demand to update the command list.
#
# This array IS the command allowlist -- deny by default. It must stay in sync
# with the /help handler in bridges/monet-tg.sh; both enumerate the SAME 18
# commands. Do not add a command here without a handler there.
# Sources BOT_TOKEN from "$MONET_HOME"/.env
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -euo pipefail

: "${BOT_TOKEN:?BOT_TOKEN not set}"

COMMANDS='[
  {"command":"help","description":"Show all commands"},
  {"command":"new","description":"Start a fresh conversation"},
  {"command":"export","description":"Export session summary"},
  {"command":"remind","description":"Set a reminder (e.g. /remind 30m call dentist)"},
  {"command":"reminders","description":"List pending reminders"},
  {"command":"clip","description":"Save a snippet: /clip tag content"},
  {"command":"clips","description":"List saved clips"},
  {"command":"find","description":"Semantic search across clips"},
  {"command":"mark","description":"Bookmark this conversation moment"},
  {"command":"marks","description":"List bookmarks"},
  {"command":"recall","description":"Retrieve a bookmark"},
  {"command":"search","description":"Search across all data sources"},
  {"command":"memory-stats","description":"Memory backend stats"},
  {"command":"memory-export","description":"Export stored memories"},
  {"command":"ss","description":"Screenshot a URL"},
  {"command":"photo-log","description":"Photo analysis history"},
  {"command":"usage","description":"Token usage summary (7 days)"},
]'

RESULT=$(curl -s --max-time 10 -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
    -H "Content-Type: application/json" \
    -d "{\"commands\": $COMMANDS}")

OK=$(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)

if [ "$OK" = "True" ]; then
    echo "Commands registered successfully."
else
    echo "Failed to register commands: $RESULT" >&2
    exit 1
fi
