---
max_turns: 10
allowed_tools: [Skill]
runs: 3
timeout_seconds: 600
---

Write the README section documenting this `retry` decorator for somebody reaching for it the
first time.

```python
"""Retry helper used by the API clients."""

import functools
import random
import time

TRANSIENT = (ConnectionError, TimeoutError)


def retry(attempts=3, base_delay=0.5, max_delay=8.0, jitter=True, on=TRANSIENT):
    """Retry a callable on transient failures with exponential backoff.

    Only exceptions in `on` are retried; everything else propagates on the first
    raise. The final attempt's exception is re-raised unchanged, so a caller sees
    the real error rather than a wrapper. Sleep between attempt n and n+1 is
    min(base_delay * 2 ** n, max_delay), multiplied by a random factor in
    [0.5, 1.0] when jitter is on, which is what keeps a fleet of clients from
    retrying in lockstep after a shared outage.
    """

    def decorate(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(attempts):
                try:
                    return func(*args, **kwargs)
                except on:
                    if attempt == attempts - 1:
                        raise
                    delay = min(base_delay * 2 ** attempt, max_delay)
                    if jitter:
                        delay *= random.uniform(0.5, 1.0)
                    time.sleep(delay)

        return wrapper

    return decorate
```
