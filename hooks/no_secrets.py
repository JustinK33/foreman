"""Refuse a Write or Edit that would put a live credential in a file.

This is the one foreman check that blocks rather than nudges. A nudge about a
secret arrives after the secret is already on disk, and at that point the advice
is worthless: the value has to be rotated, not moved.

The bar for a pattern here is "almost certainly a real credential". A security
hook that blocks legitimate work gets uninstalled the same day, and then it
protects nobody, so every pattern below is a provider-specific shape with a
fixed prefix and length rather than a guess about entropy.

Never exits non-zero. A crash here would block every edit in the session.
"""

import json
import os
import re
import sys

import foreman_state

# Provider-issued credentials. Each has a prefix and a length, so the false
# positive rate is close to zero.
PATTERNS = [
    ("an AWS access key ID", re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])")),
    ("a private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
    ("an Anthropic API key", re.compile(r"sk-ant-[A-Za-z0-9_-]{24,}")),
    ("an OpenAI API key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("a GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}")),
    ("a Slack token", re.compile(r"xox[baprs]-[0-9A-Za-z-]{10,}")),
    ("a live Stripe key", re.compile(r"sk_live_[0-9a-zA-Z]{20,}")),
    ("a Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("a SendGrid API key", re.compile(r"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}")),
]

# A quoted literal assigned to an obviously secret-shaped name. Deliberately
# requires a quoted value, which is what excludes os.environ["..."] lookups,
# process.env.X, and every other indirection.
ASSIGNMENT = re.compile(
    r"""(?ix)
    # A prefix is allowed, because DB_PASSWORD has a word character before
    # "password" and so \b would never match the thing people actually write.
    [A-Za-z0-9_.\[\]"']*
    (?:password|passwd|secret|secret_key|client_secret|api_key|apikey
      |access_key|access_token|auth_token|private_key|bearer_token)
    [A-Za-z0-9_.\]"']*
    # API_KEY: str = "...", where the colon belongs to the annotation.
    (?: \s* : \s* [\w.\[\]|, ]+? (?=\s*=) )?
    \s* [:=] \s*
    (?P<quote>["'])(?P<value>[^"'\n]{8,})(?P=quote)
    """
)

# Anything that says "this is not the real value". A doc, a fixture, a template.
PLACEHOLDER = re.compile(
    r"""(?ix)
    ^(?: x{3,} | \.{3,} | \*{3,} | [-_]{3,}
       | <[^>]*> | \{\{.*\}\} | \$\{?[A-Za-z_][\w]*\}?
       | your.* | (?:my|the)[-_ ].* | change[-_ ]?me | replace[-_ ]?me
       | example.* | sample.* | placeholder.* | dummy.* | fake.* | mock.*
       | test.* | todo.* | tbd | none | null | redacted | secret | password
       )$
    """
)
# AWS documents AKIAIOSFODNN7EXAMPLE, and every provider has an equivalent.
DOC_EXAMPLE = re.compile(r"(?i)example|redacted|xxxx|\.{3}|placeholder")

# Where a credential-shaped string is expected and harmless.
SKIP_PATH = re.compile(
    r"""(?ix)
    (?:^|/) (?: \.env(?:\.|$) | node_modules/ | vendor/ | dist/ | build/
              | \.git/ | fixtures?/ | __mocks__/ | __fixtures__/
              | tests?/ | spec/ | __tests__/ | examples?/ | samples?/ )
    | (?:^|[^A-Za-z])(?:test|spec)s?(?:[^A-Za-z]|$)
    """
)
# Prose shows key formats on purpose.
SKIP_EXTENSION = {
    ".md", ".markdown", ".rst", ".txt", ".adoc", ".example", ".sample",
    ".template", ".tmpl", ".dist", ".lock", ".snap",
}


def added_text(tool_name, tool_input):
    """Only what this call introduces. Editing a line that happens to sit next
    to a key is not the same as writing the key."""
    if tool_name == "Write":
        return tool_input.get("content") or tool_input.get("file_text") or ""
    if tool_name == "Edit":
        return tool_input.get("new_string") or tool_input.get("new_str") or ""
    if tool_name == "MultiEdit":
        parts = []
        for edit in tool_input.get("edits") or []:
            if isinstance(edit, dict):
                parts.append(edit.get("new_string") or edit.get("new_str") or "")
        return "\n".join(parts)
    return ""


def findings(text):
    # Every match, not the first: a documented example key near the top of a
    # file must not vouch for a real one further down.
    found = []
    for label, pattern in PATTERNS:
        if any(not DOC_EXAMPLE.search(m.group(0)) for m in pattern.finditer(text)):
            found.append(label)

    for match in ASSIGNMENT.finditer(text):
        value = match.group("value").strip()
        # DOC_EXAMPLE as well as PLACEHOLDER: one catches a value that starts like
        # a stand-in, the other catches AKIAIOSFODNN7EXAMPLE, where the giveaway is
        # at the end. Both mean nobody has to rotate anything.
        if PLACEHOLDER.match(value) or DOC_EXAMPLE.search(value):
            continue
        # Not a provider shape, so name the variable rather than claim to know
        # what the value is.
        name = match.group(0).split("=")[0].split(":")[0].strip()
        found.append(f"a hardcoded value assigned to `{name}`")
    return found


def main():
    if foreman_state.disabled("FOREMAN_SECRETS"):
        return
    mode = os.environ.get("FOREMAN_SECRETS", "").strip().lower()

    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return

    tool_input = data.get("tool_input") or {}
    path = tool_input.get("file_path") or ""
    # With no path, none of the exemptions below can be evaluated, and this hook
    # would rather miss a secret than block a legitimate write it cannot judge.
    if not path:
        return
    # Judged inside the repo, so a checkout at ~/specs-site is not a spec folder.
    cwd = data.get("cwd") or ""
    if cwd and os.path.isabs(path) and path.startswith(cwd.rstrip("/") + "/"):
        path = os.path.relpath(path, cwd)
    if SKIP_PATH.search(path) or os.path.splitext(path)[1].lower() in SKIP_EXTENSION:
        return

    found = findings(added_text(data.get("tool_name", ""), tool_input))
    if not found:
        return

    what = found[0] if len(found) == 1 else found[0] + ", and " + str(len(found) - 1) + " more"
    reason = (
        f"[foreman] This write contains what looks like {what}. Secrets do not belong in "
        "tracked files: once written, the value has to be rotated, not just moved. "
        "Read it from an environment variable instead, put the real value in .env, "
        "and confirm .env is in .gitignore. If this is a placeholder or a documented "
        "key format, make that obvious in the value itself (XXXX, or EXAMPLE) and "
        "write it again."
    )

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                # "ask" hands the call to the user instead of refusing outright.
                "permissionDecision": "ask" if mode == "ask" else "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


main()
