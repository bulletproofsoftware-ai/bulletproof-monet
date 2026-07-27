#!/usr/bin/env python3
"""n8n-cost.py — execution cost tracker (PRD #34).

Ranks n8n workflows by execution cost (frequency x average duration) over the
recent execution window, so high-cost / low-value workflows surface for
optimization or retirement. Weekly cron; optional --deliver to Telegram.

Reads N8N_API_KEY from $MONET_HOME/.env.
"""
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
ENV = f"{HOME}/.env"
BASE = os.environ.get("N8N_API_URL", "http://localhost:5679/api/v1")
WINDOW = int(os.environ.get("N8N_EXEC_WINDOW", "250"))


def api_key():
    k = os.environ.get("N8N_API_KEY", "")
    if k:
        return k
    try:
        with open(ENV) as fh:
            for line in fh:
                if line.startswith("N8N_API_KEY="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def get(path, key):
    req = urllib.request.Request(BASE + path, headers={"X-N8N-API-KEY": key})
    with urllib.request.urlopen(req, timeout=12) as r:
        return json.load(r)


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def build_report(key):
    wf = get("/workflows?limit=250", key).get("data", [])
    ex = get(f"/executions?limit={WINDOW}&includeData=false", key).get("data", [])
    names = {w["id"]: w.get("name", w["id"]) for w in wf}

    active = {w["id"]: w.get("active", False) for w in wf}

    agg = {}
    for e in ex:
        wid = e.get("workflowId")
        if not wid:
            continue
        a = agg.setdefault(wid, {"n": 0, "dur": 0.0, "last": None})
        a["n"] += 1
        st, sp = parse_ts(e.get("startedAt")), parse_ts(e.get("stoppedAt"))
        if st and sp:
            a["dur"] += (sp - st).total_seconds()
        if st and (a["last"] is None or st > a["last"]):
            a["last"] = st

    ts = [parse_ts(e.get("startedAt")) for e in ex if parse_ts(e.get("startedAt"))]
    span = f"{min(ts).date()}..{max(ts).date()}" if ts else "recent window"
    # A workflow that stopped running partway through the window is spending
    # nothing now; its totals are historical residue and must not be ranked as
    # a live cost driver (e.g. a bridge replaced mid-window by another service).
    midpoint = min(ts) + (max(ts) - min(ts)) / 2 if ts else None

    rows = []
    for wid, a in agg.items():
        stale = not active.get(wid, False) or (
            midpoint is not None and a["last"] is not None and a["last"] < midpoint)
        avg = a["dur"] / a["n"] if a["n"] else 0
        rows.append((a["dur"], names.get(wid, wid), a["n"], avg, stale, a["last"]))
    rows.sort(reverse=True, key=lambda r: r[0])

    lines = [f"💰 *n8n Execution Cost* (by total compute, {span}, {len(ex)} execs)"]
    for total, name, n, avg, stale, last in rows[:15]:
        mark = ""
        if stale:
            seen = f", last {last.date()}" if last else ""
            mark = f"  ⚠️ not currently running{seen}"
        lines.append(f"• {name}: {total:.0f}s total = {n} runs x {avg:.1f}s avg{mark}")

    live = [r for r in rows if not r[4]]
    if live:
        top, name, n, avg, _, _ = live[0]
        lines.append(f"\nTop consumer: {name} ({top:.0f}s). "
                     f"High freq x long duration = optimize or reduce cadence.")
        if live[0] is not rows[0]:
            lines.append(f"(Excludes {rows[0][1]} — higher total but no longer running.)")
    elif rows:
        lines.append("\nNo currently-running workflows in this window.")
    return "\n".join(lines)


def main():
    key = api_key()
    if not key:
        print("n8n-cost: N8N_API_KEY not found")
        return
    try:
        report = build_report(key)
    except Exception as e:  # noqa: BLE001
        print(f"n8n-cost: API error: {e}")
        return
    print(report)
    if len(sys.argv) >= 3 and sys.argv[1] == "--deliver":
        try:
            subprocess.run([f"{HOME}/tg-send.sh", sys.argv[2]], input=report,
                           text=True, timeout=30)
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
