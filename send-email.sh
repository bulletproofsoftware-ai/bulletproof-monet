#!/bin/bash
# send-email.sh — Send a plain-text email over SMTP.
# Usage: send-email.sh <recipient> <subject> <body>
#
# Prints exactly "OK" on success, or "ERROR: <reason>" on failure, because the
# assistant's system prompt tells the model to check this output for OK or error.
#
# Config: SMTP_HOST (host or host:port), SMTP_USER, SMTP_PASS. All three are
# required; unset means email is unavailable and this exits non-zero without
# sending. The envelope sender is SMTP_USER.
#
# When the recipient is not SMTP_USER, SMTP_USER is Cc'd so the operator keeps a
# copy of anything sent on their behalf.
#
# Transport: STARTTLS on port 587 (the default), implicit TLS on 465. Credentials
# are passed to python via the environment, never on the command line, so they do
# not appear in the process table.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

TO="${1:-}"
SUBJECT="${2:-}"
BODY="${3:-}"

LOG_DIR="${MONET_LOG_DIR:-${MONET_HOME}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="${LOG_DIR}/monet-email.log"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] EMAIL $*" >> "$LOG" 2>/dev/null; }

if [ -z "$TO" ] || [ -z "$SUBJECT" ] || [ -z "$BODY" ]; then
    echo "ERROR: usage: send-email.sh <recipient> <subject> <body>"
    exit 2
fi

if [ -z "${SMTP_HOST:-}" ] || [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
    log "SKIP not configured to=$TO"
    echo "ERROR: SMTP is not configured (set SMTP_HOST, SMTP_USER, SMTP_PASS in .env)"
    exit 1
fi

log "START to=$TO subject=\"${SUBJECT:0:60}\" len=${#BODY}"

# Recipient, subject and body all originate from model output. They are handed to
# python as argv entries and never interpolated into a shell string.
RESULT=$(SMTP_HOST="$SMTP_HOST" SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" \
    python3 - "$TO" "$SUBJECT" "$BODY" <<'PYEOF' 2>&1
import os, re, smtplib, ssl, sys
from email.message import EmailMessage

to, subject, body = sys.argv[1], sys.argv[2], sys.argv[3]

host_raw = os.environ["SMTP_HOST"]
user = os.environ["SMTP_USER"]
password = os.environ["SMTP_PASS"]

if ":" in host_raw:
    host, _, port_s = host_raw.rpartition(":")
    try:
        port = int(port_s)
    except ValueError:
        print("ERROR: SMTP_HOST port is not a number: %s" % port_s)
        raise SystemExit(1)
else:
    host, port = host_raw, 587

# A header value containing CR or LF would let generated text inject extra
# headers. Reject rather than silently strip, so the failure is visible.
for label, value in (("recipient", to), ("subject", subject)):
    if "\n" in value or "\r" in value:
        print("ERROR: %s contains a newline" % label)
        raise SystemExit(1)

if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", to):
    print("ERROR: recipient is not a valid email address: %s" % to)
    raise SystemExit(1)

msg = EmailMessage()
msg["From"] = user
msg["To"] = to
msg["Subject"] = subject
# Keep the operator in the loop on anything sent on their behalf.
if to.strip().lower() != user.strip().lower():
    msg["Cc"] = user
msg.set_content(body)

try:
    ctx = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, timeout=30, context=ctx) as s:
            s.login(user, password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=30) as s:
            s.starttls(context=ctx)
            s.login(user, password)
            s.send_message(msg)
except smtplib.SMTPAuthenticationError:
    print("ERROR: SMTP authentication failed for %s" % user)
    raise SystemExit(1)
except Exception as exc:
    print("ERROR: %s: %s" % (type(exc).__name__, exc))
    raise SystemExit(1)

print("OK")
PYEOF
)
STATUS=$?

if [ $STATUS -eq 0 ] && [ "$RESULT" = "OK" ]; then
    log "SENT to=$TO"
    echo "OK"
    exit 0
fi

log "FAIL to=$TO: $RESULT"
# Guarantee the ERROR: prefix even if python died before printing one.
case "$RESULT" in
    ERROR:*) echo "$RESULT" ;;
    *)       echo "ERROR: ${RESULT:-send failed}" ;;
esac
exit 1
