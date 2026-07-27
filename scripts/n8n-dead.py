#!/usr/bin/env python3
"""n8n-dead.py — dead workflow detector (PRD #33).

Flags n8n workflows whose most recent execution is older than THRESHOLD_DAYS
(or which have never executed), as a "deprecated / broken / replaced?" digest.
Dispositions you record (in data/workflow-dispositions.json) suppress repeat
nags for that workflow until it runs again.

  n8n-dead.py                         print digest
  n8n-dead.py --deliver CHAT          also send to Telegram
  n8n-dead.py --ack <workflowId> <note>   record a disposition (stop nagging)
"""
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
ENV = f"{HOME}/.env"
BASE = os.environ.get("N8N_API_URL", "http://localhost:5679/api/v1")
THRESHOLD_DAYS = int(os.environ.get("N8N_DEAD_DAYS", "30"))
DISPO = os.environ.get("N8N_DISPOSITIONS", f"{HOME}/data/workflow-dispositions.json")


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


def retention_horizon(key):
    """Oldest execution n8n still retains, across all workflows.

    n8n prunes execution history, so a workflow with zero retained executions
    has not necessarily never run — it may just run less often than the
    retention window (monthly workflows are the common case). Returns None if
    the horizon can't be determined, in which case callers should not claim
    anything stronger than "no executions found".
    """
    try:
        ex = get("/executions?limit=250&includeData=false", key).get("data", [])
    except Exception:  # noqa: BLE001
        return None
    ts = [t for t in (parse_ts(e.get("startedAt")) for e in ex) if t]
    # Only meaningful if the page came back full — a partial page means we can
    # see all retained history, so absence really does mean "never ran".
    return min(ts) if ts and len(ex) >= 250 else None


def load_dispo():
    try:
        with open(DISPO) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_dispo(d):
    os.makedirs(os.path.dirname(DISPO), exist_ok=True)
    tmp = DISPO + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(d, fh, indent=2)
    os.replace(tmp, DISPO)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--ack":
        d = load_dispo()
        d[sys.argv[2]] = {"note": " ".join(sys.argv[3:]),
                          "acked": datetime.now(timezone.utc).strftime("%Y-%m-%d")}
        save_dispo(d)
        print(f"disposition recorded for {sys.argv[2]}")
        return

    key = api_key()
    if not key:
        print("n8n-dead: N8N_API_KEY not found")
        return
    try:
        wf = get("/workflows?limit=250", key).get("data", [])
    except Exception as e:  # noqa: BLE001
        print(f"n8n-dead: API error: {e}")
        return

    dispo = load_dispo()
    now = datetime.now(timezone.utc)
    horizon = retention_horizon(key)
    dead = []
    for w in wf:
        wid = w["id"]
        try:
            ex = get(f"/executions?workflowId={wid}&limit=1", key).get("data", [])
        except Exception:  # noqa: BLE001
            continue
        last = parse_ts(ex[0].get("startedAt")) if ex else None
        days = (now - last).days if last else None
        if days is None or days >= THRESHOLD_DAYS:
            # suppress if acked and still no newer run than the ack
            if wid in dispo and not ex:
                continue
            dead.append((w.get("name", wid), wid, days, w.get("active")))

    dead.sort(key=lambda x: (x[2] is not None, x[2] or 0), reverse=True)
    lines = [f"🪦 *Dead Workflow Detector* (idle ≥{THRESHOLD_DAYS}d or never run)"]
    if not dead:
        lines.append("All workflows have run recently. 🎉")
    for name, wid, days, active in dead:
        if days is not None:
            age = f"{days}d idle"
        elif horizon is not None:
            # n8n prunes old executions. No rows only proves nothing ran since
            # the horizon — a monthly/quarterly workflow can look "never run".
            age = f"no runs since {horizon.date()} (execution history pruned)"
        else:
            age = "never executed"
        lines.append(f"• {name} — {age}{' [inactive]' if not active else ''}  (id {wid})")
    if dead:
        lines.append("\nDeprecated / broken / replaced? Record with: "
                     "n8n-dead.py --ack <id> '<note>'")
    report = "\n".join(lines)
    print(report)
    if len(sys.argv) >= 3 and sys.argv[1] == "--deliver":
        try:
            subprocess.run([f"{HOME}/tg-send.sh", sys.argv[2]], input=report,
                           text=True, timeout=30)
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
