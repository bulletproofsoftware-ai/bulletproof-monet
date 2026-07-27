#!/bin/bash
# monet-progress.sh — send/edit a Telegram progress message.
#   send <chat_id> <text>            -> prints message_id
#   edit <chat_id> <message_id> <text>
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
export PATH="/usr/local/bin:$PATH"
cmd="${1:?send|edit}"; shift
api="https://api.telegram.org/bot${BOT_TOKEN:-}"

# When MONET_TG_SEND is set, deliver through it rather than curling the Telegram
# API directly. That keeps the progress ack on the same delivery path as every
# other outbound message (and makes it testable). Such a sender cannot return a
# message_id, so the editable-update path degrades to plain sends.
if [ -n "${MONET_TG_SEND:-}" ]; then
  case "$cmd" in
    send)
      chat="${1:?chat}"; text="${2:?text}"
      printf '%s' "$text" | "$MONET_TG_SEND" "$chat" >/dev/null 2>&1 || true
      ;;
    edit)
      chat="${1:?chat}"; mid="${2:?mid}"; text="${3:?text}"
      printf '%s' "$text" | "$MONET_TG_SEND" "$chat" >/dev/null 2>&1 || true
      ;;
  esac
  exit 0
fi

case "$cmd" in
  send)
    chat="${1:?chat}"; text="${2:?text}"
    resp=$(curl -s --max-time 12 -X POST "$api/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json,sys;print(json.dumps({'chat_id':'$chat','text':sys.argv[1]}))" "$text")")
    echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('result',{}).get('message_id','') if d.get('ok') else '')" 2>/dev/null
    ;;
  edit)
    chat="${1:?chat}"; mid="${2:?mid}"; text="${3:?text}"
    curl -s --max-time 12 -X POST "$api/editMessageText" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "import json,sys;print(json.dumps({'chat_id':'$chat','message_id':int('$mid'),'text':sys.argv[1]}))" "$text")" \
      >/dev/null 2>&1
    ;;
esac
