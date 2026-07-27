#!/usr/bin/env python3
"""Monet Audit Trail — SQLite append-only audit logging and session persistence.

Usage from Python:
    from audit import AuditDB
    db = AuditDB()
    db.log_event(channel='tg', action='message_received', chat_id='123', details='hello')
    db.save_session(chat_id='123', session_id='abc', turns=5)

Usage from bash (via CLI):
    python3 $MONET_HOME/lib/audit.py log --channel tg --action message_received --chat_id 123
    python3 $MONET_HOME/lib/audit.py session-save --chat_id 123 --session_id abc --turns 5
    python3 $MONET_HOME/lib/audit.py session-load --chat_id 123
    python3 $MONET_HOME/lib/audit.py usage --days 7
    python3 $MONET_HOME/lib/audit.py usage --today
"""

import argparse
import json
import os
import sqlite3
import sys
import time
from contextlib import contextmanager
from pathlib import Path
import monet_paths

DB_PATH = os.environ.get("MONET_AUDIT_DB", os.path.join(monet_paths.DATA_DIR, "audit.db"))

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now')),
    epoch INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    user_id TEXT,
    channel TEXT NOT NULL,
    chat_id TEXT,
    sender TEXT,
    session_id TEXT,
    action TEXT NOT NULL,
    details TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    duration_ms INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_audit_channel ON audit_log(channel);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_session ON audit_log(session_id);
CREATE INDEX IF NOT EXISTS idx_audit_epoch ON audit_log(epoch);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL UNIQUE,
    channel TEXT NOT NULL DEFAULT 'tg',
    session_id TEXT NOT NULL,
    last_activity INTEGER NOT NULL,
    turn_count INTEGER DEFAULT 0,
    context_summary TEXT,
    last_user_message TEXT,
    last_response_preview TEXT,
    model TEXT,
    total_input_tokens INTEGER DEFAULT 0,
    total_output_tokens INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now'))
);

CREATE INDEX IF NOT EXISTS idx_sessions_chat ON sessions(chat_id);
CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity);

