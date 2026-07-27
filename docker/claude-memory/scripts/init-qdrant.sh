#!/bin/bash
# Initialize Qdrant collection for Claude memories

set -e

# Load environment variables
source "$(dirname "$0")/../.env"

QDRANT_URL="http://localhost:6334"

echo "Waiting for Qdrant to be ready..."
until curl -s "$QDRANT_URL/collections" -H "api-key: $QDRANT_API_KEY" 2>/dev/null | grep -q "collections"; do
    echo "Qdrant not ready, waiting..."
    sleep 2
done

echo "Qdrant is ready. Creating collection..."

# Create the claude_memories collection with API key
curl -s -X PUT "$QDRANT_URL/collections/claude_memories" \
  -H "Content-Type: application/json" \
  -H "api-key: $QDRANT_API_KEY" \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    }
  }'

echo ""
echo "Collection created successfully!"

# Verify collection
echo "Verifying collection..."
curl -s "$QDRANT_URL/collections/claude_memories" \
  -H "api-key: $QDRANT_API_KEY" | jq .

echo ""
echo "Qdrant initialization complete!"
