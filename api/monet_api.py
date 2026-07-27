#!/usr/bin/env python3
"""Monet REST Management API — lightweight read-only API for dashboard and monitoring.

Endpoints:
    GET /health          - Service health and uptime
    GET /sessions        - Active sessions from SQLite
    GET /audit           - Filterable audit log
    GET /usage           - Token usage summary (7-day history + today)
    GET /usage/today     - Today's usage breakdown
    GET /memory/stats    - Qdrant collection stats
    GET /cron            - Cron job status (last runs from audit)

Authentication: Bearer token from MONET_API_KEY env var

Usage:
    MONET_API_KEY=xxx python3 $MONET_HOME/api/monet_api.py
    # Runs on localhost:8091
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime
from functools import wraps
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

# Add lib to path
sys.path.insert(0, monet_paths.path("lib"))
from audit import AuditDB

API_KEY = os.environ.get("MONET_API_KEY", "")
PORT = int(os.environ.get("MONET_API_PORT", "8091"))
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6334")
QDRANT_API_KEY = os.environ.get("QDRANT_API_KEY", "")
START_TIME = time.time()

db = AuditDB()


def get_qdrant_stats():
    """Get Qdrant collection statistics."""
    try:
        import requests
        headers = {"Content-Type": "application/json"}
        if QDRANT_API_KEY:
            headers["api-key"] = QDRANT_API_KEY
        resp = requests.get(f"{QDRANT_URL}/collections", headers=headers, timeout=5)
        collections = resp.json().get("result", {}).get("collections", [])
        stats = {}
        for c in collections:
            name = c["name"]
            info = requests.get(
                f"{QDRANT_URL}/collections/{name}", headers=headers, timeout=5
            ).json()
            result = info.get("result", {})
            stats[name] = {
                "points": result.get("points_count", 0),
                "status": result.get("status", "unknown"),
            }
        return stats
    except Exception as e:
        return {"error": str(e)}


def get_service_health():
    """Check if key services are running."""
    services = {}
    checks = {
        "qdrant": f"{QDRANT_URL}/collections",
        "ollama": "http://localhost:11434/api/tags",
        "n8n": "http://localhost:5679/healthz",
    }
    for name, url in checks.items():
        try:
            import requests
            resp = requests.get(url, timeout=3)
            services[name] = {"status": "up", "code": resp.status_code}
        except Exception:
            services[name] = {"status": "down"}
    return services


class MonetAPIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data, default=str).encode())

    def check_auth(self):
        if not API_KEY:
            return True  # No key configured = dev mode
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[7:] == API_KEY
        return False

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        if not self.check_auth():
            self.send_json({"error": "Unauthorized"}, 401)
            return

        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        try:
            if path == "/health":
                self.handle_health()
            elif path == "/sessions":
                self.handle_sessions(params)
            elif path == "/audit":
                self.handle_audit(params)
            elif path == "/usage":
                self.handle_usage(params)
            elif path == "/usage/today":
                self.handle_usage_today()
            elif path == "/memory/stats":
                self.handle_memory_stats()
            elif path == "/cron":
                self.handle_cron()
            elif path == "/stats":
                self.handle_stats()
            else:
                self.send_json({"error": "Not found"}, 404)  # VAPT: removed endpoint enumeration
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

    def handle_health(self):
        uptime = int(time.time() - START_TIME)
        services = get_service_health()
        self.send_json({
            "status": "ok",
            "uptime_seconds": uptime,
            "uptime_human": f"{uptime // 3600}h {(uptime % 3600) // 60}m",
            "services": services,
            "timestamp": datetime.now().isoformat(),
        })

    def handle_sessions(self, params):
        hours = int(params.get("hours", [24])[0])
        sessions = db.get_active_sessions(max_age_hours=hours)
        self.send_json({"sessions": sessions, "count": len(sessions)})

    def handle_audit(self, params):
        limit = int(params.get("limit", [50])[0])
        channel = params.get("channel", [None])[0]
        action = params.get("action", [None])[0]
        since = params.get("since", [None])[0]
        since_epoch = int(since) if since else None

        events = db.get_audit_log(limit=limit, channel=channel, action=action,
                                   since_epoch=since_epoch)
        self.send_json({"events": events, "count": len(events)})

    def handle_usage(self, params):
        days = int(params.get("days", [7])[0])
        summary = db.get_usage_summary(days=days)
        today = db.get_usage_today()
        self.send_json({"today": today, "history": summary})

    def handle_usage_today(self):
        today = db.get_usage_today()
        self.send_json(today)

    def handle_memory_stats(self):
        stats = get_qdrant_stats()
        total = sum(v.get("points", 0) for v in stats.values() if isinstance(v, dict) and "points" in v)
        self.send_json({"collections": stats, "total_points": total})

    def handle_cron(self):
        # Get recent cron events from audit log
        events = db.get_audit_log(limit=20, channel="cron")
        self.send_json({"cron_events": events, "count": len(events)})

    def handle_stats(self):
        stats = db.get_stats()
        stats["api_uptime"] = int(time.time() - START_TIME)
        self.send_json(stats)


def main():
    server = HTTPServer(("127.0.0.1", PORT), MonetAPIHandler)
    print(f"Monet API running on http://127.0.0.1:{PORT}")
    print(f"Auth: {'Bearer token required' if API_KEY else 'DISABLED (dev mode)'}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
