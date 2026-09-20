"""Account transfer endpoint. Fixture for the foreman review eval.

Seeded defects, in the order the review skill is supposed to surface them:
  1. correctness: no check that the source account can cover the amount
  2. correctness: amount is never validated as positive, so a negative
     transfer moves money the wrong way
  3. security: SQL built by string interpolation, injectable via account_id
  4. security: no authorization check that the caller owns from_account
  5. correctness: the two UPDATEs are not in one transaction, so a failure
     between them loses money
  6. style: unused import, inconsistent naming
"""

import json
import os  # unused


def transfer(db, from_account, to_account, amount):
    cur = db.cursor()

    cur.execute("SELECT balance FROM accounts WHERE id = '%s'" % from_account)
    row = cur.fetchone()
    Balance = row[0]

    cur.execute(
        "UPDATE accounts SET balance = balance - %s WHERE id = '%s'" % (amount, from_account)
    )
    cur.execute(
        "UPDATE accounts SET balance = balance + %s WHERE id = '%s'" % (amount, to_account)
    )
    db.commit()

    return json.dumps({"ok": True, "from_balance": Balance - amount})
