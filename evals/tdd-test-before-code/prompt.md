---
max_turns: 10
allowed_tools: [Skill]
runs: 3
timeout_seconds: 600
---

`cart.py` has no way to take an item back out.

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

Its existing suite, `test_cart.py`:

```python
from cart import Cart


def test_add_item_sets_quantity():
    cart = Cart()
    assert cart.add_item("APPLE", qty=2, unit_price=150) == 2


def test_add_item_accumulates_the_same_sku():
    cart = Cart()
    cart.add_item("APPLE", qty=2, unit_price=150)
    assert cart.add_item("APPLE", qty=3) == 5


def test_add_item_rejects_a_zero_quantity():
    cart = Cart()
    try:
        cart.add_item("APPLE", qty=0)
    except ValueError:
        return
    raise AssertionError("expected ValueError")
```

Add `remove_item(sku)`: it drops that line from the cart, and raises `KeyError` if the sku was
never added. Show the code, in the order you would write it.
