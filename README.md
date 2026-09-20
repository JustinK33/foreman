# foreman

A tight senior-engineer toolkit for Claude Code.
Five skills, one hook, no filler: TDD, code review, security audits, performance audits, and documentation that doesn't sound like a model wrote it.

## What's in it

| Command | Skill | What it does |
|---|---|---|
| `/tdd` | `tdd` | Strict red-green-refactor loop, no production code ahead of a test |
| `/review` | `review` | Correctness, then tests, security, design, readability, perf, in that order |
| `/security` | `security` | Vulnerability scan by exploit frequency, front end and back end |
| `/perf` | `perf` | Measure first, then N+1 queries and missing indexes before anything clever |
| `/docs` | `docs` | READMEs, API docs, ADRs, runbooks, in a human voice |

Each skill also auto-triggers without the slash command when its `description` matches what you asked for.

One hook runs underneath:

**`scope-check`** (`PostToolUse` on `Write`, `Edit`, `MultiEdit`) estimates how much a change added and nudges, never blocks, when a diff outgrew its task.
It trips at 80 lines or 50 KB, so minified and generated files do not sneak past a line count.
It reports through `hookSpecificOutput.additionalContext`, because bare stdout on `PostToolUse` lands in the transcript where the agent never reads it.

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

`scope-check` needs `python3` and `bash` on PATH. If either is missing the hook exits quietly rather than erroring.

## Uninstall

```
/plugin uninstall foreman@foreman
```

## Why five

Each skill covers a distinct phase of shipping: test it, review it, secure it, make it fast, document it.
That is deliberately the whole list.

Every skill's `name` and `description` is loaded into every session, while its body only loads when the skill fires.
So the cost of a skill you never invoke is paid on every single prompt, forever.
A plugin with thirty skills is a plugin whose descriptions are a coin flip to match, which is how you end up with a toolbox nobody reaches into.

There is deliberately no lean-build or anti-over-engineering skill here.
[ponytail](https://github.com/DietrichGebert/ponytail) already does that, as an always-on hook, and running two overlapping rulesets costs double the tokens to say the same thing twice.
The one piece foreman keeps is `scope-check`, because a diff-size nudge is additive rather than a second opinion.
What survived from that idea lives in `skills/review/SKILL.md` under "cuts that are never acceptable": validation, error handling, security checks, and accessibility are never what you trade away to make a diff smaller.

## Customizing

- **Nudge thresholds**: `LINE_THRESHOLD` and `BYTE_THRESHOLD` in `hooks/scope-check.sh`.
- **How eagerly a skill fires**: the `description` in its `SKILL.md` frontmatter is the entire matching surface. Tighten it to fire less, add trigger phrases to fire more.
- **Adding a skill**: copy `skills/<name>/SKILL.md`, and add `commands/<name>.md` if you want a slash command. Both are auto-discovered, no manifest entry needed. Commands must be `.md`; Claude Code does not read `.toml`.

## Development

```bash
bash tests/test-scope-check.sh   # 9 hook cases, no framework
claude plugin details foreman    # what actually got discovered, and its token cost
claude plugin eval               # scores /review against a fixture with six seeded defects
```

`tests/test-scope-check.sh` covers the cases that were real bugs: a 2 MB write that used to abort the hook with `exit 126` by blowing `ARG_MAX`, a `MultiEdit` batch that used to slip through the matcher, and a 300 KB single-line file that a line count scored as one line.

## License

MIT
