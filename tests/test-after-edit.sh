#!/usr/bin/env bash
# Every case here either caught a real bug or guards one that was fixed.
# No framework: asserts on the hook's stdout and exit code, nothing more.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/after-edit.sh"

# The hook keeps its one-nudge-per-file-per-session markers under TMPDIR. A
# fresh TMPDIR per run is what stops the dedupe cases from passing once and
# then failing forever after, which is how this suite first went red.
TMPDIR="$(mktemp -d)"
export TMPDIR

pass=0
fail=0
return_dir=""

# git ls-files only reports tracked files, so every fixture stages its contents.
fixture() {
  return_dir="$(mktemp -d)"
  git -C "$return_dir" init -q
}

fixture && TESTED_REPO="$return_dir"
mkdir -p "$TESTED_REPO/src" "$TESTED_REPO/tests"
: > "$TESTED_REPO/src/billing.py"
: > "$TESTED_REPO/src/orphan.py"
: > "$TESTED_REPO/tests/test_billing.py"
git -C "$TESTED_REPO" add -A

# The only non-source file here is latest.py, which a sloppy "does the name
# contain test" check would miscount as a test suite.
fixture && UNTESTED_REPO="$return_dir"
mkdir -p "$UNTESTED_REPO/src"
: > "$UNTESTED_REPO/src/thing.py"
: > "$UNTESTED_REPO/src/latest.py"
git -C "$UNTESTED_REPO" add -A

fixture && JAVA_REPO="$return_dir"
mkdir -p "$JAVA_REPO/src"
: > "$JAVA_REPO/src/Invoice.java"
: > "$JAVA_REPO/src/InvoiceTest.java"
git -C "$JAVA_REPO" add -A

NOT_A_REPO="$(mktemp -d)"

# Usage: check <name> <expect: silent|scope|test|both> <cwd> <python-json-expr>
# The python expression reads sys.argv[1] for the cwd to report in the payload.
check() {
  local name="$1" expect="$2" cwd="$3" payload="$4"
  local out status want_scope=0 want_test=0 got_scope=0 got_test=0
  # These two strings are the two nudges. Asserting on them stops a case from
  # passing because the *other* check happened to fire.
  local scope_marker='Quick gut check'
  local test_marker='Write the test that would have failed'

  out="$(python3 -c "$payload" "$cwd" | bash "$HOOK" 2>/dev/null)"
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "  FAIL  $name: hook exited $status, must always exit 0"
    fail=$((fail + 1))
    return
  fi

  if [ "$expect" = silent ]; then
    if [ -n "$out" ]; then
      echo "  FAIL  $name: expected silence, got: ${out:0:90}"
      fail=$((fail + 1))
      return
    fi
    echo "  ok    $name"
    pass=$((pass + 1))
    return
  fi

  case "$expect" in
    scope) want_scope=1 ;;
    test) want_test=1 ;;
    both) want_scope=1; want_test=1 ;;
  esac

  # The nudge only reaches the model through additionalContext.
  if ! printf '%s' "$out" | grep -q 'additionalContext'; then
    echo "  FAIL  $name: output is not hookSpecificOutput JSON"
    fail=$((fail + 1))
    return
  fi

  printf '%s' "$out" | grep -qF "$scope_marker" && got_scope=1
  printf '%s' "$out" | grep -qF "$test_marker" && got_test=1

  if [ "$got_scope" -ne "$want_scope" ] || [ "$got_test" -ne "$want_test" ]; then
    echo "  FAIL  $name: wanted scope=$want_scope test=$want_test, got scope=$got_scope test=$got_test"
    fail=$((fail + 1))
    return
  fi

  echo "  ok    $name"
  pass=$((pass + 1))
}

echo "scope"

# Baseline: an ordinary oversized file. /tmp is no repo, so scope fires alone.
check "100-line Write nudges" scope "" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/a.py","content":"x\n"*100}}))'

