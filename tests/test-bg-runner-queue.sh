#!/bin/bash
# test-bg-runner-queue.sh — monet-bg-runner.sh must resolve a queued job's dir.
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MONET_HOME="${MONET_HOME:-$REPO_ROOT}"
TEST_CHAT_ID="${TEST_CHAT_ID:-111111111}"
export MONET_QUEUE_DIR=$(mktemp -d)
trap 'rm -rf "$MONET_QUEUE_DIR"' EXIT

QUEUE="$MONET_HOME/src/monet-queue"

JID=$("$QUEUE" enqueue "$TEST_CHAT_ID" "say PONG")
"$QUEUE" claim 1 >/dev/null
OUT=$(MONET_DRYRUN=1 "$MONET_HOME/monet-bg-runner.sh" "$JID" 2>&1)
echo "$OUT" | grep -q "resolved job dir" || { echo "FAIL: runner did not resolve queue job dir"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "$MONET_QUEUE_DIR/$JID" || { echo "FAIL: wrong dir resolved"; echo "$OUT"; exit 1; }
echo "BG-RUNNER QUEUE RESOLUTION PASSED"
