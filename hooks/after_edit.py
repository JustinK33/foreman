"""Three independent checks against a Write, Edit, or MultiEdit tool call.

    scope       did this change add more code than the task needed?
    test-first  did production code just land with no test anywhere near it?
    comments    do the comments it added read like a person wrote them?

All three nudge, none blocks. One hook rather than three so an edit pays for one
process and one payload parse, and so the model gets one combined note instead
of three competing ones.

Never exits non-zero: a hook failure is noisier than a missed nudge.

The payload arrives on stdin, not argv. A Write of a large file exceeds ARG_MAX
(1 MB on macOS) and argv would abort the interpreter with exit 126.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

# Resolved from this file's own directory, which Python puts on sys.path when it
# runs a script. Shared with session_tests.py, which reads the markers written
# here: the two have to agree on the directory name or the Stop check silently
# never fires.
import comment_style
import foreman_state


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
    # Stacks that used to be invisible here, which reads as the hook being
    # broken rather than deliberately quiet.
    ".vue", ".svelte", ".sh", ".bash", ".lua", ".clj", ".cljs", ".cljc",
    ".hs", ".zig", ".erl", ".jl", ".groovy", ".pl", ".pm", ".nim", ".ml",
}
# Additive, comma separated, so covering one more stack never needs a fork.
SOURCE_EXTENSIONS |= {
    ext if ext.startswith(".") else "." + ext
    for ext in (
        e.strip().lower()
        for e in os.environ.get("FOREMAN_SOURCE_EXTENSIONS", "").split(",")
    )
    if ext
}

# Prose, data, and markup. "Could a stdlib call have covered this in less code?"
# is incoherent advice about a README, and a long doc is the most common large
# Write there is, so without this the scope check is mostly false positives.
NON_CODE_EXTENSIONS = {
    ".md", ".markdown", ".rst", ".txt", ".adoc", ".json", ".jsonc", ".yaml",
    ".yml", ".toml", ".ini", ".cfg", ".csv", ".tsv", ".svg", ".lock", ".html",
    ".htm", ".xml", ".po", ".pot", ".snap", ".patch", ".diff", ".sql",
}
# Vendored, generated, and build output. Nobody unit-tests these, and nobody
# needs to be asked whether they could have been shorter either.
SKIP_PATH = re.compile(
    r"(^|/)(node_modules|vendor|third_party|dist|build|target|\.venv|venv|"
    r"migrations|generated|__pycache__|\.next|\.git)(/|$)"
)
SKIP_FILE = re.compile(r"(\.d\.ts|\.min\.[a-z]+|\.config\.[a-z]+|^__init__\.py|^conftest\.py)$")
# Below this, a filename is too short to match on without guessing: "db" would
# claim every test file with "db" anywhere in its name.
MIN_STEM = 3
# Separators required, so "latest.py" is not read as a test file.
SEP_TEST = re.compile(r"(?:^|[^A-Za-z])(?:test|spec)s?(?:[^A-Za-z]|$)", re.IGNORECASE)
# Case-sensitive, for the FooTest.java / BarSpec.scala convention.
CAMEL_TEST = re.compile(r"[a-z0-9](?:Test|Tests|Spec|Specs|IT)\.[A-Za-z]+$")


def squash(name):
    """Fold separators and case, so after_edit.py is matched by test-after-edit.sh.
    A snake_case module tested by a kebab-case file is not an untested module."""
    return re.sub(r"[-_.\s]", "", name).lower()


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
    return foreman_state.mark(session_id, hashlib.sha1(key.encode()).hexdigest())


def inside(path, cwd):
    """A scratch file in /tmp is not this repo's untested module."""
    if not os.path.isabs(path):
        return True
    try:
        root = os.path.abspath(cwd)
        return os.path.commonpath([os.path.abspath(path), root]) == root
    except ValueError:
        return False


def git(args, cwd):
    """Tracked-file queries only. Returns [] on anything unexpected, because
    every caller treats "I could not tell" as "stay quiet"."""
    try:
        done = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if done.returncode != 0:
        return []
    return done.stdout.splitlines()


def referenced_by_a_test(stem, cwd):
    """Does any test file mention this module by name?

    The filename check below is a guess about naming convention. This is closer
    to the real question, and it is what rescues a repo whose tests all live in
    one tests/test_api.py: the filename check can never be satisfied there, so
    without this every source file gets nudged forever.

    A common stem like "utils" will match tests that do not really cover it,
    which makes this silent when it should speak. That is the correct direction
    to be wrong in: a nudge you learn to ignore is worse than no nudge.
    """
    if not stem:
        return False
    # No pathspec: one subprocess, no argv limit, and is_test_path already knows
    # how to recognise a test file.
    return any(is_test_path(f) for f in git(["grep", "-l", "-F", "-e", stem], cwd))


def tracked_tests(cwd):
    """The repo's test files, or [] when it has none, or when this is not a git
    repo at all. A repo with no tests is a different conversation than a missing
    test, and not one a hook should start, so [] means every check goes quiet."""
    return [f for f in git(["ls-files"], cwd) if is_test_path(f)]


