#!/bin/bash
# monet-research.sh <chat_id> <query>
# Multi-angle web research for Monet: monet's Claude generates several search-query
# variations -> agy (Antigravity CLI) runs them in PARALLEL as web searches ->
# Claude aggregates + synthesizes -> result delivered to the Telegram chat.
# Designed to run in the BACKGROUND (searches+synthesis exceed the 300s TG turn).
# Pin cwd+HOME: `claude` derives its projects/<slug> dir from the working
# directory. Without this, sessions are written under one slug dir and
# resumed under another -> "No conversation found" on a live transcript.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"
# keyring env so agy finds its persisted OAuth token
U=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$U"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$U/bus"

CHAT_ID="${1:?usage: monet-research.sh <chat_id> <query>}"
QUERY="${2:?usage: monet-research.sh <chat_id> <query>}"
LOG="/var/log/monet-tg.log"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
NVAR="${RESEARCH_VARIATIONS:-5}"      # number of search angles
LOCK="${MONET_HOME}/.monet-research.lock"
WORK="$(mktemp -d /tmp/monet-research.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESEARCH $*" >> "$LOG"; }

# serialize: at most one research run at a time (agy is heavy)
exec 6>"$LOCK"
if ! flock -n 6; then
    echo "⏳ A research run is already in progress — try again in a minute." | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    exit 0
fi

log "START chat=$CHAT_ID q=\"${QUERY:0:80}\""

# --- 1. generate query variations (Claude) ---
VARS="$(timeout 60 claude -p --model "$MODEL" --max-turns 1 \
    --dangerously-skip-permissions --disable-slash-commands \
    "Generate exactly $NVAR diverse web-search queries to research this topic from different angles (direct, alternative terms, recent/2026, sub-aspects, comparisons): \"$QUERY\". Output ONLY the queries, one per line, no numbering, no commentary." \
    2>>"$LOG" | sed '/^[[:space:]]*$/d' | head -"$NVAR")"
[ -z "$VARS" ] && VARS="$QUERY"
log "variations: $(echo "$VARS" | wc -l | tr -d ' ')"

# --- 2. run agy web searches in PARALLEL ---
i=0
while IFS= read -r v; do
    [ -z "$v" ] && continue
    i=$((i+1))
    (
        agy --dangerously-skip-permissions --print-timeout 4m \
            --log-file "$WORK/agy-$i.log" \
            -p "Search the web for: $v. Summarize the key findings concisely and include the source URLs." \
            > "$WORK/result-$i.txt" 2>>"$LOG"
    ) &
done <<< "$VARS"
wait
log "searches complete ($i angles)"

# --- 3. aggregate ---
AGG=""
n=0
for f in "$WORK"/result-*.txt; do
    [ -s "$f" ] || continue
    n=$((n+1))
    AGG+="$(printf '\n\n=== Angle %s ===\n%s' "$n" "$(cat "$f")")"
done
if [ -z "$AGG" ]; then
    echo "⚠️ Research for \"$QUERY\" returned no results (agy searches empty)." | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null
    log "FAIL no results"
    exit 0
fi

# --- 4. synthesize (Claude) ---
SUMMARY="$(timeout 150 claude -p --model "$MODEL" --max-turns 1 \
    --dangerously-skip-permissions --disable-slash-commands \
    "Synthesize the web-search results below into a tight research brief on \"$QUERY\" for delivery on Telegram. Sections: *Key Findings* (bullets), *Details by angle*, *Sources* (the URLs), *Actionable insights*. Use ONLY information present in the results; do not invent facts. Keep it scannable.

SEARCH RESULTS:$AGG" \
    2>>"$LOG")"
[ -z "$SUMMARY" ] && SUMMARY="(synthesis step failed — raw findings)$AGG"

# --- 5. save markdown doc (PRD #16) + deliver ---
RESEARCH_DIR="${MONET_HOME}/research"
mkdir -p "$RESEARCH_DIR" 2>/dev/null
SLUG=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-60)
[ -z "$SLUG" ] && SLUG="research"
DOC="$RESEARCH_DIR/$(date +%Y-%m-%d)-${SLUG}.md"
{
    printf '# Research Brief: %s\n\n' "$QUERY"
    printf '_Generated %s by Monet — %s search angles_\n\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$n"
    printf '%s\n' "$SUMMARY"
} > "$DOC" 2>/dev/null && log "DOC saved $DOC"

# Self-critique pass (PRD #3) — flag weak/unsupported conclusions before delivery
CRITIC_FOOTER=$(printf '%s' "$SUMMARY" | timeout 70 "$MONET_HOME"/bin/critic "research: $QUERY" 2>/dev/null)
[ -n "$CRITIC_FOOTER" ] && log "CRITIC flagged research brief"

printf '🔎 Research brief: %s\n\n%s%s\n\n📄 Saved: %s' "$QUERY" "$SUMMARY" "${CRITIC_FOOTER:+

$CRITIC_FOOTER}" "$DOC" | ${MONET_HOME}/tg-send.sh "$CHAT_ID" 2>/dev/null
log "DELIVERED chat=$CHAT_ID angles=$n len=${#SUMMARY} doc=$DOC critic=${CRITIC_FOOTER:+flagged}"
