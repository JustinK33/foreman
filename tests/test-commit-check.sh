#!/usr/bin/env bash
# Driven through the shim, not the module, because this hook decides whether a
# command runs at all: the deny has to come back as PreToolUse JSON in the exact
# shape Claude Code acts on, and exit 0 has to hold even when it is denying.
#
# The staged-file cases need a real index, so each uses its own git fixture.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/commit-check.sh"

# Per-session markers live under TMPDIR. A fresh one per run keeps the
# once-per-session cases from passing once and failing forever after.
TMPDIR="$(mktemp -d)"
export TMPDIR

pass=0
fail=0

# Every case names a session, so the two once-per-session findings cannot leak
# between cases. Most cases are about the message or the contents, so they share
# a session that has already had both process findings raised against it.
QUIET="primed"

prime() {
  python3 - "$ROOT/hooks" "$1" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import foreman_state

foreman_state.mark(sys.argv[2], "asked-to-test-before-commit")
foreman_state.mark(sys.argv[2], "asked-to-read-the-diff")
PY
}

payload() {
  python3 -c '
import json, os, sys
data = {
    "hook_event_name": "PreToolUse",
    "tool_name": sys.argv[1],
    "session_id": sys.argv[2],
    "cwd": sys.argv[3],
    "tool_input": {"command": sys.argv[4]},
}
# Set TRANSCRIPT to hand the hook a transcript_path, as Claude Code does.
if os.environ.get("TRANSCRIPT"):
    data["transcript_path"] = os.environ["TRANSCRIPT"]
print(json.dumps(data))' "$@"
}

# Usage: expect_deny <name> <substring> [session] [cwd] <command>
expect_deny() {
  local name="$1" want="$2" session="$3" cwd="$4" command="$5" out status
  out="$(payload Bash "$session" "$cwd" "$command" | bash "$HOOK" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "  FAIL  $name: hook exited $status, must always exit 0"
    fail=$((fail + 1))
    return
  fi
  # Parsed, not grepped: a deny that is the wrong shape does not deny anything.
  if ! printf '%s' "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["hookEventName"] == "PreToolUse", data
assert data["permissionDecision"] == "deny", data
sys.exit(0 if sys.argv[1] in data["permissionDecisionReason"] else 1)' "$want" 2>/dev/null; then
    echo "  FAIL  $name: no deny carrying '$want', got: ${out:0:160}"
    fail=$((fail + 1))
    return
  fi
  echo "  ok    $name"
  pass=$((pass + 1))
}

# Usage: expect_allow <name> [session] [cwd] <command>
expect_allow() {
  local name="$1" session="$2" cwd="$3" command="$4" out status
  out="$(payload Bash "$session" "$cwd" "$command" | bash "$HOOK" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "  FAIL  $name: hook exited $status, must always exit 0"
    fail=$((fail + 1))
    return
  fi
  if [ -n "$out" ]; then
    echo "  FAIL  $name: expected silence, got: ${out:0:160}"
    fail=$((fail + 1))
    return
  fi
  echo "  ok    $name"
  pass=$((pass + 1))
}

# A repo with one staged source file: enough for the content checks to have a
# "logic" side without tripping anything on its own.
new_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  printf 'x = 1\n' > "$dir/app.py"
  git -C "$dir" add app.py
  printf '%s' "$dir"
}

CODE_REPO="$(new_repo)"
# A repo whose staged contents alone are enough to deny, used by the cases that
# have to prove an exemption rather than the absence of a finding.
MIXED_DEPS_EARLY="$(new_repo)"
printf '{"dependencies":{"x":"2.0.0"}}\n' > "$MIXED_DEPS_EARLY/package.json"
git -C "$MIXED_DEPS_EARLY" add package.json
prime "$QUIET"

echo "the subject line"

expect_deny "over the 50 character limit" "over the 50" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: rework the retry path so that it no longer loses the final batch"'
# Exactly 50, so the boundary is pinned rather than approximately right.
expect_allow "at exactly 50 characters" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: keep the final batch after the retry gives up"'
expect_deny "at 51" "over the 50" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: keep every final batch when the retry gives up"'

expect_deny "past tense" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit -m "Added a retry to the uploader"'
expect_deny "past tense behind a conventional prefix" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: updated the uploader"'
expect_allow "the imperative" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: retry the uploader once"'

expect_deny "a placeholder subject" "nothing about what" "$QUIET" "$CODE_REPO" \
  'git commit -m "wip"'
# A subject can be several words and still say nothing.
expect_deny "several vacuous words" "nothing about what" "$QUIET" "$CODE_REPO" \
  'git commit -m "more stuff"'
