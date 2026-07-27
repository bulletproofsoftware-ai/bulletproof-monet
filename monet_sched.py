#!/usr/bin/env python3
"""monet_sched.py — Monet agent-managed scheduler.

Stores recurring/one-shot jobs in $MONET_HOME/cron-jobs.json. A job runs a
natural-language PROMPT through Claude on schedule and delivers the result to a
Telegram chat. Designed to be driven BY the agent: when the operator asks Monet to
"every weekday at 7am send me a threat brief", the agent calls:

    monet-schedule.sh add --chat <id> --schedule "weekdays 7am" \
        --prompt "<what to generate>" --name threat-brief

Schedule accepts either a raw 5-field cron expr ("0 7 * * 1-5") or friendly
specs: "daily 7am", "weekdays 7am", "every monday 9am", "hourly",
"every 30m", "once 2026-06-13T09:00". Cron is evaluated in --tz, which defaults
to $MONET_TZ, then $BRIEFING_TIMEZONE, then UTC -- never a baked-in region.
Matching is pure-python (no croniter dependency).

Subcommands: add | list | show | remove | enable | disable | due | mark-run
Output is JSON for machine subcommands (due, add) and human text for list/show.
"""
import argparse
import json
import os
import re
import secrets
import sys
import tempfile
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "lib"))
import monet_paths

JOBS_FILE = os.environ.get("MONET_JOBS_FILE", monet_paths.path("cron-jobs.json"))
# No region is hardcoded: UTC is the neutral fallback, and BRIEFING_TIMEZONE
# is reused so a deployer who set one timezone does not have to set two.
DEFAULT_TZ = os.environ.get("MONET_TZ") or os.environ.get("BRIEFING_TIMEZONE") or "UTC"
DEFAULT_CHAT = os.environ.get("MONET_DEFAULT_CHAT", "")
MAX_JOBS = 100


# --------------------------------------------------------------------------- #
# Storage (atomic, never partially-written)
# --------------------------------------------------------------------------- #
def load_jobs():
    try:
        with open(JOBS_FILE) as fh:
            data = json.load(fh)
            return data if isinstance(data, list) else []
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def save_jobs(jobs):
    d = os.path.dirname(JOBS_FILE) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".cron-jobs.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(jobs, fh, indent=2)
        os.replace(tmp, JOBS_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------- #
# Schedule parsing  (friendly spec -> cron expr, or one-shot timestamp)
# --------------------------------------------------------------------------- #
_DOW = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}


def _parse_time_of_day(text):
    m = re.match(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", text.strip(), re.I)
    if not m:
        return None
    hour = int(m.group(1))
    minute = int(m.group(2) or 0)
    ampm = (m.group(3) or "").lower()
    if ampm == "pm" and hour < 12:
        hour += 12
    elif ampm == "am" and hour == 12:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return hour, minute


def parse_schedule(spec, tz):
    """Return ('cron', expr) or ('once', epoch_ts). Raises ValueError on junk."""
    spec = spec.strip()
    low = spec.lower()

    # Raw 5-field cron
    if re.match(r"^[\d*/,\-]+(\s+[\d*/,\-]+){4}$", spec):
        return ("cron", spec)

    # once <iso>
    m = re.match(r"^once\s+(.+)$", low)
    if m:
        iso = m.group(1).strip()
        try:
            dt = datetime.fromisoformat(iso)
        except ValueError:
            raise ValueError(f"could not parse one-shot datetime: {iso!r}")
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo(tz))
        return ("once", int(dt.timestamp()))

    # hourly
    if low == "hourly":
        return ("cron", "0 * * * *")

    # every <n>m / <n>h
    m = re.match(r"^every\s+(\d+)\s*(m|min|minutes?|h|hours?)$", low)
    if m:
        n = int(m.group(1))
        unit = m.group(2)[0]
        if unit == "m":
            if not (1 <= n <= 59):
                raise ValueError("every <n>m requires 1-59")
            return ("cron", f"*/{n} * * * *")
        if not (1 <= n <= 23):
            raise ValueError("every <n>h requires 1-23")
        return ("cron", f"0 */{n} * * *")

    # daily <time>
    m = re.match(r"^(daily|every day)\s+(.+)$", low)
    if m:
        tod = _parse_time_of_day(m.group(2))
        if not tod:
            raise ValueError(f"bad time in {spec!r}")
        return ("cron", f"{tod[1]} {tod[0]} * * *")

    # weekdays <time>
    m = re.match(r"^weekdays?\s+(.+)$", low)
    if m:
        tod = _parse_time_of_day(m.group(1))
        if not tod:
            raise ValueError(f"bad time in {spec!r}")
        return ("cron", f"{tod[1]} {tod[0]} * * 1-5")

    # every <dow> <time>
    m = re.match(r"^(?:every\s+)?(sun|mon|tue|wed|thu|fri|sat)\w*\s+(.+)$", low)
    if m:
        dow = _DOW[m.group(1)[:3]]
        tod = _parse_time_of_day(m.group(2))
        if not tod:
            raise ValueError(f"bad time in {spec!r}")
        return ("cron", f"{tod[1]} {tod[0]} * * {dow}")

    raise ValueError(
        f"unrecognized schedule {spec!r}. Use a 5-field cron expr or: "
        "'daily 7am', 'weekdays 7am', 'every monday 9am', 'hourly', "
        "'every 30m', 'once 2026-06-13T09:00'"
    )


