#!/bin/bash
# lib/monet-env.sh — resolve the Monet install root and load configuration.
# Source this from every entrypoint:  . "$(dirname "$(readlink -f "$0")")/lib/monet-env.sh"
#
# Resolution order for MONET_HOME:
#   1. an already-exported MONET_HOME (operator override)
#   2. the directory this file's parent lives in (i.e. the checkout that is running)
#   3. /opt/monet (historical default)
# The self-locating step 2 is what makes a clean clone work with zero configuration.

if [ -z "${MONET_HOME:-}" ]; then
    _monet_env_self="${BASH_SOURCE[0]}"
    # Resolve symlinks so bridges/ copies and /usr/local/bin symlinks resolve correctly.
    while [ -L "$_monet_env_self" ]; do
        _monet_env_link=$(readlink "$_monet_env_self")
        case "$_monet_env_link" in
            /*) _monet_env_self="$_monet_env_link" ;;
            *)  _monet_env_self="$(dirname "$_monet_env_self")/$_monet_env_link" ;;
        esac
    done
    _monet_env_lib=$(cd "$(dirname "$_monet_env_self")" && pwd)
    MONET_HOME=$(cd "$_monet_env_lib/.." && pwd) || MONET_HOME=/opt/monet
    unset _monet_env_self _monet_env_link _monet_env_lib
fi
export MONET_HOME

# Load .env if present. `set -a` exports everything defined in it.
if [ -f "$MONET_HOME/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$MONET_HOME/.env"
    set +a
fi

# Claude Code derives its projects/<slug> directory from $HOME and cwd. Pin both so
# --resume finds the transcript it wrote. Do NOT set HOME to MONET_HOME unconditionally:
# MONET_CLAUDE_HOME lets an operator keep Claude state outside the install root.
export HOME="${MONET_CLAUDE_HOME:-${HOME:-$MONET_HOME}}"

# Standard subdirectories, all overridable.
export MONET_LOG_DIR="${MONET_LOG_DIR:-$MONET_HOME/logs}"
export MONET_DATA_DIR="${MONET_DATA_DIR:-$MONET_HOME/data}"
export MONET_QUEUE_DIR="${MONET_QUEUE_DIR:-$MONET_HOME/queue}"
export MONET_PENDING_DIR="${MONET_PENDING_DIR:-$MONET_HOME/pending}"
