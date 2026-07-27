#!/bin/bash
# PreToolUse hook: Tool Facade — intercepts exploratory searches and serves
# memory content AS the result. Claude never needs to "decide" to check memory.
# If Qdrant has the answer, it's delivered directly. No redirect, no "go check
# memory_recall." The answer is HERE. Use it and move on.

HOOK_DATA=$(cat /dev/stdin 2>/dev/null)
TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$HOOK_DATA" | jq -r '.tool_input // empty' 2>/dev/null)

# Extract search terms based on tool type
SEARCH_TERMS=""
SEARCH_PATH=""
FILE_GLOB=""
FILE_TYPE=""
case "$TOOL_NAME" in
  Grep)
    SEARCH_TERMS=$(echo "$TOOL_INPUT" | jq -r '.pattern // empty' 2>/dev/null)
    SEARCH_PATH=$(echo "$TOOL_INPUT" | jq -r '.path // empty' 2>/dev/null)
    FILE_GLOB=$(echo "$TOOL_INPUT" | jq -r '.glob // empty' 2>/dev/null)
    FILE_TYPE=$(echo "$TOOL_INPUT" | jq -r '.type // empty' 2>/dev/null)
    ;;
  Glob)
    SEARCH_TERMS=$(echo "$TOOL_INPUT" | jq -r '.pattern // empty' 2>/dev/null)
    SEARCH_PATH=$(echo "$TOOL_INPUT" | jq -r '.path // empty' 2>/dev/null)
    ;;
  *)
    echo '{"hookSpecificOutput":{"decision":"allow"}}'
    exit 0
    ;;
esac

# Skip if no meaningful search terms
if [ -z "$SEARCH_TERMS" ] || [ ${#SEARCH_TERMS} -lt 4 ]; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Skip if searching source code files (actual code searches, not config hunting)
# Check: glob filter targets code files, or type parameter is a code language
CODE_EXTENSIONS="\.py|\.js|\.ts|\.tsx|\.jsx|\.go|\.rs|\.java|\.rb|\.cpp|\.c|\.h|\.swift|\.kt"
if [ -n "$FILE_GLOB" ] && echo "$FILE_GLOB" | grep -qE "$CODE_EXTENSIONS"; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi
CODE_TYPES="py|js|ts|go|rust|java|ruby|cpp|c|swift|kotlin"
if [ -n "$FILE_TYPE" ] && echo "$FILE_TYPE" | grep -qE "^($CODE_TYPES)$"; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Skip if searching inside a project's src/lib/app directories (clearly code work)
if [ -n "$SEARCH_PATH" ] && echo "$SEARCH_PATH" | grep -qE "/src/|/lib/|/app/|/components/|/pages/|/tests?/|/spec/"; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Skip glob patterns that are clearly looking for code files
if [ "$TOOL_NAME" = "Glob" ] && echo "$SEARCH_TERMS" | grep -qE "\*\.(py|js|ts|tsx|jsx|go|rs|java|rb|sh|css|html|vue|svelte)"; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Detect host and set paths
if [ -d "~/mcp-servers" ]; then
  ENV_FILE="~/mcp-servers/.env"
else
  ENV_FILE="$HOME/Documents/Code/claude_backend/.env"
fi

OLLAMA_URL="http://localhost:11434"
QDRANT_URL="http://localhost:6334"

# Load Qdrant API key
QDRANT_API_KEY=""
if [ -f "$ENV_FILE" ]; then
  QDRANT_API_KEY=$(grep '^QDRANT_API_KEY=' "$ENV_FILE" | cut -d'=' -f2)
fi

if [ -z "$QDRANT_API_KEY" ]; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Build a search query from the search terms + tool context
QUERY_TEXT="$SEARCH_TERMS"
if [ -n "$SEARCH_PATH" ]; then
  QUERY_TEXT="$SEARCH_TERMS $SEARCH_PATH"
fi

# Truncate and escape for JSON
QUERY_TEXT=$(echo "$QUERY_TEXT" | head -c 500)
QUERY_JSON=$(printf '%s' "$QUERY_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

if [ -z "$QUERY_JSON" ]; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Generate embedding via Ollama (fast, 2s timeout)
EMBEDDING=$(curl -s -m 2 "$OLLAMA_URL/api/embeddings" \
  -d "{\"model\":\"nomic-embed-text\",\"prompt\":$QUERY_JSON}" 2>/dev/null \
  | jq -r '.embedding // empty' 2>/dev/null)

if [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ]; then
  echo '{"hookSpecificOutput":{"decision":"allow"}}'
  exit 0
fi

# Search Qdrant with LOWER threshold (0.60) — wider net, importance-filter after
RESPONSE=$(curl -s -m 2 -X POST "$QDRANT_URL/collections/claude_memories/points/search" \
  -H "api-key: $QDRANT_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"vector\":$EMBEDDING,\"limit\":5,\"score_threshold\":0.60,\"with_payload\":true}" 2>/dev/null)

# Apply importance-weighted filtering and serve memory as resolved facts
FACADE_RESULT=$(echo "$RESPONSE" | python3 -c '
import sys, json, math
try:
    data = json.load(sys.stdin)
    results = data.get("result", [])
    if not results:
        print("ALLOW")
        sys.exit(0)

    type_weights = {"preference": 1.15, "decision": 1.15, "fact": 1.0, "context": 0.95}
    resolved = []

    for r in results:
        score = r.get("score", 0)
        payload = r.get("payload", {})
        ac = payload.get("access_count", 0)
        mtype = payload.get("type", "fact")

        access_boost = 1 + math.log2(1 + ac) * 0.1
        tw = type_weights.get(mtype, 1.0)
        meta = 1.1 if payload.get("is_meta_memory") else 1.0
        adjusted = score * access_boost * tw * meta

        if adjusted >= 0.72:
            content = payload.get("content", "")
            project = payload.get("project", "global")
            tags = ", ".join(payload.get("tags", [])[:3])
            resolved.append(f"[{mtype}|{project}] {content}")

    if resolved:
        # Serve as resolved facts — not a redirect
        print("RESOLVED")
        for m in resolved[:5]:
            print(m)
    else:
        print("ALLOW")
except Exception:
    print("ALLOW")
' 2>/dev/null)

FIRST_LINE=$(echo "$FACADE_RESULT" | head -1)

if [ "$FIRST_LINE" = "RESOLVED" ]; then
  # Tool Facade: deliver memory content directly as the answer
  MEMORIES=$(echo "$FACADE_RESULT" | tail -n +2)
  FACADE_MSG=$(printf 'KNOWN INFORMATION (from your memory system — these are verified facts, use them directly):\n\n%s\n\nThis answers your search. Proceed with this information. Do NOT re-search the filesystem for what is already known above.' "$MEMORIES")
  ESCAPED_MSG=$(printf '%s' "$FACADE_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

  echo "{\"hookSpecificOutput\":{\"decision\":\"block\",\"reason\":$ESCAPED_MSG}}"
  exit 0
fi

# No relevant memories — allow the search
echo '{"hookSpecificOutput":{"decision":"allow"}}'
exit 0
