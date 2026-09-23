#!/usr/bin/env bash
# comment_style is pure text in, findings out, so it is driven directly. The
# cases that matter most are the silent ones: this check reads prose and
# guesses, and a false positive tells you to delete a comment that was right.
#
# Shell to match the rest of tests/ and to stay inside the one CI glob.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT/hooks" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import comment_style as cs

passed = failed = 0


def check(name, got, want):
    global passed, failed
    if got == want:
        print(f"  ok    {name}")
        passed += 1
    else:
        print(f"  FAIL  {name}: got {got!r}, want {want!r}")
        failed += 1


def flagged(text, ext=".py"):
    """The reasons, so a case cannot pass because a different pattern fired."""
    return [reason for _, _, reason in cs.findings(text, ext)]


def one(text, ext=".py"):
    got = flagged(text, ext)
    return got[0] if len(got) == 1 else got


RESTATES = "restates the code next to it"
BANNER = "labels a section the code already declares"
RECAPS = "recaps the edit, which is the commit message's job"
READER = "addresses the reader instead of explaining the code"

print("rule 1: a comment that duplicates the code")

check("increment over +=", one("# Increment the counter\ncounter += 1"), RESTATES)
check("a trailing restatement", one("counter += 1  # increment the counter"), RESTATES)
check("parse over a call to parse", one("# Parse the config file\nconfig = parse(path)"), RESTATES)
check("pure narration with no overlap",
      one("# Store the result in a temporary variable\nx = compute()"), RESTATES)
# camelCase and snake_case are the same words as the prose around them.
check("camelCase repeated in prose",
      one("// Set the spot price\nthis.spotPrice = p;", ".ts"), RESTATES)
check("snake_case repeated in prose",
      one("# Return the invoice total\nreturn invoice_total"), RESTATES)
# Plural and third person: "returns the invoices" over `return invoice` is still
# saying it twice. Deliberately a word that is not on the generic-verb list, so
# the case tests the folding rather than the list.
check("third person and plurals",
      one("# Returns the parsed invoices\nreturn parsed_invoice"), RESTATES)
check("singular prose over a plural identifier",
      one("# Holds the pending invoice\npending_invoices = []"), RESTATES)
# A preposition is not information. "Loop through the items" is the textbook
# example of rule 1, and it read as informative until "through" was a stopword.
check("a preposition does not rescue it",
      one("# Loop through the items\nfor item in items:\n    pass"), RESTATES)
check("iterate over, same shape",
      one("# Iterate over each row again\nfor row in rows:\n    pass"), RESTATES)

print()
print("and the comments it must leave alone")

# The one that matters. Every rule the article actually argues for is a "why",
# so the causal escape hatch has to hold or the check is a liability.
check("why, not what", flagged("# Ordered before the flush because the writer buffers\nflush()"), [])
check("an unidiomatic choice, rule 5",
      flagged("# A list, not a set: callers depend on insertion order\nseen = []"), [])
check("a link to the source, rule 6",
      flagged("# Adapted from https://example.com/bitcount\nn = n - ((n >> 1) & 0x5555)"), [])
check("a bug reference, rule 8",
      flagged("# Works around upstream #4412, remove when it lands\nsleep(1)"), [])
check("a jira key exempts too",
      flagged("# Added for PROJ-88\nretries = 5"), [])
check("a TODO is rule 9, not a finding",
      flagged("# TODO: batch these writes\nsave(row)"), [])

# One word is not a claim about the code, even when it is the identifier below.
# A bare label is how people mark a branch, and rewriting those is not the point.
check("a one word comment", flagged("# fallthrough\nbreak"), [])
check("a one word label naming the line", flagged("# counter\ncounter += 1"), [])
# A comment with no code under it cannot be compared to anything.
check("a comment with nothing after it", flagged("# set the flag"), [])
check("real explanation of a magic number",
      flagged("# 90 days, the retention window the contract promises\nTTL = 7776000"), [])

print()
print("decoration and section labels")

check("a banner", one("# ===== Helpers =====\ndef helper(): pass"), BANNER)
check("a dashed rule", one("# ------------------\ndef helper(): pass"), BANNER)
check("a one word label", one("# Imports\nimport os"), BANNER)
check("a two word label", one("# Helper functions\ndef helper(): pass"), BANNER)
check("a numbered step", one("# Step 1: read the file\ntext = open(p).read()"), BANNER)
check("main entry point", one("// Main entry point\nfunc main() {}", ".go"), BANNER)
# A label that says something beyond its own position stays.
check("a label with content is not a banner",
      flagged("# Constants shared with the Go service, keep them in sync\nTTL = 60"), [])

print()
print("narrating the edit instead of the code")

