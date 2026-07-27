"""Shared test bootstrap.

Puts the repo's api/ on sys.path so `import monet_webhook` works from a clean
clone at any location, and exposes the synthetic chat id every test uses.

The environment must be set up BEFORE monet_webhook is imported: the module
reads MONET_AUTHORIZED_CHAT into a module-level constant at import time, so a
later assignment would have no effect.
"""
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
API_DIR = os.path.join(REPO_ROOT, "api")

for p in (API_DIR, os.path.join(REPO_ROOT, "lib")):
    if p not in sys.path:
        sys.path.insert(0, p)

os.environ.setdefault("MONET_HOME", REPO_ROOT)

TEST_CHAT_ID = os.environ.get("TEST_CHAT_ID", "111111111")
os.environ.setdefault("MONET_AUTHORIZED_CHAT", TEST_CHAT_ID)

# An id that is deliberately NOT the authorized one, for negative-path tests.
UNAUTHORIZED_CHAT_ID = "9999"
assert UNAUTHORIZED_CHAT_ID != TEST_CHAT_ID, "unauthorized fixture id must differ from TEST_CHAT_ID"
