#!/usr/bin/env python3
import os
"""Clip/Snippet store: CRUD operations for the Qdrant 'clips' collection.

Supports text snippets, bookmarks, photo extractions. Mirrors tg-memory.py patterns.
CLI: python3 clip_helper.py {init|store|search|list|delete} [args]
"""

import sys
import json
import time
import uuid
import requests
from datetime import datetime

QDRANT_URL = "http://127.0.0.1:6334"
QDRANT_KEY = os.environ.get("QDRANT_API_KEY", "")
OLLAMA_URL = "http://127.0.0.1:11434"
COLLECTION = "clips"
EMBED_MODEL = "nomic-embed-text"
VECTOR_DIM = 768

HEADERS = {
    "api-key": QDRANT_KEY,
    "Content-Type": "application/json",
}


def ensure_collection():
    """Idempotent creation of the clips collection."""
    try:
        r = requests.get(
            f"{QDRANT_URL}/collections/{COLLECTION}",
            headers=HEADERS,
            timeout=5,
        )
        if r.status_code == 200:
            print(f"Collection '{COLLECTION}' already exists.")
            return True
    except Exception:
        pass

    try:
        r = requests.put(
            f"{QDRANT_URL}/collections/{COLLECTION}",
            headers=HEADERS,
            json={"vectors": {"size": VECTOR_DIM, "distance": "Cosine"}},
            timeout=10,
        )
        r.raise_for_status()
        print(f"Collection '{COLLECTION}' created.")
        return True
    except Exception as e:
        print(f"Failed to create collection: {e}", file=sys.stderr)
        return False


def get_embedding(text):
    """Generate embedding via Ollama nomic-embed-text."""
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


def store_clip(chat_id, tag, content, source="clip", content_type="text", metadata=None):
    """Store a clip in Qdrant. Returns point ID or None."""
    embedding = get_embedding(content)
    if not embedding:
        print("Failed to generate embedding.", file=sys.stderr)
        return None

    point_id = str(uuid.uuid4())
    now = int(time.time())

    payload = {
        "chat_id": str(chat_id),
        "tag": tag,
        "content": content[:5000],
        "source": source,
        "content_type": content_type,
        "timestamp": now,
    }
    if metadata:
        payload["metadata"] = metadata

    try:
        r = requests.put(
            f"{QDRANT_URL}/collections/{COLLECTION}/points",
            headers=HEADERS,
            json={"points": [{"id": point_id, "vector": embedding, "payload": payload}]},
            timeout=10,
        )
        r.raise_for_status()
        return point_id
    except Exception as e:
        print(f"Failed to store clip: {e}", file=sys.stderr)
        return None


def search_clips(chat_id, query, limit=5, source_filter=None):
    """Vector search across clips. Returns list of hits."""
    embedding = get_embedding(query)
    if not embedding:
        return []

    must_conditions = [{"key": "chat_id", "match": {"value": str(chat_id)}}]
    if source_filter:
        must_conditions.append({"key": "source", "match": {"value": source_filter}})

    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
            headers=HEADERS,
            json={
                "vector": embedding,
                "filter": {"must": must_conditions},
                "limit": limit,
                "score_threshold": 0.3,
                "with_payload": True,
            },
            timeout=8,
        )
        r.raise_for_status()
        return r.json().get("result", [])
    except Exception:
        return []


def list_clips(chat_id, tag=None, source=None, limit=20):
    """List clips with optional tag/source filters."""
    must_conditions = [{"key": "chat_id", "match": {"value": str(chat_id)}}]
    if tag:
        must_conditions.append({"key": "tag", "match": {"value": tag}})
    if source:
        must_conditions.append({"key": "source", "match": {"value": source}})

    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/scroll",
            headers=HEADERS,
            json={
                "filter": {"must": must_conditions},
                "limit": limit,
                "with_payload": True,
                "with_vector": False,
            },
            timeout=8,
        )
        r.raise_for_status()
        return r.json().get("result", {}).get("points", [])
    except Exception:
        return []


def delete_clip(clip_id):
    """Delete a clip by point ID."""
    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{COLLECTION}/points/delete",
            headers=HEADERS,
            json={"points": [clip_id]},
            timeout=5,
        )
        r.raise_for_status()
        return True
    except Exception:
        return False


