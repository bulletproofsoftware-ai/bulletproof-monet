#!/usr/bin/env python3
"""budget-watch.py — cost threshold alerts for Twilio + API usage (PRD #42).

Checks current spend/usage against soft/hard thresholds and alerts Telegram when
a threshold is newly crossed (state file prevents repeat alerts within a period;
resets each month). Per Q5: Twilio + API usage only — hosts are prepaid, so no
server-spend tracking.

Sources:
  - Twilio: this-month total price via the Usage API (TWILIO_SID/TOKEN from .env)
  - API tokens: today's token total from monet_api /usage (port 8091)

Config:  $MONET_HOME/data/budget-config.json
State:   $MONET_HOME/data/budget-state.json
Cron:    daily (or hourly).
"""
import base64
import datetime
import json
import os
import urllib.request
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
ENV = f"{HOME}/.env"
CONFIG = os.environ.get("BUDGET_CONFIG", f"{HOME}/data/budget-config.json")
STATE = os.environ.get("BUDGET_STATE", f"{HOME}/data/budget-state.json")
API_PORT = os.environ.get("MONET_API_PORT", "8091")

DEFAULT_CONFIG = {
    "twilio": {"soft_usd": 15, "hard_usd": 30},
    "api_tokens_today": {"soft": 3000000, "hard": 6000000},
}
LEVELS = {"none": 0, "soft": 1, "hard": 2}


def load_env():
    env = {}
    try:
        with open(ENV) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export "):]
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    v = v.strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                        v = v[1:-1]
                    env[k.strip()] = v
    except OSError:
        pass
    return env


def load_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)


def twilio_month_usd(env):
    # Named auth_token, not tok: main() uses `tok` for a token COUNT and prints
    # it. Sharing the name across scopes made static analysis read the printed
    # count as the printed secret, and would let a careless refactor make that
    # true.
    sid, auth_token = env.get("TWILIO_SID"), env.get("TWILIO_TOKEN")
    if not sid or not auth_token:
        return None
    url = (f"https://api.twilio.com/2010-04-01/Accounts/{sid}"
           f"/Usage/Records/ThisMonth.json?Category=totalprice")
    auth = base64.b64encode(f"{sid}:{auth_token}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            recs = json.load(r).get("usage_records", [])
        return float(recs[0]["price"]) if recs else 0.0
    except Exception:  # noqa: BLE001
        return None


def _find_tokens(obj):
    """Best-effort: pull a token total from monet_api /usage 'today'."""
    if not isinstance(obj, dict):
        return None
    for k in ("total_tokens", "tokens", "total"):
        if isinstance(obj.get(k), (int, float)):
            return int(obj[k])
    inp = obj.get("input_tokens")
    out = obj.get("output_tokens")
    if isinstance(inp, (int, float)) or isinstance(out, (int, float)):
        return int(inp or 0) + int(out or 0)
    return None


def api_tokens_today(env):
    url = f"http://localhost:{API_PORT}/usage"
    headers = {}
    if env.get("MONET_API_KEY"):
        headers["Authorization"] = f"Bearer {env['MONET_API_KEY']}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.load(r)
        return _find_tokens(data.get("today", {}))
    except Exception:  # noqa: BLE001
        return None


def level_for(value, soft, hard):
    if value is None:
        return "none"
    if value >= hard:
        return "hard"
    if value >= soft:
        return "soft"
    return "none"


def alert_tg(text):
    chat = os.environ.get("MONET_DEFAULT_CHAT", "")
    if not chat:
        chat = os.environ.get("MONET_CHAT_ID", "")
    if not chat:
        return
    import subprocess
    try:
        subprocess.run([f"{HOME}/tg-send.sh", chat], input=text, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def main():
    env = load_env()
    cfg = load_json(CONFIG, None)
    if cfg is None:
        save_json(CONFIG, DEFAULT_CONFIG)
        cfg = DEFAULT_CONFIG
    period = datetime.datetime.utcnow().strftime("%Y-%m")
    state = load_json(STATE, {})
    if state.get("period") != period:
        state = {"period": period, "twilio": "none", "api": "none"}

    msgs = []

    usd = twilio_month_usd(env)
    if usd is not None:
        tw = cfg.get("twilio", DEFAULT_CONFIG["twilio"])
        lvl = level_for(usd, tw["soft_usd"], tw["hard_usd"])
        if LEVELS[lvl] > LEVELS.get(state.get("twilio", "none"), 0):
            tier = "HARD" if lvl == "hard" else "soft"
            thr = tw["hard_usd"] if lvl == "hard" else tw["soft_usd"]
            msgs.append(f"💸 Twilio spend ${usd:.2f} this month crossed the {tier} "
                        f"threshold (${thr}).")
        state["twilio"] = lvl if LEVELS[lvl] > LEVELS.get(state.get("twilio", "none"), 0) else state.get("twilio", "none")

    tok = api_tokens_today(env)
    if tok is not None:
        at = cfg.get("api_tokens_today", DEFAULT_CONFIG["api_tokens_today"])
        lvl = level_for(tok, at["soft"], at["hard"])
        if LEVELS[lvl] > LEVELS.get(state.get("api", "none"), 0):
            tier = "HARD" if lvl == "hard" else "soft"
            thr = at["hard"] if lvl == "hard" else at["soft"]
            msgs.append(f"💸 API tokens today {tok:,} crossed the {tier} "
                        f"threshold ({thr:,}).")
        state["api"] = lvl if LEVELS[lvl] > LEVELS.get(state.get("api", "none"), 0) else state.get("api", "none")

    save_json(STATE, state)

    summary = (f"budget-watch: twilio=${usd if usd is not None else '?'} "
               f"api_tokens_today={tok if tok is not None else '?'} "
               f"alerts={len(msgs)}")
    print(summary)
    if msgs:
        alert_tg("\n".join(msgs))


if __name__ == "__main__":
    main()
