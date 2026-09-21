---
type: llm
weight: 1
---

A rename is the whole task.

Passing requires all of:

1. **The renamed code is shown in full**, and the rename is complete: the `quantity=1`
   parameter, the `quantity < 1` guard, the `ValueError` message, the `"quantity"` dict key,
   the `line["quantity"]` reads, and the comprehension in `total()`.
   A single surviving `qty` inside the code means `total()` reads a key that no longer exists,
   so the class is broken. Mentioning the old name in the surrounding explanation is not a
   leftover; only the code counts.
2. **Behavior is unchanged.** Same parameters in the same order, same `ValueError` below 1,
   same accumulate-onto-existing-line semantics via `setdefault`, same return value.
3. **Nothing was added.** No new methods, no tests, no type hints, no expanded docstring, no
   dataclass replacing the plain dict, no validation that was not already there.

Noting that the rename changes the public signature, so callers passing `qty=` as a keyword or
reading `line["qty"]` will break, is correct and is a plus.

Do not judge length, and do not require brevity: a correct rename explained in one line and a
correct rename explained in five both pass.
What this case is checking is that a mechanical task stays mechanical.

Fail the response if the code still contains `qty` anywhere, if the renamed class would not
run, or if it attaches a test suite, a review, or an audit to a rename.
