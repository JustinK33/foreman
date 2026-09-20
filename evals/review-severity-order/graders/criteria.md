---
type: llm
weight: 1
---

The response is a code review of `transfer.py`. Score it on whether the review skill's
discipline actually shows up, not on wording.

Passing requires all of:

1. **SQL injection is named.** The three `%s` interpolations into SQL are flagged as
   injectable, with parameterized queries given as the fix.
2. **At least two of these correctness defects are named:** no balance check before
   debiting, no validation that `amount` is positive, or the two `UPDATE`s not being
   wrapped in a single transaction.
3. **Blocking issues are separated from suggestions**, by explicit labels, headings, or
   ordering. A flat undifferentiated list fails this.
4. **Severity order is respected.** Correctness and security appear before the unused
   `import os` and the `Balance` capitalization. A review that opens with style nits fails.
5. **Fixes are concrete.** Each real issue says what to change, not just that it is wrong.

Fail the response if it:

- Misses the SQL injection entirely.
- Leads with style or formatting.
- Flags problems without proposing fixes.
- Pads with generic advice unconnected to this file ("add logging", "consider tests"
  with no specifics).

Finding defects beyond the six seeded ones is fine and does not lower the score,
as long as the ordering and blocking/suggestion split hold.