# --------------------------------------------------------------------------- #
# Pure-python cron matching
# --------------------------------------------------------------------------- #
def _expand_field(field, lo, hi):
    vals = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, step_s = part.split("/", 1)
            step = int(step_s)
        if part in ("*", ""):
            start, end = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            start, end = int(a), int(b)
        else:
            start = end = int(part)
        for v in range(start, end + 1, step):
            if lo <= v <= hi:
                vals.add(v)
    return vals


def cron_matches(expr, dt):
    """True if datetime dt (already in target tz) matches 5-field cron expr."""
    try:
        minute, hour, dom, mon, dow = expr.split()
    except ValueError:
        return False
    # cron dow: 0 and 7 are Sunday. Python weekday(): Mon=0..Sun=6 -> map.
    py_dow = (dt.weekday() + 1) % 7  # Sun=0..Sat=6
    dow_set = _expand_field(dow, 0, 7)
    if 7 in dow_set:
        dow_set.add(0)
    return (
        dt.minute in _expand_field(minute, 0, 59)
        and dt.hour in _expand_field(hour, 0, 23)
        and dt.day in _expand_field(dom, 1, 31)
        and dt.month in _expand_field(mon, 1, 12)
        and py_dow in dow_set
    )


def next_cron_run(expr, tz, after_ts=None):
    """Forward-scan minute-by-minute (up to ~366 days) for next match."""
    z = ZoneInfo(tz)
    start = datetime.fromtimestamp(after_ts or time.time(), z).replace(second=0, microsecond=0)
    start += timedelta(minutes=1)
    for i in range(366 * 24 * 60):
        cand = start + timedelta(minutes=i)
        if cron_matches(expr, cand):
            return int(cand.timestamp())
    return None


def job_next_run(job, after_ts=None):
    sch = job.get("schedule", {})
    if sch.get("type") == "once":
        return sch.get("run_at")
    if sch.get("type") == "cron":
        return next_cron_run(sch["expr"], job.get("tz", DEFAULT_TZ), after_ts)
    return None


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def _find(jobs, jid):
    for j in jobs:
        if j["id"] == jid:
            return j
    return None


def cmd_add(args):
    jobs = load_jobs()
    if len(jobs) >= MAX_JOBS:
        print(json.dumps({"error": f"job limit reached ({MAX_JOBS})"}))
        return 1
    chat = args.chat or DEFAULT_CHAT
    if not chat:
        print(json.dumps({"error": "missing --chat and no MONET_DEFAULT_CHAT"}))
        return 1
    tz = args.tz or DEFAULT_TZ
    try:
        ZoneInfo(tz)
    except Exception:
        print(json.dumps({"error": f"invalid tz {tz!r}"}))
        return 1
    try:
        kind, val = parse_schedule(args.schedule, tz)
    except ValueError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    now = int(time.time())
    jid = f"job-{now}-{secrets.token_hex(3)}"
    job = {
        "id": jid,
        "name": (args.name or "").strip() or jid,
        "chat_id": str(chat),
        "prompt": args.prompt,
        "schedule": ({"type": "cron", "expr": val} if kind == "cron"
                     else {"type": "once", "run_at": val}),
        "tz": tz,
        "skills": [s for s in (args.skills or "").split(",") if s.strip()],
        "enabled": True,
        "created_ts": now,
        "last_run": None,
        "last_status": None,
        "run_count": 0,
    }
    job["next_run"] = job_next_run(job, after_ts=now - 1)
    jobs.append(job)
    save_jobs(jobs)
    nr = (datetime.fromtimestamp(job["next_run"], ZoneInfo(tz)).strftime("%Y-%m-%d %H:%M %Z")
          if job["next_run"] else "n/a")
    print(json.dumps({"ok": True, "id": jid, "name": job["name"],
                      "schedule": job["schedule"], "tz": tz, "next_run": nr}))
    return 0


