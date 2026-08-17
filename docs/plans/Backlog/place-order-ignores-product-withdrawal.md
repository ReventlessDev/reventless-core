# Bug: a withdrawn product can still be ordered

**Status.** BACKLOG 2026-08-17, found by a browser acceptance run against a
seeded local store and then reproduced against the API. Not fixed, because the
fix is a domain change to the shipped example and it deserves its own sitting —
the same shape as the reopen-a-shipped-order fix, which needed a test written
alongside it.

**The bug in one sentence.** `PlaceOrder` never folds `CatalogProductWithdrawn`,
so its `availableProductIds` only ever grows, and a product that has been
archived or discontinued in the catalog stays orderable forever.

---

## Reproduction

Against the hybrid shop's local platform, seeded with the sample set (which
leaves one product `Archived` and one `Discontinued`):

```
# prd-008 is the discontinued product; it is absent from the ordering view
curl -s localhost:4000/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ Ordering_AvailableProducts(first:50){ edges { node { id } } } }"}'
# → 18 rows, prd-008 not among them

curl -s localhost:4000/graphql -H 'Content-Type: application/json' \
  -d '{"query":"mutation { Ordering_PlaceOrder(orderId:\"probe\", customerId:\"c\", productIds:[\"prd-008\"], shippingMethod: Standard) { __typename } }"}'
# → CommandAccepted

curl -s localhost:4000/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ Ordering_Order(id:\"probe\"){ id lifecycle productIds } }"}'
# → { id: "probe", lifecycle: "Placed", productIds: ["prd-008"] }
```

The order is placed, not refused.

## Why

The read side and the write side disagree about what "available" means, and only
the read side was taught the second half.

| Component | Folds `CatalogProductSynced` | Folds `CatalogProductWithdrawn` |
|---|---|---|
| `AvailableProducts` (view) | ✅ | ✅ → `Delete(productId)` |
| `SyncCatalogProduct` (slice) | ✅ | ✅ → `withdrawn: true` |
| **`PlaceOrder` (slice)** | ✅ | ❌ **not in its `consumedEvent`** |

`PlaceOrder_Behavior` accumulates:

```rescript
| CatalogProductSynced({productId}) => {
    ...state,
    availableProductIds: … Array.concat(state.availableProductIds, [productId]),
  }
```

and refuses with `ProductsNotAvailable` only for ids it has never seen synced.
Nothing removes an id, so withdrawal is invisible to the one component whose
decision depends on it.

## Why it matters beyond the example

**It is the same shape as the reopen-a-shipped-order drift**, which is the bug
this whole lifecycle workstream was built around: a slice fails to fold an event
that its sibling view *does* fold, so the read side moves on and the write side
keeps deciding on a stale fact. There the symptom was a row that could never
ship; here it is a row that can always be ordered.

It is also the exact rule the topology lint tried and failed to write —
"a slice ignores an event its siblings and the view consume" — with one important
difference from the case that made that rule unwritable: **`CatalogProductWithdrawn`
carries a payload**, so it *is* published in `consumedEventTypes`. The metadata
needed to catch this one is present. What is missing is the rule, not the
vocabulary. See `lifecycle-consumed-events-payload-less.md` for the half that is
genuinely blocked, and note that this instance is not blocked by it.

**The generated conformance scenarios would not catch it either**, and that is
worth knowing rather than a gap to close here. They check a command's declared
`@transition` against what `decide` does on *that entity's* lifecycle.
Orderability depends on the **product's** shelf status while `PlaceOrder`'s
from-set is about the **order's** lifecycle, so no declared edge is violated. Two
lifecycles, one decision — the case
`Backlog/command-applicability-when-retired.md` is still open for.

## What to decide

1. **Fix the fold.** `PlaceOrder` consumes `CatalogProductWithdrawn` (and
   `CatalogProductRelisted`, or the way back is broken in the other direction)
   and removes the id. Small, and it needs the GWT that was missing — nothing in
   the shop's tests covers ordering a withdrawn product.
2. **Whether the surface should offer it at all.** The `Products` row menu offers
   `Order` on archived *and* discontinued rows, and the form pre-fills the row's
   id into a picker over `AvailableProducts` that would never list it. Once (1)
   lands this becomes offered-then-refused rather than offered-then-accepted,
   which is better but still wrong. Filtering it needs a command's applicability
   to depend on an entity other than the one whose row it sits on.
3. **Whether a lint should catch the class.** The narrowing that made the
   original rule fire on ordinary DCB is available here: require the ignored
   event to be produced by a writable linked to the same view. Worth re-testing
   against this instance, which the earlier attempt did not have.
