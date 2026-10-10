#!/usr/bin/env bash
# Insecure code pattern detection. The bar is high confidence, so false positives
# should be rare. Test both detection and exemptions.
#
# No framework: asserts on the hook's stdout and exit code, nothing more.
#
# shellcheck disable=SC2016
# Single quotes preserve the source code exactly as written.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/insecure-code.sh"

pass=0
fail=0

# Usage: check <name> <expect: allow|ask> <path> <content>
check() {
  local name="$1" expect="$2" path="$3" content="$4" cwd="${5:-/repo}"
  local out status

  out="$(python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Write",
    "cwd": sys.argv[3],
    "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]},
}))' "$path" "$content" "$cwd" | bash "$HOOK" 2>/dev/null)"
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

  local decision
  decision="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    out = json.load(sys.stdin)["hookSpecificOutput"]
except Exception:
    print("unparseable"); raise SystemExit
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

echo "SQL injection detection"

check "SQL concat with +" ask "src/db.py" \
  'cursor.execute("SELECT * FROM users WHERE id = " + user_id)'

check "SQL f-string" ask "src/query.py" \
  'cursor.execute(f"SELECT * FROM users WHERE name = {username}")'

check "SQL template literal" ask "src/db.js" \
  'db.query(`SELECT * FROM users WHERE id = ${userId}`)'

check "SQL UPDATE with concat" ask "src/update.py" \
  'cursor.execute("UPDATE users SET name = " + name + " WHERE id = " + str(user_id))'

echo ""
echo "SQL injection safe patterns (should allow)"

check "parameterized with ?" allow "src/safe_db.py" \
  'cursor.execute("SELECT * FROM users WHERE id = ?", (user_id,))'

check "parameterized with %s" allow "src/safe_db.py" \
  'cursor.execute("SELECT * FROM users WHERE id = %s", [user_id])'

check "SQL without variables" allow "src/migration.sql" \
  'SELECT * FROM users WHERE active = 1'

echo ""
echo "command injection detection"

check "subprocess shell=True with f-string" ask "src/deploy.py" \
  'subprocess.run(f"git clone {repo_url}", shell=True)'

check "subprocess shell=True with concat" ask "src/backup.py" \
  'subprocess.run("rm -rf " + directory, shell=True)'

check "os.system with f-string" ask "src/cleanup.py" \
  'os.system(f"rm -rf {tmp_dir}")'

check "os.system with variable" ask "src/exec.py" \
  'os.system(command + " --force")'

check "JS exec with template" ask "src/deploy.js" \
  'exec(`git clone ${repoUrl}`)'

echo ""
echo "command injection safe patterns (should allow)"

check "subprocess shell=False" allow "src/safe_exec.py" \
  'subprocess.run(["git", "clone", repo_url])'

check "subprocess list args" allow "src/safe_exec.py" \
  'subprocess.run(["rm", "-rf", directory], shell=False)'

check "hardcoded command" allow "src/build.py" \
  'subprocess.run("npm install", shell=True)'

echo ""
echo "XSS detection"

check "dangerouslySetInnerHTML" ask "src/Component.tsx" \
  'return <div dangerouslySetInnerHTML={{ __html: userContent }} />'

check "innerHTML assignment" ask "src/app.js" \
  'element.innerHTML = userData'

check "v-html directive" ask "src/Component.vue" \
  '<div v-html="userInput"></div>'

echo ""
echo "XSS safe patterns (should allow)"

check "textContent instead" allow "src/safe.js" \
  'element.textContent = userData'

check "sanitized HTML" allow "src/safe.tsx" \
  'return <div>{sanitize(userContent)}</div>'

echo ""
echo "insecure deserialization detection"

check "pickle.load" ask "src/cache.py" \
  'data = pickle.load(file)'

check "pickle.loads" ask "src/session.py" \
  'session = pickle.loads(cookie_data)'

check "yaml.load without SafeLoader" ask "src/config.py" \
  'config = yaml.load(file_content)'

echo ""
echo "deserialization safe patterns (should allow)"

check "json.loads" allow "src/api.py" \
  'data = json.loads(request.body)'

check "yaml.safe_load" allow "src/config.py" \
  'config = yaml.safe_load(file_content)'

check "yaml.load with SafeLoader" allow "src/config.py" \
  'config = yaml.load(file_content, Loader=yaml.SafeLoader)'

