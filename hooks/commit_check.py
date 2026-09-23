"""Is this commit one change, described in one line, that has been looked at?

A PreToolUse check on Bash. It reads two things a commit is judged on after the
fact and can only be fixed before it: the subject line, and what is staged.

    the message     one change, imperative, under the subject limit unless the
                    user typed that subject themselves
    the contents    logic not mixed with dependencies or with formatting
    the process     the tests ran, and somebody read the diff

Denies rather than nudges, because every finding is a thing you would have to
rewrite history to fix a minute later, and because PreToolUse feeds
permissionDecisionReason straight to the model, which then fixes it and retries.

The two process findings deny at most once per session. A message defect is
always actionable on the retry; "the tests never ran" may not be, in a sandbox
where they cannot, and a hook that denies the same un-actionable thing forever
is a hook that has taken the repo hostage.

Never exits non-zero.
"""

import json
import os
import re
import shlex
import subprocess
import sys

import foreman_state

# Set by session_tests.py when it sees a test runner go by, and by after_edit.py
# for each production file written. Read here, so the two have to agree.
RAN = "tests-ran"
WROTE = "wrote-"
# Written here.
REVIEWED = "read-the-diff"
ASKED_TO_TEST = "asked-to-test-before-commit"
ASKED_TO_REVIEW = "asked-to-read-the-diff"