def format_clips(points):
    """Format clip points for display."""
    if not points:
        return "No clips found."

    points.sort(key=lambda p: p.get("payload", {}).get("timestamp", 0), reverse=True)

    lines = []
    for pt in points:
        p = pt.get("payload", {})
        tag = p.get("tag", "")
        content = p.get("content", "")
        source = p.get("source", "clip")
        ts = p.get("timestamp", 0)
        dt = datetime.fromtimestamp(ts).strftime("%m/%d %H:%M") if ts else "?"
        preview = content[:100] + "..." if len(content) > 100 else content
        icon = {"clip": "\U0001f4ce", "bookmark": "\U0001f516", "photo": "\U0001f4f7"}.get(source, "\U0001f4ce")
        lines.append(f"{icon} [{tag}] {preview} ({dt})")

    return "\n".join(lines)


def format_search_results(results):
    """Format search results for display."""
    if not results:
        return "No results found."

    lines = []
    for hit in results:
        p = hit.get("payload", {})
        score = hit.get("score", 0)
        tag = p.get("tag", "")
        content = p.get("content", "")
        source = p.get("source", "clip")
        ts = p.get("timestamp", 0)
        dt = datetime.fromtimestamp(ts).strftime("%m/%d %H:%M") if ts else "?"
        preview = content[:120] + "..." if len(content) > 120 else content
        icon = {"clip": "\U0001f4ce", "bookmark": "\U0001f516", "photo": "\U0001f4f7"}.get(source, "\U0001f4ce")
        lines.append(f"{icon} [{tag}] (score: {score:.2f}) {preview} ({dt})")

    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: clip_helper.py {init|store|search|list|delete} [args]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "init":
        ensure_collection()

    elif cmd == "store":
        if len(sys.argv) < 5:
            print("Usage: clip_helper.py store <chat_id> <tag> <content> [source] [content_type]", file=sys.stderr)
            sys.exit(1)
        chat_id = sys.argv[2]
        tag = sys.argv[3]
        content = sys.argv[4]
        source = sys.argv[5] if len(sys.argv) > 5 else "clip"
        content_type = sys.argv[6] if len(sys.argv) > 6 else "text"
        pid = store_clip(chat_id, tag, content, source, content_type)
        if pid:
            print(f"Clip saved: {tag}")
        else:
            print("Failed to save clip.")
            sys.exit(1)

    elif cmd == "search":
        if len(sys.argv) < 4:
            print("Usage: clip_helper.py search <chat_id> <query> [--source <src>] [--limit <n>]", file=sys.stderr)
            sys.exit(1)
        chat_id = sys.argv[2]
        query = sys.argv[3]
        source_filter = None
        limit = 5
        i = 4
        while i < len(sys.argv):
            if sys.argv[i] == "--source" and i + 1 < len(sys.argv):
                source_filter = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--limit" and i + 1 < len(sys.argv):
                limit = int(sys.argv[i + 1])
                i += 2
            else:
                i += 1
        results = search_clips(chat_id, query, limit, source_filter)
        print(format_search_results(results))

    elif cmd == "list":
        if len(sys.argv) < 3:
            print("Usage: clip_helper.py list <chat_id> [--tag <tag>] [--source <src>] [--limit <n>]", file=sys.stderr)
            sys.exit(1)
        chat_id = sys.argv[2]
        tag = None
        source = None
        limit = 20
        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--tag" and i + 1 < len(sys.argv):
                tag = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--source" and i + 1 < len(sys.argv):
                source = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--limit" and i + 1 < len(sys.argv):
                limit = int(sys.argv[i + 1])
                i += 2
            else:
                i += 1
        points = list_clips(chat_id, tag, source, limit)
        print(format_clips(points))

    elif cmd == "delete":
        if len(sys.argv) < 3:
            print("Usage: clip_helper.py delete <clip_id>", file=sys.stderr)
            sys.exit(1)
        clip_id = sys.argv[2]
        if delete_clip(clip_id):
            print(f"Clip {clip_id} deleted.")
        else:
            print(f"Failed to delete clip {clip_id}.")
            sys.exit(1)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
