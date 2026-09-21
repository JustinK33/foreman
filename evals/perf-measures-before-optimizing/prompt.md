---
max_turns: 12
allowed_tools: [Skill]
runs: 3
timeout_seconds: 600
---

`GET /reports/monthly` takes about four seconds for an account with 900 orders. Make it fast.

```python
"""Monthly reporting endpoints."""

from django.db import connection


def monthly_report(request):
    account_id = request.GET["account_id"]
    month = request.GET["month"]

    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, customer_id, total_cents FROM orders "
            "WHERE account_id = %s AND date_trunc('month', placed_on) = %s",
            [account_id, month],
        )
        orders = cursor.fetchall()

    rows = []
    for order_id, customer_id, total_cents in orders:
        with connection.cursor() as cursor:
            cursor.execute("SELECT name, tier FROM customers WHERE id = %s", [customer_id])
            name, tier = cursor.fetchone()
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT COUNT(*) FROM order_items WHERE order_id = %s", [order_id]
            )
            item_count = cursor.fetchone()[0]
        rows.append(
            {
                "order_id": order_id,
                "customer": name,
                "tier": tier,
                "items": item_count,
                "total_cents": total_cents,
            }
        )

    rows.sort(key=lambda row: row["total_cents"], reverse=True)
    return {"month": month, "rows": rows, "revenue_cents": sum(r["total_cents"] for r in rows)}
```
