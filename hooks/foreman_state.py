"""Per-session scratch markers, shared by the hooks that write and read them.

Shared rather than copied because the writer and the reader have to agree on the
directory name exactly. If they drift, nothing errors: the marker is simply never
found, and the check silently stops happening.

Every function fails open and returns a falsey value rather than raising. A hook
that crashes over a scratch file is worse than a hook that misses a nudge.
"""

import os
import re
import shutil

PREFIX = "foreman-"


def state_dir(session_id, create=True):
    if not session_id:
        return ""
    try:
        path = os.path.join(
            os.environ.get("TMPDIR", "/tmp"), PREFIX + re.sub(r"[^\w.-]", "", str(session_id))
        )
        if create:
            os.makedirs(path, exist_ok=True)
        return path
    except OSError:
        return ""


def mark(session_id, name, body=""):
    """Record a fact about this session. True if it was already recorded."""
    path = state_dir(session_id)
    if not path:
        return False
    try:
        marker = os.path.join(path, re.sub(r"[^\w.-]", "_", name))
        existed = os.path.exists(marker)
        with open(marker, "w") as handle:
            handle.write(body)
        return existed
    except OSError:
        return False


def marked(session_id, name):
    path = state_dir(session_id, create=False)
    if not path:
        return False
    return os.path.exists(os.path.join(path, re.sub(r"[^\w.-]", "_", name)))


def marks(session_id, prefix):
    """Every marker whose name starts with prefix, as a list of their bodies."""
    path = state_dir(session_id, create=False)
    if not path:
        return []
    found = []
    try:
        for name in sorted(os.listdir(path)):
            if name.startswith(prefix):
                with open(os.path.join(path, name)) as handle:
                    found.append(handle.read().strip())
    except OSError:
        return []
    return found


def clear(session_id):
    path = state_dir(session_id, create=False)
    if path:
        shutil.rmtree(path, ignore_errors=True)