expect_deny "minor fixes" "nothing about what" "$QUIET" "$CODE_REPO" \
  'git commit -m "minor fixes"'
expect_deny "a bare conventional prefix" "nothing about what" "$QUIET" "$CODE_REPO" \
  'git commit -m "chore: cleanup"'
# Function words cannot rescue it either: this still does not say what was fixed.
expect_deny "vacuous words strung together" "nothing about what" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix up the tests"'
# But one real word makes it a description, which is where the line has to be:
# "fix" alone says nothing, "fix the retry" says which thing.
expect_allow "one real word is enough" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix the retry"'
expect_allow "clean up something specific" "$QUIET" "$CODE_REPO" \
  'git commit -m "clean up the imports"'

# The example the practice is always explained with.
expect_deny "two changes joined by and" "two changes" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix the login bug and optimize the query"'
# But "and" between two nouns is one change described properly.
expect_allow "and between two nouns" "$QUIET" "$CODE_REPO" \
  'git commit -m "handle null and empty batches"'

expect_deny "a trailing period" "does not need the period" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: retry the uploader once."'

echo
echo "how the message is passed"

# The heredoc form is the one Claude Code itself is told to use, so a hook that
# cannot read it checks nothing in practice.
#
# shellcheck disable=SC2016
# Not expanding is the point: the hook is handed the command as text, exactly as
# the payload would carry it, so $(cat <<EOF ...) has to arrive unevaluated.
expect_deny "a heredoc subject" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit -m "$(cat <<'"'"'EOF'"'"'
Added a retry to the uploader

With a body that is not the subject.
EOF
)"'
# shellcheck disable=SC2016
expect_allow "a heredoc with a good subject" "$QUIET" "$CODE_REPO" \
  'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: retry the uploader once

Added, in the body, where past tense is prose and not a subject.
EOF
)"'

expect_deny "the bundled -am form" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit -am "Added a retry"'
expect_deny "--message=" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit --message="Added a retry"'
expect_deny "a commit later in the line" "past tense" "$QUIET" "$CODE_REPO" \
  'git add -A && git commit -m "Added a retry"'

# No message on the command line means git opens an editor, and what happens in
# there is not something a PreToolUse hook can see or should guess at.
expect_allow "no message means an editor" "$QUIET" "$CODE_REPO" 'git commit'
expect_allow "-F reads a file this hook will not open" "$QUIET" "$CODE_REPO" \
  'git commit -F .git/COMMIT_MSG'
# --amend --no-edit and a rebase's own commits reuse a message that was already
# judged. Checked against a repo that would otherwise trip the content findings,
# so the exemption is what makes these pass.
expect_allow "--amend --no-edit keeps the old message" "$QUIET" "$MIXED_DEPS_EARLY" \
  'git commit --amend --no-edit'
expect_allow "a rebase continuing is not a new message" "$QUIET" "$MIXED_DEPS_EARLY" \
  'git rebase --continue'

echo
echo "not a commit at all"

expect_allow "git status" "$QUIET" "$CODE_REPO" 'git status'
expect_allow "git log" "$QUIET" "$CODE_REPO" 'git log --oneline -5'
# "commit" as a word in some other command must not arm the check.
expect_allow "git log --grep commit" "$QUIET" "$CODE_REPO" 'git log --grep="commit"'
expect_allow "a message about committing" "$QUIET" "$CODE_REPO" 'echo "ready to commit"'
expect_allow "pre-commit run" "$QUIET" "$CODE_REPO" 'pre-commit run --all-files'
expect_allow "an unrelated command" "$QUIET" "$CODE_REPO" 'ls -la'
# On a session with nothing marked yet, so the process findings would fire if
# this hook judged commands other than commits. It runs before every Bash call.
expect_allow "an unrelated command on a fresh session" fresh-session "$CODE_REPO" 'ls -la'
expect_allow "a git command that is not a commit" fresh-session-2 "$CODE_REPO" 'git branch -a'

# The hook runs before every Bash call in the session, so degrading has to be
# silent rather than loud.
expect_allow "malformed stdin" "$QUIET" "$CODE_REPO" ''
if printf 'not json' | bash "$HOOK" >/dev/null 2>&1; then
  echo "  ok    non-JSON stdin exits 0"
  pass=$((pass + 1))
else
  echo "  FAIL  non-JSON stdin did not exit 0"
  fail=$((fail + 1))
fi
out="$(payload Write "$QUIET" "$CODE_REPO" 'git commit -m "wip"' | bash "$HOOK" 2>/dev/null)"
if [ -z "$out" ]; then
  echo "  ok    a non-Bash tool is ignored"
  pass=$((pass + 1))
