#!/usr/bin/env bash
# Runs after every Write, Edit, or MultiEdit. Reads the tool call off stdin as
# JSON, estimates how much just got added, and nudges (never blocks) if the
# change looks bigger than the task probably needed.
#
# Never exits non-zero: a hook failure is noisier than a missed nudge.

command -v python3 >/dev/null 2>&1 || exit 0

# Payload goes over stdin, not argv. Write of a large file exceeds ARG_MAX
# (1 MB on macOS) and argv would abort the interpreter with exit 126.
python3 -c '
import json, sys

# Lines is the headline number, but it misses minified and generated files, so
# bytes is a second trigger: 300 KB on one line is not a small change.
LINE_THRESHOLD = 80
BYTE_THRESHOLD = 50_000

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

tool_name = data.get("tool_name", "")
tool_input = data.get("tool_input") or {}


def count(new, old=""):
    """Lines and bytes added, floored at zero for pure deletions."""
    return (
        max(new.count("\n") - old.count("\n") + (1 if new and not old else 0), 0),
        max(len(new.encode("utf-8", "replace")) - len(old.encode("utf-8", "replace")), 0),
    )


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

if lines < LINE_THRESHOLD and written < BYTE_THRESHOLD:
    sys.exit(0)

size = f"{lines} lines" if lines >= LINE_THRESHOLD else f"{written // 1000} KB on very few lines"
path = tool_input.get("file_path") or "that file"

# PostToolUse only feeds the model through hookSpecificOutput.additionalContext;
# bare stdout lands in the transcript where the agent never reads it.
json.dump(
    {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                f"[foreman] That change adds roughly {size} to {path}. Quick gut check before "
                "moving on: could reuse, a stdlib call, or an existing dependency have covered "
                "this in less code? If the size is genuinely necessary (a real algorithm, a "
                "generated or vendored file, a fixture), carry on without comment."
            ),
        }
    },
    sys.stdout,
)
'
exit 0
