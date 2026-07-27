#!/bin/bash
# Monet Audit Trail — Bash helper functions
# Source this from bridge scripts: source "$MONET_HOME"/lib/audit_helpers.sh

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/monet-env.sh"
AUDIT_PY="${MONET_HOME}/lib/audit.py"
INJECTION_PY="${MONET_HOME}/lib/injection_filter.py"

# Log an audit event (non-blocking — runs in background)
# Usage: audit_log --channel tg --action message_received --chat-id 123 [--details "..."]
audit_log() {
    python3 "$AUDIT_PY" log "$@" &>/dev/null &
}

# Log an audit event and wait for result (blocking)
# Usage: audit_log_sync --channel tg --action claude_response ...
audit_log_sync() {
    python3 "$AUDIT_PY" log "$@" 2>/dev/null
}

# Save session state to SQLite
# Usage: session_save --chat-id 123 --session-id abc --turns 5 [--context-summary "..."]
session_save() {
    python3 "$AUDIT_PY" session-save "$@" &>/dev/null &
}

# Load session state from SQLite (blocking — outputs JSON)
# Usage: SESSION_JSON=$(session_load 123)
session_load() {
    python3 "$AUDIT_PY" session-load --chat-id "$1" 2>/dev/null
}

# Parse session JSON fields
# Usage: eval "$(parse_session "$SESSION_JSON")"
# Sets: DB_SESSION_ID, DB_LAST_ACTIVITY, DB_TURN_COUNT, DB_CONTEXT_SUMMARY
parse_session() {
    local json="$1"
    [ -z "$json" ] || [ "$json" = "{}" ] && return 1
    python3 -c "
import json, sys, shlex
d = json.loads(sys.argv[1])
if d:
    print(f'DB_SESSION_ID={shlex.quote(str(d.get(\"session_id\",\"\")))}')
    print(f'DB_LAST_ACTIVITY={d.get(\"last_activity\",0)}')
    print(f'DB_TURN_COUNT={d.get(\"turn_count\",0)}')
    summary = d.get('context_summary','') or ''
    print(f'DB_CONTEXT_SUMMARY={shlex.quote(summary)}')
" "$json" 2>/dev/null
}

# Extract token counts from Claude JSON output
# Usage: eval "$(parse_claude_output "$RAW_JSON")"
# Sets: CLAUDE_INPUT_TOKENS, CLAUDE_OUTPUT_TOKENS, CLAUDE_SESSION_ID, CLAUDE_RESULT_FILE
parse_claude_output() {
    local raw="$1"
    python3 -c "
import json, sys, shlex
try:
    d = json.loads(sys.argv[1])
    sid = d.get('session_id', '')
    result = d.get('result', '')
    usage = d.get('usage', {})
    inp = usage.get('input_tokens', 0)
    out = usage.get('output_tokens', 0)
    print(f'CLAUDE_SESSION_ID={shlex.quote(str(sid))}')
    print(f'CLAUDE_INPUT_TOKENS={inp}')
    print(f'CLAUDE_OUTPUT_TOKENS={out}')
    # Result may contain special chars — write to temp file instead
    import tempfile, os
    fd, path = tempfile.mkstemp(prefix='monet-resp-', dir='/tmp')
    with os.fdopen(fd, 'w') as f:
        f.write(result)
    print(f'CLAUDE_RESULT_FILE={shlex.quote(path)}')
except Exception as e:
    print(f'CLAUDE_SESSION_ID=\"\"')
    print(f'CLAUDE_INPUT_TOKENS=0')
    print(f'CLAUDE_OUTPUT_TOKENS=0')
    print(f'CLAUDE_RESULT_FILE=\"\"')
" "$raw" 2>/dev/null
}

# Check for prompt injection (blocking)
# Usage: INJECTION_RESULT=$(check_injection "user message")
# Returns JSON: {"blocked": true/false, "severity": "...", "patterns": [...], "score": 0.9}
check_injection() {
    python3 "$INJECTION_PY" "$@" 2>/dev/null
}

# Quick injection check — returns 0 if blocked, 1 if clean
# Usage: if is_injection "$MSG"; then echo "blocked"; fi
is_injection() {
    python3 "$INJECTION_PY" "$@" >/dev/null 2>&1
    # injection_filter.py exits 1 if blocked, 0 if clean — invert for bash convention
    [ $? -eq 1 ]
}

# Get usage summary (blocking)
# Usage: USAGE_TEXT=$(get_usage_summary)
get_usage_summary() {
    python3 "$AUDIT_PY" usage --days 7 --today 2>/dev/null
}

# Initialize database
init_audit_db() {
    python3 "$AUDIT_PY" init 2>/dev/null
}
