#!/usr/bin/env bash
# The test-run check is the only hook here that blocks the end of a turn, so the
# cases that matter most are the ones proving it stays quiet and cannot loop.
#
# Driven end to end: production writes are recorded by running after-edit.sh, not
# by planting markers, because the whole feature depends on those two scripts
# agreeing on a directory name. A test that writes the marker itself would pass
# even if they disagreed.
#
# No framework: asserts on the hook's stdout and exit code, nothing more.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_HOOK="$ROOT/hooks/session-tests.sh"
EDIT_HOOK="$ROOT/hooks/after-edit.sh"

# A fresh TMPDIR per run. The markers are the entire state of this feature, and a
# leaked one makes the fire-once cases pass on the first run and fail forever.
TMPDIR="$(mktemp -d)"
export TMPDIR

pass=0
fail=0

REPO="$(mktemp -d)"
git -C "$REPO" init -q
mkdir -p "$REPO/app" "$REPO/tests"
: > "$REPO/app/refunds.py"
: > "$REPO/tests/test_refunds.py"
git -C "$REPO" add -A

# A repo that does not test itself. Telling someone to run a suite they do not
# have is a different conversation, and not one a hook should start.
BARE="$(mktemp -d)"
git -C "$BARE" init -q
mkdir -p "$BARE/app"
: > "$BARE/app/refunds.py"
git -C "$BARE" add -A

ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# Record a production write the way Claude Code would: through after-edit.sh.
wrote() {
  local session="$1" cwd="$2" path="${3:-app/refunds.py}"
  python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Write",
    "hook_event_name": "PostToolUse",
    "session_id": sys.argv[1],
    "cwd": sys.argv[2],
    "tool_input": {"file_path": sys.argv[3], "content": "line\n" * 40},
}))' "$session" "$cwd" "$path" | bash "$EDIT_HOOK" >/dev/null 2>&1
}

# Run a Bash command past the recorder.
ran() {
  local session="$1" command="$2"
  python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Bash",
    "hook_event_name": "PostToolUse",
    "session_id": sys.argv[1],
    "cwd": "/repo",
    "tool_input": {"command": sys.argv[2]},
}))' "$session" "$command" | bash "$SESSION_HOOK" 2>/dev/null
}

# Returns the hook's stdout for a Stop event, and fails the case on any non-zero
# exit: this hook blocks with JSON, never with a status.
stop() {
  local session="$1" active="${2:-false}" out status
  out="$(python3 -c '
import json, sys
print(json.dumps({
    "hook_event_name": "Stop",
    "session_id": sys.argv[1],
    "cwd": "/repo",
    "stop_hook_active": sys.argv[2] == "true",
}))' "$session" "$active" | bash "$SESSION_HOOK" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "exited-$status"
    return
  fi
  printf '%s' "$out"
}

# Usage: expect_block <name> <stdout> <expected substring in reason>
expect_block() {
  local name="$1" out="$2" needle="$3" reason
  reason="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("unparseable"); raise SystemExit
# Parsed, not grepped. The reason is the entire point: a block with no reason
# stops the turn and tells the model nothing, which is strictly worse than
# staying quiet.
if data.get("decision") != "block":
    print("decision=" + repr(data.get("decision")))
else:
    print(data.get("reason") or "no-reason")
')"
  case "$reason" in
    *"$needle"*) ok "$name" ;;
    *) bad "$name: expected a block mentioning $needle, got: ${reason:0:120}" ;;
  esac
}

expect_silent() {
  local name="$1" out="$2"
  if [ -z "$out" ]; then ok "$name"; else bad "$name: expected silence, got: ${out:0:120}"; fi
}

echo "asks when nothing ran"

wrote s-basic "$REPO"
expect_block "production code and no test command" "$(stop s-basic)" "app/refunds.py"

wrote s-name "$REPO" "app/ledger.py"
expect_block "names the file it is asking about" "$(stop s-name)" "app/ledger.py"

wrote s-many "$REPO" "app/a_service.py"
wrote s-many "$REPO" "app/b_service.py"
wrote s-many "$REPO" "app/c_service.py"
wrote s-many "$REPO" "app/d_service.py"
expect_block "summarises past three files" "$(stop s-many)" "and 1 more"

echo
echo "stays quiet"

expect_silent "nothing was written" "$(stop s-empty)"

wrote s-ran "$REPO"
ran s-ran "pytest -q"
expect_silent "a test command ran" "$(stop s-ran)"

# The question is whether they ran, not whether they passed. A failing suite is a
# result; an unrun suite is a guess.
wrote s-failed "$REPO"
ran s-failed "pytest -q || true"
expect_silent "a test command ran and failed" "$(stop s-failed)"

wrote s-bare "$BARE"
expect_silent "the repo has no tests at all" "$(stop s-bare)"

wrote s-testfile "$REPO" "tests/test_refunds.py"
expect_silent "only a test file was written" "$(stop s-testfile)"

wrote s-doc "$REPO" "README.md"
expect_silent "only prose was written" "$(stop s-doc)"

