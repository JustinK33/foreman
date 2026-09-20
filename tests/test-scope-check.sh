#!/usr/bin/env bash
# Every case here either caught a real bug or guards one that was fixed.
# No framework: asserts on the hook's stdout and exit code, nothing more.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/scope-check.sh"
pass=0
fail=0

# Runs the hook on a payload built by a python snippet.
# Usage: check <name> <expect: nudge|silent> <python-expression-producing-json>
check() {
  local name="$1" expect="$2" payload="$3"
  local out status
  out="$(python3 -c "$payload" | bash "$HOOK" 2>/dev/null)"
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "  FAIL  $name: hook exited $status, must always exit 0"
    fail=$((fail + 1))
    return
  fi

  case "$expect" in
    nudge)
      if [ -z "$out" ]; then
        echo "  FAIL  $name: expected a nudge, got silence"
        fail=$((fail + 1))
        return
      fi
      # The nudge only reaches the model through additionalContext.
      if ! printf '%s' "$out" | grep -q 'additionalContext'; then
        echo "  FAIL  $name: output is not hookSpecificOutput JSON"
        fail=$((fail + 1))
        return
      fi
      ;;
    silent)
      if [ -n "$out" ]; then
        echo "  FAIL  $name: expected silence, got: ${out:0:70}"
        fail=$((fail + 1))
        return
      fi
      ;;
  esac

  echo "  ok    $name"
  pass=$((pass + 1))
}

echo "scope-check"

# Baseline: an ordinary oversized file.
check "100-line Write nudges" nudge \
  'import json;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/tmp/a.py","content":"x\n"*100}}))'

# Regression: payload used to go through argv and blew ARG_MAX (1 MB) at exit 126.
check "2MB Write survives ARG_MAX" nudge \
  'import json;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/tmp/big.js","content":"y\n"*1000000}}))'

# Regression: matcher was Write|Edit, so a large batch edit passed silently.
check "200-line MultiEdit nudges" nudge \
  'import json;print(json.dumps({"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/a.py","edits":[{"old_string":"a","new_string":"b\n"*200}]}}))'

# Regression: line counting is blind to minified and generated output.
check "300KB on one line nudges" nudge \
  'import json;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/tmp/min.js","content":"x"*300000}}))'

# A normal edit must not interrupt.
check "small Edit stays silent" silent \
  'import json;print(json.dumps({"tool_name":"Edit","tool_input":{"old_string":"a","new_string":"b\nc"}}))'

# Deleting 200 lines is not adding 200 lines.
check "large deletion stays silent" silent \
  'import json;print(json.dumps({"tool_name":"Edit","tool_input":{"old_string":"a\n"*200,"new_string":"b"}}))'

# A broken payload must degrade quietly, never surface a hook error.
check "malformed stdin stays silent" silent 'print("not json")'
check "empty stdin stays silent" silent 'print("", end="")'

# An unmatched tool should do nothing even if the matcher ever widens.
check "unknown tool stays silent" silent \
  'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"}}))'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
