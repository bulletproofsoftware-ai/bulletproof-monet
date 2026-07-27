#!/usr/bin/env python3
"""Verify the Telegram command surface is exactly the 17-command allowlist.

The surface is DENY BY DEFAULT and is enumerated in exactly two places:

    scripts/tg-register-commands.sh   what Telegram shows in the command menu
    bridges/monet-tg.sh               the /help handler, and the handlers themselves

Drift between those two is how a scrubbed command creeps back in unnoticed: a
handler with no registration is invisible but live, and a registration with no
handler force-replies into a dead end. This script fails on either.

Run it from the repository root. Exit 0 = clean, 1 = drift. CI calls it in the
hygiene job; run it by hand after touching either file.
"""
import re
import sys

ALLOWLIST = sorted("""
    help new export remind reminders
    clip clips find mark marks recall
    search memory-stats memory-export
    ss photo-log usage
""".split())

REG_FILE = "scripts/tg-register-commands.sh"
HANDLER_FILE = "bridges/monet-tg.sh"

# Commands with no handler branch, and why. Each entry is a known gap that is
# documented in README.md; an UNLISTED command missing its handler is a failure.
# Empty by design: /bg was removed from the surface rather than left registered
# and dead. Prefer deleting a command over adding an exemption here.
HANDLER_EXEMPT = {}


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    return False


def registered_commands():
    src = open(REG_FILE).read()
    return sorted(re.findall(r'"command":"([^"]+)"', src))


def help_listed_commands(handler_src):
    """Commands enumerated in the /help heredoc body."""
    body = handler_src.split("HELPEOF", 2)
    if len(body) < 3:
        return None
    return sorted(set(re.findall(r"^/([a-z][a-z-]*)", body[1], re.M)))


def has_handler(handler_src, cmd):
    """True if a dispatch branch matches cmd.

    Handlers are written as either  '^/?(a|b|c)...'  or  '^/?cmd[[:space:]]'.
    """
    esc = re.escape(cmd)
    patterns = (
        rf"\^/\?\(([a-z0-9|_-]*\|)?{esc}(\||\))",
        rf"\^/\?{esc}\[",
    )
    return any(re.search(p, handler_src) for p in patterns)


def main():
    ok = True
    handler_src = open(HANDLER_FILE).read()

    registered = registered_commands()
    if registered != ALLOWLIST:
        extra = sorted(set(registered) - set(ALLOWLIST))
        missing = sorted(set(ALLOWLIST) - set(registered))
        ok = fail(
            f"{REG_FILE} does not match the allowlist.\n"
            f"       unexpected: {extra or 'none'}\n"
            f"       missing:    {missing or 'none'}"
        )

    listed = help_listed_commands(handler_src)
    if listed is None:
        ok = fail(f"could not locate the /help heredoc in {HANDLER_FILE}")
    elif listed != ALLOWLIST:
        extra = sorted(set(listed) - set(ALLOWLIST))
        missing = sorted(set(ALLOWLIST) - set(listed))
        ok = fail(
            f"the /help listing in {HANDLER_FILE} does not match the allowlist.\n"
            f"       unexpected: {extra or 'none'}\n"
            f"       missing:    {missing or 'none'}"
        )

    for cmd in ALLOWLIST:
        if cmd in HANDLER_EXEMPT:
            continue
        if not has_handler(handler_src, cmd):
            ok = fail(f"/{cmd} is on the allowlist but has no handler in {HANDLER_FILE}")

    if ok:
        print(
            f"command allowlist verified: {len(ALLOWLIST)} commands; "
            f"registration, /help and handlers all agree"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
