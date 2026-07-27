#!/bin/bash
# tests/run-all.sh — run the whole suite. Exit 0 only if everything passed.
#
#   ./tests/run-all.sh            all tests
#   ./tests/run-all.sh --python   python only
#   ./tests/run-all.sh --shell    shell only
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MONET_HOME="${MONET_HOME:-$REPO_ROOT}"
export TEST_CHAT_ID="${TEST_CHAT_ID:-111111111}"

PY=1; SH=1
case "${1:-}" in --python) SH=0 ;; --shell) PY=0 ;; "") ;; *) echo "usage: $0 [--python|--shell]"; exit 1 ;; esac

rc=0
if [ "$PY" = 1 ]; then
    echo "==> python"
    # Prefer the venv install.sh creates, but only if pytest is actually
    # installed there. install.sh --check builds that venv from
    # requirements-webhook.txt (runtime deps only, no pytest), so preferring it
    # blindly makes the suite fail with "No module named pytest" on any host
    # where the installer has been run. Fall back to system python3.
    PYBIN="$REPO_ROOT/webhook-venv/bin/python"
    if [ ! -x "$PYBIN" ] || ! "$PYBIN" -c 'import pytest' >/dev/null 2>&1; then
        PYBIN=python3
    fi
    "$PYBIN" -m pytest "$REPO_ROOT/tests" -q || rc=1
fi
if [ "$SH" = 1 ]; then
    echo "==> shell"
    for t in "$REPO_ROOT"/tests/test-*.sh; do
        echo "--- $(basename "$t")"
        bash "$t" || { echo "FAILED: $t"; rc=1; }
    done
fi
exit $rc
