#!/bin/bash
# Summarize a conversation for session resume injection
# Reads transcript from stdin or file arg, outputs concise summary
# Usage: echo "transcript" | session-summarize.sh
#    or: session-summarize.sh /path/to/transcript.txt

OLLAMA_URL="http://localhost:11434"
MAX_CHARS=4000

# Read input from file arg or stdin
if [ -n "${1:-}" ]; then
    if [ ! -f "$1" ]; then
        echo "[Summary unavailable]"
        exit 0
    fi
    INPUT=$(head -c "$MAX_CHARS" "$1" 2>/dev/null)
else
    INPUT=$(head -c "$MAX_CHARS" 2>/dev/null)
fi

if [ -z "$INPUT" ]; then
    echo "[Summary unavailable]"
    exit 0
fi

# Build full request JSON using python3 — pipe input via stdin for clean escaping
REQUEST_JSON=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
text = sys.stdin.read()[:4000]
prompt = 'Summarize this conversation in 3-5 bullet points. Focus on decisions made, tasks completed, and pending items.\n\n' + text
print(json.dumps({'model': 'llama3.2:3b', 'prompt': prompt, 'stream': False, 'options': {'num_predict': 200}}))
" 2>/dev/null)

if [ -z "$REQUEST_JSON" ]; then
    echo "[Summary unavailable]"
    exit 0
fi

# Call Ollama
RESPONSE=$(curl -s -m 30 "$OLLAMA_URL/api/generate" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_JSON" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "[Summary unavailable]"
    exit 0
fi

SUMMARY=$(echo "$RESPONSE" | jq -r '.response // empty' 2>/dev/null)

if [ -z "$SUMMARY" ]; then
    echo "[Summary unavailable]"
    exit 0
fi

echo "$SUMMARY"
exit 0
