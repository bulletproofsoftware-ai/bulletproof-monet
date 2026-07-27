#!/bin/bash
# Backup Qdrant snapshots and n8n workflows/credentials
# Run via cron: 0 4 * * * /root/backup-services.sh >> /var/log/backup-services.log 2>&1

BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d)
RETAIN_DAYS=7

QDRANT_URL="http://localhost:6334"
QDRANT_API_KEY=$(grep QDRANT_API_KEY /root/claude-memory/.env | cut -d= -f2)

echo "=== $(date) - Starting backup ==="

mkdir -p "$BACKUP_DIR/qdrant" "$BACKUP_DIR/n8n"

# --- Qdrant snapshots ---
echo "Backing up Qdrant collections..."
for COLLECTION in $(curl -sf -H "api-key: $QDRANT_API_KEY" "$QDRANT_URL/collections" | python3 -c "import sys,json; [print(c['name']) for c in json.load(sys.stdin).get('result',{}).get('collections',[])]" 2>/dev/null); do
    echo "  Snapshot: $COLLECTION"
    SNAP=$(curl -sf -X POST \
        -H "api-key: $QDRANT_API_KEY" \
        "$QDRANT_URL/collections/$COLLECTION/snapshots" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('name',''))" 2>/dev/null)
    if [ -n "$SNAP" ]; then
        curl -sf \
            -H "api-key: $QDRANT_API_KEY" \
            "$QDRANT_URL/collections/$COLLECTION/snapshots/$SNAP" \
            -o "$BACKUP_DIR/qdrant/${COLLECTION}-${DATE}.snapshot"
        SIZE=$(stat -c%s "$BACKUP_DIR/qdrant/${COLLECTION}-${DATE}.snapshot" 2>/dev/null || echo 0)
        echo "    Saved: ${COLLECTION}-${DATE}.snapshot ($(( SIZE / 1024 / 1024 ))MB)"
        # Clean up snapshot from Qdrant
        curl -sf -X DELETE \
            -H "api-key: $QDRANT_API_KEY" \
            "$QDRANT_URL/collections/$COLLECTION/snapshots/$SNAP" >/dev/null 2>&1
    else
        echo "    ERROR: snapshot failed for $COLLECTION"
    fi
done

# --- n8n workflows ---
echo "Backing up n8n workflows..."
docker exec claude_backend_n8n n8n export:workflow --all --output=/tmp/workflows-backup.json 2>/dev/null
docker cp claude_backend_n8n:/tmp/workflows-backup.json "$BACKUP_DIR/n8n/workflows-${DATE}.json" 2>/dev/null
if [ -f "$BACKUP_DIR/n8n/workflows-${DATE}.json" ]; then
    SIZE=$(stat -c%s "$BACKUP_DIR/n8n/workflows-${DATE}.json" 2>/dev/null || echo 0)
    echo "  Saved: workflows-${DATE}.json (${SIZE} bytes)"
else
    echo "  ERROR: workflow export failed"
fi

# --- n8n credentials (encrypted) ---
echo "Backing up n8n credentials..."
docker exec claude_backend_n8n n8n export:credentials --all --output=/tmp/credentials-backup.json 2>/dev/null
docker cp claude_backend_n8n:/tmp/credentials-backup.json "$BACKUP_DIR/n8n/credentials-${DATE}.json" 2>/dev/null
if [ -f "$BACKUP_DIR/n8n/credentials-${DATE}.json" ]; then
    SIZE=$(stat -c%s "$BACKUP_DIR/n8n/credentials-${DATE}.json" 2>/dev/null || echo 0)
    echo "  Saved: credentials-${DATE}.json (${SIZE} bytes)"
    chmod 600 "$BACKUP_DIR/n8n/credentials-${DATE}.json"
else
    echo "  ERROR: credential export failed"
fi

# --- Cleanup old backups ---
echo "Cleaning up backups older than ${RETAIN_DAYS} days..."
find "$BACKUP_DIR" -type f -mtime +${RETAIN_DAYS} -delete 2>/dev/null
REMAINING=$(find "$BACKUP_DIR" -type f | wc -l)
echo "  Remaining backup files: $REMAINING"

echo "=== $(date) - Backup complete ==="
