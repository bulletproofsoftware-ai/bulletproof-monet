#!/bin/bash
# Initialize the Monet audit database
# Run once on setup, idempotent (safe to re-run)
set -e

# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/monet-env.sh"
DB_DIR="${MONET_DATA_DIR:-${MONET_HOME}/data}"
DB_PATH="$DB_DIR/audit.db"

mkdir -p "$DB_DIR"

export MONET_AUDIT_DB="$DB_PATH"
python3 "$MONET_HOME"/lib/audit.py init

# Set permissions. The chown is conditional: it only makes sense when running as
# root AND a distinct service account owns the install. A non-root installer
# already owns these files, so chown would fail and abort under `set -e`.
chmod 600 "$DB_PATH"
MONET_USER="${MONET_USER:-$(id -un)}"
if [ "$(id -u)" -eq 0 ] && id -u "$MONET_USER" >/dev/null 2>&1; then
    chown "$MONET_USER":"$MONET_USER" "$DB_PATH" "$DB_DIR"
fi

echo "Audit database initialized at $DB_PATH"
