---
type: regex
name: no-unrequested-work
pattern: def test_|red[,\s-]*green[,\s-]*refactor|\bseverity\b|\n#{1,4} *(security|performance|review)
flags: i
match: not_contains
weight: 1
---

A rename is not a request for a test suite, a TDD loop, or an audit.
These are the artifacts that only appear when a skill has taken over a task it was not asked
to run, which is the single fastest way to make somebody uninstall a plugin.
