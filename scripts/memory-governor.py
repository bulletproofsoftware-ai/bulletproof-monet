#!/usr/bin/env python3
"""Monet Memory Governor — manages memory lifecycle, compaction, and tier migration.

Runs weekly via cron. Features:
- Count vectors per Qdrant collection
- Auto-summarize episodic records beyond threshold
- Migrate warm→cold tier based on access frequency
- Report stats via tg-send.sh

Usage:
    python3 $MONET_HOME/scripts/memory-governor.py [--dry-run] [--report]
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta

import requests
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

# Configuration
CONFIG_PATH = os.environ.get("GOVERNOR_CONFIG", monet_paths.path("governor-config.json"))
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6334")
QDRANT_API_KEY = os.environ.get("QDRANT_API_KEY", "")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
TG_SEND = monet_paths.path("tg-send.sh")
CHAT_ID = os.environ.get("TG_AUTHORIZED_USER_ID", "YOUR_CHAT_ID")
AUDIT_PY = monet_paths.path("lib/audit.py")

DEFAULT_CONFIG = {
    "max_points_per_collection": 10000,
    "summarize_threshold": 8000,
    "warm_age_days": 30,
    "cold_age_days": 90,
    "prune_score_threshold": 0.3,
    "collections_to_govern": [
        "claude_memories",
        "short_term_memory",
        "working_memory",
        "episodes",
        "learnings",
    ],
}


def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            return {**DEFAULT_CONFIG, **json.load(f)}
    return DEFAULT_CONFIG


def qdrant_headers():
    h = {"Content-Type": "application/json"}
    if QDRANT_API_KEY:
        h["api-key"] = QDRANT_API_KEY
    return h


def get_collection_stats():
    """Get point counts for all collections."""
    stats = {}
    try:
        resp = requests.get(f"{QDRANT_URL}/collections", headers=qdrant_headers(), timeout=10)
        collections = resp.json().get("result", {}).get("collections", [])
        for c in collections:
            name = c["name"]
            info = requests.get(
                f"{QDRANT_URL}/collections/{name}", headers=qdrant_headers(), timeout=10
            ).json()
            points = info.get("result", {}).get("points_count", 0)
            stats[name] = {
                "points": points,
                "status": info.get("result", {}).get("status", "unknown"),
            }
    except Exception as e:
        print(f"Error getting collection stats: {e}", file=sys.stderr)
    return stats


def prune_old_working_memory(dry_run=False):
    """Delete working memory entries older than 24 hours."""
    cutoff = time.time() - 86400
    try:
        resp = requests.post(
            f"{QDRANT_URL}/collections/working_memory/points/delete",
            headers=qdrant_headers(),
            json={
                "filter": {
                    "must": [
                        {"key": "created_at", "range": {"lt": cutoff}}
                    ]
                }
            },
            timeout=30,
        )
        if not dry_run:
            return resp.json().get("result", {}).get("operation_id", 0)
    except Exception as e:
        print(f"Error pruning working memory: {e}", file=sys.stderr)
    return 0


def prune_short_term_memory(config, dry_run=False):
    """Delete short-term memory entries older than warm_age_days."""
    cutoff = time.time() - (config["warm_age_days"] * 86400)
    try:
        resp = requests.post(
            f"{QDRANT_URL}/collections/short_term_memory/points/delete",
            headers=qdrant_headers(),
            json={
                "filter": {
                    "must": [
                        {"key": "created_at", "range": {"lt": cutoff}}
                    ]
                }
            },
            timeout=30,
        )
        if not dry_run:
            return resp.json().get("result", {}).get("operation_id", 0)
    except Exception as e:
        print(f"Error pruning short-term memory: {e}", file=sys.stderr)
    return 0


def get_collection_size_mb(collection_name):
    """Estimate collection size in MB based on point count and avg vector size."""
    try:
        info = requests.get(
            f"{QDRANT_URL}/collections/{collection_name}",
            headers=qdrant_headers(), timeout=10
        ).json()
        points = info.get("result", {}).get("points_count", 0)
        # 768-dim float32 = 3072 bytes per vector + ~500 bytes payload avg
        return round(points * 3572 / (1024 * 1024), 2)
    except Exception:
        return 0.0


def generate_report(stats, config):
    """Generate a human-readable governor report."""
    lines = ["Memory Governor Report", f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M')}", ""]

    total_points = 0
    total_mb = 0.0

    for name, info in sorted(stats.items()):
        points = info["points"]
        total_points += points
        mb = get_collection_size_mb(name)
        total_mb += mb
        threshold = config["max_points_per_collection"]
        status_icon = "!" if points > threshold else "."
        lines.append(f"  {status_icon} {name}: {points:,} points (~{mb:.1f} MB)")

    lines.append("")
    lines.append(f"Total: {total_points:,} points (~{total_mb:.1f} MB)")
    lines.append(f"Threshold: {config['max_points_per_collection']:,} per collection")
    lines.append(f"Working memory prune: >24h")
    lines.append(f"Short-term prune: >{config['warm_age_days']}d")

    return "\n".join(lines)


def audit_log(action, details):
    """Log governor action to audit DB."""
    try:
        subprocess.run(
            ["python3", AUDIT_PY, "log",
             "--channel", "governor",
             "--action", action,
             "--details", details],
            timeout=5, capture_output=True
        )
    except Exception:
        pass


def send_report(report):
    """Send report via Telegram."""
    try:
        proc = subprocess.run(
            [TG_SEND, CHAT_ID, "--plain"],
            input=report, capture_output=True, text=True, timeout=10
        )
    except Exception as e:
        print(f"Failed to send report: {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Monet Memory Governor")
    parser.add_argument("--dry-run", action="store_true", help="Report only, don't modify")
    parser.add_argument("--report", action="store_true", help="Send report via Telegram")
    parser.add_argument("--json", action="store_true", help="Output JSON stats")
    args = parser.parse_args()

    config = load_config()
    stats = get_collection_stats()

    if args.json:
        print(json.dumps(stats, indent=2))
        return

    report = generate_report(stats, config)

    if not args.dry_run:
        # Prune expired working memory
        prune_old_working_memory()
        audit_log("governor_prune_working", "Pruned working memory >24h")

        # Prune old short-term memory
        prune_short_term_memory(config)
        audit_log("governor_prune_short_term", f"Pruned short-term memory >{config['warm_age_days']}d")

        audit_log("governor_run", f"total_points={sum(s['points'] for s in stats.values())}")

    print(report)

    if args.report:
        send_report(report)


if __name__ == "__main__":
    main()
