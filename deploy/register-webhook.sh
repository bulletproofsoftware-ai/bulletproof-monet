#!/bin/bash
# deploy/register-webhook.sh — register THIS deployment's own Telegram bot webhook.
#
# Contains no token. Reads BOT_TOKEN from the environment (normally via
# lib/monet-env.sh -> .env), which is why it is safe to ship.
#
#   deploy/register-webhook.sh [--delete] [--info] [--check] [--help]
#
# Environment:
#   BOT_TOKEN         required (except under --check, where it is only validated)
#   MONET_PUBLIC_URL  required, the https:// origin Telegram will POST to
#   WEBHOOK_PATH      optional, default /webhook/monet-tg-inbound
#   WEBHOOK_SECRET    optional but recommended -> sent as secret_token
#
# Exit: 0 ok | 1 usage | 3 config missing/invalid | 6 Telegram returned ok:false

set -euo pipefail

_self=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/monet-env.sh
[ -f "$_self/../lib/monet-env.sh" ] && . "$_self/../lib/monet-env.sh"

WEBHOOK_PATH="${WEBHOOK_PATH:-/webhook/monet-tg-inbound}"
ALLOWED_UPDATES='["message","callback_query","message_reaction"]'

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Redact the bot token from anything we print. Telegram echoes the request URL in
# some error bodies, so every outbound print goes through this.
redact() {
    if [ -n "${BOT_TOKEN:-}" ]; then
        sed "s|${BOT_TOKEN//|/\\|}|***REDACTED***|g"
    else
        cat
    fi
}

# Parse a Telegram JSON response: prints "ok|description" on stdout.
parse_response() {
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("false|unparseable response: %s" % e)
    sys.exit(0)
print("%s|%s" % (
    "true" if d.get("ok") else "false",
    d.get("description", "") or d.get("result", ""),
))'
}

# Validate configuration. No network I/O whatsoever.
validate_config() {
    local errs=0
    if [ -z "${BOT_TOKEN:-}" ]; then
        echo "ERROR: BOT_TOKEN is not set (put it in .env)" >&2
        errs=1
    fi
    if [ -z "${MONET_PUBLIC_URL:-}" ]; then
        echo "ERROR: MONET_PUBLIC_URL is not set (put it in .env)" >&2
        errs=1
    else
        # Telegram requires https. Validate syntactically only — no DNS, no connect.
        case "$MONET_PUBLIC_URL" in
            https://?*)
                # Reject a URL with an obviously empty or whitespace-only host.
                local host="${MONET_PUBLIC_URL#https://}"
                host="${host%%/*}"
                if [ -z "$host" ] || [ "$host" != "${host#[[:space:]]}" ]; then
                    echo "ERROR: MONET_PUBLIC_URL is not a valid https URL: no host" >&2
                    errs=1
                fi
                ;;
            *)
                echo "ERROR: MONET_PUBLIC_URL is invalid: must be an https:// URL" >&2
                echo "       (Telegram only delivers webhooks over HTTPS)" >&2
                errs=1
                ;;
        esac
    fi
    return "$errs"
}

api_call() {
    # $1 = method, rest = curl data args
    local method="$1"; shift
    curl -s --max-time 20 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/${method}" \
        "$@"
}

do_set() {
    validate_config || exit 3
    local url="${MONET_PUBLIC_URL%/}${WEBHOOK_PATH}"
    echo "Registering webhook: $url"

    local args=(-H "Content-Type: application/json")
    local payload
    payload=$(python3 -c '
import json, os, sys
body = {
    "url": sys.argv[1],
    "allowed_updates": json.loads(sys.argv[2]),
}
secret = os.environ.get("WEBHOOK_SECRET", "")
if secret:
    body["secret_token"] = secret
print(json.dumps(body))' "$url" "$ALLOWED_UPDATES")

    local resp ok desc
    resp=$(api_call setWebhook "${args[@]}" -d "$payload") || {
        echo "ERROR: could not reach the Telegram API" >&2
        exit 6
    }
    IFS='|' read -r ok desc <<<"$(printf '%s' "$resp" | parse_response)"
    if [ "$ok" != "true" ]; then
        echo "ERROR: Telegram rejected setWebhook: $desc" | redact >&2
        exit 6
    fi
    echo "  setWebhook accepted."

    if [ -n "${WEBHOOK_SECRET:-}" ]; then
        echo "  secret_token sent (requests will carry X-Telegram-Bot-Api-Secret-Token)."
    else
        echo "  WARNING: WEBHOOK_SECRET is unset — the endpoint cannot verify callers."
    fi

    # A 200 with ok:true does not guarantee the URL took. Read it back.
    echo "Verifying with getWebhookInfo..."
    local info actual
    info=$(api_call getWebhookInfo) || {
        echo "ERROR: setWebhook succeeded but getWebhookInfo was unreachable" >&2
        exit 6
    }
    actual=$(printf '%s' "$info" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("result", {}).get("url", ""))
except Exception:
    print("")')
    if [ "$actual" != "$url" ]; then
        echo "ERROR: webhook URL did not take." >&2
        echo "       expected: $url" >&2
        echo "       actual:   ${actual:-<empty>}" >&2
        exit 6
    fi
    echo "  verified: $actual"
    echo "OK"
}

do_info() {
    validate_config || exit 3
    local info
    info=$(api_call getWebhookInfo) || {
        echo "ERROR: could not reach the Telegram API" >&2
        exit 6
    }
    printf '%s' "$info" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("unparseable response: %s" % e); sys.exit(1)
if not d.get("ok"):
    print("Telegram returned ok:false: %s" % d.get("description", "")); sys.exit(6)
r = d.get("result", {})
print("url:                  %s" % (r.get("url") or "<none>"))
print("pending_update_count: %s" % r.get("pending_update_count", 0))
print("last_error_message:   %s" % (r.get("last_error_message") or "<none>"))
print("last_error_date:      %s" % (r.get("last_error_date") or "<none>"))
print("max_connections:      %s" % r.get("max_connections", "<default>"))
print("allowed_updates:      %s" % (r.get("allowed_updates") or "<all except chat_member>"))
print("has_custom_certificate: %s" % r.get("has_custom_certificate", False))
' | redact
    local rc=${PIPESTATUS[1]}
    [ "$rc" -eq 0 ] || exit "$rc"
}

do_delete() {
    validate_config || exit 3
    echo "Deleting webhook (pending updates are preserved)..."
    local resp ok desc
    resp=$(api_call deleteWebhook -H "Content-Type: application/json" \
        -d '{"drop_pending_updates": false}') || {
        echo "ERROR: could not reach the Telegram API" >&2
        exit 6
    }
    IFS='|' read -r ok desc <<<"$(printf '%s' "$resp" | parse_response)"
    if [ "$ok" != "true" ]; then
        echo "ERROR: Telegram rejected deleteWebhook: $desc" | redact >&2
        exit 6
    fi
    echo "OK: webhook deleted."
}

# --check: configuration validation ONLY. Makes zero network calls, so it is safe
# for CI and for install.sh --check on a clone with no credentials.
do_check() {
    if validate_config; then
        echo "OK: BOT_TOKEN set, MONET_PUBLIC_URL is a valid https URL."
        echo "    webhook would register at: ${MONET_PUBLIC_URL%/}${WEBHOOK_PATH}"
        exit 0
    fi
    exit 3
}

case "${1:-}" in
    --info)   do_info ;;
    --delete) do_delete ;;
    --check)  do_check ;;
    --help|-h) usage; exit 0 ;;
    "")       do_set ;;
    *)        echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
esac
