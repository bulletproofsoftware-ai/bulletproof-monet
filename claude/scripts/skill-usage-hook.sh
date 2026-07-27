#!/bin/bash
# skill-usage-hook.sh — PostToolUse(Skill) hook: append a skill-invocation record
# to the usage log for performance scoring (PRD #2). Reads the hook JSON payload
# on stdin. Must be fast and never block — always exits 0.
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../../lib/monet-env.sh"
LOG="${SKILL_USAGE_LOG:-${MONET_HOME}/data/skill-usage.jsonl}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

SKILL_USAGE_LOG="$LOG" python3 -c '
import sys, json, time, os
log = os.environ.get("SKILL_USAGE_LOG")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
slug = (ti.get("skill") or ti.get("name") or "").strip()
if not slug:
    sys.exit(0)
rec = {"slug": slug, "ts": int(time.time()), "cwd": d.get("cwd", "")}
try:
    with open(log, "a") as f:
        f.write(json.dumps(rec) + "\n")
except Exception:
    pass
' 2>/dev/null
exit 0