CREATE TABLE IF NOT EXISTS usage_daily (
    date TEXT NOT NULL,
    channel TEXT NOT NULL,
    invocations INTEGER DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    PRIMARY KEY (date, channel)
);
"""


class AuditDB:
    def __init__(self, db_path=None):
        self.db_path = db_path or DB_PATH
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _init_db(self):
        with self._conn() as conn:
            conn.executescript(SCHEMA_SQL)
            # Migrate: if old cost_daily table exists, copy data to usage_daily
            try:
                conn.execute("""INSERT OR IGNORE INTO usage_daily (date, channel, invocations, input_tokens, output_tokens)
                                SELECT date, channel, invocations, input_tokens, output_tokens FROM cost_daily""")
            except sqlite3.OperationalError:
                pass  # cost_daily doesn't exist, nothing to migrate

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def log_event(self, channel, action, user_id=None, chat_id=None,
                  sender=None, session_id=None, details=None,
                  input_tokens=0, output_tokens=0, duration_ms=0,
                  model=None):
        with self._conn() as conn:
            conn.execute(
                """INSERT INTO audit_log
                   (user_id, channel, chat_id, sender, session_id, action,
                    details, input_tokens, output_tokens, duration_ms, epoch)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (user_id, channel, chat_id, sender, session_id, action,
                 details, input_tokens, output_tokens, duration_ms,
                 int(time.time()))
            )

            # Update daily usage rollup
            if input_tokens > 0 or output_tokens > 0:
                today = time.strftime("%Y-%m-%d")
                conn.execute(
                    """INSERT INTO usage_daily (date, channel, invocations, input_tokens, output_tokens)
                       VALUES (?, ?, 1, ?, ?)
                       ON CONFLICT(date, channel) DO UPDATE SET
                           invocations = invocations + 1,
                           input_tokens = input_tokens + excluded.input_tokens,
                           output_tokens = output_tokens + excluded.output_tokens""",
                    (today, channel, input_tokens, output_tokens)
                )

    def save_session(self, chat_id, session_id, turns, channel="tg",
                     context_summary=None, last_user_message=None,
                     last_response_preview=None, model=None,
                     input_tokens=0, output_tokens=0):
        with self._conn() as conn:
            conn.execute(
                """INSERT INTO sessions
                   (chat_id, channel, session_id, last_activity, turn_count,
                    context_summary, last_user_message, last_response_preview,
                    model, total_input_tokens, total_output_tokens)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(chat_id) DO UPDATE SET
                       session_id = excluded.session_id,
                       last_activity = excluded.last_activity,
                       turn_count = excluded.turn_count,
                       context_summary = COALESCE(excluded.context_summary, sessions.context_summary),
                       last_user_message = COALESCE(excluded.last_user_message, sessions.last_user_message),
                       last_response_preview = COALESCE(excluded.last_response_preview, sessions.last_response_preview),
                       model = COALESCE(excluded.model, sessions.model),
                       total_input_tokens = sessions.total_input_tokens + excluded.total_input_tokens,
                       total_output_tokens = sessions.total_output_tokens + excluded.total_output_tokens,
                       updated_at = strftime('%Y-%m-%dT%H:%M:%S','now')""",
                (chat_id, channel, session_id, int(time.time()), turns,
                 context_summary, last_user_message, last_response_preview,
                 model, input_tokens, output_tokens)
            )

    def load_session(self, chat_id):
        with self._conn() as conn:
            row = conn.execute(
                "SELECT session_id, last_activity, turn_count, context_summary FROM sessions WHERE chat_id = ?",
                (chat_id,)
            ).fetchone()
            if row:
                return {
                    "session_id": row["session_id"],
                    "last_activity": row["last_activity"],
                    "turn_count": row["turn_count"],
                    "context_summary": row["context_summary"],
                }
        return None

    def get_usage_summary(self, days=7):
        with self._conn() as conn:
            rows = conn.execute(
                """SELECT date, SUM(invocations) as invocations,
                          SUM(input_tokens) as input_tokens,
                          SUM(output_tokens) as output_tokens
                   FROM usage_daily
                   WHERE date >= date('now', ?)
                   GROUP BY date ORDER BY date DESC""",
                (f"-{days} days",)
            ).fetchall()
            return [dict(r) for r in rows]

    def get_usage_today(self):
        with self._conn() as conn:
            row = conn.execute(
                """SELECT SUM(invocations) as invocations,
                          SUM(input_tokens) as input_tokens,
                          SUM(output_tokens) as output_tokens
                   FROM usage_daily WHERE date = date('now')"""
            ).fetchone()
            if row and row["invocations"]:
                return dict(row)
            return {"invocations": 0, "input_tokens": 0, "output_tokens": 0}

    def get_active_sessions(self, max_age_hours=24):
        cutoff = int(time.time()) - (max_age_hours * 3600)
        with self._conn() as conn:
            rows = conn.execute(
                """SELECT chat_id, channel, session_id, last_activity, turn_count,
                          model, total_input_tokens, total_output_tokens,
                          context_summary, last_user_message
                   FROM sessions WHERE last_activity > ? ORDER BY last_activity DESC""",
                (cutoff,)
            ).fetchall()
            return [dict(r) for r in rows]

    def get_audit_log(self, limit=50, channel=None, action=None, since_epoch=None):
        query = "SELECT * FROM audit_log WHERE 1=1"
        params = []
        if channel:
            query += " AND channel = ?"
            params.append(channel)
        if action:
            query += " AND action = ?"
            params.append(action)
        if since_epoch:
            query += " AND epoch >= ?"
            params.append(since_epoch)
        query += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._conn() as conn:
            rows = conn.execute(query, params).fetchall()
            return [dict(r) for r in rows]

    def cleanup_sessions(self, max_age_days=30):
        cutoff = int(time.time()) - (max_age_days * 86400)
        with self._conn() as conn:
            result = conn.execute("DELETE FROM sessions WHERE last_activity < ?", (cutoff,))
            return result.rowcount

    def get_stats(self):
        with self._conn() as conn:
            total_events = conn.execute("SELECT COUNT(*) as c FROM audit_log").fetchone()["c"]
            total_sessions = conn.execute("SELECT COUNT(*) as c FROM sessions").fetchone()["c"]
            today = self.get_usage_today()
            return {
                "total_audit_events": total_events,
                "total_sessions": total_sessions,
                "today": today,
            }


