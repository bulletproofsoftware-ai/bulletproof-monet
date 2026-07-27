#!/bin/bash
# test-dispatch.sh — an inline run that exceeds MONET_INLINE_TIMEOUT must be
# promoted to the async queue and acknowledged to the user.
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MONET_HOME="${MONET_HOME:-$REPO_ROOT}"
TEST_CHAT_ID="${TEST_CHAT_ID:-111111111}"
export MONET_QUEUE_DIR=$(mktemp -d)
SDIR=$(mktemp -d)
trap 'rm -rf "$MONET_QUEUE_DIR" "$SDIR"' EXIT

export MONET_INLINE_TIMEOUT=2
export MONET_ASYNC_DEFAULT=1

STUB="$SDIR/slow.sh"; cat > "$STUB" <<'S'
#!/bin/bash
sleep 5; echo '{"result":"late","session_id":"x"}'
S
chmod 755 "$STUB"

TGOUT="$SDIR/tg.out"; TGS="$SDIR/tgsend.sh"; cat > "$TGS" <<S
#!/bin/bash
cat >> "$TGOUT"
S
chmod 755 "$TGS"

MONET_CLAUDE_BIN="$STUB" MONET_TG_SEND="$TGS" \
    "$MONET_HOME/monet-dispatch.sh" "$TEST_CHAT_ID" "slow prompt" >/dev/null 2>&1
N=$(ls "$MONET_QUEUE_DIR" 2>/dev/null | grep -c '^q')
[ "$N" -ge 1 ] || { echo "FAIL: no job enqueued on inline timeout"; exit 1; }
grep -qi "working" "$TGOUT" || { echo "FAIL: no 'working' ack"; exit 1; }
echo "DISPATCH PROMOTE-ON-TIMEOUT PASSED"
