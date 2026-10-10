"""Per-session scratch markers, and the switches and git calls every hook uses.

Shared rather than copied because the writer and the reader have to agree on the
directory and marker names exactly. If they drift, nothing errors: the marker is
simply never found, and the check silently stops happening.

Every function fails open and returns a falsey value rather than raising. A hook
that crashes over a scratch file is worse than a hook that misses a nudge.
"""

import json
import os
import re
import shutil
import subprocess
import sys

PREFIX = "foreman-"
# Written by session_tests.py when a test runner goes by.
RAN = "tests-ran"
# Written by after_edit.py, one per production file, with the path as its body.
WROTE = "wrote-"

# In-memory cache for marks to avoid repeated file I/O
_mark_cache = {}

# Cache for git ls-files result (stable throughout session)
_git_files_cache = {}

# Shared exemption patterns - most comprehensive versions
COMMON_SKIP_PATH = re.compile(
    r"""(?ix)
    (?:^|/) (?: \.env(?:\.|$) | node_modules/ | vendor/ | dist/ | build/
              | \.git/ | fixtures?/ | __mocks__/ | __fixtures__/ | mocks?/
              | tests?/ | spec/ | __tests__/ | examples?/ | samples?/
              | third_party/ | target/ | \.venv/ | venv/ | migrations/
              | generated/ | __pycache__/ | \.next/ )
    | (?:^|[^A-Za-z])(?:test|spec)s?(?:[^A-Za-z]|$)
    """
)

# Extension sets for composition
DOCS_EXTENSIONS = {".md", ".markdown", ".rst", ".txt", ".adoc"}
CONFIG_EXTENSIONS = {".json", ".yaml", ".yml", ".toml", ".ini", ".cfg"}
TEMPLATE_EXTENSIONS = {".example", ".sample", ".template", ".tmpl", ".dist"}
TEST_EXTENSIONS = {".lock", ".snap"}
GENERATED_EXTENSIONS = {".min.js", ".min.css", ".d.ts"}


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
    # Cache git ls-files for performance (stable throughout session)
    if args == ["ls-files"] and cwd in _git_files_cache:
        return _git_files_cache[cwd]

    try:
        done = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return []

    result = done.stdout.splitlines() if done.returncode == 0 else []

    if args == ["ls-files"] and result:
        _git_files_cache[cwd] = result

    return result


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
    cache_key = (session_id, name)
    existed = cache_key in _mark_cache

    path = state_dir(session_id)
    if not path:
        return False
    try:
        marker = os.path.join(path, re.sub(r"[^\w.-]", "_", name))
        existed = existed or os.path.exists(marker)
        with open(marker, "w") as handle:
            handle.write(body)
        _mark_cache[cache_key] = body
        return existed
    except OSError:
        return False


def marked(session_id, name):
    """Check if a mark exists. Uses in-memory cache for speed."""
    cache_key = (session_id, name)
    if cache_key in _mark_cache:
        return True

    path = state_dir(session_id, create=False)
    if not path:
        return False
    exists = os.path.exists(os.path.join(path, re.sub(r"[^\w.-]", "_", name)))
    if exists:
        _mark_cache[cache_key] = ""
    return exists


def marks(session_id, prefix):
    """Every marker whose name starts with prefix, as a list of their bodies."""
    path = state_dir(session_id, create=False)
    if not path:
        return []
    found = []
    try:
        for name in sorted(os.listdir(path)):
            if name.startswith(prefix):
                cache_key = (session_id, name)
                if cache_key in _mark_cache:
                    found.append(_mark_cache[cache_key])
                else:
                    with open(os.path.join(path, name)) as handle:
                        body = handle.read().strip()
                        found.append(body)
                        _mark_cache[cache_key] = body
    except OSError:
        return []
    return found


def clear(session_id):
    path = state_dir(session_id, create=False)
    if path:
        shutil.rmtree(path, ignore_errors=True)


# Shared utility functions for all hooks


def added_text(tool_name, tool_input):
    """Extract added text from Write/Edit/MultiEdit tool input."""
    if tool_name == "Write":
        return tool_input.get("content") or tool_input.get("file_text") or ""
    if tool_name == "Edit":
        return tool_input.get("new_string") or tool_input.get("new_str") or ""
    if tool_name == "MultiEdit":
        parts = []
        for edit in tool_input.get("edits") or []:
            if isinstance(edit, dict):
                parts.append(edit.get("new_string") or edit.get("new_str") or "")
        return "\n".join(parts)
    return ""


def read_hook_input():
    """Parse JSON from stdin with error handling. Returns data dict or None."""
    try:
        return json.loads(sys.stdin.read())
    except Exception:
        return None


def extract_file_path(data):
    """Get file_path from hook data with validation. Returns path or None."""
    if not data:
        return None
    tool_input = data.get("tool_input") or {}
    path = tool_input.get("file_path") or ""
    return path if path else None


def make_relative(path, cwd):
    """Convert absolute path to repo-relative path."""
    if not cwd or not path:
        return path
    if os.path.isabs(path) and path.startswith(cwd.rstrip("/") + "/"):
        return os.path.relpath(path, cwd)
    return path


def get_extension(path):
    """Extract lowercase file extension."""
    return os.path.splitext(path)[1].lower() if path else ""


def is_exempted(path, skip_path_pattern=None, skip_extensions=None):
    """Check if path should be exempted from checks."""
    if not path:
        return True

    if skip_path_pattern and skip_path_pattern.search(path):
        return True

    if skip_extensions:
        ext = get_extension(path)
        if ext in skip_extensions:
            return True

    return False


# Hook output helpers


def deny_with_reason(reason):
    """Output PreToolUse deny decision with reason."""
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


def ask_with_reason(reason):
    """Output PreToolUse ask decision with reason."""
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


def add_context(context):
    """Output PostToolUse additional context."""
    if not context:
        return
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": context,
            }
        },
        sys.stdout,
    )