else
  echo "  FAIL  a non-Bash tool was not ignored"
  fail=$((fail + 1))
fi

echo
echo "what is in the commit"

MIXED_DEPS="$(new_repo)"
printf '{"dependencies":{"x":"2.0.0"}}\n' > "$MIXED_DEPS/package.json"
git -C "$MIXED_DEPS" add package.json
expect_deny "dependencies mixed with code" "changes dependencies" "$QUIET" "$MIXED_DEPS" \
  'git commit -m "fix: retry once"'

DEPS_ONLY="$(mktemp -d)"
git -C "$DEPS_ONLY" init -q
printf '{"dependencies":{"x":"2.0.0"}}\n' > "$DEPS_ONLY/package.json"
printf '{}\n' > "$DEPS_ONLY/package-lock.json"
git -C "$DEPS_ONLY" add -A
# A commit that is only the upgrade is the focused commit being asked for.
expect_allow "a dependency bump on its own" "$QUIET" "$DEPS_ONLY" \
  'git commit -m "build: bump x to 2.0.0"'

MIXED_FORMAT="$(new_repo)"
printf '[lint]\n' > "$MIXED_FORMAT/ruff.toml"
git -C "$MIXED_FORMAT" add ruff.toml
expect_deny "a linter config mixed with code" "formatter configuration" "$QUIET" \
  "$MIXED_FORMAT" 'git commit -m "fix: retry once"'

WITH_DOCS="$(new_repo)"
printf '# Notes\n' > "$WITH_DOCS/README.md"
git -C "$WITH_DOCS" add README.md
# Documentation travelling with the code it documents is good practice.
expect_allow "docs alongside code" "$QUIET" "$WITH_DOCS" 'git commit -m "fix: retry once"'

DOCS_AND_DEPS="$(mktemp -d)"
git -C "$DOCS_AND_DEPS" init -q
printf '{"dependencies":{"x":"2.0.0"}}\n' > "$DOCS_AND_DEPS/package.json"
printf '# Notes\n' > "$DOCS_AND_DEPS/CHANGELOG.md"
git -C "$DOCS_AND_DEPS" add -A
# Prose is neither the logic nor the noise, so an upgrade plus its changelog
# entry is still one focused commit and must not read as a mix.
expect_allow "docs alongside a dependency bump" "$QUIET" "$DOCS_AND_DEPS" \
  'git commit -m "build: bump x to 2.0.0"'

# -a stages the working tree on the way past, so that is what has to be judged.
SWEPT="$(new_repo)"
git -C "$SWEPT" commit -q -m "init"
printf '{"dependencies":{"x":"2.0.0"}}\n' > "$SWEPT/package.json"
printf 'x = 2\n' > "$SWEPT/app.py"
git -C "$SWEPT" add package.json
git -C "$SWEPT" reset -q package.json
git -C "$SWEPT" add -N package.json
expect_deny "-a sweeps the working tree into the judgement" "changes dependencies" "$QUIET" \
  "$SWEPT" 'git commit -am "fix: retry once"'

# Not a git repo, or git missing: nothing to say, so say nothing.
expect_allow "outside a repo" "$QUIET" "$(mktemp -d)" 'git commit -m "fix: retry once"'

echo
echo "the process around the commit"

# after_edit.py writes the wrote- markers and session_tests.py writes tests-ran.
# Planting them here would let this pass even if those names had drifted apart,
# so both real hooks are driven instead.
wrote() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name":"Write","session_id":sys.argv[1],"cwd":sys.argv[2],
                  "tool_input":{"file_path":"app.py","content":"x\n"*40}}))' "$1" "$2" \
    | bash "$(dirname "$HOOK")/after-edit.sh" >/dev/null 2>&1
}
ran_tests() {
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":sys.argv[1],
                  "tool_input":{"command":"pytest -q"}}))' "$1" \
    | bash "$(dirname "$HOOK")/session-tests.sh" >/dev/null 2>&1
}

TEST_REPO="$(new_repo)"
mkdir -p "$TEST_REPO/tests"
printf 'def test_x():\n    assert True\n' > "$TEST_REPO/tests/test_app.py"
git -C "$TEST_REPO" add -A

# Code changed, no suite run: the practice is that a commit records a state
# somebody checked.
wrote untested "$TEST_REPO"
expect_deny "no test ran this session" "No test command has run" untested "$TEST_REPO" \
  'git commit -m "fix: retry once"'
# And then it trusts you, because in some sandboxes the suite cannot run and a
# hook that repeats an impossible demand forever is one you uninstall.
expect_allow "and it only says so once" untested "$TEST_REPO" \
  'git commit -m "fix: retry once"'

