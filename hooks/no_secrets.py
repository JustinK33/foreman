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

import re

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

    data = foreman_state.read_hook_input()
    if not data:
        return

    path = foreman_state.extract_file_path(data)
    if not path:
        return

    cwd = data.get("cwd") or ""
    path = foreman_state.make_relative(path, cwd)

    if foreman_state.is_exempted(path, SKIP_PATH, SKIP_EXTENSION):
        return

    tool_input = data.get("tool_input") or {}
    found = findings(foreman_state.added_text(data.get("tool_name", ""), tool_input))
    if not found:
        return

    what = found[0] if len(found) == 1 else found[0] + f", and {len(found) - 1} more"
    reason = (
        f"[foreman] Detected {what}. Use environment variables (see .env) instead. "
        "Secrets in commits must be rotated. For placeholders, use XXXX or EXAMPLE."
    )

    import os
    mode = os.environ.get("FOREMAN_SECRETS", "").strip().lower()
    if mode == "ask":
        foreman_state.ask_with_reason(reason)
    else:
        foreman_state.deny_with_reason(reason)


main()