def missing_test(path, cwd, tests):
    """True when the repo tests itself and this file is the exception."""
    stem = os.path.splitext(os.path.basename(path))[0]
    if len(stem) < MIN_STEM:
        return False

    needle = squash(stem)
    if any(needle in squash(os.path.basename(f)) for f in tests):
        return False
    return not referenced_by_a_test(stem, cwd)


def measure(tool_name, tool_input):
    """(lines added, bytes added, the added text) for one tool call, or None if
    this is not a tool that writes a file.

    The text is kept as well as measured because the comment check reads it.
    Only the new side of an edit: a comment that was already in the file is not
    this change's to answer for.
    """
    if tool_name == "Write":
        content = tool_input.get("content") or tool_input.get("file_text") or ""
        return (*count(content), [content])

    if tool_name == "Edit":
        new = tool_input.get("new_string") or tool_input.get("new_str") or ""
        old = tool_input.get("old_string") or tool_input.get("old_str") or ""
        return (*count(new, old), [new])

    if tool_name != "MultiEdit":
        return None

    # One nudge for the whole batch, not one per edit.
    lines = written = 0
    added = []
    for edit in tool_input.get("edits") or []:
        if not isinstance(edit, dict):
            continue
        new = edit.get("new_string") or edit.get("new_str") or ""
        old = edit.get("old_string") or edit.get("old_str") or ""
        edit_lines, edit_bytes = count(new, old)
        lines += edit_lines
        written += edit_bytes
        added.append(new)
    return lines, written, added


def main():
    # Any non-empty value. Someone reaching for a kill switch will type 1, on,
    # true, or off, and arguing with them about which is worse than no switch.
    if os.environ.get("FOREMAN_OFF", "").strip():
        return

    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()

    measured = measure(tool_name, tool_input)
    if measured is None:
        return
    lines, written, added = measured

    raw_path = tool_input.get("file_path") or ""
    path = raw_path or "that file"
    basename = os.path.basename(raw_path)
    extension = os.path.splitext(raw_path)[1].lower()
    notes = []

    if (
        not env_off("FOREMAN_SCOPE_CHECK")
        and (lines >= LINE_THRESHOLD or written >= BYTE_THRESHOLD)
        # Only the prose-and-data filter here, deliberately not SKIP_FILE: the
        # byte threshold exists precisely so a minified blob cannot slip past a
        # line count, so excluding .min.js would undo the reason it is there.
        and extension not in NON_CODE_EXTENSIONS
    ):
        size = f"{lines} lines" if lines >= LINE_THRESHOLD else f"{written // 1000} KB on very few lines"
        notes.append(
            f"That change adds roughly {size} to {path}. Quick gut check before moving on: "
            "could reuse, a stdlib call, or an existing dependency have covered this in less "
            "code? If the size is genuinely necessary, a real algorithm or a fixture, carry "
            "on without comment."
        )

    # Production code, by every test the test-first check applies except whether a
    # test for it exists. Computed outside FOREMAN_TEST_FIRST because the Stop
    # check below shares it and has its own switch.
    production = bool(
        raw_path
        and lines >= TEST_FIRST_MIN_LINES
        and inside(raw_path, cwd)
        and extension in SOURCE_EXTENSIONS
        and not is_test_path(raw_path)
        and not SKIP_PATH.search(raw_path)
        and not SKIP_FILE.search(basename)
    )
    tests = tracked_tests(cwd) if production else []

    # What session_tests.py reads on Stop to ask whether the suite ever ran. Only
    # the files it would be fair to ask about: a repo with no tests is not told
    # to run them, and the path is recorded so the nudge can name it.
    if production and tests:
        foreman_state.mark(
            data.get("session_id", ""),
            "wrote-" + hashlib.sha1(raw_path.encode()).hexdigest(),
            raw_path,
        )

    if (
        not env_off("FOREMAN_TEST_FIRST")
        and production
        and tests
        and missing_test(raw_path, cwd, tests)
        and not already_flagged(data.get("session_id", ""), raw_path)
    ):
        notes.append(
            f"{path} just gained {lines} lines of production code and this repo has tests, "
            "but no test names or mentions this file. Write the test that would have failed "
            "before this change, watch it fail, then confirm it passes now. If the file "
            "genuinely is not unit-testable (wiring, config, a thin adapter over a library), "
            "say that in one line and move on."
        )

    # No line threshold here, unlike the other two: a four-line edit can still
    # add three comments that say nothing, and that is the whole complaint.
    # Test files are in scope, because they get narrated worst of all.
    if (
        not env_off("FOREMAN_COMMENT_CHECK")
        and extension in SOURCE_EXTENSIONS
        and not SKIP_PATH.search(raw_path)
        and not SKIP_FILE.search(basename)
    ):
        comments = comment_style.note(
            path, comment_style.findings("\n".join(added), extension)
        )
        if comments and not already_flagged(data.get("session_id", ""), "comments:" + raw_path):
            notes.append(comments)

    if not notes:
        return

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


main()
