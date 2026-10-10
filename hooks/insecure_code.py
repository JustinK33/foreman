"""Warn about code patterns that could lead to security vulnerabilities.

This hook catches common security anti-patterns before they land: SQL injection
from string concatenation, command injection from shell=True with variables,
XSS from unescaped user input, insecure deserialization, weak crypto for
passwords, and AI-specific risks like prompt injection and unsafe model loading.

Unlike no_secrets, this hook warns rather than blocks. A false positive on a
pattern is less clear-cut than a credential format, so the bar is "ask the user
to confirm" rather than "refuse outright".

Never exits non-zero. A crash here would block every edit in the session.
"""

import json
import os
import re
import sys

import foreman_state

# SQL injection: string concatenation or interpolation with SQL keywords.
# High confidence: requires both SQL keywords AND string building with variables.
SQL_CONCAT = re.compile(
    r"""(?ix)
    # String concatenation with + in Python/JS (either order)
    (?:
        (?:"|')[\s\w*,=]*(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)[\s\w*,="']*(?:"|')\s*\+
        | \+\s*(?:"|')[\s\w*,=]*(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)
    )
    """
)

SQL_FSTRING = re.compile(
    r"""(?ix)
    # Python f-string with SQL keywords
    f(?:"|''').*?(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM).*?\{[\w.]+\}
    # Or variable inside SQL
    | f(?:"|''').*?\{[\w.]+\}.*?(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)
    """
)

SQL_TEMPLATE = re.compile(
    r"""(?ix)
    # JS template literal with SQL keywords
    `.*?(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM).*?\$\{[\w.]+\}
    # Or variable inside SQL
    | `.*?\$\{[\w.]+\}.*?(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)
    """
)

# SQL_SAFE not needed - patterns specifically match concatenation which doesn't
# occur in parameterized queries
SQL_SAFE = None

# Command injection: subprocess with shell=True and variables, or os.system
SUBPROCESS_SHELL = re.compile(
    r"""(?ix)
    subprocess\.\w+\s*\(
        [^)]*
        (?:
            # f-string or template in first arg
            (?:f"|f'|`).*?shell\s*=\s*True
            # or shell=True with string concat
            | .*?(?:\+|%).*?shell\s*=\s*True
            # or shell=True before an f-string/concat arg
            | shell\s*=\s*True[^)]*(?:f"|f'|`|\+)
        )
    """
)

OS_SYSTEM = re.compile(
    r"""(?ix)
    os\.system\s*\(\s*(?:f"|f'|`|\w+\s*\+)
    """
)

JS_EXEC = re.compile(
    r"""(?ix)
    (?:child_process|cp|^|\s)exec\s*\(\s*`[^`]*\$\{
    """
)

# XSS: dangerouslySetInnerHTML, innerHTML, or v-html with variables
DANGEROUS_HTML = re.compile(
    r"""(?ix)
    dangerouslySetInnerHTML\s*=\s*\{\{?\s*__html:\s*[\w.]+
    | \.innerHTML\s*=\s*[\w.]+
    | v-html\s*=\s*(?:"|')[\w.]+
    """
)

# Insecure deserialization
PICKLE_LOAD = re.compile(r"pickle\.loads?\s*\(")
# Match yaml.load but not yaml.safe_load or when SafeLoader/safe is in args
UNSAFE_YAML = re.compile(r"(?<!safe_)yaml\.load\s*\((?![^)]*(?:SafeLoader|safe))")
SAFE_YAML = None  # Not needed with negative lookahead in pattern

# Eval/exec on external input (risky variable names)
# Negative lookbehind excludes ast.literal_eval
EVAL_EXTERNAL = re.compile(
    r"""(?ix)
    (?<!ast\.)(?<!\.)\b(?:eval|exec)\s*\(\s*(?:
        # Network/file variables
        request|response|data|payload|input|body|content
        # Or LLM output variables
        |completion|generated|output|result|answer
    )[\w.]*\s*\)
    """
)
SAFE_EVAL = None  # Not needed with negative lookbehind in pattern

# Weak crypto for passwords
WEAK_HASH_PASSWORD = re.compile(
    r"""(?ix)
    hashlib\.(?:md5|sha1)\s*\([^)]*(?:password|passwd|credential)
    """
)

# AI-specific: prompt injection via f-strings going to LLM APIs
PROMPT_INJECTION = re.compile(
    r"""(?ix)
    # F-string with user-shaped variable going to LLM API
    (?:anthropic|openai|claude|gpt)[\w.]*\(
        [^)]*(?:content|prompt|message)[^)]*
        f(?:"|''')[^"']*\{(?:user|input|request|query)[\w.]*\}
    """
)

# Unsafe model loading - match torch.load without weights_only=True
TORCH_LOAD = re.compile(r"torch\.load\s*\((?![^)]*weights_only\s*=\s*True)")
TORCH_LOAD_SAFE = None  # Not needed with negative lookahead in pattern

# Where insecure patterns are expected and harmless
SKIP_PATH = re.compile(
    r"""(?ix)
    (?:^|/) (?: node_modules/ | vendor/ | dist/ | build/ | \.git/
              | fixtures?/ | __mocks__/ | __fixtures__/ | mocks?/
              | tests?/ | spec/ | __tests__/ | examples?/ | samples?/ )
    | (?:^|[^A-Za-z])(?:test|spec)s?(?:[^A-Za-z]|$)
    """
)

SKIP_EXTENSION = {
    ".md", ".markdown", ".rst", ".txt", ".adoc", ".example", ".sample",
    ".template", ".tmpl", ".json", ".yaml", ".yml", ".lock",
}

