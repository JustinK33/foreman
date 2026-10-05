#!/usr/bin/env bash
# Entry point for the PreToolUse commit check. Logic lives in commit_check.py.
#
# Never exits non-zero. This hook runs before every Bash call, so a crash that
# exited 2 would block the whole session rather than one bad commit message.

# python.org installs on Windows ship only `python`.
PYTHON="$(command -v python3 || command -v python)" || exit 0

"$PYTHON" "$(dirname "${BASH_SOURCE[0]}")/commit_check.py"
exit 0
