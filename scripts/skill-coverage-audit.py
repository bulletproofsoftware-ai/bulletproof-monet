#!/usr/bin/env python3
"""skill-coverage-audit.py — monthly skill coverage audit (PRD #45).

Reads skill-scores.json (produced by skill-score.py) and reports skills that
are unused for >=60 days or never invoked, as a retire/keep digest. Optionally
delivers the digest to Telegram.

  skill-coverage-audit.py                 print digest to stdout
  skill-coverage-audit.py --deliver CHAT  also send via tg-send.sh
"""
import json
import os
import subprocess
import sys
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
SCORES = os.environ.get("SKILL_SCORES", f"{HOME}/data/skill-scores.json")
THRESHOLD_DAYS = int(os.environ.get("SKILL_AUDIT_DAYS", "60"))


def build_digest():
    try:
        with open(SCORES) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return "⚠️ No skill-scores.json yet — run skill-score.py first."

    scores = data.get("scores", {})
    never = sorted(s for s, v in scores.items() if v.get("invocations", 0) == 0)
    stale = sorted(
        ((s, v["days_since_used"]) for s, v in scores.items()
         if v.get("invocations", 0) > 0
         and v.get("days_since_used") is not None
         and v["days_since_used"] >= THRESHOLD_DAYS),
        key=lambda x: -x[1],
    )

    lines = [f"🧹 *Skill Coverage Audit* — {data.get('skill_count', 0)} skills"]
    if stale:
        lines.append(f"\nUsed but idle ≥{THRESHOLD_DAYS}d (retire or refresh?):")
        lines += [f"• {s} — last used {d}d ago" for s, d in stale[:20]]
    if never:
        lines.append(f"\nNever invoked ({len(never)}) — retire or surface a "
                     f"\"remember this exists?\" nudge:")
        lines += [f"• {s}" for s in never[:30]]
        if len(never) > 30:
            lines.append(f"…and {len(never) - 30} more")
    if not stale and not never:
        lines.append("\nAll skills active within the window. 🎉")
    return "\n".join(lines)


def main():
    digest = build_digest()
    print(digest)
    if len(sys.argv) >= 3 and sys.argv[1] == "--deliver":
        chat = sys.argv[2]
        try:
            subprocess.run([f"{HOME}/tg-send.sh", chat], input=digest,
                           text=True, timeout=30)
        except Exception as e:  # noqa: BLE001
            print(f"(delivery failed: {e})", file=sys.stderr)


if __name__ == "__main__":
    main()