# Pattern definitions: (name, regex, safe_regex, explanation, fix suggestion)
# safe_regex is checked first - if it matches, skip the warning
PATTERNS = [
    (
        "SQL injection",
        SQL_CONCAT,
        None,
        "String concatenation in SQL queries allows injection attacks",
        "Use parameterized queries with ? or %s placeholders instead of building SQL with string concatenation"
    ),
    (
        "SQL injection",
        SQL_FSTRING,
        None,
        "F-strings in SQL queries allow injection attacks",
        "Use parameterized queries (e.g., cursor.execute('SELECT * FROM users WHERE id = ?', (user_id,))) instead of f-strings"
    ),
    (
        "SQL injection",
        SQL_TEMPLATE,
        None,
        "Template literals in SQL queries allow injection attacks",
        "Use parameterized queries with placeholders instead of template literals in SQL"
    ),
    (
        "command injection",
        SUBPROCESS_SHELL,
        None,
        "subprocess with shell=True and string interpolation allows command injection",
        "Use shell=False and pass command as a list: subprocess.run(['git', 'clone', repo_url]) instead of subprocess.run(f'git clone {repo_url}', shell=True)"
    ),
    (
        "command injection",
        OS_SYSTEM,
        None,
        "os.system with string interpolation allows command injection",
        "Use subprocess.run with a list of arguments and shell=False instead of os.system"
    ),
    (
        "command injection",
        JS_EXEC,
        None,
        "child_process.exec with template literals allows command injection",
        "Use execFile instead: execFile('git', ['clone', repoUrl]) avoids shell interpretation"
    ),
    (
        "XSS",
        DANGEROUS_HTML,
        None,
        "Rendering user input as HTML without escaping allows XSS attacks",
        "Sanitize user input with DOMPurify or use text content rendering instead of innerHTML"
    ),
    (
        "insecure deserialization",
        PICKLE_LOAD,
        None,
        "pickle.load on untrusted data can execute arbitrary code",
        "Use JSON for data serialization instead of pickle, or validate the source is trusted"
    ),
    (
        "insecure deserialization",
        UNSAFE_YAML,
        None,
        "yaml.load without SafeLoader can execute arbitrary code",
        "Use yaml.safe_load() instead of yaml.load(), or yaml.load(data, Loader=yaml.SafeLoader)"
    ),
    (
        "code execution risk",
        EVAL_EXTERNAL,
        None,
        "eval/exec on external input or LLM output can execute arbitrary code",
        "Avoid eval/exec entirely. Use json.loads for data, ast.literal_eval for literals, or a parser for expressions"
    ),
    (
        "weak cryptography",
        WEAK_HASH_PASSWORD,
        None,
        "MD5/SHA1 are too fast for password hashing and vulnerable to rainbow tables",
        "Use bcrypt, argon2, or scrypt for password hashing: bcrypt.hashpw(password.encode(), bcrypt.gensalt())"
    ),
    (
        "prompt injection",
        PROMPT_INJECTION,
        None,
        "F-strings with user input in LLM prompts allow prompt injection attacks",
        "Separate instructions from user data. Use message roles, XML tags, or explicit boundaries instead of f-strings"
    ),
    (
        "unsafe model loading",
        TORCH_LOAD,
        None,
        "torch.load without weights_only=True can execute arbitrary code from malicious model files",
        "Use torch.load(path, weights_only=True) or use safetensors format instead"
    ),
]


def added_text(tool_name, tool_input):
    """Only what this call introduces. Editing a line that happens to sit next
    to a vulnerability is not the same as introducing the vulnerability."""
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
    """Returns list of (vuln_type, explanation, fix) for all detected issues."""
    found = []

    for vuln_type, pattern, safe_pattern, explanation, fix in PATTERNS:
        # All patterns now use negative lookahead/lookbehind to exclude safe variants
        # safe_pattern is no longer used
        if pattern.search(text):
            found.append((vuln_type, explanation, fix))

    return found


def main():
    if foreman_state.disabled("FOREMAN_INSECURE_CODE"):
        return

    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return

    tool_input = data.get("tool_input") or {}
    path = tool_input.get("file_path") or ""

    # Cannot evaluate exemptions without a path. Fail open.
    if not path:
        return

    # Convert to repo-relative path for consistent exemption checking
    cwd = data.get("cwd") or ""
    if cwd and os.path.isabs(path) and path.startswith(cwd.rstrip("/") + "/"):
        path = os.path.relpath(path, cwd)

    # Exempt test files, fixtures, examples, and docs
    if SKIP_PATH.search(path) or os.path.splitext(path)[1].lower() in SKIP_EXTENSION:
        return

    found = findings(added_text(data.get("tool_name", ""), tool_input))
    if not found:
        return

    # Build a clear, actionable warning message
    vuln_type, explanation, fix = found[0]
    filename = os.path.basename(path)

    if len(found) == 1:
        reason = (
            f"[foreman] Security concern in {filename}:\n\n"
            f"{explanation}.\n\n"
            f"Fix: {fix}"
        )
    else:
        reason = (
            f"[foreman] {len(found)} security concerns in {filename}:\n\n"
            f"1. {vuln_type}: {explanation}\n"
        )
        for i, (vtype, expl, _) in enumerate(found[1:3], 2):
            reason += f"{i}. {vtype}: {expl}\n"
        if len(found) > 3:
            reason += f"\n...and {len(found) - 3} more.\n"
        reason += f"\nFirst fix: {fix}"

    reason += (
        "\n\nIf this is test/example code, move it to a tests/ or examples/ directory. "
        "To disable these checks: set FOREMAN_INSECURE_CODE=off in .claude/settings.json"
    )

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


main()
