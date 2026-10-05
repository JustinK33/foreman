# Contributing to foreman

Bug reports, false positives and pull requests are all welcome.
A false positive is worth an issue on its own: a hook that blocks legitimate work gets uninstalled, so every one is treated as a bug.

Security issues, including any way past the secrets gate, go through [SECURITY.md](SECURITY.md) instead.

## Running a local checkout

```
/plugin marketplace add /path/to/your/foreman
/plugin install foreman@foreman
```

Pick this or the GitHub source, not both, for the reason in the README's Troubleshooting section.

## Adding a skill

Create `skills/<name>/SKILL.md`.
It is auto-discovered, with no manifest entry needed, and `/foreman:<name>` works from the slash menu on its own.
Do not also add a `commands/<name>.md`; Claude Code lists commands and skills separately, so the name would appear twice.

Every pull request that changes a hook carries a case in the matching `tests/test-*.sh` that fails without the change.

## Development

```bash
bash tests/test-after-edit.sh                       # edit-hook cases, no framework
bash tests/test-comment-style.sh                    # comment-quality cases
bash tests/test-commit-check.sh                     # commit-gate cases
bash tests/test-no-secrets.sh                       # credential-gate cases
bash tests/test-session-tests.sh                    # test-run-check cases
bash tests/test-foreman-state.sh                    # cases on the shared marker module
claude plugin details foreman                       # what got discovered, and its token cost
claude plugin eval . --case tdd-test-before-code    # one case, about a minute, ~$0.20
claude plugin eval                                  # all 42 runs: hours, ~$3, and see below first
```

That 42 is 7 cases, 3 runs each, twice: once with the plugin and once without.
The comparison is the point, so the without-plugin arm is half the bill.

## The evals

Seven cases in `evals/`, one per skill plus two that exist to catch the opposite failure.

| Case | Asserts |
|---|---|
| `tdd-test-before-code` | The test for `remove_item` appears before `remove_item` does |
| `review-severity-order` | SQL injection is named, and style nits do not lead |
| `security-ranks-by-exploitability` | The SSRF is found, not just the obvious hardcoded key |
| `perf-measures-before-optimizing` | The N+1 is diagnosed before anyone reaches for Redis |
| `docs-plain-voice` | No "delve", "seamlessly", "leverage", or "in today's fast-paced world" |
| `no-fire-on-comprehension-question` | "What does this do?" gets an answer, not a red-green-refactor loop |
| `no-fire-on-a-mechanical-rename` | A rename stays a rename, with no test suite or audit bolted on |

The last two matter as much as the first five.
A plugin that fires when you didn't ask is worse than one that stays quiet, and a suite of
only should-fire cases will happily reward a skill that fires at everything.

Each case pairs a judge with at least one mechanical grader, because a judge alone drifts and
a judge alone is also the expensive half of the bill.
Four things about the harness are worth knowing before adding a case, each learned by getting
it wrong first:

- Grader patterns are JavaScript `RegExp`. Inline `(?i)` and `(?s)` throw, so flags belong in `flags:`.
- The sandbox working directory starts empty, so a fixture file committed to the repo is invisible to the agent under test. Fixture code is inlined into each `prompt.md` instead.
- A `not_contains` grader passes against an empty response, so no case is built only from negations.
- A fixture must not describe its own defects. `review-severity-order` originally listed them in a docstring, which graded the agent on reading an answer key.

CI checks all four, so a case that violates one fails before it ever costs a run.

Work one case at a time with `--case`.
That is the supported way to use this suite, not a workaround for it.
The full run is 42 agent runs issued serially, and a burst that long draws API stalling. One full
run was measured, and it is worth being concrete about how badly it went: 24 of the 42 runs errored,
every one of them with `timed out after 300s`, over four and a half hours and $2.86.
Cases set `timeout_seconds: 600` because a few legitimately need longer than the 300 default, not
because a higher ceiling prevents the stalling. It does not.

The ceiling is also not reliably applied. Every case declares 600, but that run's failures all read
`timed out after 300s`, the harness default, while a later single-case run did honor 600.
So a timeout in a full run tells you even less than a timeout in a `--case` run does.

