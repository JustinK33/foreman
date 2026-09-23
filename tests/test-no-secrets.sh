#!/usr/bin/env bash
# The credential gate is the one check that blocks, so the false-positive cases
# below matter more than the detection cases. A security hook that stops
# legitimate work gets uninstalled, and then it protects nothing.
#
# No framework: asserts on the hook's stdout and exit code, nothing more.
#
# shellcheck disable=SC2016
# The single quotes are the point. These fixtures are source code being handed
# to the hook, so ${DB_PASSWORD} and `ANTHROPIC_API_KEY=...` have to reach it
# unexpanded, exactly as a user would have written them in a file.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/no-secrets.sh"

pass=0
fail=0

# Usage: check <name> <expect: allow|deny|ask> <path> <content>
check() {
  local name="$1" expect="$2" path="$3" content="$4"
  local out status

  out="$(python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Write",
    "cwd": "/repo",
    "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]},
}))' "$path" "$content" | bash "$HOOK" 2>/dev/null)"
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "  FAIL  $name: hook exited $status, must always exit 0"
    fail=$((fail + 1))
    return
  fi

  if [ "$expect" = allow ]; then
    if [ -n "$out" ]; then
      echo "  FAIL  $name: expected to allow, got: ${out:0:110}"
      fail=$((fail + 1))
      return
    fi
    echo "  ok    $name"
    pass=$((pass + 1))
    return
  fi

  # Parsed, not grepped: the decision and the reason are a contract with Claude
  # Code, and a whitespace change in json.dump must not read as a pass.
  local decision
  decision="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    out = json.load(sys.stdin)["hookSpecificOutput"]
except Exception:
    print("unparseable"); raise SystemExit
# The model only gets to fix the line if the reason reaches it.
reason = out.get("permissionDecisionReason") or ""
print(out.get("permissionDecision", "none") if reason.strip() else "no-reason")
')"

  if [ "$decision" != "$expect" ]; then
    echo "  FAIL  $name: expected $expect, got $decision"
    fail=$((fail + 1))
    return
  fi
  echo "  ok    $name"
  pass=$((pass + 1))
}

echo "detects"

check "AWS access key ID" deny "src/config.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

check "PEM private key" deny "src/auth.py" \
  'KEY = """-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCA
-----END RSA PRIVATE KEY-----"""'

check "Anthropic API key" deny "src/client.ts" \
  'const key = "sk-ant-api03-7fKq2LmNpR8sTvWxYz1234567890AbCdEfGh"'

check "OpenAI API key" deny "src/client.ts" \
  'const key = "sk-proj-9dJk2LmNpR8sTvWxYz1234567890AbCdEfGhIjKl"'

check "GitHub token" deny "scripts/release.js" \
  'const token = "ghp_9dJk2LmNpR8sTvWxYz1234567890AbCdEfGhIj"'

# The '' splits the prefix so GitHub push protection does not read these fake
# keys as real ones. The shell joins the halves, so the hook sees the whole key.
check "Slack token" deny "src/notify.rb" \
  'TOKEN = "xox''b-123456789012-9876543210987-AbCdEfGhIjKlMnOp"'

check "live Stripe key" deny "src/billing.go" \
  'const key = "sk_''live_9dJk2LmNpR8sTvWxYz1234567890"'

check "Google API key" deny "src/maps.js" \
  'const k = "AIzaSyD9dJk2LmNpR8sTvWxYz1234567890AbCdE"'

check "hardcoded password literal" deny "src/db.py" \
  'DB_PASSWORD = "hunter2CorrectHorse"'

check "hardcoded client_secret" deny "src/oauth.py" \
  'client_secret = "9dJk2LmNpR8sTvWxYz1234567890"'

echo
echo "does not block legitimate work"

# The whole point: the fix the hook asks for must not itself be blocked.
check "reading from the environment" allow "src/db.py" \
  'DB_PASSWORD = os.environ["DB_PASSWORD"]'

check "process.env lookup" allow "src/client.ts" \
  'const key = process.env.ANTHROPIC_API_KEY'

# A real .env is where the real value belongs.
check ".env itself" allow ".env" \
  'ANTHROPIC_API_KEY=sk-ant-api03-7fKq2LmNpR8sTvWxYz1234567890AbCdEfGh'

check ".env.local" allow "config/.env.local" \
  'AWS_ACCESS_KEY_ID=AKIA2E0TVBZJ4QK7XYZM'

# AWS documents AKIAIOSFODNN7EXAMPLE. Every provider has an equivalent.
check "documented example key" allow "src/config.py" \
  'AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"'

check "placeholder in a template" allow "src/config.py" \
  'API_KEY = "your-api-key-here"'

check "angle-bracket placeholder" allow "src/config.py" \
  'password = "<your password>"'

check "XXXX redaction" allow "src/config.py" \
  'api_key = "XXXXXXXXXXXX"'

check "interpolated value" allow "deploy/config.py" \
  'password = "${DB_PASSWORD}"'

# A README showing a key format is documentation, not a leak.
check "markdown showing a key format" allow "README.md" \
  'Set `ANTHROPIC_API_KEY=sk-ant-api03-7fKq2LmNpR8sTvWxYz1234567890AbCdEfGh`'

# Fixtures contain fake keys on purpose, and blocking them blocks the tests
# that prove this hook works.
check "test fixture with a fake key" allow "tests/fixtures/creds.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

check "a test file" allow "src/auth_test.go" \
  'const key = "sk_''live_9dJk2LmNpR8sTvWxYz1234567890"'

check "an example directory" allow "examples/quickstart.py" \
  'client_secret = "9dJk2LmNpR8sTvWxYz1234567890"'

# Short values are not credentials, they are flags and enum members.
check "short value" allow "src/config.py" \
  'password = "none"'

check "ordinary code" allow "src/util.py" \
  'def slugify(name):
    return name.lower().replace(" ", "-")'

# "latest" contains "test", and must not be read as a test path.
check "latest.py is not a test path" deny "src/latest.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

echo
echo "degrades quietly"

check "no file path" allow "" 'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

if [ -n "$(printf 'not json' | bash "$HOOK" 2>/dev/null)" ]; then
  echo "  FAIL  malformed stdin must stay silent"
  fail=$((fail + 1))
else
  echo "  ok    malformed stdin stays silent"
  pass=$((pass + 1))
fi

if [ -n "$(printf '' | bash "$HOOK" 2>/dev/null)" ]; then
  echo "  FAIL  empty stdin must stay silent"
  fail=$((fail + 1))
else
  echo "  ok    empty stdin stays silent"
  pass=$((pass + 1))
fi

echo
echo "config"

FOREMAN_SECRETS=off \
  check "FOREMAN_SECRETS=off allows it through" allow "src/config.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

FOREMAN_OFF=1 \
  check "FOREMAN_OFF=1 allows it through" allow "src/config.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

# For anyone who will not accept a hook that refuses outright.
FOREMAN_SECRETS=ask \
  check "FOREMAN_SECRETS=ask defers to the user" ask "src/config.py" \
  'AWS_ACCESS_KEY_ID = "AKIA2E0TVBZJ4QK7XYZM"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
