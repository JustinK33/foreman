---
max_turns: 8
allowed_tools: [Skill]
runs: 3
timeout_seconds: 600
---

Rename the variable `qty` to `quantity` everywhere it appears in this file and show me the
result. Nothing else.

```python
"""A small shopping cart."""


class Cart:
    def __init__(self):
        self.lines = {}

    def add_item(self, sku, qty=1, unit_price=0):
        """Adding an existing sku accumulates quantity rather than replacing it."""
        if qty < 1:
            raise ValueError("qty must be at least 1")
        line = self.lines.setdefault(sku, {"qty": 0, "unit_price": unit_price})
        line["qty"] += qty
        return line["qty"]

    def total(self):
        return sum(line["qty"] * line["unit_price"] for line in self.lines.values())
```
