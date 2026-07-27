#!/bin/bash
# Ensure writable directories exist
mkdir -p /qdrant/snapshots/tmp /tmp/qdrant-temp 2>/dev/null || true
exec /qdrant/entrypoint.sh "$@"
