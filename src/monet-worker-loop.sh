#!/bin/bash
# monet-worker-loop.sh <slot> — claim and run queued jobs forever (or once if MONET_WORKER_ONESHOT=1)
set -uo pipefail
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
SLOT="${1:?slot}"
QUEUE="$MONET_HOME"/src/monet-queue
RUNNER="${MONET_BG_RUNNER:-${MONET_HOME}/monet-bg-runner.sh}"
LOG="${MONET_LOG_FILE:-${MONET_LOG_DIR:-$MONET_HOME/logs}/monet-tg.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{ : >> "$LOG"; } 2>/dev/null || LOG=/dev/null
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [worker:$SLOT] $*" >> "$LOG"; }
run_once(){
  local jid; jid=$("$QUEUE" claim "$SLOT")
  if [ -n "$jid" ]; then log "claimed $jid"; "$RUNNER" "$jid"; return 0; fi
  return 1
}
if [ "${MONET_WORKER_ONESHOT:-0}" = "1" ]; then run_once; exit 0; fi
log "start"
while true; do run_once || sleep 2; done
