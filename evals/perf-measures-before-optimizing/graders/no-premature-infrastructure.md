---
type: regex
name: no-premature-infrastructure
pattern: ^[^.!?]{0,400}?\b(redis|memcached|celery|read replica|message queue)\b
flags: i
match: not_contains
weight: 1
---

Reaching for a cache, a queue, or a read replica in the opening breath means the actual
problem, a missing index and 1800 avoidable round trips, went undiagnosed.
Mentioning them later as a deliberate follow-up is fine; leading with them is not.
