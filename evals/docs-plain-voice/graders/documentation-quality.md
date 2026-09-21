---
type: llm
weight: 1
---

The response is a README section for the `retry` decorator. Score whether a first-time user
could actually use it correctly.

Passing requires all of:

1. **A runnable usage example**, showing the decorator applied to a function.
2. **Every parameter is covered**: `attempts`, `base_delay`, `max_delay`, `jitter`, `on`.
3. **Which exceptions are retried is stated exactly**: only those in `on` (by default
   `ConnectionError` and `TimeoutError`); anything else propagates on the first raise.
4. **The backoff formula is stated**, not just called "exponential":
   `min(base_delay * 2 ** n, max_delay)`, and jitter multiplies it by a random factor in
   `[0.5, 1.0]`.
5. **Why jitter exists is explained in one clause**: it stops many clients retrying in lockstep
   after a shared outage. A user who does not know this turns it off.
6. **The failure behavior is stated**: after the last attempt the original exception is
   re-raised unchanged.

Fail the response if it:

- Omits `on` or `jitter`, the two parameters a user gets wrong.
- Describes backoff only as "exponential" with no formula or numbers.
- Opens with marketing ("a powerful, flexible retry utility").
- Restates the docstring verbatim with no example.
- Invents parameters or behavior the code does not have.