# A one-line change is a tweak, and the same threshold that stops the test-first
# check from nagging about it stops this one from asking for a suite run.
python3 -c '
import json, sys
print(json.dumps({"tool_name": "Write", "hook_event_name": "PostToolUse",
                  "session_id": "s-tiny", "cwd": sys.argv[1],
                  "tool_input": {"file_path": "app/tiny.py", "content": "x = 1\n"}}))' \
  "$REPO" | bash "$EDIT_HOOK" >/dev/null 2>&1
expect_silent "a one-line tweak" "$(stop s-tiny)"

echo
echo "cannot loop"

# The one place a bug here traps the user rather than annoying them.
wrote s-active "$REPO"
expect_silent "stop_hook_active is true" "$(stop s-active true)"

wrote s-once "$REPO"
first="$(stop s-once)"
second="$(stop s-once)"
expect_block "first Stop blocks" "$first" "app/refunds.py"
expect_silent "a later Stop in the same session" "$second"

echo
echo "recognises a test runner"

for command in \
  "pytest" \
  "pytest -q tests/" \
  "python3 -m pytest" \
  "python -m unittest discover" \
  "npm test" \
  "npm run test:unit" \
  "yarn test --watch=false" \
  "pnpm run test" \
  "npx jest --ci" \
  "vitest run" \
  "go test ./..." \
  "cargo test" \
  "cargo nextest run" \
  "bundle exec rspec spec/" \
  "rspec" \
  "mvn -q verify test" \
  "./gradlew test" \
  "dotnet test" \
  "swift test" \
  "mix test" \
  "make test" \
  "rake test:units" \
  "ctest --output-on-failure" \
  "vendor/bin/phpunit" \
  "tox -e py311" \
  "bash tests/test-after-edit.sh" \
  "cd /repo && pytest" \
  "ruff check . ; pytest -q"
do
  session="runner-$(printf '%s' "$command" | shasum | cut -c1-8)"
  wrote "$session" "$REPO"
  ran "$session" "$command"
  if [ -z "$(stop "$session")" ]; then
    ok "recognised: $command"
  else
    bad "not recognised as a test run: $command"
  fi
done

echo
echo "does not mistake other commands for a test run"

for command in \
  "git commit -m 'add tests for refunds'" \
  "ls tests/" \
  "cat tests/test_refunds.py" \
  "npm install" \
  "npm run build" \
  "go build ./..." \
  "mkdir -p tests" \
  "git add tests/test_refunds.py"
do
  session="other-$(printf '%s' "$command" | shasum | cut -c1-8)"
  wrote "$session" "$REPO"
  ran "$session" "$command"
  if [ -n "$(stop "$session")" ]; then
    ok "not a test run: $command"
  else
    bad "counted as a test run: $command"
  fi
done

echo
echo "config"

wrote s-off "$REPO"
expect_silent "FOREMAN_TEST_RUN_CHECK=off" "$(FOREMAN_TEST_RUN_CHECK=off stop s-off)"

wrote s-alloff "$REPO"
expect_silent "FOREMAN_OFF=1" "$(FOREMAN_OFF=1 stop s-alloff)"

# Switching it off must not leave the session permanently un-nudgeable: the
# marker is only written when the hook actually speaks.
expect_block "still asks once the switch is removed" "$(stop s-off)" "app/refunds.py"

echo
echo "cleans up and degrades quietly"

end_session() {
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "SessionEnd", "session_id": sys.argv[1], "cwd": "/repo"}))' \
    "$1" | bash "$SESSION_HOOK" >/dev/null 2>&1
}

wrote s-end "$REPO"
# Asserted before the cleanup, so "the directory is gone" cannot pass because the
# fixture never created one.
if [ -d "$TMPDIR/foreman-s-end" ]; then
  ok "SessionEnd: the marker directory exists first"
else
  bad "SessionEnd: no marker directory to clean up, the fixture is wrong"
fi
end_session s-end
if [ -d "$TMPDIR/foreman-s-end" ]; then
  bad "SessionEnd left the marker directory behind"
else
  ok "SessionEnd removes the marker directory"
fi

# Cleanup has to survive the switches, because a session that started with the
# check enabled still has markers to remove.
wrote s-end-off "$REPO"
FOREMAN_OFF=1 end_session s-end-off
if [ -d "$TMPDIR/foreman-s-end-off" ]; then
  bad "SessionEnd skipped cleanup because FOREMAN_OFF was set"
else
  ok "SessionEnd cleans up even when disabled"
fi

expect_silent "no session id" "$(stop "")"

if [ -n "$(printf 'not json' | bash "$SESSION_HOOK" 2>/dev/null)" ]; then
  bad "malformed stdin must stay silent"
else
  ok "malformed stdin stays silent"
fi

if [ -n "$(printf '' | bash "$SESSION_HOOK" 2>/dev/null)" ]; then
  bad "empty stdin must stay silent"
else
  ok "empty stdin stays silent"
fi

# An event this hook is not registered for must not produce anything.
expect_silent "an unknown event" "$(python3 -c '
import json
print(json.dumps({"hook_event_name": "PreCompact", "session_id": "s-weird", "cwd": "/repo"}))' \
  | bash "$SESSION_HOOK" 2>/dev/null)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
