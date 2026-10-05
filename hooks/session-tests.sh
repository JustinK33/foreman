#!/usr/bin/env bash
# Entry point for the test-run check, which spans three events: it records a test
# invocation on PostToolUse for Bash, asks about it on Stop, and tidies up on
# SessionEnd. One script for all three because they share the marker directory,
# and the event name arrives in the payload anyway.
#
# Never exits non-zero. Stop blocks by printing JSON, not by exiting 2.

# python.org installs on Windows ship only `python`.
PYTHON="$(command -v python3 || command -v python)" || exit 0

# Payload over stdin, not argv, matching the other hooks.
"$PYTHON" "$(dirname "${BASH_SOURCE[0]}")/session_tests.py"
exit 0
