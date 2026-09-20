---
name: perf
description: Use when the user asks to improve performance, find bottlenecks, optimize the backend, or speed something up. Also trigger on "/perf".
---

# Performance Review

Measure before you change anything, and change the thing that's actually slow, not the thing that's easiest to rewrite.

## Method

1. **Find the bottleneck, don't guess it.** Look for profiling data, logs, query timings, or APM traces first. If none exist, say so and either ask for a profile or reason from the code's structure (loop nesting, query patterns) while being explicit that this is an estimate, not a measurement.
2. **Prioritize by impact x frequency**, not by what looks inelegant. A slightly ugly function called once at startup matters less than a mediocre one called per-request.
3. **Fix, then re-measure.** A performance fix without a before/after number is a guess that happened to compile.

## Backend patterns to check, roughly by how often they're the real cause

1. **N+1 queries** - a loop that issues one query per iteration instead of one batched query (`SELECT` in a loop over an ORM relationship is the classic case). Usually the single highest-impact fix available.
2. **Missing or wrong indexes** - slow queries on columns used in `WHERE`, `JOIN`, or `ORDER BY` without a supporting index; also indexes that exist but aren't used because of a function wrapped around the column or a type mismatch.
3. **Unbounded result sets** - loading an entire table into memory instead of paginating, streaming, or filtering at the database layer.
4. **Synchronous I/O blocking a request path that doesn't need it** - sequential awaited calls to independent services instead of concurrent ones; blocking calls on an async runtime's event loop.
5. **Missing caching for expensive, repeatable work** - the same computation or query re-run per request when the result is stable for some useful window. Also check the inverse: caching that's gone stale or is invalidated incorrectly, which is worse than no cache.
6. **Algorithmic complexity** - an O(n^2) pass over data that's routinely large, where a hash map or a single sorted pass gets it to O(n) or O(n log n). Only worth flagging where n is actually large in practice.
7. **Connection/resource churn** - opening a new DB connection, HTTP client, or thread pool per request instead of reusing a pool.
8. **Serialization overhead** - large payloads serialized/deserialized in full when only a subset of fields is needed downstream.

## Design-level changes (bigger lever, bigger cost, mention with the tradeoff attached)

- Read replicas or caching layers for read-heavy workloads.
- Moving work off the request path into a background job/queue when the caller doesn't need the result synchronously.
- Denormalizing a hot-path read to avoid an expensive join, at the cost of write complexity and eventual-consistency risk, state that cost explicitly.
- Batching/debouncing high-frequency writes.

Always name what a design change costs (consistency, complexity, operational surface) alongside what it buys. A recommendation without the tradeoff isn't a complete recommendation.

## What not to do

- Don't micro-optimize code that isn't on a hot path; that's wasted effort and adds noise to the diff.
- Don't recommend a caching layer, queue, or read replica as a first move if the actual problem is a missing index or an N+1 query, fix the cheap thing first.
- Don't sacrifice correctness or readability for a speedup that hasn't been shown to matter. Pair with `lean`: the fastest code is often also the simplest, but not always, call out explicitly when they trade off against each other.
