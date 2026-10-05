"""Per-session scratch markers, and the switches and git calls every hook uses.

Shared rather than copied because the writer and the reader have to agree on the
directory and marker names exactly. If they drift, nothing errors: the marker is
simply never found, and the check silently stops happening.

Every function fails open and returns a falsey value rather than raising. A hook
that crashes over a scratch file is worse than a hook that misses a nudge.
"""

import os
import re
import shutil
import subprocess

PREFIX = "foreman-"
# Written by session_tests.py when a test runner goes by.
RAN = "tests-ran"
# Written by after_edit.py, one per production file, with the path as its body.
WROTE = "wrote-"


def env_int(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def env_off(name):
    return os.environ.get(name, "").strip().lower() in ("0", "off", "false", "no")


def disabled(switch):
    """FOREMAN_OFF silences everything; each check also has its own switch."""
    return bool(os.environ.get("FOREMAN_OFF", "").strip()) or env_off(switch)


def git(args, cwd):
    """Returns [] on anything unexpected, because every caller treats "I could
    not tell" as "stay quiet"."""
    try:
        done = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return done.stdout.splitlines() if done.returncode == 0 else []


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
