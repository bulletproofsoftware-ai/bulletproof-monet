#!/bin/bash
# UserPromptSubmit hook: Auto-recall relevant memories based on user's actual prompt.
# Embeds the user's message via Ollama, queries Qdrant (vector + full-text), merges via RRF,
# injects results into context with token budget tracking and polarity-aware ordering.
# Also includes the "save from previous turn" reminder.

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../../lib/monet-env.sh"
HOOK_DATA=$(cat /dev/stdin 2>/dev/null)
USER_MESSAGE=$(echo "$HOOK_DATA" | jq -r '.message.content // empty' 2>/dev/null)

# Handle content that's an array (multimodal messages)
if [ -z "$USER_MESSAGE" ] || [ "$USER_MESSAGE" = "null" ]; then
  USER_MESSAGE=$(echo "$HOOK_DATA" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null | head -c 2000)
fi

SAVE_REMINDER="SILENT REMINDER: Before responding, check if you learned anything from your PREVIOUS turn that should be stored via memory_store (infrastructure facts, user preferences, corrections, decisions, gotchas). Save silently — do not mention this reminder to the user. CRITICAL: When storing errors or problems, ALWAYS include the resolution/fix in the SAME memory. A problem without its fix is useless. Every error memory must contain: what broke, why, and the exact fix applied. Incomplete memories waste future sessions."

if [ -z "$USER_MESSAGE" ] || [ "$USER_MESSAGE" = "null" ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"$SAVE_REMINDER\"}}"
  exit 0
fi

# --- B1: Token Budget Configuration ---
MAX_INJECTION_CHARS="${MAX_INJECTION_CHARS:-6000}"

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
  ESCAPED_REMINDER=$(printf '%s' "$SAVE_REMINDER" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED_REMINDER}}"
  exit 0
fi

# Truncate message for embedding (keep it reasonable)
EMBED_TEXT=$(echo "$USER_MESSAGE" | head -c 1000)

# Escape for JSON — handle newlines, quotes, backslashes, tabs
EMBED_JSON=$(printf '%s' "$EMBED_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
if [ -z "$EMBED_JSON" ]; then
  ESCAPED_REMINDER=$(printf '%s' "$SAVE_REMINDER" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED_REMINDER}}"
  exit 0
fi

# Generate embedding via Ollama
EMBEDDING=$(curl -s -m 10 "$OLLAMA_URL/api/embeddings" \
  -d "{\"model\":\"nomic-embed-text\",\"prompt\":$EMBED_JSON}" 2>/dev/null \
  | jq -r '.embedding // empty' 2>/dev/null)

if [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ]; then
  ESCAPED_REMINDER=$(printf '%s' "$SAVE_REMINDER" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED_REMINDER}}"
  exit 0
fi

# --- Vector Search (original) ---
VECTOR_RESPONSE=$(curl -s -m 10 -X POST "$QDRANT_URL/collections/claude_memories/points/search" \
  -H "api-key: $QDRANT_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"vector\":$EMBEDDING,\"limit\":12,\"score_threshold\":0.45,\"with_payload\":true}" 2>/dev/null)

