#!/usr/bin/env python3
"""n8n-health.py — daily n8n workflow health monitor (PRD #31).

Queries the n8n public API for all workflows and recent executions, then per
workflow computes: last execution status, error rate, average duration, and
last-run time. Surfaces broken/erroring workflows.

  n8n-health.py            full report (all workflows with executions)
  n8n-health.py --pulse    ONLY the problem section (empty if all healthy),
                           for inclusion in the morning pulse

Reads N8N_API_KEY from $MONET_HOME/.env. Error-rate threshold and execution
window are configurable via env.

Error rate is computed over a TIME window (N8N_RECENT_DAYS, default 7), not a
fixed execution count. A count window made long-fixed workflows look broken
forever on low-volume instances: 250 executions could span months, so stale
pre-fix errors stayed in the denominator until enough new runs displaced them.
The time window only counts recent executions, so a fix is reflected promptly.
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

ENV = monet_paths.path(".env")
BASE = os.environ.get("N8N_API_URL", "http://localhost:5679/api/v1")
WINDOW = int(os.environ.get("N8N_EXEC_WINDOW", "250"))  # hard cap on executions fetched
RECENT_DAYS = float(os.environ.get("N8N_RECENT_DAYS", "7"))  # time window for error rate
RECOVERED_HOURS = float(os.environ.get("N8N_RECOVERED_HOURS", "24"))  # clear alert if no error this recent
ERR_RATE_ALERT = float(os.environ.get("N8N_ERR_RATE_ALERT", "0.25"))


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


def recent_executions(key, cutoff):
    """Fetch executions newer than cutoff, paginating most-recent-first.

    The public API has no date filter, but it returns executions newest-first,
    so we page until we cross the cutoff (then stop) or hit the WINDOW cap.
    """
    out = []
    cursor = None
    while len(out) < WINDOW:
        params = {"limit": 100, "includeData": "false"}
        if cursor:
            params["cursor"] = cursor
        page = get("/executions?" + urllib.parse.urlencode(params), key)
        data = page.get("data", [])
        if not data:
            break
        stop = False
        for e in data:
            started = parse_ts(e.get("startedAt"))
            if started and started < cutoff:
                stop = True
                continue
            out.append(e)
        cursor = page.get("nextCursor")
        if stop or not cursor:
            break
    return out


def parse_ts(s):
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def main():
    pulse = "--pulse" in sys.argv
    key = api_key()
    if not key:
        print("" if pulse else "⚠️ n8n health: N8N_API_KEY not found")
        return
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=RECENT_DAYS)
    try:
        wf = get("/workflows?limit=250", key).get("data", [])
        ex = recent_executions(key, cutoff)
    except Exception as e:  # noqa: BLE001
        print("" if pulse else f"⚠️ n8n health: API error: {e}")
        return

    names = {w["id"]: w.get("name", w["id"]) for w in wf}
    active = {w["id"]: w.get("active", False) for w in wf}

    agg = {}
    for e in ex:
        wid = e.get("workflowId")
        if not wid:
            continue
        a = agg.setdefault(wid, {"total": 0, "errors": 0, "last": None,
                                 "last_status": None, "last_error": None, "durs": []})
        a["total"] += 1
        st, sp = parse_ts(e.get("startedAt")), parse_ts(e.get("stoppedAt"))
        started = st
        if e.get("status") == "error":
            a["errors"] += 1
            if started and (a["last_error"] is None or started > a["last_error"]):
                a["last_error"] = started
        if started and (a["last"] is None or started > a["last"]):
            a["last"] = started
            a["last_status"] = e.get("status")
        if st and sp:
            a["durs"].append((sp - st).total_seconds())

    problems = []
    healthy = []
    recovered_window = timedelta(hours=RECOVERED_HOURS)
    for wid, a in agg.items():
        rate = a["errors"] / a["total"] if a["total"] else 0
        avg = sum(a["durs"]) / len(a["durs"]) if a["durs"] else 0
        name = names.get(wid, wid)
        # "Recovered" = most recent run succeeded AND no error within the recovery
        # window. Lets a workflow clear promptly after a fix instead of lingering
        # in the alert list for the full RECENT_DAYS just because of pre-fix errors.
        recovered = (a["last_status"] == "success"
                     and (a["last_error"] is None
                          or now - a["last_error"] > recovered_window))
        tag = " (recovered)" if recovered and rate >= ERR_RATE_ALERT else ""
        line = (f"{name}: {a['total']} runs, {a['errors']} err "
                f"({rate:.0%}), avg {avg:.1f}s, last={a['last_status']}{tag}")
        if a["last_status"] == "error" or (rate >= ERR_RATE_ALERT and not recovered):
            problems.append((rate, f"⚠️ {line}"))
        else:
            healthy.append(line)

    problems.sort(reverse=True)

    if pulse:
        if problems:
            print("*Workflow health — needs attention:*")
            for _, p in problems:
                print(p)
        return

    print(f"n8n workflow health — {len(wf)} workflows ({sum(active.values())} active), "
          f"{len(ex)} executions in last {RECENT_DAYS:g}d")
    if problems:
        print("\nNEEDS ATTENTION:")
        for _, p in problems:
            print(p)
    if healthy:
        print(f"\nHEALTHY ({len(healthy)}):")
        for h in healthy:
            print(f"  {h}")
    idle = [names[w] for w in names if w not in agg]
    if idle:
        print(f"\nNo recent executions ({len(idle)}): " + ", ".join(idle[:20]))


if __name__ == "__main__":
    main()
