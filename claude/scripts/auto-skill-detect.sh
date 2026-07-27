#!/bin/bash
# Auto-detect reusable patterns from TG conversations
# Called at session end to check if conversation pattern should become a skill
# Usage: auto-skill-detect.sh <session_id>

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../../lib/monet-env.sh"
SESSION_ID="${1:-}"
if [ -z "$SESSION_ID" ]; then
    echo "Usage: auto-skill-detect.sh <session_id>" >&2
    exit 1
fi

LOG_FILE="${MONET_HOME}/logs/auto-skill.log"
SUGGESTION_DIR="${MONET_HOME}/data/skill-suggestions"
SKILL_DIR="${MONET_HOME}/.claude/skills/auto"
QDRANT_URL="http://localhost:6334"
OLLAMA_URL="http://localhost:11434"
ENV_FILE="~/mcp-servers/.env"

mkdir -p "$(dirname "$LOG_FILE")" "$SUGGESTION_DIR" "$SKILL_DIR"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-skill] session=$SESSION_ID $*" >> "$LOG_FILE"
}

# Load Qdrant API key
QDRANT_API_KEY=""
if [ -f "$ENV_FILE" ]; then
    QDRANT_API_KEY=$(grep '^QDRANT_API_KEY=' "$ENV_FILE" | cut -d'=' -f2)
fi

if [ -z "$QDRANT_API_KEY" ]; then
    log "ERROR: No QDRANT_API_KEY found in $ENV_FILE"
    exit 0
fi

log "START scanning pheromone_trails"

# Query Qdrant pheromone_trails for trails with reinforcement_count >= 3
TRAILS=$(curl -s -m 10 "$QDRANT_URL/collections/pheromone_trails/points/scroll" \
    -H "api-key: $QDRANT_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"limit": 5, "filter": {"must": [{"key": "reinforcement_count", "range": {"gte": 3}}]}, "with_payload": true}' 2>/dev/null)

if [ -z "$TRAILS" ]; then
    log "No response from Qdrant"
    exit 0
fi

POINT_COUNT=$(echo "$TRAILS" | jq '.result.points | length' 2>/dev/null)
if [ -z "$POINT_COUNT" ] || [ "$POINT_COUNT" = "0" ] || [ "$POINT_COUNT" = "null" ]; then
    log "No trails with reinforcement_count >= 3"
    exit 0
fi

log "Found $POINT_COUNT qualifying trails"

echo "$TRAILS" | jq -c '.result.points[]' 2>/dev/null | while IFS= read -r point; do
    TRAIL_ID=$(echo "$point" | jq -r '.id // "unknown"')
    TOOL_CHAIN=$(echo "$point" | jq -r '.payload.tool_chain // .payload.pattern // .payload.description // "unknown"')
    REINFORCEMENT=$(echo "$point" | jq -r '.payload.reinforcement_count // 0')

    # Generate a slug for matching
    SKILL_SLUG=$(echo "$TOOL_CHAIN" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | head -c 40 | sed 's/-$//')

    # Check if a skill already exists with similar name
    if ls "$SKILL_DIR"/ 2>/dev/null | grep -qi "$SKILL_SLUG"; then
        log "SKIP trail=$TRAIL_ID — skill already exists matching '$SKILL_SLUG'"
        continue
    fi

    log "Querying Ollama for trail=$TRAIL_ID chain='$TOOL_CHAIN'"

    # Escape the chain for JSON
    CHAIN_JSON=$(printf '%s' "$TOOL_CHAIN" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

    PROMPT="Given this tool chain pattern: ${TOOL_CHAIN} (used ${REINFORCEMENT} times successfully)\nShould this become a reusable skill? If yes, suggest: name, description, trigger. If no, say NONE."
    PROMPT_JSON=$(printf '%s' "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

    RESPONSE=$(curl -s -m 15 "$OLLAMA_URL/api/generate" \
        -d "{\"model\": \"llama3.2:3b\", \"prompt\": $PROMPT_JSON, \"stream\": false}" 2>/dev/null)

    ANSWER=$(echo "$RESPONSE" | jq -r '.response // empty' 2>/dev/null)

    if [ -z "$ANSWER" ]; then
        log "ERROR: Empty Ollama response for trail=$TRAIL_ID"
        continue
    fi

    # Check if Ollama said NONE
    if echo "$ANSWER" | grep -qi "NONE"; then
        log "Ollama says NONE for trail=$TRAIL_ID"
        continue
    fi

    # Write suggestion
    SUGGESTION_FILE="$SUGGESTION_DIR/suggestion-$(date +%s).json"
    jq -n \
        --arg trail_id "$TRAIL_ID" \
        --arg session_id "$SESSION_ID" \
        --arg tool_chain "$TOOL_CHAIN" \
        --argjson reinforcement "$REINFORCEMENT" \
        --arg suggestion "$ANSWER" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{trail_id: $trail_id, session_id: $session_id, tool_chain: $tool_chain, reinforcement_count: $reinforcement, suggestion: $suggestion, generated_at: $ts, status: "pending"}' \
        > "$SUGGESTION_FILE" 2>/dev/null

    log "OK suggestion written to $SUGGESTION_FILE"
done

log "DONE"