def env_int(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def env_off(name):
    return os.environ.get(name, "").strip().lower() in ("0", "off", "false", "no")


# Fifty is the number everyone quotes and git's own tooling assumes: `git log
# --oneline` and every forge's commit list truncate around there.
SUBJECT_MAX = env_int("FOREMAN_SUBJECT_MAX", 50)

# Committing at all, as opposed to the dozens of other things `git` does.
COMMITTING = re.compile(r"(?:^|[;&|(]\s*)git\s+(?:-[-\w=./]+\s+|--\w+\s+\S+\s+)*commit\b")
# Looking before you leap. Recorded so the check below can tell whether anybody
# read the change, which is the one best practice a hook can actually observe.
REVIEWING = re.compile(
    r"(?:^|[;&|(]\s*)git\s+(?:-[-\w=./]+\s+)*(?:status|diff|show|add\s+-p|add\s+--patch)\b"
)

# `git commit -m "$(cat <<'EOF' ... EOF)"`, which is the form Claude Code itself
# is told to use, so parsing it is not optional.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1\r?\n(.*?)(?:\r?\n)?[ \t]*\2", re.DOTALL)

# type(scope)!: is metadata, not the summary, but it does occupy the line.
CONVENTIONAL = re.compile(r"^\w+(?:\([^)]*\))?!?:\s*")

# Past tense reads as a changelog entry. git's own convention is the imperative,
# because a subject completes the sentence "applying this commit will ...".
PAST_TENSE = re.compile(
    r"""(?ix) ^ (?:
        added | adding | fixed | updated | removed | removing | changed | deleted
      | refactored | renamed | moved | implemented | created | bumped | dropped
      | cleaned | optimi[sz]ed | reverted | documented | migrated | upgraded
      | downgraded | simplified | rewrote | tested | replaced | introduced
    ) \b"""
)

# Words that record that something happened and nothing about what. A subject
# built only out of these says nothing: "minor fixes" and "more stuff" and
# "wip" are the same message. One word from outside the list is enough to make
# it a description, which is why this is a vocabulary and not a phrase list.
VACUOUS = frozenset(
    """wip work progress tmp temp temporary test testing tests stuff things
    thing misc miscellaneous minor small little quick various sundry cleanup
    clean tidy tidying fix fixes fixed fixing update updates updating change
    changes changed tweak tweaks tweaked edit edits commit commits save saving
    saved checkpoint snapshot more again another asdf asdfasdf foo bar baz qux
    final latest new now done ok okay yet still here there this that""".split()
)
# Function words that cannot rescue a vacuous subject on their own.
GLUE = frozenset("a an the to for of in on up and or some it its my".split())

# The verbs a subject line is built from. Two of them either side of an "and" is
# the example everybody gives for a commit that should have been two.
VERB = r"""(?: add | fix | remove | delete | drop | update | refactor | rename
    | move | optimi[sz]e | bump | clean | format | document | test | revert
    | implement | support | handle | extract | inline | split | merge
    | deprecate | migrate | upgrade | downgrade | simplify | rewrite | replace
    | introduce | expose | enforce | teach | stop | skip | allow | let )"""
TWO_CHANGES = re.compile(rf"(?ix) \b {VERB} \w* \b .* \b and \s+ {VERB} \w* \b")

# Upgrading a dependency reshapes every call site, so a logic change buried in
# one is a logic change nobody will ever find again.
DEPENDENCY = re.compile(
    r"""(?ix) (?: ^ | / ) (?:
        package(?:-lock)?\.json | yarn\.lock | pnpm-lock\.yaml | bun\.lockb
      | npm-shrinkwrap\.json | requirements[\w.-]*\.txt | Pipfile(?:\.lock)?
      | poetry\.lock | pdm\.lock | uv\.lock | pyproject\.toml | setup\.py
      | Gemfile(?:\.lock)? | go\.mod | go\.sum | Cargo\.toml | Cargo\.lock
      | composer\.(?:json|lock) | pom\.xml | build\.gradle(?:\.kts)?
      | gradle/libs\.versions\.toml | [\w.-]+\.csproj | packages\.lock\.json
      | Package\.(?:swift|resolved) | mix\.(?:exs|lock) | pubspec\.(?:yaml|lock)
    ) $"""
)

# Reformatting is the other change that swamps a diff. A linter config landing
# with source means a rule changed and the reformatting rode along with it.
FORMATTING = re.compile(
    r"""(?ix) (?: ^ | / ) (?:
        \.editorconfig | \.prettierrc[\w.]* | prettier\.config\.\w+
      | \.eslintrc[\w.]* | eslint\.config\.\w+ | biome\.jsonc? | dprint\.json
      | ruff\.toml | \.ruff\.toml | \.flake8 | setup\.cfg | tox\.ini
      | \.clang-format | \.clang-tidy | rustfmt\.toml | \.rustfmt\.toml
      | \.rubocop\.yml | \.stylelintrc[\w.]* | tslint\.json | \.swiftformat
      | \.scalafmt\.conf | \.golangci\.ya?ml | \.pre-commit-config\.yaml
    ) $"""
)

# Prose and data. Docs travelling with the code they document is good practice,
# not a mixed commit, so these count as neither logic nor noise.
NEUTRAL_EXTENSIONS = {
    ".md", ".markdown", ".rst", ".txt", ".adoc", ".csv", ".tsv", ".svg",
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".po", ".pot",
}


def git(args, cwd):
    """Returns [] on anything unexpected: "I could not tell" means stay quiet."""
    try:
        done = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return done.stdout.splitlines() if done.returncode == 0 else []


def first_line(text):
    for line in text.split("\n"):
        if line.strip():
            return line.strip()
    return ""


def message_argument(args):
    """The -m value, or "" when the command carries no message on the line."""
    for index, arg in enumerate(args):
        # -F reads the message from a file this hook has no business opening.
        if arg in ("-F", "--file") or arg.startswith("--file="):
            return ""
        if arg.startswith("--message="):
            return arg.partition("=")[2]
        # -m"subject", which shlex has already unquoted for us.
        if arg.startswith("-m") and len(arg) > len("-m"):
            return arg[2:]
        # -m on its own, and the bundled -am form git also accepts.
        if re.fullmatch(r"-[a-zA-Z]*m", arg) and index + 1 < len(args):
            return args[index + 1]
    return ""


def subject_of(command):
    """The first line of the commit message, or "" if the command does not carry
    one. No message means git opens an editor, and what happens in there is not
    this hook's business."""
    heredoc = HEREDOC.search(command)
    if heredoc:
        return first_line(heredoc.group(3))
    try:
        args = shlex.split(command, comments=False)
    except ValueError:
        return ""
    return first_line(message_argument(args))


def staged(command, cwd):
    """The files this commit would record. `-a` stages the whole working tree on
    the way past, so that is what has to be listed for it."""
    sweeps_everything = bool(re.search(r"(?:^|\s)-[a-zA-Z]*a[a-zA-Z]*(?=\s|$)", command))
    names = git(["diff", "--cached", "--name-only"], cwd)
    if sweeps_everything:
        names += git(["diff", "--name-only"], cwd)
    return sorted(set(names))


def mixed(names):
    """(logic files, dependency files, formatting files) in one commit.

    Only reported when logic is present on one side of the mix. A commit that is
    nothing but a lockfile bump is exactly the focused commit being asked for.
    """
    logic, dependencies, formatting = [], [], []
    for name in names:
        if DEPENDENCY.search(name):
            dependencies.append(name)
        elif FORMATTING.search(name):
            formatting.append(name)
        elif os.path.splitext(name)[1].lower() not in NEUTRAL_EXTENSIONS:
            logic.append(name)
    return logic, dependencies, formatting


def is_placeholder(summary):
    """Does the subject name a change, or only note that there was one?"""
    words = [w.lower() for w in re.findall(r"[A-Za-z]+", summary)]
    if not words:
        return True
    return all(word in VACUOUS or word in GLUE for word in words)


def few(names, limit=3):
    shown = ", ".join(names[:limit])
    return shown + (f", and {len(names) - limit} more" if len(names) > limit else "")


def squash(text):
    return " ".join(text.split()).lower()


def user_said(subject, transcript_path):
    """Did the user type this subject themselves? Then its length is their call,
    not the agent's to rewrite. Only what the user wrote counts: tool results
    also arrive as role user, so only plain strings and text blocks are read.
    Anything unreadable counts as no, which is the limit applying as before."""
    wanted = squash(subject)
    try:
        with open(transcript_path, encoding="utf-8") as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "user":
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, str):
                    texts = [content]
                elif isinstance(content, list):
                    texts = [
                        block.get("text") or ""
                        for block in content
                        if isinstance(block, dict) and block.get("type") == "text"
                    ]
                else:
                    continue
                if any(wanted in squash(text) for text in texts):
                    return True
    except (OSError, TypeError):
        return False
    return False


