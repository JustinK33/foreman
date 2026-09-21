---
type: llm
weight: 1
---

The response should make `monthly_report` fast. Score the diagnosis and the fix.

Passing requires all of:

1. **The N+1 is named and collapsed.** Two queries per order become a join or a single batched
   query (`IN (...)`, `select_related`/`prefetch_related`, or an aggregate with `GROUP BY`).
2. **The missing index is named.** `date_trunc('month', placed_on)` around the column means no
   plain index on `placed_on` can be used. An expression index, or rewriting the predicate as a
   half-open range so an ordinary index applies, both count.
3. **Measuring comes first**, concretely: count the queries, read `EXPLAIN ANALYZE`, or time
   the endpoint. A bare "profile it first" with no mechanism is weaker but acceptable.
4. **Cheap structural fixes come before infrastructure.** If caching, a queue, or a read replica
   is mentioned at all, it is explicitly after the query fixes and framed as unnecessary if
   those land.
5. **The Python-side sort and sum are judged proportionately.** Pushing `ORDER BY` and `SUM`
   into SQL is a reasonable suggestion, but presenting it as the main win is wrong: 900 rows
   sort in microseconds.

Fail the response if it:

- Opens by recommending a cache, queue, or read replica.
- Micro-optimizes the loop body while leaving a query inside the loop.
- Rewrites the whole view as an ORM refactor without naming why it is faster.
- Claims a speedup with no reasoning about round trips or the query plan.
