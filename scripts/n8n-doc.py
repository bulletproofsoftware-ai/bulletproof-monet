#!/usr/bin/env python3
"""n8n-doc.py — workflow auto-documenter (PRD #32).

Reads a workflow's nodes/connections via the n8n API and asks Claude to produce
a human-readable description: purpose, trigger, inputs, outputs, external calls,
and failure modes. Writes docs/workflows/<slug>.md.

  n8n-doc.py <workflowId|name>     document one workflow
  n8n-doc.py --all                 document every workflow

Reads N8N_API_KEY from $MONET_HOME/.env. Uses `claude -p` (subscription).
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

HOME = monet_paths.MONET_HOME
ENV = f"{HOME}/.env"
BASE = os.environ.get("N8N_API_URL", "http://localhost:5679/api/v1")
OUT_DIR = os.environ.get("N8N_DOC_DIR", f"{HOME}/docs/workflows")
MODEL = os.environ.get("DOC_MODEL", "claude-haiku-4-5")
SUBPROC_PATH = os.pathsep.join([
    "/usr/local/bin",
    monet_paths.path(".local/bin"),
    monet_paths.path("bin"),
    "/usr/bin",
    "/bin",
])


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
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def slug(s):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", s.lower())).strip("-")[:60] or "workflow"


def node_summary(wf):
    """Compact, LLM-friendly view of nodes + key params + wiring."""
    out = []
    for n in wf.get("nodes", []):
        p = n.get("parameters", {})
        keys = {}
        for k in ("url", "method", "rule", "triggerTimes", "path", "httpMethod",
                  "functionCode", "jsCode", "command", "operation", "resource", "text"):
            if k in p and p[k]:
                v = json.dumps(p[k]) if not isinstance(p[k], str) else p[k]
                keys[k] = v[:240]
        out.append({"name": n.get("name"), "type": n.get("type"), "key_params": keys})
    return {"name": wf.get("name"), "active": wf.get("active"),
            "nodes": out, "connections": wf.get("connections", {})}


def document(wf, key):
    summary = node_summary(wf)
    prompt = (
        "Write concise developer documentation for this n8n workflow in Markdown. "
        "Sections: ## Purpose (1-2 sentences), ## Trigger, ## Inputs, ## Outputs, "
        "## External Calls (APIs/services/commands it hits), ## Failure Modes "
        "(what breaks it and how it shows up). Base everything ONLY on the node "
        "graph below; do not invent. Keep it tight.\n\nWORKFLOW JSON:\n"
        + json.dumps(summary)[:12000]
    )
    try:
        p = subprocess.run(
            ["claude", "-p", "--model", MODEL, "--max-turns", "1",
             "--dangerously-skip-permissions", "--disable-slash-commands",
             "--output-format", "json", prompt],
            capture_output=True, text=True, timeout=120, cwd=HOME,
            env={**os.environ, "HOME": HOME,
                 "PATH": SUBPROC_PATH + ":" + os.environ.get("PATH", "")},
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout).get("result", "").strip()
    except json.JSONDecodeError:
        return None


def write_doc(wf, body):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, slug(wf.get("name", wf["id"])) + ".md")
    header = (f"# {wf.get('name')}\n\n"
              f"_n8n workflow `{wf['id']}` · active={wf.get('active')} · "
              f"auto-documented by n8n-doc.py_\n\n")
    with open(path, "w") as fh:
        fh.write(header + body + "\n")
    return path


def main():
    key = api_key()
    if not key:
        print("n8n-doc: N8N_API_KEY not found")
        return
    if len(sys.argv) < 2:
        print("usage: n8n-doc.py <workflowId|name> | --all")
        return
    wfs = get("/workflows?limit=250", key).get("data", [])
    if sys.argv[1] == "--all":
        targets = wfs
    else:
        q = sys.argv[1].lower()
        targets = [w for w in wfs if w["id"] == sys.argv[1] or q in w.get("name", "").lower()]
    if not targets:
        print(f"no workflow matching '{sys.argv[1]}'")
        return
    for w in targets:
        full = get(f"/workflows/{w['id']}", key)
        body = document(full, key)
        if not body:
            print(f"  FAILED to document {w.get('name')}")
            continue
        path = write_doc(full, body)
        print(f"  documented {w.get('name')} -> {path}")


if __name__ == "__main__":
    main()
