---
type: regex
name: stays-a-question
pattern: red[,\s-]*green[,\s-]*refactor|def test_
flags: i
match: not_contains
weight: 1
---

A question about what code does is not a request to build anything.
Answering it with a red-green-refactor loop or a test suite is over-triggering, and
over-triggering is what makes people uninstall a plugin.
