#!/usr/bin/env bash
# Entry point for the PreToolUse credential check. Logic lives in no_secrets.py.
#
# Never exits non-zero. This hook runs before every Write and Edit, so a crash
# that exited 2 would block the whole session rather than one bad write.

command -v python3 >/dev/null 2>&1 || exit 0

python3 "$(dirname "${BASH_SOURCE[0]}")/no_secrets.py"
exit 0
