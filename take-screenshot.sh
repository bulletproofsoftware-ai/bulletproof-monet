#!/bin/bash
# Takes a screenshot of a URL, saves to /var/www/screenshots/
# Outputs the public URL of the screenshot
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
URL="$1"
if [ -z "$URL" ]; then
    echo ""
    exit 1
fi

# Add https:// if no protocol
if [[ ! "$URL" =~ ^https?:// ]]; then
    URL="https://$URL"
fi

RAND=$(python3 -c "import secrets; print(secrets.token_hex(4))")
FILENAME="ss-$(date +%s)-${RAND}.png"
OUTPATH="/var/www/screenshots/$FILENAME"

# Full-page capture via playwright (preferred). Falls back to viewport-only
# chromium if node/playwright is unavailable, so /ss never hard-fails.
CHROME="${MONET_HOME}/.cache/ms-playwright/chromium-1187/chrome-linux/chrome"
[ -x "$CHROME" ] || CHROME=$(ls -d "$MONET_HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome 2>/dev/null | tail -1)

if [ ! -x "$CHROME" ]; then
    echo ""
    exit 1
fi

FULLJS="${MONET_HOME}/lib/ss-fullpage.js"
if [ -f "$FULLJS" ] && command -v node >/dev/null 2>&1; then
    timeout 90 node "$FULLJS" "$URL" "$OUTPATH" >/dev/null 2>&1
fi

# Fallback: viewport-only screenshot straight from chromium.
if [ ! -s "$OUTPATH" ]; then
    timeout 60 "$CHROME" \
        --headless \
        --disable-gpu \
        --no-sandbox \
        --hide-scrollbars \
        --window-size=1280,720 \
        --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
        --screenshot="$OUTPATH" \
        "$URL" >/dev/null 2>&1
fi

# Fix SELinux context so nginx can read it
chmod 644 "$OUTPATH" 2>/dev/null
restorecon "$OUTPATH" 2>/dev/null

if [ -s "$OUTPATH" ]; then
    echo "https://your-server.example.com/ss/$FILENAME"
else
    echo ""
    exit 1
fi