echo ""
echo "eval/exec on external input"

check "eval on request data" ask "src/api.py" \
  'result = eval(request.data)'

check "exec on response" ask "src/process.py" \
  'exec(response.text)'

check "eval on LLM output" ask "src/ai.py" \
  'result = eval(completion)'

check "exec on generated code" ask "src/codegen.py" \
  'exec(generated_code)'

echo ""
echo "eval/exec safe patterns (should allow)"

check "eval on literal" allow "src/calc.py" \
  'result = eval("2 + 2")'

check "ast.literal_eval" allow "src/parse.py" \
  'data = ast.literal_eval(input_str)'

echo ""
echo "weak cryptography for passwords"

check "MD5 for password" ask "src/auth.py" \
  'hash = hashlib.md5(password.encode()).hexdigest()'

check "SHA1 for password" ask "src/auth.py" \
  'hash = hashlib.sha1(user_password.encode()).hexdigest()'

echo ""
echo "weak crypto safe patterns (should allow)"

check "MD5 for checksum" allow "src/verify.py" \
  'checksum = hashlib.md5(file_content).hexdigest()'

check "bcrypt for password" allow "src/auth.py" \
  'hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())'

check "argon2 for password" allow "src/auth.py" \
  'hash = argon2.hash(password)'

echo ""
echo "AI-specific patterns"

check "prompt injection via f-string" ask "src/ai.py" \
  'anthropic.messages.create(messages=[{"role": "user", "content": f"Task: {user_task}"}])'

check "unsafe torch.load" ask "src/model.py" \
  'model = torch.load(model_path)'

check "prompt injection in OpenAI" ask "src/gpt.py" \
  'openai.chat.completions.create(messages=[{"content": f"Summarize: {user_input}"}])'

echo ""
echo "AI safe patterns (should allow)"

check "torch.load with weights_only" allow "src/model.py" \
  'model = torch.load(model_path, weights_only=True)'

check "prompt with proper boundaries" allow "src/ai.py" \
  'prompt = "Summarize this text:\n\n" + sanitize(user_input)'

check "hardcoded prompt" allow "src/ai.py" \
  'anthropic.messages.create(messages=[{"role": "user", "content": "Hello"}])'

echo ""
echo "exemptions (test files should allow)"

check "SQL injection in test" allow "tests/test_db.py" \
  'cursor.execute("SELECT * FROM users WHERE id = " + user_id)'

check "command injection in test" allow "tests/test_exec.py" \
  'subprocess.run(f"echo {data}", shell=True)'

check "SQL in spec file" allow "spec/db_spec.rb" \
  'query = "SELECT * FROM users WHERE id = #{user_id}"'

check "pickle in fixture" allow "fixtures/data.py" \
  'data = pickle.load(file)'

check "SQL in example" allow "examples/queries.py" \
  'cursor.execute(f"SELECT * FROM {table}")'

check "command in mock" allow "__mocks__/exec.js" \
  'exec(`rm -rf ${dir}`)'

echo ""
echo "exemptions (docs should allow)"

check "SQL in markdown" allow "docs/database.md" \
  'cursor.execute("SELECT * FROM users WHERE id = " + user_id)'

check "command in README" allow "README.md" \
  'subprocess.run(f"git clone {repo}", shell=True)'

echo ""
echo "edge cases"

check "no SQL keywords" allow "src/concat.py" \
  'message = "Hello " + username'

check "SQL keywords without variables" allow "src/query.sql" \
  'SELECT * FROM users WHERE active = TRUE'

check "multiple issues" ask "src/bad.py" \
  'cursor.execute("SELECT * FROM users WHERE id = " + user_id)
os.system(f"rm {file}")'

echo ""
echo "mixed safe and unsafe patterns"

check "safe YAML then unsafe YAML" ask "src/config.py" \
  'safe_config = yaml.safe_load(file1)
unsafe_config = yaml.load(file2)'

check "unsafe SQL then safe SQL" ask "src/db.py" \
  'cursor.execute("DELETE FROM users WHERE id = " + user_id)
cursor.execute("SELECT * FROM users WHERE id = ?", (user_id,))'

check "safe torch.load then unsafe torch.load" ask "src/model.py" \
  'safe_model = torch.load(path1, weights_only=True)
unsafe_model = torch.load(path2)'

echo ""
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
