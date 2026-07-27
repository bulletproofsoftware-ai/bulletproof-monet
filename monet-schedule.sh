#!/bin/bash
# monet-schedule.sh — agent-facing CLI for Monet's scheduler.
# Thin wrapper over monet_sched.py. The agent calls this to create/manage
# scheduled jobs from natural language.
#
#   monet-schedule.sh add --chat <id> --schedule "<spec>" --prompt "<text>" [--name N] [--tz Z] [--skills a,b]
#   monet-schedule.sh list [--chat <id>]
#   monet-schedule.sh show|remove|enable|disable <id>
#
# <spec>: a 5-field cron expr ("0 7 * * 1-5") or a friendly form:
#   "daily 7am" | "weekdays 7am" | "every monday 9am" | "hourly" |
#   "every 30m" | "once 2026-06-13T09:00"   (tz defaults to America/New_York)
# shellcheck source=lib/monet-env.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib/monet-env.sh"
export PATH="/usr/local/bin:${MONET_HOME}/.local/bin:/usr/bin:/bin"
exec python3 "$MONET_HOME"/monet_sched.py "$@"