def cmd_list(args):
    jobs = load_jobs()
    if args.chat:
        jobs = [j for j in jobs if str(j.get("chat_id")) == str(args.chat)]
    if not jobs:
        print("No scheduled jobs.")
        return 0
    lines = ["Scheduled jobs:"]
    for j in jobs:
        sch = j.get("schedule", {})
        disp = sch.get("expr") if sch.get("type") == "cron" else (
            "once @ " + datetime.fromtimestamp(sch.get("run_at", 0),
                                               ZoneInfo(j.get("tz", DEFAULT_TZ))).strftime("%Y-%m-%d %H:%M"))
        nr = j.get("next_run")
        nr_s = (datetime.fromtimestamp(nr, ZoneInfo(j.get("tz", DEFAULT_TZ))).strftime("%m-%d %H:%M")
                if nr else "—")
        state = "" if j.get("enabled", True) else " [disabled]"
        lines.append(f"• {j['name']} ({j['id']}){state}\n    {disp} {j.get('tz','')} | next {nr_s} | runs {j.get('run_count',0)}\n    “{j['prompt'][:80]}”")
    print("\n".join(lines))
    return 0


def cmd_show(args):
    j = _find(load_jobs(), args.id)
    if not j:
        print(json.dumps({"error": "not found"}))
        return 1
    print(json.dumps(j, indent=2))
    return 0


def cmd_remove(args):
    jobs = load_jobs()
    new = [j for j in jobs if j["id"] != args.id and j.get("name") != args.id]
    if len(new) == len(jobs):
        print(json.dumps({"error": "not found"}))
        return 1
    save_jobs(new)
    print(json.dumps({"ok": True, "removed": args.id}))
    return 0


def _set_enabled(jid, state):
    jobs = load_jobs()
    j = _find(jobs, jid) or next((x for x in jobs if x.get("name") == jid), None)
    if not j:
        print(json.dumps({"error": "not found"}))
        return 1
    j["enabled"] = state
    if state:
        j["next_run"] = job_next_run(j, after_ts=int(time.time()) - 1)
    save_jobs(jobs)
    print(json.dumps({"ok": True, "id": j["id"], "enabled": state}))
    return 0


def cmd_enable(args):
    return _set_enabled(args.id, True)


def cmd_disable(args):
    return _set_enabled(args.id, False)


def cmd_due(args):
    """Emit chat_id\tjob_id\tprompt for each enabled job due now. Used by runner."""
    jobs = load_jobs()
    now = int(time.time())
    out = []
    for j in jobs:
        if not j.get("enabled", True):
            continue
        sch = j.get("schedule", {})
        due = False
        if sch.get("type") == "once":
            due = sch.get("run_at", 0) <= now and j.get("last_run") is None
        elif sch.get("type") == "cron":
            z = ZoneInfo(j.get("tz", DEFAULT_TZ))
            nowdt = datetime.fromtimestamp(now, z).replace(second=0, microsecond=0)
            # avoid double-fire within same minute
            already = j.get("last_run") and (now - j["last_run"] < 60)
            due = cron_matches(sch["expr"], nowdt) and not already
        if due:
            prompt = j["prompt"].replace("\t", " ").replace("\n", " ")
            out.append(f"{j['chat_id']}\t{j['id']}\t{prompt}")
    sys.stdout.write("\n".join(out))
    return 0


def cmd_mark_run(args):
    jobs = load_jobs()
    j = _find(jobs, args.id)
    if not j:
        return 1
    now = int(time.time())
    j["last_run"] = now
    j["last_status"] = args.status
    j["run_count"] = int(j.get("run_count", 0)) + 1
    sch = j.get("schedule", {})
    if sch.get("type") == "once":
        j["enabled"] = False  # one-shot: disable after firing
        j["next_run"] = None
    else:
        j["next_run"] = job_next_run(j, after_ts=now)
    save_jobs(jobs)
    return 0


def main():
    p = argparse.ArgumentParser(prog="monet-schedule")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add")
    a.add_argument("--chat")
    a.add_argument("--schedule", required=True)
    a.add_argument("--prompt", required=True)
    a.add_argument("--name")
    a.add_argument("--skills")
    a.add_argument("--tz")
    a.set_defaults(fn=cmd_add)

    l = sub.add_parser("list"); l.add_argument("--chat"); l.set_defaults(fn=cmd_list)
    s = sub.add_parser("show"); s.add_argument("id"); s.set_defaults(fn=cmd_show)
    r = sub.add_parser("remove"); r.add_argument("id"); r.set_defaults(fn=cmd_remove)
    e = sub.add_parser("enable"); e.add_argument("id"); e.set_defaults(fn=cmd_enable)
    d = sub.add_parser("disable"); d.add_argument("id"); d.set_defaults(fn=cmd_disable)
    du = sub.add_parser("due"); du.set_defaults(fn=cmd_due)
    m = sub.add_parser("mark-run"); m.add_argument("id"); m.add_argument("status"); m.set_defaults(fn=cmd_mark_run)

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
