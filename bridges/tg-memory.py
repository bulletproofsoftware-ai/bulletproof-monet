#!/usr/bin/env python3
import os
"""Telegram session memory: store/recall conversation turns via Qdrant + Ollama."""

import sys
import json
import time
import uuid
import requests

QDRANT_URL = "http://127.0.0.1:6334"
QDRANT_KEY = os.environ.get("QDRANT_API_KEY", "")
OWNER_NAME = os.environ.get("MONET_OWNER_NAME", "the operator")
OLLAMA_URL = "http://127.0.0.1:11434"
COLLECTION = "tg_sessions"
EMBED_MODEL = "nomic-embed-text"
TTL_DAYS = 30
RECALL_LIMIT = 5
RECENT_LIMIT = 5
SCORE_THRESHOLD = 0.3

HEADERS = {
    "api-key": QDRANT_KEY,
    "Content-Type": "application/json",
}


def get_embedding(text):
    """Generate embedding via Ollama. Returns list of floats or None."""
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/embeddings",
            json={"model": EMBED_MODEL, "prompt": text[:2000]},
            timeout=10,
        )
        r.raise_for_status()
        return r.json().get("embedding")
    except Exception:
        return None


def store(chat_id, user_msg, assistant_msg):
    """Store a conversation turn in Qdrant."""
    combined = f"User: {user_msg}\nAssistant: {assistant_msg}"
    embedding = get_embedding(combined)
    if not embedding:
        return

    point_id = str(uuid.uuid4())
    now = int(time.time())

    payload = {
        "chat_id": str(chat_id),
        "user_msg": user_msg[:1000],
        "assistant_msg": assistant_msg[:2000],
        "timestamp": now,
    }

    try:
        requests.put(
            f"{QDRANT_URL}/collections/{COLLECTION}/points",
            headers=HEADERS,
            json={"points": [{"id": point_id, "vector": embedding, "payload": payload}]},
            timeout=10,
        )
    except Exception:
        pass

    # Prune old points (>TTL_DAYS) for this chat_id
    cutoff = now - (TTL_DAYS * 86400)
    try:
        requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/delete",
            headers=HEADERS,
            json={
                "filter": {
                    "must": [
                        {"key": "chat_id", "match": {"value": str(chat_id)}},
                        {"key": "timestamp", "range": {"lt": cutoff}},
                    ]
                }
            },
            timeout=5,
        )
    except Exception:
        pass


def recall(chat_id, current_message):
    """Retrieve relevant past turns for context injection."""
    embedding = get_embedding(current_message)
    if not embedding:
        return ""

    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
            headers=HEADERS,
            json={
                "vector": embedding,
                "filter": {"must": [{"key": "chat_id", "match": {"value": str(chat_id)}}]},
                "limit": RECALL_LIMIT,
                "score_threshold": SCORE_THRESHOLD,
                "with_payload": True,
            },
            timeout=8,
        )
        r.raise_for_status()
        results = r.json().get("result", [])
    except Exception:
        return ""

    if not results:
        return ""

    # Sort by timestamp (oldest first) for natural flow
    results.sort(key=lambda x: x.get("payload", {}).get("timestamp", 0))

    lines = ["[Previous conversations for context]"]
    for hit in results:
        p = hit.get("payload", {})
        user = p.get("user_msg", "")
        asst = p.get("assistant_msg", "")
        lines.append("---")
        lines.append(f"{OWNER_NAME}: {user}")
        lines.append(f"You: {asst}")
    lines.append("---")
    lines.append("[End of previous context — respond to the current message below]\n")
    return "\n".join(lines)


def recent(chat_id, limit=RECENT_LIMIT):
    """Retrieve the last N exchanges chronologically. No embedding needed."""
    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/scroll",
            headers=HEADERS,
            json={
                "filter": {"must": [{"key": "chat_id", "match": {"value": str(chat_id)}}]},
                "limit": 50,  # over-fetch then sort/trim client-side
                "with_payload": True,
                "with_vector": False,
            },
            timeout=5,
        )
        r.raise_for_status()
        points = r.json().get("result", {}).get("points", [])
    except Exception:
        return ""

    if not points:
        return ""

    # Sort by timestamp descending, take last N, then reverse for chronological order
    points.sort(key=lambda p: p.get("payload", {}).get("timestamp", 0), reverse=True)
    points = points[:limit]
    points.reverse()

    lines = [f"[Your last few exchanges with {OWNER_NAME}]"]
    for pt in points:
        p = pt.get("payload", {})
        user = p.get("user_msg", "")
        asst = p.get("assistant_msg", "")
        # Truncate to keep context lean
        if len(asst) > 500:
            asst = asst[:500] + "..."
        if len(user) > 400:
            user = user[:400] + "..."
        # Label session summaries distinctly
        if user.startswith("session-summary"):
            lines.append(f"[Session summary] {asst}")
        else:
            lines.append(f"{OWNER_NAME}: {user}")
            lines.append(f"You: {asst}")
        lines.append("")
    lines.append("[End of recent history — continue the conversation naturally]\n")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "store" and len(sys.argv) >= 5:
        store(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "recall" and len(sys.argv) >= 4:
        result = recall(sys.argv[2], sys.argv[3])
        if result:
            print(result)
    elif cmd == "recent" and len(sys.argv) >= 3:
        limit = int(sys.argv[3]) if len(sys.argv) >= 4 else RECENT_LIMIT
        result = recent(sys.argv[2], limit)
        if result:
            print(result)
    else:
        sys.exit(1)
