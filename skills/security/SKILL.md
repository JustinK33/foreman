---
name: security
description: Use when the user asks for a security review, vulnerability scan, security audit, or to check code for security issues, front end or back end. Also trigger on "/foreman:security" or "/security".
argument-hint: "[file, directory, or area to audit]"
---

# Security Review

Walk the codebase like an attacker would: find every place untrusted data enters, and follow it.

## Where to look, in order of actual exploit frequency

1. **Injection** - SQL/NoSQL queries built with string concatenation instead of parameterization; shell commands built from user input; template injection (SSTI) where user input reaches a template engine; LDAP/XPath injection in less common stacks.
2. **Broken authentication & session handling** - Passwords stored with fast hashes (MD5/SHA1/plain) instead of bcrypt/argon2/scrypt; session tokens that don't expire or aren't invalidated on logout; JWTs with `alg: none` accepted, or signature not verified at all; missing rate limiting on login/password-reset endpoints.
3. **Broken access control** - Authorization checked at the UI layer but not the API; object references (IDs in URLs) not checked against the requesting user (IDOR); admin routes reachable by role-check bypass; missing checks on newly added endpoints that copy an existing pattern minus the auth middleware.
4. **Sensitive data exposure** - Secrets, API keys, or credentials committed to the repo or logged in plaintext; PII in logs or error messages; missing encryption in transit (HTTP instead of HTTPS) or at rest for sensitive fields; overly detailed error messages that leak stack traces or internal paths to the client.
5. **Cross-site scripting (XSS)** - User input rendered into HTML without escaping; `dangerouslySetInnerHTML` / `innerHTML` / `v-html` fed from user data; missing or weak Content-Security-Policy.
6. **Cross-site request forgery (CSRF)** - State-changing requests (POST/PUT/DELETE) without CSRF tokens or `SameSite` cookie protection on cookie-authenticated apps.
7. **Insecure deserialization** - Deserializing untrusted data with formats that can execute code (pickle, unsafe YAML load, Java native serialization) instead of safe formats (JSON) or safe-mode loaders.
8. **Dependency risk** - Known-vulnerable versions of libraries in the manifest (check against what's actually imported and reachable, not just what's listed); transitive dependencies pulling in something abandoned.
9. **Misconfiguration** - Debug mode on in production; default credentials; overly permissive CORS (`*` with credentials); directory listing enabled; verbose framework version headers.
10. **SSRF** - Server-side requests built from user-supplied URLs without validating against internal/metadata IP ranges (particularly relevant for anything that fetches a URL the user gives it, like a webhook or image importer).

## Front end specific

DOM-based XSS, insecure `postMessage` handlers (missing origin checks), secrets accidentally bundled into client-side JS, client-side-only validation with no server-side enforcement behind it, insecure storage of tokens (localStorage vs httpOnly cookies for anything sensitive).

## How to report findings

For each finding: severity (critical/high/medium/low, based on exploitability and impact, not just theoretical existence), the exact location, a minimal proof-of-concept or trigger condition, and the concrete fix, not just "sanitize input." Don't pad the report with informational-only findings dressed up as vulnerabilities; that trains people to skim past the report entirely.

## Ground rules

- Never write, complete, or explain working exploit code, malware, or attack tooling, even to demonstrate a finding. Describe the vulnerability class and how to reproduce/verify it at a level a defender needs, not a weaponized payload.
- If asked to test against a live system that isn't clearly the user's own, decline and explain why.
- A vulnerability that requires an already-compromised, fully-trusted position to exploit is lower priority than one reachable from an anonymous request; state the practical prerequisite for each finding so priority is obvious.
