#!/bin/bash
# monet-ask-approval.sh <chat_id> <prompt> — send an Approve/Deny keyboard for a prompt.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
CHAT="${1:?chat}"; PROMPT="${2:?prompt}"
TOKEN="p$(date +%s)-$$-$RANDOM"
mkdir -p "$MONET_HOME"/pending
printf '%s' "$PROMPT" > "${MONET_HOME}/pending/$TOKEN"
KB=$(python3 -c "import json;print(json.dumps({'inline_keyboard':[[{'text':'✅ Approve','callback_data':'approve:$TOKEN'},{'text':'🚫 Deny','callback_data':'deny:$TOKEN'}]]}))")
curl -s --max-time 12 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys;print(json.dumps({'chat_id':'$CHAT','text':'⚠️ Approve this action?\n\n'+sys.argv[1],'reply_markup':json.loads(sys.argv[2])}))" "$PROMPT" "$KB")" \
  | python3 -c "import sys,json;print('sent:',json.load(sys.stdin).get('ok'))" 2>/dev/null
