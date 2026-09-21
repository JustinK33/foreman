---
description: Audit the codebase or current diff for security vulnerabilities, front end and back end.
argument-hint: "[path or module, defaults to the current diff]"
---

Follow the `security` skill. Scope to $ARGUMENTS if given, otherwise scan the current diff plus anywhere it touches auth, data access, or user input. Report each finding with severity, exact location, trigger condition, and fix. Don't write or complete exploit code.