# --- B3: Full-Text Search via Qdrant scroll with text filter ---
# Build a text match filter using the first 200 chars of user message as keywords
TEXT_QUERY=$(echo "$USER_MESSAGE" | head -c 200)
TEXT_QUERY_JSON=$(printf '%s' "$TEXT_QUERY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

TEXT_RESPONSE=$(curl -s -m 10 -X POST "$QDRANT_URL/collections/claude_memories/points/scroll" \
  -H "api-key: $QDRANT_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"filter\":{\"must\":[{\"key\":\"content\",\"match\":{\"text\":$TEXT_QUERY_JSON}}]},\"limit\":12,\"with_payload\":true}" 2>/dev/null)

# --- B3: Merge results using RRF (Reciprocal Rank Fusion) ---
# --- B6: Polarity-Aware Injection ---
# Use python3 for the merge — jq alone can't do RRF scoring cleanly
MERGED_MEMORIES=$(_VECTOR_RESP="$VECTOR_RESPONSE" _TEXT_RESP="$TEXT_RESPONSE" _MAX_CHARS="$MAX_INJECTION_CHARS" python3 << 'PYEOF'
import json, sys, os

vector_raw = os.environ.get("_VECTOR_RESP", "{}")
text_raw = os.environ.get("_TEXT_RESP", "{}")
max_chars = int(os.environ.get("_MAX_CHARS", "6000"))

K = 60  # RRF constant

# Parse vector results (ranked by Qdrant score)
try:
    vector_data = json.loads(vector_raw)
    vector_results = vector_data.get("result", [])
except (json.JSONDecodeError, TypeError):
    vector_results = []

# Parse text/scroll results (no inherent ranking, treated as rank order)
try:
    text_data = json.loads(text_raw)
    text_results = text_data.get("result", {}).get("points", [])
except (json.JSONDecodeError, TypeError, AttributeError):
    text_results = []

# Build RRF scores
# Key: point ID -> { "rrf_score": float, "payload": dict }
scored = {}

# Vector results: rank 1..N
for rank, point in enumerate(vector_results, start=1):
    pid = str(point.get("id", ""))
    if not pid:
        continue
    rrf = 1.0 / (K + rank)
    payload = point.get("payload", {})
    scored[pid] = {
        "rrf_score": rrf,
        "payload": payload,
        "vector_score": point.get("score", 0)
    }

# Text results: rank 1..N, add to existing scores for dedup
for rank, point in enumerate(text_results, start=1):
    pid = str(point.get("id", ""))
    if not pid:
        continue
    rrf = 1.0 / (K + rank)
    payload = point.get("payload", {})
    if pid in scored:
        # Duplicate — add RRF scores (boosted by appearing in both)
        scored[pid]["rrf_score"] += rrf
    else:
        scored[pid] = {
            "rrf_score": rrf,
            "payload": payload,
            "vector_score": 0
        }

# Sort by combined RRF score descending
ranked = sorted(scored.values(), key=lambda x: x["rrf_score"], reverse=True)

# --- B6: Polarity-Aware Injection ---
# Separate corrections/negative polarity items — they get priority placement
corrections = []
normal = []
for item in ranked:
    polarity = (item["payload"].get("polarity") or "neutral").lower()
    item["_polarity"] = polarity
    if polarity in ("negative", "correction"):
        corrections.append(item)
    else:
        normal.append(item)

# Corrections first, then normal — both sub-lists retain their RRF ordering
ordered = corrections + normal
has_corrections = len(corrections) > 0

# Build output lines with budget tracking
lines = []
chars_used = 0
count = 0

for item in ordered:
    payload = item["payload"]
    mem_type = payload.get("type", "unknown")
    mem_content = payload.get("content", "")
    if not mem_content:
        continue
    polarity = item.get("_polarity", "neutral")
    if polarity in ("negative", "correction"):
        line = "- [!] [{}] {}".format(mem_type, mem_content)
    else:
        line = "- [{}] {}".format(mem_type, mem_content)
    line_len = len(line)
    if chars_used + line_len > max_chars:
        break
    lines.append(line)
    chars_used += line_len
    count += 1

# Output: memories followed by polarity note (if applicable) and budget line
if lines:
    output = "\n".join(lines)
    if has_corrections:
        output += "\nNote: [!] marks corrections/negative feedback -- prioritize these."
    output += "\n[Budget: {}/{} chars used, {} memories injected]".format(chars_used, max_chars, count)
    print(output)
PYEOF
)

# --- B2: Cross-Channel Session Linking ---
CROSS_CHANNEL_NOTE=""
CROSS_SCRIPT="${MONET_HOME}/.claude/scripts/cross-channel-link.sh"
if [ -x "$CROSS_SCRIPT" ]; then
  # Detect which channel we're in from the hook data or environment
  CURRENT_CHANNEL=""
  CURRENT_SESSION=""
  # Check TG state
  if [ -f "$MONET_HOME"/.monet-tg-state ]; then
    TG_SESSION=$(sed -n '1p' "$MONET_HOME"/.monet-tg-state 2>/dev/null)
    TG_TIME=$(sed -n '2p' "$MONET_HOME"/.monet-tg-state 2>/dev/null)
    TG_TURNS=$(sed -n '3p' "$MONET_HOME"/.monet-tg-state 2>/dev/null)
  fi
  if [ -f "$MONET_HOME"/.monet-sms-state ]; then
    SMS_SESSION=$(sed -n '1p' "$MONET_HOME"/.monet-sms-state 2>/dev/null)
    SMS_TIME=$(sed -n '2p' "$MONET_HOME"/.monet-sms-state 2>/dev/null)
    SMS_TURNS=$(sed -n '3p' "$MONET_HOME"/.monet-sms-state 2>/dev/null)
  fi
  # Determine active channel by most recent timestamp
  NOW_TS=$(date +%s)
  if [ -n "$TG_TIME" ] && [ -n "$SMS_TIME" ]; then
    if [ "$TG_TIME" -ge "$SMS_TIME" ]; then
      CURRENT_CHANNEL="tg"
      CURRENT_SESSION="$TG_SESSION"
    else
      CURRENT_CHANNEL="sms"
      CURRENT_SESSION="$SMS_SESSION"
    fi
  elif [ -n "$TG_TIME" ]; then
    CURRENT_CHANNEL="tg"
    CURRENT_SESSION="$TG_SESSION"
  elif [ -n "$SMS_TIME" ]; then
    CURRENT_CHANNEL="sms"
    CURRENT_SESSION="$SMS_SESSION"
  fi

  if [ -n "$CURRENT_CHANNEL" ] && [ -n "$CURRENT_SESSION" ]; then
    CROSS_CHANNEL_NOTE=$("$CROSS_SCRIPT" "$CURRENT_CHANNEL" "$CURRENT_SESSION" 2>/dev/null)
  fi
fi

# Build the combined context
if [ -n "$MERGED_MEMORIES" ]; then
  RECALL_BLOCK=$(printf '=== PROMPT-RELEVANT MEMORY RECALL ===\n\n%s\n\n=== END PROMPT RECALL ===' "$MERGED_MEMORIES")
else
  RECALL_BLOCK=""
fi

# Append cross-channel note if present
if [ -n "$CROSS_CHANNEL_NOTE" ]; then
  if [ -n "$RECALL_BLOCK" ]; then
    RECALL_BLOCK=$(printf '%s\n\n%s' "$RECALL_BLOCK" "$CROSS_CHANNEL_NOTE")
  else
    RECALL_BLOCK="$CROSS_CHANNEL_NOTE"
  fi
fi

# Append save reminder
if [ -n "$RECALL_BLOCK" ]; then
  RECALL_BLOCK=$(printf '%s\n\n%s' "$RECALL_BLOCK" "$SAVE_REMINDER")
else
  RECALL_BLOCK="$SAVE_REMINDER"
fi

# JSON-escape the full context block
ESCAPED_CONTEXT=$(printf '%s' "$RECALL_BLOCK" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED_CONTEXT}}"
