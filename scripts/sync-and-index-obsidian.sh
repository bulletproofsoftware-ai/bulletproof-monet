#!/bin/bash
# Sync Obsidian vault from Google Drive and reindex for RAG
# Run via cron: 0 3 * * * /root/sync-and-index-obsidian.sh >> /var/log/obsidian-index.log 2>&1

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
QDRANT_API_KEY=$(grep QDRANT_API_KEY /root/claude-memory/.env | cut -d= -f2)
export QDRANT_API_KEY
export PYTHONUNBUFFERED=1

echo "=== $(date) - Starting Obsidian sync ==="

# Merge outbox notes into vault before sync
OUTBOX="${MONET_HOME}/obsidian-outbox"
if [ -d "$OUTBOX" ] && [ "$(ls -A "$OUTBOX" 2>/dev/null)" ]; then
    echo "Merging outbox notes into vault..."
    cp -r "$OUTBOX/"* /root/obsidian-vault/ 2>/dev/null
    rm -rf "$OUTBOX/"*
    echo "Outbox merged."
fi

# Sync from Google Drive
rclone sync obsidian: /root/obsidian-vault/ \
    --exclude ".obsidian/**" \
    --exclude ".git/**" \
    --exclude ".claude/**" \
    --exclude ".trash/**" \
    --exclude "node_modules/**" \
    --quiet

echo "Sync complete. Starting indexer..."

# Run indexer
python3 /root/index-obsidian.py

echo "=== $(date) - Done ==="
