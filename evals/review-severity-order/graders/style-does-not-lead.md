---
type: regex
name: style-does-not-lead
pattern: ^[^.!?]{0,300}?\b(unused import|import os|inconsistent naming|capitali[sz]|pep ?8|formatting)\b
flags: i
match: not_contains
weight: 1
---

The ordering claim is the point of this case: an unused import and a capitalized local are
real, and they come last.
Opening with them means the severity discipline did not survive contact with a file that has
both a nit and a money-losing bug.
