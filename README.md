# foreman

[![ci](https://github.com/JustinK33/foreman/actions/workflows/ci.yml/badge.svg)](https://github.com/JustinK33/foreman/actions/workflows/ci.yml)

A tight senior-engineer toolkit for Claude Code.
Five skills for when you ask, and one hook for when you don't.

Most plugins are a pile of skills, which means they only help when your wording happens to match a description.
The hook is the part that works whether or not you remember to invoke anything.

## The hook

`after-edit` runs on `PostToolUse` for `Write`, `Edit`, and `MultiEdit`, and makes two independent checks.
It nudges; it never blocks.

**Scope.** Trips at 80 lines or 50 KB added in one change, so minified and generated files can't slip past a line count.

**Test-first.** Trips when production code lands and no test in the repo names that file:

```
[foreman] src/billing/refunds.py just gained 62 lines of production code and this
repo has tests, but none of them name this file. Write the test that would have
failed before this change, watch it fail, then confirm it passes now. If the file
genuinely is not unit-testable (wiring, config, a thin adapter over a library),
say that in one line and move on.
```

This is the part a skill cannot do.
A skill fires on description match or an explicit `/tdd`, so if you never say the word "test", nothing intervenes while a few hundred untested lines get written.
The skill is *how* to do TDD; the hook is *did you*.

It is built to stay quiet, because a nudge you learn to ignore is worse than no nudge:

- Silent in a repo with no tests at all. That's a different conversation, and not one a hook should start.
- Silent outside a git repo, and silent for paths outside the repo you're working in.
- Silent for `tests/`, `spec/`, `__tests__/`, `*_test.go`, `FooTest.java` and friends, so writing the test is never flagged for lacking a test.
- Silent for `node_modules`, `vendor`, `dist`, `build`, `migrations`, `generated`, `*.d.ts`, `*.min.*`.
- Silent under 10 changed lines. A tweak is not a missing test.
- One nudge per file per session. Repetition just trains the model to tune it out.

## The skills

| Command | Skill | What it does |
|---|---|---|
| `/tdd` | `tdd` | Strict red-green-refactor loop, no production code ahead of a test |
| `/review` | `review` | Correctness, then tests, security, design, readability, perf, in that order |
| `/security` | `security` | Vulnerability scan by exploit frequency, front end and back end |
| `/perf` | `perf` | Measure first, then N+1 queries and missing indexes before anything clever |
| `/docs` | `docs` | READMEs, API docs, ADRs, runbooks, in a human voice |

Each also auto-triggers without the slash command when its `description` matches what you asked for.

## Install

```
/plugin marketplace add JustinK33/foreman
/plugin install foreman@foreman
```

From a local checkout instead:

```
/plugin marketplace add ~/Projects/foreman
/plugin install foreman@foreman
```

Send those as two separate prompts, then restart the session so the hook registers.
Skills and commands hot-reload; hooks do not.

`after-edit` needs `bash` and `python3` on PATH, and uses `git` when available.
If any of them is missing it exits quietly rather than erroring.

## Configuring

Every knob is an environment variable, because editing the script in place gets overwritten the next time the plugin updates.

| Variable | Default | Effect |
|---|---|---|
| `FOREMAN_LINE_THRESHOLD` | `80` | Lines added before the scope check speaks up |
| `FOREMAN_BYTE_THRESHOLD` | `50000` | Bytes added before the scope check speaks up |
| `FOREMAN_TEST_FIRST_MIN_LINES` | `10` | Lines added before a missing test is worth mentioning |
| `FOREMAN_SCOPE_CHECK` | on | Set to `off` to disable the scope check |
| `FOREMAN_TEST_FIRST` | on | Set to `off` to disable the test-first check |

Also worth knowing:

- **How eagerly a skill fires**: the `description` in its `SKILL.md` frontmatter is the entire matching surface. Tighten it to fire less, add trigger phrases to fire more.
- **Adding a skill**: create `skills/<name>/SKILL.md`, and `commands/<name>.md` if you want a slash command. Both are auto-discovered, no manifest entry needed. Commands must be `.md`; Claude Code does not read `.toml`.

## Uninstall

```
/plugin uninstall foreman@foreman
```

## Why only five skills

Each one covers a distinct phase of shipping: test it, review it, secure it, make it fast, document it.
That is deliberately the whole list.

Every skill's `name` and `description` is loaded into every session, while its body only loads when the skill fires.
So the cost of a skill you never invoke is paid on every single prompt, forever.
A plugin with thirty skills is a plugin whose descriptions are a coin flip to match, which is how you end up with a toolbox nobody reaches into.

There is deliberately no lean-build or anti-over-engineering skill here.
[ponytail](https://github.com/DietrichGebert/ponytail) already does that as an always-on hook, and running two overlapping rulesets costs double the tokens to say the same thing twice.
What survived from that idea lives in `skills/review/SKILL.md` under "cuts that are never acceptable": validation, error handling, security checks, and accessibility are never what you trade away to make a diff smaller.

## Development

```bash
bash tests/test-after-edit.sh                       # 25 hook cases, no framework
claude plugin details foreman                       # what got discovered, and its token cost
claude plugin eval . --case tdd-test-before-code    # one case, about a minute, ~$0.20
claude plugin eval                                  # all 42 runs: hours, ~$3, and see below first
```

### The evals

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
The full run is 42 agent runs issued serially, and a burst that long draws API stalling: in one
measured run, 15 of the 42 stalled, and the whole thing took four and a half hours to produce
$2.86 of mostly nothing. Cases set `timeout_seconds: 600` because a few legitimately need longer
than the 300 default, not because a higher ceiling prevents the stalling. It does not.

Which means a red score is not automatically a regression, and that distinction is not guessable.
Open `evals/results/<stamp>/aggregate-result.json` and look at the run before believing it:

- `turns: 0`, or a `durationSeconds` well past the case's limit, is a stalled run. It did no work and says nothing about the plugin. The worst one observed spent 1075 seconds to complete zero turns.
- A real failure has a healthy turn count and a duration inside the limit. For scale, healthy runs here finish in 9 to 77 seconds.
- A stall can read as a *pass* just as easily. A `not_contains` grader is satisfied by the empty response a stalled run returns.

Every case in `tests/test-after-edit.sh` either caught a real bug or guards one that was fixed:

- A 2 MB write that used to abort the hook with `exit 126` by blowing `ARG_MAX`, because the payload went through argv instead of stdin.
- A `MultiEdit` batch that slipped through a `Write|Edit` matcher.
- A 300 KB single-line file that a line count scored as one line.
- A scratch file in `/tmp` being judged against the tests of whatever repo you happened to be in.
- `latest.py` being miscounted as a test file, which would make an untested repo look tested.
- A dedupe marker that leaked across runs, so the dedupe cases passed once and then failed forever.

CI additionally refuses a dangling reference to a skill or hook script that does not exist, which is how v0.1.0 shipped two skills still pointing at a `lean` helper that had been deleted.

## License

MIT
