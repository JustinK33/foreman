"""Did the tests ever actually run?

The test-first check in after_edit.py knows whether a test *exists* for a file.
It cannot know whether anyone *ran* one, because that happens in a Bash call it
never sees. This hook closes that gap across three events:

    PostToolUse (Bash)  a test runner was invoked, so record it
    Stop                production code landed, nothing ran, so say so once
    SessionEnd          throw the session's markers away

"Did you run them" is the question, not "did they pass". A failing suite is a
result; an unrun suite is a guess.

Never exits non-zero. Stop blocks by returning {"decision": "block"} with a
reason, which is verified to reach the model, so blocking never needs exit 2.
"""

import json
import os
import re
import sys

import foreman_state

RAN = "tests-ran"
NUDGED = "asked-to-run-tests"
# How many filenames to name before summarising. Enough to be concrete, few
# enough that the ask does not turn into a wall of paths.
NAMED = 3

# Recognising a test invocation. Breadth matters more than precision here: an
# unrecognised runner means nudging someone who did run their tests, which is
# the one outcome that gets a hook uninstalled. A false match only makes this
# quiet, so `grep pytest foo.py` counting as a test run is the acceptable half
# of being wrong.
TEST_COMMAND = re.compile(
    r"""(?ix)
    (?: ^ | [;&|(`] | \s )                      # a command start, not mid-word
    (?:
        (?: python[\d.]* \s+ -m \s+ )? (?: pytest | unittest | nose2 | tox | nox ) \b
      | py\.test \b
      | (?: npx \s+ | yarn \s+ | pnpm \s+ (?:run\s+)? | bunx \s+ )?
        (?: jest | vitest | mocha | jasmine | karma | ava | cypress | playwright ) \b
      | (?: npm | yarn | pnpm | bun | deno ) \s+ (?:run\s+)? test \b
      | go \s+ test \b
      | gotestsum \b
      | cargo \s+ (?: test | nextest ) \b
      | (?: bundle \s+ exec \s+ )? rspec \b
      | rails \s+ test \b
      | (?: mvn | gradle | \./gradlew ) \s+ (?:\S+\s+)* test \b
      | dotnet \s+ test \b
      | swift \s+ test \b
      | (?: vendor/bin/ | \./ )? phpunit \b
      | mix \s+ test \b
      | ctest \b
      | (?: make | rake | just ) \s+ \S*test
      # A frameworkless shell suite, which is what this repo's own tests are.
      | (?: bash | sh | zsh ) \s+ \S*test\S*\.sh
    )
    """
)


def env_off(name):
    return os.environ.get(name, "").strip().lower() in ("0", "off", "false", "no")


def stop(data, session):
    # Two dedupe guards, for two different situations. stop_hook_active covers
    # the immediate re-entry after this hook blocks, which is the case where a
    # bug would trap the user in a loop rather than merely annoy them. The marker
    # covers every later Stop in the session, where stop_hook_active is False
    # again because the user has since sent another prompt.
    if data.get("stop_hook_active"):
        return
    if foreman_state.marked(session, RAN) or foreman_state.marked(session, NUDGED):
        return

    written = [path for path in foreman_state.marks(session, "wrote-") if path]
    if not written:
        return

    foreman_state.mark(session, NUDGED)
    shown = ", ".join(sorted(written)[:NAMED])
    if len(written) > NAMED:
        shown += f", and {len(written) - NAMED} more"

    json.dump(
        {
            "decision": "block",
            "reason": (
                f"[foreman] Production code changed this session ({shown}) and no test "
                "command ran. Run the suite before finishing, and say in one line whether "
                "it passed. If the suite cannot run in this environment, or nothing that "
                "changed is testable, say which and stop."
            ),
        },
        sys.stdout,
    )


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return

    session = data.get("session_id", "")
    event = data.get("hook_event_name", "")

    # Cleanup runs regardless of the switches. Leaving scratch directories behind
    # is the bug this event is here to fix, and a disabled check still has to
    # tidy up after a session that started with it enabled.
    if event == "SessionEnd":
        foreman_state.clear(session)
        return

    if os.environ.get("FOREMAN_OFF", "").strip() or env_off("FOREMAN_TEST_RUN_CHECK"):
        return

    if event == "Stop":
        stop(data, session)
        return

    if data.get("tool_name") == "Bash":
        command = (data.get("tool_input") or {}).get("command") or ""
        if TEST_COMMAND.search(command):
            foreman_state.mark(session, RAN)


main()
