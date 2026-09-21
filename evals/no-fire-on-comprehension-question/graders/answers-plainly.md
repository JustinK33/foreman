---
type: llm
weight: 1
---

The prompt is a comprehension question with one correct answer: `add_item` uses `setdefault`,
so adding the same sku again accumulates onto the existing line and returns the new running
quantity for that sku. The line is not replaced.

Passing requires:

1. **The accumulation is described correctly**, including that the returned value is the new
   running quantity for that sku.
2. **Nothing was built.** No test suite, no red-green-refactor loop, no refactor proposal, no
   severity-ranked audit, no rewrite of the class.

Noticing that the second call's `unit_price` is silently discarded, because `setdefault` only
inserts when the key is absent, is correct and is a plus.
So is walking through a short worked example.

Do not fail an answer for being longer than strictly necessary, and do not require any
particular length: an accurate explanation is an accurate explanation.
What this case is checking is that a question about existing code gets answered rather than
turned into a project.

Fail the response if it says the existing line is replaced or overwritten, if it claims the
second `unit_price` takes effect, or if it answers by starting to build something.
