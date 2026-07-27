#!/bin/bash
# Import memories from export file and re-embed with Ollama

set -e

# Load environment variables
source "$(dirname "$0")/../.env"

QDRANT_URL="http://localhost:6334"
OLLAMA_URL="http://localhost:11434"  # Host system Ollama
EXPORT_FILE="$(dirname "$0")/../memories_export.json"

echo "Importing memories from: $EXPORT_FILE"

# Wait for services
echo "Waiting for Ollama..."
until curl -s -f "$OLLAMA_URL/api/tags" > /dev/null 2>&1; do
    echo "Ollama not ready, waiting..."
    sleep 2
done

echo "Waiting for Qdrant..."
until curl -s "$QDRANT_URL/collections" -H "api-key: $QDRANT_API_KEY" 2>/dev/null | grep -q "collections"; do
    echo "Qdrant not ready, waiting..."
    sleep 2
done

echo "Services ready. Importing memories..."

# Read and process each memory
cat "$EXPORT_FILE" | jq -c '.memories[]' | while read -r memory; do
    content=$(echo "$memory" | jq -r '.payload.content')
    id=$(echo "$memory" | jq -r '.id')
    payload=$(echo "$memory" | jq '.payload')

    echo "Processing memory: $id"
    echo "  Content: ${content:0:50}..."

    # Generate embedding with Ollama
    embedding=$(curl -s "$OLLAMA_URL/api/embeddings" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"nomic-embed-text\", \"prompt\": \"$content\"}" | jq -c '.embedding')

    if [ "$embedding" = "null" ] || [ -z "$embedding" ]; then
        echo "  ERROR: Failed to generate embedding for $id"
        continue
    fi

    # Store in Qdrant with API key
    result=$(curl -s -X PUT "$QDRANT_URL/collections/claude_memories/points" \
        -H "Content-Type: application/json" \
        -H "api-key: $QDRANT_API_KEY" \
        -d "{
            \"points\": [{
                \"id\": \"$id\",
                \"vector\": $embedding,
                \"payload\": $payload
            }]
        }")

    status=$(echo "$result" | jq -r '.status')
    if [ "$status" = "ok" ]; then
        echo "  SUCCESS: Memory imported"
    else
        echo "  ERROR: $result"
    fi
done

echo ""
echo "Memory import complete!"

# Verify count
count=$(curl -s "$QDRANT_URL/collections/claude_memories" \
    -H "api-key: $QDRANT_API_KEY" | jq '.result.points_count')
echo "Total memories in collection: $count"
