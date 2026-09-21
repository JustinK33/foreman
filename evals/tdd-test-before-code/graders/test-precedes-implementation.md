---
type: regex
name: test-precedes-implementation
pattern: def test_\w*remove\w*[\s\S]*def remove_item
flags: ""
match: contains
weight: 1
---

The whole point of the skill is that the test exists before the code it forces.
If `remove_item` appears in the answer before any test naming it, the loop was not followed,
whatever the surrounding prose claims.

`[\s\S]*` rather than `.*` with an `s` flag, because the pattern has to survive a reader
copying it somewhere that does not set flags.