def message_findings(subject, dictated=False):
    found = []
    if not subject:
        return found
    summary = CONVENTIONAL.sub("", subject)

    if len(subject) > SUBJECT_MAX and not dictated:
        found.append(
            f"The subject is {len(subject)} characters, over the {SUBJECT_MAX} the "
            "subject line has to scan in. Say the one change and move the rest into "
            "the body, after a blank line."
        )
    if is_placeholder(summary):
        found.append(
            f'"{subject}" records that something happened and nothing about what. '
            "Name the change."
        )
    elif PAST_TENSE.match(summary):
        found.append(
            f'"{summary.split()[0]}" is past tense. A subject completes the sentence '
            '"applying this commit will ...", so use the imperative.'
        )
    if TWO_CHANGES.search(summary):
        found.append(
            "The subject describes two changes joined by \"and\". If it really is two, "
            "commit them separately so either one can be reviewed, or reverted, on its "
            "own. If it is one change, say the one thing it does."
        )
    if summary.endswith("."):
        found.append("The subject is a title, not a sentence, so it does not need the period.")
    return found


def content_findings(names):
    logic, dependencies, formatting = mixed(names)
    found = []
    if logic and dependencies:
        found.append(
            f"This commit changes dependencies ({few(dependencies)}) and code "
            f"({few(logic)}) together. An upgrade reshapes every call site it touches, "
            "so a logic change inside one is invisible in review and unbisectable "
            "later. Commit the dependency move on its own first."
        )
    if logic and formatting:
        found.append(
            f"This commit changes linter or formatter configuration ({few(formatting)}) "
            f"and code ({few(logic)}) together, so there is no way to tell which lines "
            "changed behaviour and which the formatter rewrote. Land the config and its "
            "reformatting by themselves."
        )
    return found


def process_findings(session):
    """The two practices that are about the commit rather than in it. Each one
    denies once per session and then trusts you, because neither is always
    possible and a hook that repeats itself forever gets switched off."""
    found = []
    wrote = [path for path in foreman_state.marks(session, WROTE) if path]

    if (
        wrote
        and not foreman_state.marked(session, RAN)
        and not foreman_state.mark(session, ASKED_TO_TEST)
    ):
        found.append(
                f"No test command has run this session, and this commit carries code "
                f"changes ({few(wrote)}). Run the suite before recording the snapshot; "
                "a commit is the thing that says this state was known good. If the "
                "suite cannot run here, say so in one line and commit anyway."
            )
    if not foreman_state.marked(session, REVIEWED) and not foreman_state.mark(
        session, ASKED_TO_REVIEW
    ):
        found.append(
            "Nothing has run git status or git diff this session, so this commit is "
            "being recorded without anybody having read it. Look at exactly which "
            "files and lines are staged first."
        )
    return found


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return

    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command") or ""
    session = data.get("session_id", "")

    # Recorded whatever the switches say: the marker has to be there if the
    # check is turned on mid-session, and writing it decides nothing by itself.
    if REVIEWING.search(command):
        foreman_state.mark(session, REVIEWED)

    if os.environ.get("FOREMAN_OFF", "").strip() or env_off("FOREMAN_COMMIT_CHECK"):
        return
    if not COMMITTING.search(command):
        return
    # --amend --no-edit and a rebase's own commits are not new messages.
    if "--no-edit" in command or "--continue" in command:
        return

    cwd = data.get("cwd") or os.getcwd()
    subject = subject_of(command)
    # Only a subject over the limit needs the transcript, so only then is it read.
    dictated = len(subject) > SUBJECT_MAX and user_said(subject, data.get("transcript_path"))
    found = (
        message_findings(subject, dictated)
        + content_findings(staged(command, cwd))
        + process_findings(session)
    )
    if not found:
        return

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "[foreman] "
                + " ".join(f"({n}) {text}" for n, text in enumerate(found, 1)),
            }
        },
        sys.stdout,
    )


main()
