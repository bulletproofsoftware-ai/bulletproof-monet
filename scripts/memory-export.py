#!/usr/bin/env python3
"""Monet Memory Export/Import — structured backup and restore for Qdrant collections.

Export: Dumps all Qdrant collections to JSON files.
Import: Restores from JSON backup.

Usage:
    python3 $MONET_HOME/scripts/memory-export.py export [--output-dir /path]
    python3 $MONET_HOME/scripts/memory-export.py import --input-dir /path [--collection name]
    python3 $MONET_HOME/scripts/memory-export.py list
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6334")
QDRANT_API_KEY = os.environ.get("QDRANT_API_KEY", "")
DEFAULT_EXPORT_DIR = os.path.join(monet_paths.DATA_DIR, "memory-exports")
BATCH_SIZE = 100


def qdrant_headers():
    h = {"Content-Type": "application/json"}
    if QDRANT_API_KEY:
        h["api-key"] = QDRANT_API_KEY
    return h


def list_collections():
    resp = requests.get(f"{QDRANT_URL}/collections", headers=qdrant_headers(), timeout=10)
    return [c["name"] for c in resp.json().get("result", {}).get("collections", [])]


def get_collection_info(name):
    resp = requests.get(f"{QDRANT_URL}/collections/{name}", headers=qdrant_headers(), timeout=10)
    result = resp.json().get("result", {})
    return {
        "name": name,
        "points_count": result.get("points_count", 0),
        "status": result.get("status", "unknown"),
    }


def scroll_all_points(collection, batch_size=BATCH_SIZE):
    """Scroll through all points in a collection."""
    all_points = []
    offset = None

    while True:
        body = {"limit": batch_size, "with_payload": True, "with_vector": True}
        if offset is not None:
            body["offset"] = offset

        resp = requests.post(
            f"{QDRANT_URL}/collections/{collection}/points/scroll",
            headers=qdrant_headers(),
            json=body,
            timeout=60,
        )
        data = resp.json().get("result", {})
        points = data.get("points", [])
        next_offset = data.get("next_page_offset")

        all_points.extend(points)

        if not points or next_offset is None:
            break
        offset = next_offset

    return all_points


def export_collection(collection, output_dir):
    """Export a single collection to JSON."""
    points = scroll_all_points(collection)
    info = get_collection_info(collection)

    export_data = {
        "collection": collection,
        "exported_at": datetime.now().isoformat(),
        "points_count": len(points),
        "collection_info": info,
        "points": points,
    }

    path = Path(output_dir) / f"{collection}.json"
    with open(path, "w") as f:
        json.dump(export_data, f, default=str)

    return len(points), str(path)


def import_collection(collection, input_path):
    """Import points into a collection from JSON."""
    with open(input_path) as f:
        data = json.load(f)

    points = data.get("points", [])
    if not points:
        return 0

    # Check if collection exists
    try:
        requests.get(
            f"{QDRANT_URL}/collections/{collection}",
            headers=qdrant_headers(), timeout=10
        ).raise_for_status()
    except Exception:
        print(f"Collection '{collection}' does not exist. Skipping.", file=sys.stderr)
        return 0

    # Upsert in batches
    imported = 0
    for i in range(0, len(points), BATCH_SIZE):
        batch = points[i : i + BATCH_SIZE]
        formatted = []
        for p in batch:
            point = {"id": p["id"], "payload": p.get("payload", {})}
            if "vector" in p:
                point["vector"] = p["vector"]
            formatted.append(point)

        resp = requests.put(
            f"{QDRANT_URL}/collections/{collection}/points",
            headers=qdrant_headers(),
            json={"points": formatted},
            timeout=60,
        )
        if resp.status_code == 200:
            imported += len(batch)

    return imported


def cmd_export(args):
    output_dir = args.output_dir or f"{DEFAULT_EXPORT_DIR}/{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    Path(output_dir).mkdir(parents=True, exist_ok=True)

    collections = list_collections()
    if args.collection:
        collections = [c for c in collections if c == args.collection]

    results = []
    for c in collections:
        count, path = export_collection(c, output_dir)
        results.append(f"  {c}: {count:,} points → {path}")

    # Write manifest
    manifest = {
        "exported_at": datetime.now().isoformat(),
        "collections": collections,
        "output_dir": output_dir,
    }
    with open(f"{output_dir}/manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Export complete to {output_dir}")
    for r in results:
        print(r)


def cmd_import(args):
    input_dir = args.input_dir
    if not os.path.isdir(input_dir):
        print(f"Input directory not found: {input_dir}", file=sys.stderr)
        sys.exit(1)

    json_files = list(Path(input_dir).glob("*.json"))
    json_files = [f for f in json_files if f.name != "manifest.json"]

    if args.collection:
        json_files = [f for f in json_files if f.stem == args.collection]

    for jf in json_files:
        collection = jf.stem
        count = import_collection(collection, str(jf))
        print(f"  {collection}: imported {count:,} points from {jf}")


def cmd_list(args):
    collections = list_collections()
    total = 0
    for c in collections:
        info = get_collection_info(c)
        pts = info["points_count"]
        total += pts
        print(f"  {c}: {pts:,} points ({info['status']})")
    print(f"\nTotal: {total:,} points across {len(collections)} collections")


def main():
    parser = argparse.ArgumentParser(description="Monet Memory Export/Import")
    sub = parser.add_subparsers(dest="cmd")

    exp = sub.add_parser("export")
    exp.add_argument("--output-dir", default=None)
    exp.add_argument("--collection", default=None)

    imp = sub.add_parser("import")
    imp.add_argument("--input-dir", required=True)
    imp.add_argument("--collection", default=None)

    sub.add_parser("list")

    args = parser.parse_args()

    if args.cmd == "export":
        cmd_export(args)
    elif args.cmd == "import":
        cmd_import(args)
    elif args.cmd == "list":
        cmd_list(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
