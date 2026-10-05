<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" width="96" alt="foreman">
  </picture>
</p>

<h3 align="center">Your agent leaks secrets, skips tests, and commits "wip". Foreman says no.</h3>

<p align="center">
  <a href="#install">Install</a> · <a href="#what-it-catches">What it catches</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/JustinK33/foreman/issues">Issues</a>
</p>

<p align="center">
  <a href="https://github.com/JustinK33/foreman/actions/workflows/ci.yml"><img src="https://github.com/JustinK33/foreman/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FJustinK33%2Fforeman%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version&color=blue" alt="version">
  <img src="https://img.shields.io/badge/Claude%20Code-plugin-d97757" alt="Claude Code plugin">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

<p align="center">
  <img src="assets/demo.gif" width="900" alt="Claude tries to hardcode a live Stripe key and foreman refuses the write, then foreman refuses the commit &quot;fixed stuff and updated deps&quot; and Claude splits it into two clean commits">
</p>

---

## About

foreman is a set of guardrails for Claude Code.
Four hooks run on every write and every commit, whether or not you remember to ask, and five skills cover testing, review, security, performance and docs when you do.

Most plugins are a pile of skills, which means they only help when your wording happens to match a description.
The hooks are the part that works when you are not watching: they refuse the two mistakes you cannot cleanly undo, a credential on disk and a bad commit in history, and nudge on the rest.
Every one of them is tuned to stay quiet, because a check you learn to ignore is worse than no check.

## What it catches

| The habit | Without foreman | With foreman |
|---|---|---|
| Pasting a live API key into `config.py` | The key is on disk, then in git, then it has to be rotated | The write is refused and Claude rewrites it to read an environment variable |
| `git commit -m "fixed stuff and updated deps"` | A commit nobody can review, revert or bisect | The commit is refused with a numbered list of what to fix, and Claude retries |
| Three hundred lines of code with no test | You find out in review, or in production | A nudge to write the test that would have failed, the moment the code lands |
| "Done!" without ever running the suite | You find out when CI goes red | The turn does not end until the suite has run or Claude says why it cannot |
| `# Loop through the items` | Comments that read as machine-written | A nudge to keep the why and delete the rest |


## Install

```
/plugin marketplace add JustinK33/foreman
/plugin install foreman@foreman
```

Send those as two separate prompts, then restart the session so the hooks register.
Skills hot-reload; hooks do not.

### Check it worked

Type `/foreman:` and you should see five entries.

Then watch the hooks fire, which takes about a minute because they are deterministic.
In a repo that already has tests somewhere, ask for a new source file of a hundred or so lines,
and tell it not to run anything.
Two checks speak up at once, one about the size and one about the missing test, and then a third
stops the turn from ending to ask whether you ran the suite.

If the menu is empty, you skipped the restart. If the menu is there but the hooks never speak,
see Troubleshooting.

### Requirements

- Claude Code 2.1 or newer. Plugin marketplaces, slash-invocable skills, and the
  `additionalContext` field the edit hook writes to are all version-gated.
  The `Stop` block form is verified against 2.1.278, and `PostToolUseFailure` against 2.1.289.
- `bash` and `python3` (or `python`) on PATH. `git` is used when available.
  If any is missing the hooks exit quietly rather than erroring.
- On Windows, Git Bash or WSL. The hooks have a PowerShell entry point, but it shells out to `bash`.

## The secrets gate

`no-secrets` runs on `PreToolUse` for `Write`, `Edit`, and `MultiEdit`, and refuses the write when it
contains something that looks like a live credential. It is the one check here that blocks, because a
nudge about a secret arrives after the secret is on disk, and by then the advice is worthless: the
value has to be rotated, not moved.

Claude gets told why, so it rewrites the line to read an environment variable instead of retrying blind.

It knows AWS access key IDs, PEM private keys, Anthropic, OpenAI, GitHub, Slack, Stripe live, Google
and SendGrid keys, and a quoted literal assigned to a name like `DB_PASSWORD` or `client_secret`.
Every pattern is a provider shape with a fixed prefix and length rather than a guess about entropy,
because a gate that blocks legitimate work gets uninstalled the same day and then protects nothing.

So it stays out of the way of:

- `.env` and `.env.local`. That is where the real value belongs.
- Tests, fixtures, mocks, and `examples/`. Fake keys live there on purpose, including the ones that test this hook.
- Markdown and other prose, where showing a key format is the point.
- Anything self-evidently not real: `your-api-key-here`, `<your password>`, `XXXXXXXX`, `${DB_PASSWORD}`, and `AKIAIOSFODNN7EXAMPLE`, which is AWS's own documented example.
- A value under 8 characters. That is a flag, not a credential.
- Reading from the environment, which is the fix it asks for and so must never be what it blocks.

