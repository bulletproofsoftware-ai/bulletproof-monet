#!/bin/bash
# session-nudge.sh — Monet SessionStart hook (feature #1, the "nudge").
# FAST: pure bash, no LLM, no network — safe for the latency-sensitive pipeline.
# Every Nth session it injects a one-line reminder to persist durable knowledge.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../../lib/monet-env.sh"
COUNTER_FILE="${MONET_HOME}/.nudge-counter"
N="${MONET_NUDGE_EVERY:-5}"

n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$COUNTER_FILE" 2>/dev/null

if [ $((n % N)) -ne 0 ]; then
    exit 0
fi

NUDGE="Reflection nudge: if this conversation produced a durable fact about ${MONET_OWNER_NAME:-the operator}, a stable preference, or a reusable multi-step procedure, persist it now with memory_store so it survives across sessions (reusable procedures may later become skills). Skip one-off trivia and ephemeral lookups."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}' \
    "$(printf '%s' "$NUDGE" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
exit 0
