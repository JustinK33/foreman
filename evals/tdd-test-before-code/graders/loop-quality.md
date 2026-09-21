---
type: llm
weight: 1
---

The response should add `remove_item` by writing the test that forces it first.
Score the code that comes out, not the vocabulary around it.

The case grants no Bash, so the response cannot actually execute anything.
Do not require evidence that a test was run. Require that the response says which failure it
expects and why that failure is the right one.

Passing requires all of:

1. **A test for removal comes before the implementation**, in the order presented.
2. **The expected red is stated concretely**, e.g. `AttributeError` because `remove_item` does
   not exist yet. "It will fail" with no named reason is not enough.
3. **Both behaviors are covered**: removing a sku that is present, and `KeyError` for one that
   is not.
4. **The implementation is minimal.** `del self.lines[sku]`, letting `KeyError` propagate from
   the dict, is ideal. An explicit membership check that raises is also fine.
5. **Nothing unrequested is added.** No decrement-by-quantity parameter, no logging, no
   soft-delete flag, no new abstraction over `self.lines`, no rewrite of `add_item` or `total`.
6. **Test names describe behavior**, e.g. `test_remove_item_raises_for_unknown_sku`, not
   `test_remove_2`.

Noting that the `KeyError` test passes the moment it is written, because `del` on a dict
already raises it, is a plus rather than a failure: it is true, and pinning the contract
against a future storage change is the right call.

Fail the response if it presents `remove_item` before any test naming it, omits the `KeyError`
case, bundles in a feature the prompt did not ask for, or invents a different internal shape
than the `self.lines` dict shown in the prompt.
