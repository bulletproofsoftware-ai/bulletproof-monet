#!/usr/bin/env python3
import os
"""Unified search across all Qdrant collections.

Searches clips, tg_sessions, claude_memories, obsidian_docs in parallel,
merges results by score, returns top 10.

Usage: python3 unified_search.py <chat_id> <query>
"""

import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

QDRANT_URL = "http://127.0.0.1:6334"
QDRANT_KEY = os.environ.get("QDRANT_API_KEY", "")
OLLAMA_URL = "http://127.0.0.1:11434"
EMBED_MODEL = "nomic-embed-text"

HEADERS = {
    "api-key": QDRANT_KEY,
    "Content-Type": "application/json",
}

COLLECTIONS = {
    "clips": {
        "label": "\U0001f4ce Clip",
        "content_field": "content",
        "secondary_field": "tag",
        "filter_by_chat": True,
    },
    "tg_sessions": {
        "label": "\U0001f4ac Chat",
        "content_field": "user_msg",
        "secondary_field": "assistant_msg",
        "filter_by_chat": True,
    },
    "claude_memories": {
        "label": "\U0001f9e0 Memory",
        "content_field": "content",
        "secondary_field": None,
        "filter_by_chat": False,
    },
    "obsidian_docs": {
        "label": "\U0001f4dd Note",
        "content_field": "text",
        "secondary_field": "file_path",
        "filter_by_chat": False,
    },
}


def get_embedding(text):
    """Generate embedding via Ollama."""
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


def collection_exists(name):
    """Check if a Qdrant collection exists."""
    try:
        r = requests.get(f"{QDRANT_URL}/collections/{name}", headers=HEADERS, timeout=3)
        return r.status_code == 200
    except Exception:
        return False


def search_collection(name, config, embedding, chat_id, limit=5):
    """Search a single collection. Returns normalized results."""
    if not collection_exists(name):
        return []

    search_body = {
        "vector": embedding,
        "limit": limit,
        "score_threshold": 0.3,
        "with_payload": True,
    }

    if config["filter_by_chat"] and chat_id:
        search_body["filter"] = {
            "must": [{"key": "chat_id", "match": {"value": str(chat_id)}}]
        }

    try:
        r = requests.post(
            f"{QDRANT_URL}/collections/{name}/points/search",
            headers=HEADERS,
            json=search_body,
            timeout=8,
        )
        r.raise_for_status()
        hits = r.json().get("result", [])
    except Exception:
        return []

    results = []
    for hit in hits:
        p = hit.get("payload", {})
        score = hit.get("score", 0)
        content = p.get(config["content_field"], "")
        secondary = p.get(config["secondary_field"], "") if config["secondary_field"] else ""
        ts = p.get("timestamp", 0)

        preview = content[:150]
        if len(content) > 150:
            preview += "..."
        # Prepend secondary info for context (but not full assistant responses)
        if secondary and config["secondary_field"] not in ("assistant_msg",):
            preview = f"[{secondary}] {preview}"

        results.append({
            "source": config["label"],
            "collection": name,
            "score": score,
            "preview": preview,
            "timestamp": ts,
        })

    return results


def unified_search(chat_id, query, limit=10):
    """Search across all collections in parallel, merge by score."""
    embedding = get_embedding(query)
    if not embedding:
        return "Failed to generate search embedding."

    all_results = []

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {}
        for name, config in COLLECTIONS.items():
            f = executor.submit(search_collection, name, config, embedding, chat_id, limit=5)
            futures[f] = name

        for future in as_completed(futures, timeout=12):
            try:
                results = future.result(timeout=8)
                all_results.extend(results)
            except Exception:
                pass

    if not all_results:
        return "No results found across any collection."

    # Sort by score descending, take top N
    all_results.sort(key=lambda x: x["score"], reverse=True)
    all_results = all_results[:limit]

    lines = [f"Search results for \"{query}\":"]
    for i, r in enumerate(all_results, 1):
        ts_str = ""
        if r["timestamp"]:
            ts_str = f" ({datetime.fromtimestamp(r['timestamp']).strftime('%m/%d')})"
        lines.append(f"{i}. {r['source']}{ts_str} [{r['score']:.2f}]")
        lines.append(f"   {r['preview']}")

    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: unified_search.py <chat_id> <query>", file=sys.stderr)
        sys.exit(1)

    chat_id = sys.argv[1]
    query = " ".join(sys.argv[2:])
    result = unified_search(chat_id, query)
    print(result)
