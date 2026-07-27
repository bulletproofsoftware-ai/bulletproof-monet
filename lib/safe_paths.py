"""Safe construction of filesystem paths from untrusted identifiers.

Several call sites take an identifier that arrived over the network — a
Telegram callback token, a session id, a filename fragment — and join it to a
base directory. Joining directly is unsafe in two distinct ways:

  1. ``os.path.join(base, "../../etc/passwd")`` escapes upward.
  2. ``os.path.join(base, "/etc/passwd")`` discards ``base`` entirely, because
     an absolute right-hand operand replaces the left.

Both matter here: the approve/deny handler reads *and then deletes* the
resolved path, so a traversal is an arbitrary-delete primitive, not merely an
information leak.

The helpers below fail closed: anything that is not a single, plain path
segment resolving inside the base directory raises ``UnsafeIdentifier``.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

__all__ = ["UnsafeIdentifier", "is_safe_segment", "safe_join"]


class UnsafeIdentifier(ValueError):
    """Raised when an untrusted identifier cannot be used as a path segment."""


# A conservative allow-list. Identifiers in this codebase are generated tokens,
# chat ids and session uuids, all of which fit comfortably.
_SAFE_SEGMENT = re.compile(r"\A[A-Za-z0-9._-]{1,255}\Z")


def is_safe_segment(identifier: object) -> bool:
    """True if *identifier* is usable as a single filesystem path segment."""
    if not isinstance(identifier, str):
        return False
    if not _SAFE_SEGMENT.match(identifier):
        return False
    # "." and ".." match the character class but are traversal, not names.
    if identifier in (".", ".."):
        return False
    # Leading dots hide files and are never intentional for these tokens.
    if identifier.startswith("."):
        return False
    return True


def safe_join(base: str | os.PathLike[str], identifier: str, suffix: str = "") -> Path:
    """Join *identifier* (+ optional *suffix*) under *base*, or raise.

    Raises UnsafeIdentifier if the identifier is not a plain segment, or if
    the resolved path would fall outside *base* — the second check also covers
    symlinks pointing out of the directory.
    """
    if not is_safe_segment(identifier):
        raise UnsafeIdentifier(f"unsafe path identifier: {identifier!r}")

    base_path = Path(base)
    candidate = base_path / f"{identifier}{suffix}"

    try:
        resolved_base = base_path.resolve()
        resolved = candidate.resolve()
    except OSError as exc:  # pragma: no cover - filesystem-dependent
        raise UnsafeIdentifier(f"cannot resolve path for {identifier!r}") from exc

    if resolved != resolved_base and resolved_base not in resolved.parents:
        raise UnsafeIdentifier(
            f"path for {identifier!r} escapes {base_path}"
        )
    return resolved
