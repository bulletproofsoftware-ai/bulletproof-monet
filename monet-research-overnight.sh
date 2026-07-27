#!/bin/bash
# monet-research-overnight.sh — drains the overnight research queue and runs each
# question through monet-research.sh, delivering a saved markdown brief to the
# chat by morning (PRD #16). Cron: nightly ~03:00. flock-guarded; sequential
# (agy is heavy and monet-research.sh self-serializes).
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"
LOG="/var/log/monet-tg.log"
LOCK="${MONET_HOME}/.monet-research-overnight.lock"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESEARCH-OVERNIGHT $*" >> "$LOG"; }

exec 8>"$LOCK"
flock -n 8 || exit 0

DUE=$(python3 "$MONET_HOME"/bin/research-queue drain 2>>"$LOG")
[ -z "$DUE" ] && exit 0

COUNT=0
while IFS=$'\t' read -r CHAT Q; do
    [ -z "$CHAT" ] && continue
    [ -z "$Q" ] && continue
    COUNT=$((COUNT+1))
    log "RUN chat=$CHAT q=\"${Q:0:80}\""
    "$MONET_HOME"/monet-research.sh "$CHAT" "$Q" >>"$LOG" 2>&1 || log "FAIL chat=$CHAT"
done <<< "$DUE"

log "DONE drained=$COUNT"
