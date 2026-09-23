---
name: review
description: Use before pushing, opening a PR, or when the user asks to review code, review a diff, or review a pull request. Also trigger on "/foreman:review" or "/review".
argument-hint: "[PR number, branch, or path]"
---

# Code Review

Review like the senior engineer whose approval actually means something, not the one who rubber-stamps to clear their queue.

## What to review

`$ARGUMENTS`, when that is not empty. A bare number is a PR number, so fetch it with `gh pr view` and
`gh pr diff`. Anything with a slash or a dot is a path. Otherwise treat it as a branch or a ref and diff
it against the default branch.

With no argument, review the uncommitted diff, and if the tree is clean, the most recent commit.

## Order of operations

Review in this order; each layer is cheaper to fix than the next, so catch it first:

1. **Correctness** - Does it do what it claims? Walk the logic against the stated requirement, not just against itself. Check edge cases: empty input, nulls, concurrent access, the boundary conditions.
2. **Tests** - Do tests exist for the change? Do they test behavior, not implementation? Would they actually fail if the logic were wrong (mentally break the code and check)?
3. **Security** - Any of: unvalidated input crossing a trust boundary, secrets or credentials in code, injection vectors (SQL, command, template), broken auth/authz checks, unsafe deserialization. If found, this blocks the review regardless of everything else.
4. **API/interface design** - Is the public surface (function signatures, endpoints, schemas) something you'd be comfortable maintaining in a year? Breaking changes called out explicitly?
5. **Readability & maintainability** - Naming, function length, whether a future reader (including future-you) can follow the intent without re-deriving it.
6. **Performance** - Only flag if there's a real cost: N+1 queries, unbounded loops over user-controlled input, obvious algorithmic complexity issues. Don't nitpick micro-optimizations with no measured impact.
7. **Style/nits** - Last, and lightest touch. If a linter/formatter should catch it, say so once and move on; don't relitigate style in prose.

## Cuts that are never acceptable

A change can be small and still be wrong to accept. Block on these regardless of how tidy the diff looks:

- Input validation dropped at a trust boundary (anything from a user, network, or file).
- No error handling on an operation that can fail: I/O, network calls, parsing.
- A security check thinned out or removed: auth, authorization, escaping, sanitization.
- Accessibility stripped from user-facing code: semantic elements, labels, keyboard paths.

Brevity is a property of the solution, not a license to skip the parts that prevent data loss.
If a diff got shorter by deleting one of the above, that is not simplification.

## How to write the actual comments

- Lead with what's good, briefly, then get specific. No padding.
- Every comment on a real issue includes: what's wrong, why it matters, and a concrete suggested fix, not just "this could be better."
- Separate **blocking** issues from **suggestions** explicitly. Reviewers who don't do this either block on nits or let real issues slide because everything reads the same.
- Ask questions when intent is unclear rather than assuming malice or incompetence: "What happens if `items` is empty here?" beats "This will break."
- Reference specific lines/files, not vague summaries.

## For a full PR (not just a diff)

Also check: does the PR do one thing (or is it three PRs wearing a trenchcoat)? Does the description explain *why*, not just *what*? Is the diff reviewable in one sitting, or should it be split?

## Self-review mode

When the user wants to review their own code before pushing: be at least as strict as you'd be reviewing someone else's. The most common failure mode here is going easy because there's no external reviewer to disappoint.

## Output format

A short summary verdict first (ship it / ship with fixes / blocking issues), then the issues grouped by severity, each with file:line, the problem, and the fix. Skip the sections above that had nothing to flag, don't force filler into them.