Set `FOREMAN_SECRETS=ask` to be prompted instead of refused, or `off` to disable it.

## The edit hook

`after-edit` runs on `PostToolUse` for `Write`, `Edit`, and `MultiEdit`, and makes three independent checks.
It nudges; it never blocks.

**Scope.** Trips at 80 lines or 50 KB added in one change, so minified and generated files can't slip past a line count. Skips prose and data, because "could a stdlib call have covered this" is nonsense advice about a README.

**Test-first.** Trips when production code lands and no test in the repo names or mentions that file:

```
[foreman] src/billing/refunds.py just gained 62 lines of production code and this
repo has tests, but no test names or mentions this file. Write the test that would
have failed before this change, watch it fail, then confirm it passes now. If the
file genuinely is not unit-testable (wiring, config, a thin adapter over a
library), say that in one line and move on.
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
- Silent when any test file *mentions* the file by name, not just when one is named after it. A repo whose tests all live in one `tests/test_suite.py` can never satisfy a filename match, so without this it would be nudged on every file forever. Separators are folded too: `after_edit.py` is covered by `test-after-edit.sh`.
- Silent when the answer is unclear. A common name like `utils` will match tests that don't really cover it, and a false silence costs less than a nudge you learn to ignore.

**Comments.** Trips when the comments a change added are the ones that make code read as machine-written:
a line restating the line below it, a `# ---- Imports ----` banner, `# Updated to handle the empty case`
narrating the edit rather than the code, or `# Note that we then loop over each item` talking to the reader.

```
[foreman] 3 comments this change added to app/refunds.py read as narration
rather than explanation: "Loop through the items" (restates the code next to
it); "---- Helpers ----" (labels a section the code already declares);
"Updated to handle the empty case" (recaps the edit, which is the commit
message's job). Rewrite them the way a person reviewing this file would want
them: keep only what the code cannot say itself, which is why this approach
and not the obvious one, what breaks if it changes, and a link to the source
or the issue. Delete the rest rather than rewording them.
```

