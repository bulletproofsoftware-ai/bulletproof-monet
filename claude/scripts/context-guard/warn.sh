#!/bin/bash
# Context Guard - PreToolUse Autonomous Warnings
# Fully autonomous — never asks user to intervene.
# Level 1 (~70%): Save state silently, work concisely
# Level 2 (~82%): Update saved state, minimal responses
# Level 3 (~92%): Final state save, wrap up current step, auto-compaction imminent
#
# After compaction, session-start.sh recovers state from memory_scratch.

FLAG="/tmp/.claude-context-guard"
NOTIFIED="/tmp/.claude-context-guard-notified"

# ── PERSISTENT LEVEL 3 CHECK ──
# If we've hit level 3, remind to wrap up but DO NOT block tool calls.
# Auto-compaction is imminent — let Claude finish the current tool call.
CURRENT=0
[ -f "$NOTIFIED" ] && CURRENT=$(cat "$NOTIFIED" 2>/dev/null)
CURRENT=${CURRENT:-0}

if [ "$CURRENT" -ge 3 ]; then
    cat <<'WARN'
{"systemMessage":"CONTEXT GUARD: Context nearly full — auto-compaction imminent. Wrap up your current step concisely. Your session state is saved. Do NOT mention context limits to the user."}
WARN
    exit 0
fi

# ── NEW ESCALATION CHECK ──
# Fast path: no new flag = no action (< 1ms)
[ ! -f "$FLAG" ] && exit 0

LEVEL=$(cat "$FLAG" 2>/dev/null)
rm -f "$FLAG"

case "$LEVEL" in
    1)
        cat <<'WARN'
{"systemMessage":"CONTEXT GUARD [~70% used]: SILENTLY use memory_scratch to save session state — key: 'session-state', content: current task, key findings, next steps, important values/paths discovered. Do NOT tell the user about context usage. Continue working but keep responses concise — shorter explanations, fewer optional details."}
WARN
        ;;
    2)
        cat <<'WARN'
{"systemMessage":"CONTEXT GUARD [~82% used]: SILENTLY update memory_scratch session state — key: 'session-state', content: current task, ALL findings and conclusions, exact next steps with specific commands/paths, any errors or important output. Do NOT mention context to the user. Keep responses minimal — only essential information. Finish the current task step then pause for user input rather than chaining multiple steps."}
WARN
        ;;
    3)
        cat <<'WARN'
{"systemMessage":"CONTEXT GUARD [~92% used]: FINAL state save. SILENTLY update memory_scratch — key: 'session-state', content: complete task state, all progress, exact resume instructions. Finish your current step concisely. Auto-compaction is imminent and session-start.sh will recover state. Do NOT mention context limits to the user."}
WARN
        ;;
esac

exit 0
