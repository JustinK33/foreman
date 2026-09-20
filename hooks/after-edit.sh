#!/usr/bin/env bash
# Runs after every Write, Edit, or MultiEdit. Reads the tool call off stdin as
# JSON and runs two independent checks against it:
#
#   scope       did this change add more code than the task needed?
#   test-first  did production code just land with no test anywhere near it?
#
# Both nudge, neither blocks. One hook rather than two so an edit pays for one
# process and one payload parse, and so the model gets one combined note
# instead of two competing ones.
#
# Never exits non-zero: a hook failure is noisier than a missed nudge.

command -v python3 >/dev/null 2>&1 || exit 0

# Payload goes over stdin, not argv. Write of a large file exceeds ARG_MAX
# (1 MB on macOS) and argv would abort the interpreter with exit 126.
python3 -c '
import hashlib, json, os, re, subprocess, sys

def env_int(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default

def env_off(name):
    return os.environ.get(name, "").strip().lower() in ("0", "off", "false", "no")

# Lines is the headline number, but it misses minified and generated files, so
# bytes is a second trigger: 300 KB on one line is not a small change.
LINE_THRESHOLD = env_int("FOREMAN_LINE_THRESHOLD", 80)
BYTE_THRESHOLD = env_int("FOREMAN_BYTE_THRESHOLD", 50_000)
# Below this, an untested edit is a tweak, not a missing test.
TEST_FIRST_MIN_LINES = env_int("FOREMAN_TEST_FIRST_MIN_LINES", 10)

SOURCE_EXTENSIONS = {
    ".py", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".go", ".rs", ".java",
    ".kt", ".kts", ".rb", ".php", ".swift", ".cs", ".fs", ".scala", ".ex",
    ".exs", ".dart", ".c", ".cc", ".cpp", ".m", ".mm",
}
# Vendored, generated, and build output. Nobody unit-tests these.
SKIP_PATH = re.compile(
    r"(^|/)(node_modules|vendor|third_party|dist|build|target|\.venv|venv|"
    r"migrations|generated|__pycache__|\.next|\.git)(/|$)"
)
SKIP_FILE = re.compile(r"(\.d\.ts|\.min\.[a-z]+|\.config\.[a-z]+|^__init__\.py|^conftest\.py)$")
# Separators required, so "latest.py" is not read as a test file.
SEP_TEST = re.compile(r"(?:^|[^A-Za-z])(?:test|spec)s?(?:[^A-Za-z]|$)", re.I)
# Case-sensitive, for the FooTest.java / BarSpec.scala convention.
CAMEL_TEST = re.compile(r"[a-z0-9](?:Test|Tests|Spec|Specs|IT)\.[A-Za-z]+$")


def is_test_path(path):
    parts = path.split("/")
    if any(SEP_TEST.search(part) for part in parts[:-1]):
        return True
    name = parts[-1]
    return bool(SEP_TEST.search(name) or CAMEL_TEST.search(name))


def count(new, old=""):
    """Lines and bytes added, floored at zero for pure deletions."""
    return (
        max(new.count("\n") - old.count("\n") + (1 if new and not old else 0), 0),
        max(len(new.encode("utf-8", "replace")) - len(old.encode("utf-8", "replace")), 0),
    )


def already_flagged(session_id, key):
    """One test-first nudge per file per session. Repeating it just trains the
    model to ignore it. Fails open: if the marker cannot be written, nudge."""
    if not session_id:
        return False
    try:
        state = os.path.join(
            os.environ.get("TMPDIR", "/tmp"), "foreman-" + re.sub(r"[^\w.-]", "", session_id)
        )
        os.makedirs(state, exist_ok=True)
        marker = os.path.join(state, hashlib.sha1(key.encode()).hexdigest())
        if os.path.exists(marker):
            return True
        open(marker, "w").close()
    except OSError:
        return False
    return False


def inside(path, cwd):
    """A scratch file in /tmp is not this repo\x27s untested module."""
    if not os.path.isabs(path):
        return True
    try:
        root = os.path.abspath(cwd)
        return os.path.commonpath([os.path.abspath(path), root]) == root
    except ValueError:
        return False


def missing_test(path, cwd):
    """True only when the repo demonstrably tests itself and this file is the
    exception. A repo with no tests at all is a different conversation than a
    missing test, and not one a hook should start."""
    try:
        listing = subprocess.run(
            ["git", "ls-files"], cwd=cwd, capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if listing.returncode != 0:
        return False  # not a git repo: nothing to compare against

    tests = [f for f in listing.stdout.splitlines() if is_test_path(f)]
    if not tests:
        return False

    stem = os.path.splitext(os.path.basename(path))[0]
    if len(stem) < 3:
        return False  # too short to match on without guessing
    return not any(stem.lower() in os.path.basename(f).lower() for f in tests)


try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input") or {}
cwd = data.get("cwd") or os.getcwd()

lines = written = 0
if tool_name == "Write":
    content = tool_input.get("content") or tool_input.get("file_text") or ""
    lines, written = count(content)
elif tool_name == "Edit":
    new = tool_input.get("new_string") or tool_input.get("new_str") or ""
    old = tool_input.get("old_string") or tool_input.get("old_str") or ""
    lines, written = count(new, old)
elif tool_name == "MultiEdit":
    # One nudge for the whole batch, not one per edit.
    for edit in tool_input.get("edits") or []:
        if not isinstance(edit, dict):
            continue
        new = edit.get("new_string") or edit.get("new_str") or ""
        old = edit.get("old_string") or edit.get("old_str") or ""
        edit_lines, edit_bytes = count(new, old)
        lines += edit_lines
        written += edit_bytes
else:
    sys.exit(0)

raw_path = tool_input.get("file_path") or ""
path = raw_path if raw_path else "that file"
notes = []

if not env_off("FOREMAN_SCOPE_CHECK") and (lines >= LINE_THRESHOLD or written >= BYTE_THRESHOLD):
    size = f"{lines} lines" if lines >= LINE_THRESHOLD else f"{written // 1000} KB on very few lines"
    notes.append(
        f"That change adds roughly {size} to {path}. Quick gut check before moving on: "
        "could reuse, a stdlib call, or an existing dependency have covered this in less "
        "code? If the size is genuinely necessary (a real algorithm, a generated or "
        "vendored file, a fixture), carry on without comment."
    )

if (
    not env_off("FOREMAN_TEST_FIRST")
    and raw_path
    and lines >= TEST_FIRST_MIN_LINES
    and inside(raw_path, cwd)
    and os.path.splitext(raw_path)[1] in SOURCE_EXTENSIONS
    and not is_test_path(raw_path)
    and not SKIP_PATH.search(raw_path)
    and not SKIP_FILE.search(os.path.basename(raw_path))
    and missing_test(raw_path, cwd)
    and not already_flagged(data.get("session_id", ""), raw_path)
):
    notes.append(
        f"{path} just gained {lines} lines of production code and this repo has tests, "
        "but none of them name this file. Write the test that would have failed before "
        "this change, watch it fail, then confirm it passes now. If the file genuinely "
        "is not unit-testable (wiring, config, a thin adapter over a library), say that "
        "in one line and move on."
    )

if not notes:
    sys.exit(0)

# PostToolUse only feeds the model through hookSpecificOutput.additionalContext;
# bare stdout lands in the transcript where the agent never reads it.
json.dump(
    {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "\n\n".join("[foreman] " + note for note in notes),
        }
    },
    sys.stdout,
)
'
exit 0
