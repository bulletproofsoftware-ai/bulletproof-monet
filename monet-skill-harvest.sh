#!/bin/bash
# monet-skill-harvest.sh — out-of-band learning loop (feature #1).
# Cron: a few times a day. NEVER runs in the live TG pipeline (no latency impact).
# Scans recent sessions, drafts reusable skills into skills/_proposed/ for review.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail
export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:/usr/bin:/bin"
LOCK_FILE="${MONET_HOME}/.monet-harvest.lock"
exec 7>"$LOCK_FILE"
flock -n 7 || exit 0
exec python3 "$MONET_HOME"/monet_harvest.py
