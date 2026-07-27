#!/bin/bash
# test-worker-drain.sh — the worker loop claims and drains a queued job.
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MONET_HOME="${MONET_HOME:-$REPO_ROOT}"
TEST_CHAT_ID="${TEST_CHAT_ID:-111111111}"
export MONET_QUEUE_DIR=$(mktemp -d)
STUB=$(mktemp)
trap 'rm -rf "$MONET_QUEUE_DIR" "$STUB"' EXIT

cat > "$STUB" <<'S'
#!/bin/bash
jd="${MONET_QUEUE_DIR}/$1"; echo completed > "$jd/status"; echo "stub-done" > "$jd/result"
S
chmod +x "$STUB"

JID=$("$MONET_HOME/src/monet-queue" enqueue "$TEST_CHAT_ID" "drain me")
MONET_BG_RUNNER="$STUB" MONET_WORKER_ONESHOT=1 "$MONET_HOME/src/monet-worker-loop.sh" 1
[ "$(cat "$MONET_QUEUE_DIR/$JID/status")" = "completed" ] || { echo "FAIL: job not drained"; exit 1; }
echo "WORKER DRAIN PASSED"
