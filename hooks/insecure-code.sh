#!/bin/bash
# Warn about insecure code patterns (SQL injection, command injection, XSS, etc.)
if command -v python3 >/dev/null 2>&1; then
    python3 "$(dirname "$0")/insecure_code.py"
elif command -v python >/dev/null 2>&1; then
    python "$(dirname "$0")/insecure_code.py"
else
    exit 0
fi