def format_usage_report(summary, today=None):
    lines = []
    if today:
        lines.append(f"Today: {today['invocations']} calls, "
                      f"{today['input_tokens']:,} in / {today['output_tokens']:,} out")
        lines.append("")

    if summary:
        lines.append("Last 7 days:")
        for row in summary:
            lines.append(f"  {row['date']}: {row['invocations']} calls, "
                          f"{row['input_tokens']:,} in / {row['output_tokens']:,} out")
    else:
        lines.append("No usage data found.")

    return "\n".join(lines)


def cli():
    parser = argparse.ArgumentParser(description="Monet Audit Trail CLI")
    sub = parser.add_subparsers(dest="cmd")

    # log event
    log_p = sub.add_parser("log")
    log_p.add_argument("--channel", required=True)
    log_p.add_argument("--action", required=True)
    log_p.add_argument("--user-id", default=None)
    log_p.add_argument("--chat-id", default=None)
    log_p.add_argument("--sender", default=None)
    log_p.add_argument("--session-id", default=None)
    log_p.add_argument("--details", default=None)
    log_p.add_argument("--input-tokens", type=int, default=0)
    log_p.add_argument("--output-tokens", type=int, default=0)
    log_p.add_argument("--duration-ms", type=int, default=0)
    log_p.add_argument("--model", default=None)

    # session save
    ss = sub.add_parser("session-save")
    ss.add_argument("--chat-id", required=True)
    ss.add_argument("--session-id", required=True)
    ss.add_argument("--turns", type=int, required=True)
    ss.add_argument("--channel", default="tg")
    ss.add_argument("--context-summary", default=None)
    ss.add_argument("--last-message", default=None)
    ss.add_argument("--last-response", default=None)
    ss.add_argument("--model", default=None)
    ss.add_argument("--input-tokens", type=int, default=0)
    ss.add_argument("--output-tokens", type=int, default=0)

    # session load
    sl = sub.add_parser("session-load")
    sl.add_argument("--chat-id", required=True)

    # usage
    usage_p = sub.add_parser("usage")
    usage_p.add_argument("--days", type=int, default=7)
    usage_p.add_argument("--today", action="store_true")
    usage_p.add_argument("--json", action="store_true", dest="as_json")

    # stats
    sub.add_parser("stats")

    # cleanup
    cl = sub.add_parser("cleanup")
    cl.add_argument("--max-age-days", type=int, default=30)

    # init (just create tables)
    sub.add_parser("init")

    args = parser.parse_args()
    db = AuditDB()

    if args.cmd == "log":
        db.log_event(
            channel=args.channel, action=args.action, user_id=args.user_id,
            chat_id=args.chat_id, sender=args.sender, session_id=args.session_id,
            details=args.details, input_tokens=args.input_tokens,
            output_tokens=args.output_tokens, duration_ms=args.duration_ms,
            model=args.model
        )

    elif args.cmd == "session-save":
        db.save_session(
            chat_id=args.chat_id, session_id=args.session_id,
            turns=args.turns, channel=args.channel,
            context_summary=args.context_summary,
            last_user_message=args.last_message,
            last_response_preview=args.last_response,
            model=args.model,
            input_tokens=args.input_tokens,
            output_tokens=args.output_tokens
        )
        print("ok")

    elif args.cmd == "session-load":
        session = db.load_session(args.chat_id)
        if session:
            print(json.dumps(session))
        else:
            print("{}")

    elif args.cmd == "usage":
        if args.as_json:
            today = db.get_usage_today()
            summary = db.get_usage_summary(args.days)
            print(json.dumps({"today": today, "history": summary}))
        else:
            today = db.get_usage_today() if args.today else None
            summary = db.get_usage_summary(args.days)
            print(format_usage_report(summary, today))

    elif args.cmd == "stats":
        print(json.dumps(db.get_stats(), indent=2))

    elif args.cmd == "cleanup":
        removed = db.cleanup_sessions(args.max_age_days)
        print(f"Removed {removed} stale sessions")

    elif args.cmd == "init":
        print(f"Database initialized at {db.db_path}")

    else:
        parser.print_help()


if __name__ == "__main__":
    cli()