wrote tested "$TEST_REPO"
ran_tests tested
prime tested   # so only the test finding could speak
expect_allow "silent once a runner has gone by" tested "$TEST_REPO" \
  'git commit -m "fix: retry once"'

# Nothing written this session means nothing to have tested. The review finding
# is taken out of the way with a real git status, which is how it happens.
payload Bash nothing-written "$TEST_REPO" 'git status' | bash "$HOOK" >/dev/null 2>&1
expect_allow "silent when no code changed" nothing-written "$TEST_REPO" \
  'git commit -m "docs: fix a typo"'

expect_deny "nobody read the diff" "git status or git diff" unreviewed "$TEST_REPO" \
  'git commit -m "docs: fix a typo"'
expect_allow "and it only says so once" unreviewed "$TEST_REPO" \
  'git commit -m "docs: fix a typo"'

# The marker is written by this same hook seeing the review go past.
payload Bash reviewed "$TEST_REPO" 'git status' | bash "$HOOK" >/dev/null 2>&1
expect_allow "silent after a git status" reviewed "$TEST_REPO" \
  'git commit -m "docs: fix a typo"'

payload Bash diffed "$TEST_REPO" 'git diff --cached' | bash "$HOOK" >/dev/null 2>&1
expect_allow "silent after a git diff" diffed "$TEST_REPO" \
  'git commit -m "docs: fix a typo"'

echo
echo "more than one thing wrong"

out="$(payload Bash multi "$CODE_REPO" 'git commit -m "Added the retry and optimized the query."' \
  | bash "$HOOK" 2>/dev/null)"
count="$(printf '%s' "$out" | python3 -c '
import json, re, sys
reason = json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"]
print(len(re.findall(r"\(\d+\)", reason)))' 2>/dev/null)"
# Past tense, two changes, a trailing period, and the unread diff: four, in one
# deny, numbered, so a single retry can fix all of them instead of four rounds.
if [ "$count" = 4 ]; then
  echo "  ok    every finding arrives in one numbered deny"
  pass=$((pass + 1))
else
  echo "  FAIL  every finding arrives in one numbered deny: numbered $count, wanted 4"
  fail=$((fail + 1))
fi

echo
echo "a subject the user dictated"

# One entry per way a long subject can reach the transcript. Only the first two
# are the user talking; a tool result and the agent's own words are not.
TRANSCRIPT_FILE="$TMPDIR/transcript.jsonl"
cat > "$TRANSCRIPT_FILE" <<'JSONL'
{"type":"user","message":{"role":"user","content":"commit it as \"fix: rework the retry path so that it no longer loses the final batch\" please"}}
not json, which a transcript can end with mid-write
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"use Fix:   Keep every final batch when the retry gives up, as the message"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"fix: stop the uploader from dropping the batch on retry"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fix: make the uploader keep the batch across every retry"}]}}
{"type":"user","message":{"role":"user","content":"commit with: fixed the retry path so that it no longer loses the final batch"}}
JSONL
export TRANSCRIPT="$TRANSCRIPT_FILE"

expect_allow "a long subject the user typed" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: rework the retry path so that it no longer loses the final batch"'
expect_allow "in a text block, matched ignoring case and spacing" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: keep every final batch when the retry gives up"'
expect_deny "a long subject only a tool result contained" "over the 50" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: stop the uploader from dropping the batch on retry"'
expect_deny "a long subject only the agent wrote" "over the 50" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: make the uploader keep the batch across every retry"'
expect_deny "dictated waives the length, not the tense" "past tense" "$QUIET" "$CODE_REPO" \
  'git commit -m "fixed the retry path so that it no longer loses the final batch"'
TRANSCRIPT="$TMPDIR/no-such-transcript.jsonl" \
  expect_deny "an unreadable transcript keeps the limit" "over the 50" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: rework the retry path so that it no longer loses the final batch"'
unset TRANSCRIPT

echo
echo "config"

FOREMAN_COMMIT_CHECK=off \
  expect_allow "FOREMAN_COMMIT_CHECK=off silences it" off-switch "$CODE_REPO" \
  'git commit -m "wip"'
FOREMAN_OFF=1 \
  expect_allow "FOREMAN_OFF silences it too" off-switch-2 "$CODE_REPO" \
  'git commit -m "wip"'
FOREMAN_SUBJECT_MAX=72 \
  expect_allow "FOREMAN_SUBJECT_MAX raises the limit" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: rework the retry path so it stops losing the batch"'
FOREMAN_SUBJECT_MAX=20 \
  expect_deny "and lowers it" "over the 20" "$QUIET" "$CODE_REPO" \
  'git commit -m "fix: retry the uploader once"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