check("added", one("# Added retry handling\nretry()"), RECAPS)
check("updated to", one("# Updated to use the new client\nclient = New()"), RECAPS)
check("as requested", one("# Lowered the limit as requested\nLIMIT = 5"), RECAPS)
check("now returns", one("# This now returns a list\nreturn [x]"), RECAPS)
# The git log's job is the objection, so an edit note that says why survives.
check("a change note that says why",
      flagged("# Changed to a deque because pop(0) was quadratic\nq = deque()"), [])

print()
print("talking to the reader")

check("note that", one("# Note that this runs on every request\nhandle()"), READER)
check("as you can see", one("# As you can see, the ids line up\nzip(a, b)"), READER)
check("here we", one("# Here we build the payload\npayload = {}"), READER)
check("in this example", one("# In this example the port is fixed\nport = 8080"), READER)
check("for clarity", one("# Split for clarity\na, b = pair"), READER)
check("simply", one("# This simply wraps the client\nreturn Client()"), READER)
check("is responsible for", one("# This function is responsible for auth\ndef auth(): pass"), READER)
check("we can", one("# We can reuse the same buffer\nbuf.reset()"), READER)
# "We cannot" is an explanation, and the exemption has to win over "we can".
check("we cannot is an explanation",
      flagged("# We cannot reuse the buffer, the reader holds it\nbuf = new()"), [])

print()
print("what it is not allowed to see")

# A "#" or "//" that is not a comment. Inventing a finding out of code is the
# worst failure available to this check.
check("a url in a string is not a comment",
      flagged('home = "https://example.com/setup"'), [])
check("a fragment in a string is not a comment",
      flagged('anchor = "#imports"'), [])
# Whitespace before the token is not enough on its own: this one would read as
# a banner comment if the quote counting went away.
check("a token inside a string literal is not a comment",
      flagged('heading = "Chapter 2 # Imports"'), [])
check("a decrement is not a comment", flagged("i--;\nreturn i;", ".c"), [])
# Shell parameter expansion, where "#" follows a bare identifier and the quotes
# around it balance. This is what the whitespace rule is for, and these two
# bodies read as "added" and "updated" without it.
check("shell parameter expansion is not a comment",
      flagged("one=${path#added}\ntwo=${path#updated}", ".sh"), [])

# Documentation has its own conventions, where "Returns the parsed rows." is
# correct. Each of these would be flagged if the doc-comment guard went away.
check("a rustdoc line is invisible", flagged("/// Increment the counter\ncounter += 1;", ".rs"), [])
check("an inner rustdoc line is invisible", flagged("//! Imports\nuse std::fs;", ".rs"), [])
check("a haddock line is invisible", flagged("-- | Increment the counter\nn = n + 1", ".hs"), [])
check("a roxygen line is invisible", flagged("#' Increment the counter\nn <- n + 1", ".r"), [])
# Python docstrings and javadoc hold no line-comment token, so the scanner
# cannot see them at all. Asserted so that stays true if the tokens change.
check("a docstring is invisible", flagged('def f():\n    """Return the parsed rows."""'), [])
check("a javadoc block is invisible",
      flagged("/**\n * Returns the parsed rows.\n */\nint f() {}", ".java"), [])

# Prose inside a string is not commentary on anything. A prompt template with
# markdown headings is the case that found this.
check("markdown in a docstring is invisible",
      flagged('TEMPLATE = """\n# Imports\n# Increment the counter\n"""\nx = 1'), [])
check("markdown in a template literal is invisible",
      flagged("const t = `\n// Imports\n// Increment the counter\n`;\nlet x = 1;", ".js"), [])
# And the scanner has to come back out the other side of one.
check("a comment after a closing fence is still seen",
      flagged('T = """\n# Imports\n"""\n# Increment the counter\ncounter += 1'), [RESTATES])
# Directives are machine-readable, not prose.
check("noqa is a directive", flagged("import os  # noqa: F401"), [])
check("a shebang is a directive", flagged("#!/usr/bin/env bash\nset -e", ".sh"), [])
check("a type directive", flagged("x = y  # type: ignore"), [])
check("eslint-disable is a directive",
      flagged("const x = 1; // eslint-disable-line no-unused-vars", ".js"), [])
# An unknown extension means no idea what a comment looks like, so no findings.
check("an unknown extension is silent", flagged("# Increment the counter\nx += 1", ".xyz"), [])
check("markdown is silent", flagged("# Increment the counter\nx += 1", ".md"), [])

print()
print("shape of the result")

found = cs.findings("# Imports\nimport os\n\n# Increment the counter\ncounter += 1", ".py")
check("two findings, in order", [r for _, _, r in found], [BANNER, RESTATES])
check("line numbers are 1 based and relative", [n for n, _, _ in found], [1, 4])
check("the body is stripped", [b for _, b, _ in found], ["Imports", "Increment the counter"])
# The threshold is what keeps one stylistic quibble from being a nudge.
check("one finding is below the threshold", len(cs.findings("# Imports\nimport os", ".py")), 1)
check("the threshold is more than one", cs.MIN_FINDINGS > 1, True)

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
