#!/usr/bin/env bash
# Entry point for the PostToolUse hook. The checks live in after_edit.py, next
# to this file, so they can be linted and unit tested as Python rather than as
# a 200-line single-quoted bash string.
#
# Never exits non-zero: a hook failure is noisier than a missed nudge.

# python.org installs on Windows ship only `python`.
PYTHON="$(command -v python3 || command -v python)" || exit 0

# Payload goes over stdin, not argv. A Write of a large file exceeds ARG_MAX
# (1 MB on macOS) and argv would abort the interpreter with exit 126.
"$PYTHON" "$(dirname "${BASH_SOURCE[0]}")/after_edit.py"
exit 0
