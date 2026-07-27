"""monet_paths — resolve the Monet install root for Python components.

MONET_HOME resolution mirrors lib/monet-env.sh:
  1. an exported MONET_HOME
  2. the parent of the directory this module lives in (the running checkout)
  3. /opt/monet
"""
import os

_here = os.path.dirname(os.path.realpath(__file__))
MONET_HOME = os.environ.get("MONET_HOME") or os.path.dirname(_here) or "/opt/monet"

LOG_DIR     = os.environ.get("MONET_LOG_DIR",     os.path.join(MONET_HOME, "logs"))
DATA_DIR    = os.environ.get("MONET_DATA_DIR",    os.path.join(MONET_HOME, "data"))
QUEUE_DIR   = os.environ.get("MONET_QUEUE_DIR",   os.path.join(MONET_HOME, "queue"))
PENDING_DIR = os.environ.get("MONET_PENDING_DIR", os.path.join(MONET_HOME, "pending"))
API_DIR     = os.path.join(MONET_HOME, "api")


def path(*parts):
    """Join parts onto MONET_HOME. monet_paths.path('tg-send.sh') -> <root>/tg-send.sh"""
    return os.path.join(MONET_HOME, *parts)
