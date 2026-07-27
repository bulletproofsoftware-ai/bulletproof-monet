#!/bin/bash
# deploy/smoke-test.sh — verify a Monet install actually works.
#
#   deploy/smoke-test.sh [--local-only] [--help]
#
# --local-only  Only the checks that need no Telegram credential.
# (default)     The above, plus the end-to-end first-message test.
#
# Exit: 0 all pass | 7 any check failed

set -uo pipefail

_self=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/monet-env.sh
. "$_self/../lib/monet-env.sh"

LOCAL_ONLY=0
case "${1:-}" in
    --local-only) LOCAL_ONLY=1 ;;
    --help|-h)    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")           ;;
    *)            echo "ERROR: unknown option: $1" >&2; exit 1 ;;
esac

PASS=0
FAIL=0

report() {
    # report <ok|fail> <name> [detail]
    if [ "$1" = "ok" ]; then
        printf '  PASS  %s\n' "$2"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s%s\n' "$2" "${3:+ — $3}"
        FAIL=$((FAIL + 1))
    fi
}

# http_check <name> <url> [expected-substring] [header]
http_check() {
    local name="$1" url="$2" expect="${3:-}" header="${4:-}" body
    local args=(-sf --max-time 10)
    [ -n "$header" ] && args+=(-H "$header")
    if ! body=$(curl "${args[@]}" "$url" 2>/dev/null); then
        report fail "$name" "unreachable ($url)"
        return 1
    fi
    if [ -n "$expect" ] && ! printf '%s' "$body" | grep -q "$expect"; then
        report fail "$name" "unexpected response body"
        return 1
    fi
    report ok "$name"
    return 0
}

echo "Local service checks:"
http_check "monet-api /health"        "http://127.0.0.1:${MONET_API_PORT:-8091}/health"
http_check "webhook /healthz"         "http://127.0.0.1:${MONET_WEBHOOK_PORT:-8093}/healthz" '"ok"'
http_check "qdrant /collections"      "http://127.0.0.1:6334/collections" "collections" "api-key: ${QDRANT_API_KEY:-}"
http_check "ollama /api/tags"         "http://127.0.0.1:11434/api/tags" "models"
http_check "n8n /healthz"             "http://127.0.0.1:5679/healthz"
http_check "markdown-for-agents /health" "http://127.0.0.1:8090/health"

if [ "$LOCAL_ONLY" -eq 0 ]; then
    echo
    echo "End-to-end checks:"

    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${MONET_CHAT_ID:-}" ]; then
        report fail "end-to-end" "BOT_TOKEN and MONET_CHAT_ID must be set (use --local-only to skip)"
    else
        # 1. The registered webhook points where we think it does.
        info=$("$_self/register-webhook.sh" --info 2>/dev/null)
        if [ -z "$info" ]; then
            report fail "getWebhookInfo" "could not query Telegram"
        else
            reg_url=$(printf '%s' "$info" | awk '/^url:/{print $2}')
            last_err=$(printf '%s' "$info" | sed -n 's/^last_error_message: *//p')
            case "$reg_url" in
                "${MONET_PUBLIC_URL%/}"*) report ok "webhook url matches MONET_PUBLIC_URL" ;;
                *) report fail "webhook url" "registered '$reg_url' does not match '${MONET_PUBLIC_URL:-}'" ;;
            esac
            if [ -z "$last_err" ] || [ "$last_err" = "<none>" ]; then
                report ok "webhook has no last_error_message"
            else
                report fail "webhook last_error_message" "$last_err"
            fi
        fi

        # 2. Drive the REAL webhook handler with a synthetic update. This exercises
        #    the actual handler, router and delivery path without a human typing
        #    into Telegram.
        payload=$(python3 -c '
import json, os, sys
print(json.dumps({
  "update_id": 1,
  "message": {
    "message_id": 1,
    "date": 0,
    "chat": {"id": int(sys.argv[1]), "type": "private"},
    "from": {"id": int(sys.argv[1]), "is_bot": False, "first_name": "smoke"},
    "text": "/help",
  },
}))' "$MONET_CHAT_ID" 2>/dev/null)

        if [ -z "$payload" ]; then
            report fail "synthetic update" "MONET_CHAT_ID is not numeric"
        else
            hdrs=(-H "Content-Type: application/json")
            [ -n "${WEBHOOK_SECRET:-}" ] && hdrs+=(-H "X-Telegram-Bot-Api-Secret-Token: ${WEBHOOK_SECRET}")
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
                    "${hdrs[@]}" -d "$payload" \
                    "http://127.0.0.1:${MONET_WEBHOOK_PORT:-8093}/webhook/monet-tg-inbound" 2>/dev/null)
            if [ "$code" = "200" ]; then
                report ok "synthetic /help update accepted by the local webhook"
            else
                report fail "synthetic update" "HTTP $code from the local webhook"
            fi
        fi

        # 3. Confirm delivery works by sending a real confirmation message.
        resp=$(curl -s --max-time 15 -X POST \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${MONET_CHAT_ID}" \
            --data-urlencode "text=Monet is installed." 2>/dev/null)
        if printf '%s' "$resp" | grep -q '"ok":true'; then
            report ok "confirmation message delivered to MONET_CHAT_ID"
        else
            desc=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("description",""))
except Exception: print("unparseable")' 2>/dev/null)
            # Never echo the token, even if Telegram reflects it.
            [ -n "${BOT_TOKEN:-}" ] && desc=$(printf '%s' "$desc" | sed "s|${BOT_TOKEN}|***|g")
            report fail "sendMessage" "$desc"
        fi
    fi
fi

echo
echo "$PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 7
exit 0
