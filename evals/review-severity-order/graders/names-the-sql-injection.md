---
type: regex
name: names-the-sql-injection
pattern: sql injection|injectable|parameteri[sz]ed|bound parameter|placeholder
flags: i
match: contains
weight: 1
---

Three `%s` interpolations put `from_account` straight into SQL.
It is the defect in this file that an attacker reaches first, so a review that does not name it
is not a review, and that judgement does not need a judge.