Which means a red score is not automatically a regression, and that distinction is not guessable.
Open `evals/results/<stamp>/aggregate-result.json` and look at the runs before believing any score:

- `turns: 0`, or a `durationSeconds` well past the case's limit, is a stalled run. It did no work and says nothing about the plugin. The worst one observed spent 1075 seconds to complete zero turns.
- A real failure has a healthy turn count and a duration inside the limit. For scale, healthy runs here finish in 9 to 77 seconds.
- A stall can read as a *pass* just as easily. A `not_contains` grader is satisfied by the empty response a stalled run returns.

That measured run is the worked example. Read at face value it says foreman makes documentation
worse: `docs-plain-voice` scored 0.50 with the plugin against 0.83 without, a 0.33 regression.
It says nothing of the kind. All three with-plugin runs stalled, at 1035, 1075 and 915 seconds
with 1, 0 and 0 turns, and the graders scored empty responses: `evidence: ""`, and the
`not_contains` grader passing on nothing, which is what floors the score at 0.50 instead of 0.
The skill was never given a chance to do better or worse than the baseline.

Two other cases, `tdd-test-before-code` and `security-ranks-by-exploitability`, produced zero usable
runs in *either* arm. Only 18 of the 42 runs came back clean, spread so thinly that no case in that
run has enough of both arms to compare. The honest summary of the only full run to date is that it
measured the API's queueing behaviour, not the plugin.

That run is committed, trimmed, as `evals/reference-run.json`, because `evals/results/` is gitignored
and otherwise none of the advice above has anything to point at.

Every case in `tests/` either caught a real bug or guards one that was fixed:

- A 2 MB write that used to abort the hook with `exit 126` by blowing `ARG_MAX`, because the payload went through argv instead of stdin.
- A `MultiEdit` batch that slipped through a `Write|Edit` matcher.
- A 300 KB single-line file that a line count scored as one line.
- A scratch file in `/tmp` being judged against the tests of whatever repo you happened to be in.
- `latest.py` being miscounted as a test file, which would make an untested repo look tested.
- A dedupe marker that leaked across runs, so the dedupe cases passed once and then failed forever.
- The scope check firing on any long file, including the README, because it had no file-type filter at all. It was caught by foreman nudging about a 138-line markdown document.
- A repo whose tests all live in one file being told every source file was untested, because matching only ever compared filenames.
- `after_edit.py` reported as untested while `test-after-edit.sh` was testing it, because a hyphen is not an underscore.
- A `\k<quote>` backreference, which is JavaScript and not Python. It raised at import, the shim exited 0 as designed, and so the credential gate silently did not exist. Every deny case "passed" by comparing two empty strings.
- A deny assertion that grepped for `"permissionDecision":"deny"` while `json.dump` writes a space after the colon. The suite now parses the JSON, so formatting cannot read as a pass.
- `DB_PASSWORD` sailing past the credential gate, because `\b` does not match between `_` and `p`.
- The test-run check asking about files in a repo with no test suite, and asking twice in one session.
- A markdown heading inside a triple-quoted string read as a banner comment, so every prompt template and fixture blob got reviewed as though its headings were code comments.
- `# Loop through the items` sailing past the comment check, the single most textbook rule-1 comment there is, because `through` was not on the stopword list and so read as information the code did not carry.
- A commit subject of exactly 50 characters. The boundary case in the suite was 49, so an off-by-one on the limit survived mutation testing until both 50 and 51 were pinned.

Each hook is a Python module with a shell shim beside it: `hooks/after_edit.py` behind
`hooks/after-edit.sh`, and so on. The logic used to be one single-quoted Python string inside the
shell script, which meant an apostrophe needed a `\x27` escape and no linter could see any of it.
`hooks/foreman_state.py` is shared, because the hook that records a production write and the hook
that reads it on `Stop` have to agree on a directory name, and if they drift nothing errors: the
check just silently stops happening.

`ruff.toml` pins the rule set rather than taking the installed version's defaults, because CI
installs the newest ruff on every run and a release would otherwise turn the repo red with nothing
in it having changed.

CI additionally refuses a dangling reference to a skill or hook script that does not exist, which is how v0.1.0 shipped two skills still pointing at a `lean` helper that had been deleted.
