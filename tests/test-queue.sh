#!/bin/bash
# test-queue.sh — enqueue/position/claim semantics of src/monet-queue.
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MONET_HOME="${MONET_HOME:-$REPO_ROOT}"
TEST_CHAT_ID="${TEST_CHAT_ID:-111111111}"
export MONET_QUEUE_DIR=$(mktemp -d)
trap 'rm -rf "$MONET_QUEUE_DIR"' EXIT

Q="$MONET_HOME/src/monet-queue"
fail(){ echo "FAIL: $1"; exit 1; }

J1=$("$Q" enqueue "$TEST_CHAT_ID" "first prompt")
[ -d "$MONET_QUEUE_DIR/$J1" ] || fail "job dir not created"
[ "$(cat "$MONET_QUEUE_DIR/$J1/chat_id")" = "$TEST_CHAT_ID" ] || fail "chat_id wrong"
[ "$(cat "$MONET_QUEUE_DIR/$J1/prompt")" = "first prompt" ] || fail "prompt wrong"
[ "$(cat "$MONET_QUEUE_DIR/$J1/status")" = "queued" ] || fail "status not queued"

sleep 1
J2=$("$Q" enqueue "$TEST_CHAT_ID" "second prompt")
[ "$("$Q" position "$J1")" = "1" ] || fail "J1 position != 1"
[ "$("$Q" position "$J2")" = "2" ] || fail "J2 position != 2"

C1=$("$Q" claim 1)
[ "$C1" = "$J1" ] || fail "claim did not return oldest (got $C1 want $J1)"
[ "$(cat "$MONET_QUEUE_DIR/$J1/status")" = "claimed" ] || fail "claimed status not set"

# concurrent claim safety: two claims must never return the same id
CA=$("$Q" claim 4); CB=$("$Q" claim 5)
[ "$CA" != "$CB" ] || [ -z "$CA" ] || fail "double-claim of same job"

echo "ALL QUEUE TESTS PASSED"