The rules are [Stack Overflow's nine](https://stackoverflow.blog/2021/12/23/best-practices-for-writing-code-comments/),
narrowed to the ones an edit payload can actually see.
Four of those nine argue for comments that explain *why*, and that is also what keeps this check from
arguing with good comments: any comment reaching for a causal word, a link, an issue number, or a
`TODO` is exempt before a single pattern runs.

- Silent for docstrings, javadoc, rustdoc, and `--` Haddock blocks. "Returns the parsed config." is correct in a docstring and narration on a bare line, so the scanner deliberately cannot see them.
- Silent for `pragma`, `eslint-disable`, `type:` and other machine-read directives.
- Silent under two findings in one change. One flat comment is a comment; three is a habit.
- Silent for `#` inside a string, which is most of what a `#` in a shell script or a URL fragment actually is.
- One nudge per file per session, like the others.
- No line threshold, unlike the other two. A four-line edit can still add three comments that say nothing, and that is the entire complaint.

## The commit gate

`commit-check` runs on `PreToolUse` for `Bash` and refuses a `git commit` that a reviewer would have
to ask "what were they trying to do?" about. It blocks rather than nudges, because every finding is a
thing you would need to rewrite history to fix a minute later.

Claude gets the reason, so it rewrites the message or splits the commit and retries.

It reads the three things a commit is judged on afterwards and can only be fixed before:

**The message.** Over 50 characters. Past tense, where git's own convention is the imperative because
a subject completes the sentence "applying this commit will ...". A subject that records that
something happened and nothing about what, so `wip` and `minor fixes` and `more stuff` all fail while
`fix the retry` passes. Two changes joined by an "and". A trailing period on a title.
The 50 only binds subjects Claude wrote: a subject you typed yourself anywhere in the session is committed at whatever length you gave it.
The other message checks still apply to it.

**The contents.** Dependencies changed together with code, which is the one mix that makes a logic
change invisible in review and unbisectable later. A linter or formatter config landing with source,
where there is no way to tell which lines changed behaviour and which the formatter rewrote.
A lockfile bump on its own is exactly the focused commit being asked for, so that passes, and
documentation travelling with the code it documents is good practice rather than a mix.

**The process.** No test command ran this session and this commit carries code changes. Nothing ran
`git status` or `git diff`, so the commit is being recorded without anyone having read it.

```
[foreman] (1) "Fixed" is past tense. A subject completes the sentence
"applying this commit will ...", so use the imperative. (2) The subject
describes two changes joined by "and". If it really is two, commit them
separately so either one can be reviewed, or reverted, on its own. If it is
one change, say the one thing it does. (3) This commit changes dependencies
(package.json) and code (app.py) together. An upgrade reshapes every call site
it touches, so a logic change inside one is invisible in review and
unbisectable later. Commit the dependency move on its own first.
```

Every finding arrives in one numbered deny, so a single retry fixes all of them instead of four rounds.

The fences:

- **The two process findings deny once per session, then trust you.** A bad subject is always fixable on the retry. "The tests never ran" may not be, in a sandbox where they cannot, and a hook that denies the same impossible thing forever has taken the repo hostage.
- **Silent when there is no message on the command line.** That means git opens an editor, and what happens in there is not something a `PreToolUse` hook can see or should guess at. Same for `-F`.
- **Silent for `--amend --no-edit` and `git rebase --continue`,** which reuse a message that was already judged.
- **Silent for everything that is not a commit.** It runs before every `Bash` call in the session, so `pre-commit run`, `git log --grep=commit` and `echo "ready to commit"` all have to pass untouched.
- **`-a` is accounted for.** It stages the working tree on the way past, so that is what gets judged.
- Silent outside a git repo, and silent whenever it cannot tell.

Set `FOREMAN_COMMIT_CHECK=off` to disable it, or `FOREMAN_SUBJECT_MAX` to move the 50.

## Did the tests actually run

`session-tests` is the check the edit hook wants to make and structurally cannot.
The edit hook knows whether a test *exists* for a file. It cannot know whether anyone ever *ran* one, because that happens in a `Bash` call it never sees.

So it spans three events: it notes a test invocation on `PostToolUse` for `Bash`, and on `PostToolUseFailure` too, because that is where Claude Code reports a run that exited red. Then on `Stop` - the moment Claude is about to hand the turn back - it speaks if production code landed this session and nothing ever ran.

```
[foreman] Production code changed this session (app/refunds.py, app/ledger.py) and
no test command ran. Run the suite before finishing, and say in one line whether it
passed. If the suite cannot run in this environment, or nothing that changed is
testable, say which and stop.
```

"Did you run them" is the question, not "did they pass".
A failing suite is a result. An unrun suite is a guess.

It recognises about forty runners, from `pytest` and `go test` to `./gradlew test` and a bare `bash tests/foo-test.sh`.
Breadth matters more than precision in that list: an unrecognised runner means nagging someone who did run their tests, while a false match only makes the check quiet.

This is the one hook that interrupts, so it is fenced in three ways:

- **It asks once.** Ever, per session. The block carries an explicit way out, and "the suite can't run here" ends it.
- **It cannot loop.** `Stop` payloads carry `stop_hook_active`, true on the re-entry a block causes, and the hook returns immediately when it sees it. A marker file guards every later `Stop` in the same session, where that flag has reset because you sent another prompt. Two guards because they cover two different situations.
- **It only counts what the edit hook already counted.** Same source-extension, size and `tests/` rules, so a README, a one-line tweak, or a repo with no test suite is never what it asks about.

`SessionEnd` deletes the session's markers, which live under `$TMPDIR`.

Set `FOREMAN_TEST_RUN_CHECK=off` to disable it.

## The skills

| Skill | What it does |
|---|---|
| `/foreman:tdd` | Strict red-green-refactor loop, no production code ahead of a test |
| `/foreman:review` | Correctness, then tests, security, design, readability, perf, in that order |
| `/foreman:security` | Vulnerability scan by exploit frequency, front end and back end |
| `/foreman:perf` | Measure first, then N+1 queries and missing indexes before anything clever |
| `/foreman:docs` | READMEs, API docs, ADRs, runbooks, in a human voice |

The `foreman:` prefix is the canonical name and what the slash menu shows.
Bare `/tdd` also works, but only while nothing else claims that name, and `review` and `security` are
exactly the ones likely to collide, because Claude Code ships its own `/code-review` and `/security-review`.
Type the prefix and you always get the one you meant.

Each also auto-triggers without the slash command when its `description` matches what you asked for.
Arguments pass straight through: `/foreman:review 1234`, `/foreman:perf GET /reports`.

### Why these and not the built-ins

`/code-review` and `/security-review` ship with Claude Code, and they can do things these cannot:
post inline PR comments, and apply their own fixes. If that is what you want, use them.

What they do not carry is an opinion about order. `/foreman:review` grades correctness before tests
before security and puts style nits last, because each layer is cheaper to fix than the next.
It also carries a list of cuts that are never acceptable: input validation at a trust boundary,
error handling on anything that can fail, an auth or escaping check, accessibility in user-facing code.
A diff that got shorter by deleting one of those did not get simpler.
That ordering and that floor are the whole reason these two exist alongside the built-ins.

## Configuring

Every knob is an environment variable, because editing the script in place gets overwritten the next time the plugin updates.

| Variable | Default | Effect |
|---|---|---|
| `FOREMAN_LINE_THRESHOLD` | `80` | Lines added before the scope check speaks up |
| `FOREMAN_BYTE_THRESHOLD` | `50000` | Bytes added before the scope check speaks up |
| `FOREMAN_TEST_FIRST_MIN_LINES` | `10` | Lines added before a missing test is worth mentioning |
| `FOREMAN_SUBJECT_MAX` | `50` | Characters a commit subject may reach before the gate refuses it. Subjects you typed yourself are exempt |
| `FOREMAN_SCOPE_CHECK` | on | Set to `off` to disable the scope check |
| `FOREMAN_TEST_FIRST` | on | Set to `off` to disable the test-first check |
| `FOREMAN_COMMENT_CHECK` | on | Set to `off` to stop flagging comments that narrate |
| `FOREMAN_COMMIT_CHECK` | on | Set to `off` to let any commit through |
| `FOREMAN_SOURCE_EXTENSIONS` | - | Extra extensions for the test-first and comment checks, comma separated: `.tf,.sql` |
| `FOREMAN_SECRETS` | on | `ask` to be prompted instead of refused, `off` to disable the gate |
| `FOREMAN_TEST_RUN_CHECK` | on | Set to `off` to stop asking whether the suite ran |
| `FOREMAN_OFF` | - | Set to any non-empty value to silence every check at once |

They go in the `env` block of `.claude/settings.json`, either the one in your project or `~/.claude/settings.json`:

```json
{
  "env": {
    "FOREMAN_LINE_THRESHOLD": "150",
    "FOREMAN_TEST_FIRST": "off"
  }
}
```

Exporting them from `.zshrc` works only if Claude Code happened to inherit that environment, so the settings file is the answer that always holds.

Also worth knowing:

- **Turning a skill off**: do it through Claude Code, with `/plugin` or by disabling the skill. Editing the `description` out of a `SKILL.md` works until the next plugin update overwrites it.
- **How eagerly a skill fires**: the `description` in its `SKILL.md` frontmatter is the entire matching surface. Tighten it to fire less, add trigger phrases to fire more.

## Troubleshooting

**The slash menu is empty.** Restart the session. Skills hot-reload, hooks do not, and a fresh install needs the restart either way.

**`its network source differs from the one declared for it in settings`.** You added the marketplace twice, from two different sources. `JustinK33/foreman` and a local checkout both claim the name `foreman`, and Claude Code will not silently repoint a marketplace. Drop the old declaration, then add the one you want:

```
/plugin marketplace remove foreman
```

**The hooks never speak.** They are built to stay quiet, so first check it is not on purpose: no tests anywhere in the repo, under 10 changed lines, a file under `tests/`, or a path Claude Code sees as outside the working repo. Beyond that they need `python3` on PATH, and they will not fire on a language outside the extension list.

**It keeps asking whether the tests ran.** It asks once per session, so a second ask means a second session. If it asks about something you did run, the runner is not in its list: name it in the ask and Claude will run it again, or set `FOREMAN_TEST_RUN_CHECK=off`. Either way that list is worth an issue.

**It refused a commit I wanted to make.** The reason says which of the findings applied, and all of
them are fixable in the retry: reword the subject, or `git reset` the dependency or config file and
commit it on its own first. A subject you dictate in the chat is never refused for length. If it refuses a subject you stand behind, `FOREMAN_SUBJECT_MAX` moves the
50 and `FOREMAN_COMMIT_CHECK=off` stands it down. The two findings about running the tests and reading
the diff only ever fire once per session, so neither can wedge a commit.

**A skill fires when you didn't want it.** Its `description` is the entire matching surface. See Configuring.

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

## Contributing

How to run the tests and the evals, what the eval harness gets wrong, and the bugs every regression test guards against are all in [CONTRIBUTING.md](CONTRIBUTING.md).
Security issues go through [SECURITY.md](SECURITY.md), not a public issue.

## License

MIT
