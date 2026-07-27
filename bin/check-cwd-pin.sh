#!/bin/bash
# check-cwd-pin.sh — guard against the "No conversation found" class of bug.
#
# `claude` derives its ~/.claude/projects/<slug> dir from the working directory.
# Any Monet script that invokes `claude` must pin cwd to "$MONET_HOME", or its
# sessions land in a stray slug dir and later --resume fails on a live
# transcript. Fixed 2026-07-20; this check stops it from silently returning.
#
# Run: "$MONET_HOME"/bin/check-cwd-pin.sh  (exit 0 = clean, 1 = unpinned found)
set -uo pipefail

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
MONET="$MONET_HOME"
unpinned=()
stray_growth=0

# 1) Every script that actually INVOKES claude must have the cd pin.
#    (pgrep/pkill references don't count — e.g. monet-watchdog.sh.)
while IFS= read -r f; do
    case "$f" in *.bak*|*/check-cwd-pin.sh) continue;; esac
    # Strip comment and pgrep/pkill lines first: those reference claude as a
    # search pattern, not an invocation (e.g. monet-watchdog.sh line 25).
    grep -vE '^[[:space:]]*#|pgrep|pkill' "$f" 2>/dev/null \
        | grep -qE '(^|[^-[:alnum:]_])claude[[:space:]]+(-p|.*--resume)' || continue
    # The pin is now `cd "$MONET_HOME"`, established by sourcing lib/monet-env.sh.
    # Accept either that or a literal cd to the resolved install root.
    grep -qE '^[[:space:]]*cd[[:space:]]+"?\$\{?MONET_HOME\}?"?' "$f" 2>/dev/null && continue
    grep -qE "^[[:space:]]*cd[[:space:]]+\"?${MONET}\"?([[:space:]]|$|\|)" "$f" 2>/dev/null && continue
    unpinned+=("$f")
done < <(find "$MONET" -maxdepth 2 \( -name '*.sh' -o -path "$MONET/bin/*" \) -type f 2>/dev/null)

# 2) Stray project dirs are the observable symptom.
# Claude Code slugifies the working directory by replacing '/' with '-', so the
# expected dir for this install root is derived, not hardcoded.
EXPECTED_SLUG="${MONET//\//-}"
for d in "$MONET"/.claude/projects/*/; do
    [ -d "$d" ] || continue
    case "$d" in */"$EXPECTED_SLUG"/) continue;; esac
    n=$(find "$d" -name '*.jsonl' -mmin -1440 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && { echo "WARN: $n new session(s) in stray dir $d (last 24h)"; stray_growth=1; }
done

if [ ${#unpinned[@]} -gt 0 ]; then
    echo "FAIL: these invoke claude without 'cd ${MONET_HOME}':"
    printf '  %s\n' "${unpinned[@]}"
fi

if [ ${#unpinned[@]} -eq 0 ] && [ "$stray_growth" -eq 0 ]; then
    echo "OK: all claude callers pinned; no stray session growth."
    exit 0
fi
exit 1
