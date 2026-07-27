#!/bin/bash
# monet-nlm-artifacts.sh <chat_id> <title> <source_file> [artifacts]
# Background NotebookLM artifact pipeline for Monet: create notebook -> add the
# source -> wait for ingest -> generate the requested artifacts (default:
# audio,slide-deck,infographic) -> wait for each -> enable public share ->
# deliver the share link to the Telegram chat. Runs detached (generation takes
# minutes, far past Monet's 300s turn). Monet calls this; it does NOT block Monet.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
cd "$MONET_HOME" || exit 1
set -uo pipefail

export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:${MONET_HOME}/bin:/usr/bin:/bin"
U=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$U"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$U/bus"

CHAT_ID="${1:?usage: monet-nlm-artifacts.sh <chat_id> <title> <source_file> [artifacts]}"
TITLE="${2:?missing title}"
SRC="${3:?missing source_file}"
ARTIFACTS="${4:-audio,slide-deck,infographic}"
LOG="/var/log/monet-tg.log"
LOCK="${MONET_HOME}/.monet-nlm.lock"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] NLM $*" >> "$LOG"; }
send(){ printf '%s' "$1" | "$MONET_HOME"/tg-send.sh "$CHAT_ID" 2>/dev/null; }
jid(){ python3 -c "import sys,json
KEYS=('task_id','id','artifact_id','artifactId')
def f(o):
    if isinstance(o,dict):
        for k in KEYS:
            v=o.get(k)
            if isinstance(v,str) and v: return v
        for x in o.values():
            r=f(x)
            if r: return r
    elif isinstance(o,list):
        for x in o:
            r=f(x)
            if r: return r
    return None
try: print(f(json.load(sys.stdin)) or '')
except Exception: pass" 2>/dev/null; }

exec 5>"$LOCK"
if ! flock -n 5; then send "⏳ A NotebookLM build is already running — try again when it finishes."; exit 0; fi

log "START chat=$CHAT_ID title=\"$TITLE\" artifacts=$ARTIFACTS"

# 1. create notebook
NB=$(timeout 120 notebooklm create "$TITLE" --json 2>>"$LOG" | jid)
if [ -z "$NB" ]; then log "FAIL create"; send "⚠️ NotebookLM: couldn't create the notebook (check /var/log/monet-tg.log)."; exit 1; fi
log "notebook=$NB"

# 2. add source + wait for ingest
timeout 180 notebooklm source add "$SRC" -n "$NB" 2>>"$LOG"
timeout 240 notebooklm source wait -n "$NB" 2>>"$LOG" || true
log "source ingested"

# 3. generate requested artifacts (async -> collect artifact ids)
declare -A AID
IFS=',' read -ra KINDS <<< "$ARTIFACTS"
for k in "${KINDS[@]}"; do
    k=$(echo "$k" | xargs)
    case "$k" in
        audio)       desc="deep dive on the key findings and actionable insights" ;;
        slide-deck)  desc="executive summary of the key findings" ;;
        infographic) desc="key stats, CVEs, and findings" ;;
        *)           desc="summary of the key findings" ;;
    esac
    id=$(timeout 120 notebooklm generate "$k" "$desc" -n "$NB" --json 2>>"$LOG" | jid)
    [ -n "$id" ] && { AID[$k]=$id; log "gen $k -> $id"; } || log "gen $k FAILED to start"
done

# 4. wait for each artifact
for k in "${!AID[@]}"; do
    timeout 720 notebooklm artifact wait "${AID[$k]}" -n "$NB" --timeout 700 2>>"$LOG" && log "ready: $k" || log "timeout/err: $k"
done

# 5. enable public sharing + get link
SHARE=$(timeout 90 notebooklm share public --enable -n "$NB" 2>>"$LOG")
LINK=$(printf '%s' "$SHARE" | grep -oE 'https?://[^ ")]+' | head -1)
[ -z "$LINK" ] && LINK=$(timeout 60 notebooklm share status -n "$NB" 2>>"$LOG" | grep -oE 'https?://[^ ")]+' | head -1)

# 6. deliver
READY=$(printf '%s, ' "${!AID[@]}" | sed 's/, $//')
if [ -n "$LINK" ]; then
    send "✅ NotebookLM ready: *$TITLE*
Artifacts: ${READY:-none}
$LINK"
else
    send "✅ NotebookLM artifacts generated for *$TITLE* (${READY:-none}), but I couldn't get a public link — open it in NotebookLM (notebook $NB)."
fi
log "DONE chat=$CHAT_ID notebook=$NB link=${LINK:-none}"
