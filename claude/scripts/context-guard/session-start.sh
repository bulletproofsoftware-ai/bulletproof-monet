#!/bin/bash
# Context Guard - SessionStart Recovery
# Fires when a session starts (startup, resume, clear, compact).
# Clean slate + post-compaction recovery prompt.

INPUT=$(cat)

# Clean ALL state files for fresh session
rm -f /tmp/.claude-context-guard
rm -f /tmp/.claude-context-guard-notified
rm -f /tmp/.claude-context-counter

# Detect if this is a post-compaction resume
SOURCE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('source', d.get('session_source', 'startup')))
except:
    print('startup')
" 2>/dev/null)

if [ "$SOURCE" = "compact" ]; then
    cat <<'MSG'
{"systemMessage":"SESSION RESUMED AFTER COMPACTION. You previously saved investigation state before compacting. IMMEDIATELY: (1) Use memory_scratch(operation='read', key='session-state') to retrieve your saved progress. (2) Briefly tell the user what you were working on and where you left off. (3) Resume the task from where you stopped. Do NOT ask the user to re-explain — your saved state has everything."}
MSG
else
    OWNER="${MONET_OWNER_NAME:-the operator}"
    cat <<MSG
{"systemMessage":"You have persistent memory via MCP tools (memory_recall, memory_store, rag_search). BEFORE saying you don't know something about ${OWNER} (preferences, facts, decisions, history), ALWAYS call memory_recall first. Never claim information isn't stored without checking."}
MSG
fi

exit 0
