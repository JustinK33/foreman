---
name: tdd
description: Use whenever the user asks to build a feature, fix a bug, or wants strict test-driven development (red-green-refactor). Also trigger on "/tdd", "write the test first", or "TDD this".
---

# Test-Driven Development

Red, green, refactor. In that order, every time. No production code without a failing test that demanded it.

## The loop

1. **Red** - Write one small test for behavior that doesn't exist yet. Run it. Confirm it fails, and fails for the reason you expect (not a typo or import error). A test you haven't watched fail is a test you can't trust.
2. **Green** - Write the *smallest* amount of code that makes the test pass. Hardcoding a return value to pass one test is correct at this stage if that's genuinely the minimum. Resist the urge to also handle the next three cases you can already see coming.
3. **Refactor** - With the safety net of a passing test, clean up: remove duplication, rename for clarity, extract only if extraction earns its keep. Tests must stay green through this step. If they don't, you broke behavior, not just structure.
4. Repeat for the next smallest behavior.

## Test quality bar

- One assertion concept per test. If a test needs three "and"s in its name, split it.
- Test names describe behavior, not implementation: `rejects_withdrawal_over_balance`, not `test_withdraw_2`.
- Arrange-Act-Assert (or Given-When-Then) structure, visually separated, no need to label it.
- Cover: the happy path, the boundary (empty, zero, max, off-by-one), and the failure mode (invalid input, exception). Skip redundant tests that vary only in irrelevant input.
- Mock at architectural boundaries (network, filesystem, clock, external services), not internal collaborators. Over-mocking makes tests pass while the real integration is broken.
- A test that never fails when the code is wrong is worse than no test. Sanity-check new tests by breaking the code and confirming the test catches it.

## When the user has existing code with no tests

Don't try to blanket the file. Characterize current behavior with a few tests first (this locks in what the code *does*, not what it *should* do), then apply the red-green-refactor loop only to the part you're changing.

## What this skill does not do

It doesn't decide *what* to build, that's the task at hand, it governs *how* the code gets built once you know. Pair with the `lean` skill: the "green" step should reach for the smallest solution on the lean ladder, not the most general one.

## Anti-patterns to avoid

- Writing all the tests up front, then all the code. That's "test-first," not TDD; you lose the fast feedback loop and the tests stop steering the design.
- Testing private/internal implementation details instead of observable behavior. Refactoring should never require touching the tests unless the public contract changed.
- Skipping the "watch it fail" step. A test that passes immediately might be testing nothing.
