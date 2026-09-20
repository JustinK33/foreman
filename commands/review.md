---
description: Review the current diff or a PR for correctness, tests, security, design, readability, and performance, in that order.
---

Follow the `review` skill. Review $ARGUMENTS if given (a PR number, branch, or file); otherwise review the current uncommitted diff (`git diff` / `git diff --staged`). Lead with a one-line verdict, then list blocking issues separately from suggestions, each with file:line and a concrete fix.
