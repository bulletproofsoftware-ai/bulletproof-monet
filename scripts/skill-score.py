#!/usr/bin/env python3
"""skill-score.py — aggregate skill usage into skill-scores.json (PRD #2).

Reads the invocation log written by the Skill PostToolUse hook
($MONET_HOME/data/skill-usage.jsonl) and the skills inventory
($MONET_SKILLS_DIR, default ~/.claude/skills), and writes per-skill metrics to
$MONET_HOME/data/skill-scores.json:

  invocations, last_used, days_since_used,
  avg_quality, modification_rate   (the latter two populate once the #3
                                    critic loop lands — null until then)

Cron: nightly. Consumed by skill-coverage-audit.py (#45).
"""
import glob
import json
import os
import time
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
# Skill docs live in the operator's Claude Code config (outside this repo), so
# this resolves against the invoking user's $HOME, not the install root.
SKILLS_DIR = os.environ.get("MONET_SKILLS_DIR",
                            os.path.expanduser("~/.claude/skills"))
USAGE = os.environ.get("SKILL_USAGE_LOG", f"{HOME}/data/skill-usage.jsonl")
OUT = os.environ.get("SKILL_SCORES", f"{HOME}/data/skill-scores.json")


def inventory():
    out = []
    for p in sorted(glob.glob(f"{SKILLS_DIR}/*/")):
        name = os.path.basename(p.rstrip("/"))
        if name.startswith("_"):
            continue
        out.append(name)
    return out


def load_usage():
    recs = []
    try:
        with open(USAGE) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return recs


def main():
    inv = inventory()
    usage = load_usage()
    agg = {s: {"invocations": 0, "last_used": None} for s in inv}
    for r in usage:
        s = r.get("slug")
        if not s:
            continue
        agg.setdefault(s, {"invocations": 0, "last_used": None})
        agg[s]["invocations"] += 1
        ts = r.get("ts")
        if ts and (agg[s]["last_used"] is None or ts > agg[s]["last_used"]):
            agg[s]["last_used"] = ts

    now = int(time.time())
    scores = {}
    for s, v in agg.items():
        lu = v["last_used"]
        scores[s] = {
            "invocations": v["invocations"],
            "last_used": lu,
            "days_since_used": None if lu is None else (now - lu) // 86400,
            "avg_quality": None,        # set by #3 critic loop
            "modification_rate": None,  # set by #3 critic loop
        }

    out = {"generated": now, "skill_count": len(inv), "scores": scores}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(out, fh, indent=2)
    os.replace(tmp, OUT)
    used = sum(1 for v in scores.values() if v["invocations"] > 0)
    print(f"skill-score: {len(inv)} skills, {used} used, {len(usage)} invocations logged -> {OUT}")


if __name__ == "__main__":
    main()