# Regression: payload used to go through argv and blew ARG_MAX (1 MB) at exit 126.
check "2MB Write survives ARG_MAX" scope "" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/big.js","content":"y\n"*1000000}}))'

# Regression: matcher was Write|Edit, so a large batch edit passed silently.
check "200-line MultiEdit nudges" scope "" \
  'import json,sys;print(json.dumps({"tool_name":"MultiEdit","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/a.py","edits":[{"old_string":"a","new_string":"b\n"*200}]}}))'

# Regression: line counting is blind to minified and generated output.
check "300KB on one line nudges" scope "" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/min.js","content":"x"*300000}}))'

# A normal edit must not interrupt.
check "small Edit stays silent" silent "" \
  'import json,sys;print(json.dumps({"tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"old_string":"a","new_string":"b\nc"}}))'

# Deleting 200 lines is not adding 200 lines.
check "large deletion stays silent" silent "" \
  'import json,sys;print(json.dumps({"tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"old_string":"a\n"*200,"new_string":"b"}}))'

# A broken payload must degrade quietly, never surface a hook error.
check "malformed stdin stays silent" silent "" 'import sys;print("not json")'
check "empty stdin stays silent" silent "" 'import sys;print("", end="")'

# An unmatched tool should do nothing even if the matcher ever widens.
check "unknown tool stays silent" silent "" \
  'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"ls"}}))'

echo
echo "test-first"

# The core case: production code in a repo that tests itself, no test naming it.
check "untested new source nudges" test "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*40}}))'

# tests/test_billing.py names this file, so there is nothing to say.
check "source with a test stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/billing.py","content":"x\n"*40}}))'

# A repo with no tests is a different conversation, not one a hook should start.
# This also proves latest.py is not miscounted as a test file.
check "repo with no tests stays silent" silent "$UNTESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/thing.py","content":"x\n"*40}}))'

# InvoiceTest.java has no separator before "Test": the camel-case convention.
check "FooTest.java counts as a test" silent "$JAVA_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/Invoice.java","content":"x\n"*40}}))'

# Writing the test itself must never be flagged for lacking a test.
check "editing a test file stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"tests/test_orphan.py","content":"x\n"*40}}))'

# Outside a repo there is nothing to compare against, so do not guess.
check "non-repo stays silent" silent "$NOT_A_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*40}}))'

# A scratch file in /tmp is not this repo's untested module, even though the
# repo has tests and nothing in them names it.
check "file outside the repo stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/orphan_elsewhere.py","content":"x\n"*40}}))'

# Generated and vendored trees are not hand-tested.
check "migrations stay silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/migrations/0001_orphan.py","content":"x\n"*40}}))'

# A few lines is a tweak, not a missing test.
check "tiny untested edit stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","old_string":"a","new_string":"b\n"*4}}))'

# Non-source extensions are out of scope entirely.
check "markdown stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"docs/orphan.md","content":"x\n"*40}}))'

# Both checks can fire on one edit, and the nudges must combine, not compete.
check "big untested file gets both notes" both "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*120}}))'

echo
echo "config and dedupe"

# Repeating the same nudge every edit just trains the model to ignore it.
check "first nudge in a session fires" test "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","session_id":"dedupe-fixture","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*40}}))'
check "same file again stays silent" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","session_id":"dedupe-fixture","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*40}}))'

# Users on an updated plugin cannot edit the script, so the knobs are env vars.
FOREMAN_TEST_FIRST=off \
  check "FOREMAN_TEST_FIRST=off silences it" silent "$TESTED_REPO" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"src/orphan.py","content":"x\n"*40}}))'

FOREMAN_LINE_THRESHOLD=10 \
  check "FOREMAN_LINE_THRESHOLD lowers the bar" scope "" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/a.py","content":"x\n"*20}}))'

FOREMAN_SCOPE_CHECK=off \
  check "FOREMAN_SCOPE_CHECK=off silences it" silent "" \
  'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"/tmp/a.py","content":"x\n"*100}}))'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
