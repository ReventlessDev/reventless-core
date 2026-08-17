# Bug: a withdrawn product can still be ordered

**Status.** ✅ **DONE 2026-08-17.** Found by a browser acceptance run against a
seeded local store, reproduced against the API, and fixed in the same shape as
the reopen-a-shipped-order fix — a domain change to the shipped example with the
GWT that was missing written alongside it. Decision (1) is implemented and
verified live; (2) stays deferred and now names its blocker precisely; (3) is
answered, and the answer is not the one this file expected.

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

*(Confirmed by measurement — see decision 3 below. The metadata is indeed
present; the rule turned out to be blocked by something else.)*

**The generated conformance scenarios would not catch it either**, and that is
worth knowing rather than a gap to close here. They check a command's declared
`@transition` against what `decide` does on *that entity's* lifecycle.
Orderability depends on the **product's** shelf status while `PlaceOrder`'s
from-set is about the **order's** lifecycle, so no declared edge is violated. Two
lifecycles, one decision — the case
`Backlog/command-applicability-when-retired.md` is still open for.

## What was decided

### 1. Fix the fold — done

`PlaceOrder` now consumes `CatalogProductWithdrawn({productId})` and
`CatalogProductRelisted({productId})`. Withdrawal filters the id out of
`availableProductIds`; relist re-adds it by sharing the `CatalogProductSynced`
arm, so the way back is not broken in the other direction. Four GWT cases were
added — a withdrawn product refused, siblings unaffected, a mixed basket naming
only what it refused, and a relisted product orderable again.

**Only the hybrid example was affected.** `online-shop-dcb` has no withdrawal at
all — its `SyncCatalogProduct` knows `Synced` and `PriceChanged` and nothing
else — so there was no drift to fix there.

The tests are load-bearing, not decorative: with the withdrawal arm neutered to
`| CatalogProductWithdrawn(_) => state`, two of the four fail. Full suite after
the fix: 249 suites / 2071 tests green.

**Verified live**, because a GWT feeds a fold its events directly and so cannot
see the risk that actually mattered here — a correct fold that never *receives*
the event, since the DCB decision read must fetch `CatalogProductWithdrawn`
across partitions before availability can be re-derived. Against the hybrid local
platform (in-memory, isolated ports), the sequence from the reproduction above:

| step | before | after |
|---|---|---|
| order a live product | accepted | accepted |
| `Catalog_DiscontinueProduct`, then order it | **accepted** | `ProductsNotAvailable {missing:["prd-gone"]}` |
| an order row appears for it | **yes** | no |
| an untouched product | accepted | accepted |
| `Catalog_ArchiveProduct`, then order it | **accepted** | `ProductsNotAvailable` |
| `Catalog_UnarchiveProduct`, then order it | — | accepted |

Both of the catalog's two routes off the shelf reach the write side, and the one
route back restores it. That last row is the arm no reproduction had exercised.

### 2. Whether the surface should offer it at all — still deferred, blocker named

Unchanged as a judgement, and (1) does what this file predicted: the row menu's
`Order` on a withdrawn product is now offered-then-refused rather than
offered-then-accepted. Better, still wrong.

What running this clarified is *which* open plan it is waiting on, because it is
not the obvious one. `Products.shelfStatus` already carries `@retired Archived`
and `@retired Discontinued`, and `@allowedStates` / `@transition` already filter
per-row commands against it — that machinery works, and it is why
`UnarchiveProduct` is offered on exactly the rows it applies to. It does not
reach `Order` because `Order` is an **Ordering** command sitting on a **Catalog**
row: its `@transition` is written in the *order's* lifecycle, and no annotation
lets it be written in the product's.

So this is not the orthogonal-flag case `command-applicability-when-retired.md`
is held open for (a retirement axis separate from the lifecycle on the *same*
row). It is a cross-entity one: the row's lifecycle belongs to another plugin's
view. Whichever plan takes it, that is the thing to design for.

### 3. Whether a lint should catch the class — answered, and the answer inverted

This file expected the metadata to be the blocker and the narrowing to be fine.
Measured against the real specs, it is the other way round.

**The metadata is sufficient.** The recorded reason the rule was unwritable — that
`consumedEventTypes` drops payload-less variants — does not apply to this
instance, exactly as this file predicted. All three inputs are published:

```
AvailableProducts  consumed  [Synced, PriceChanged, Withdrawn, Relisted]
SyncCatalogProduct produced  [Synced, PriceChanged, Withdrawn, Relisted]
PlaceOrder consumed, pre-fix [OrderPlaced, Synced]
```

**The narrowing is not.** Applied to the pre-fix plugin, the rule fires — and
names three events, not one: `Withdrawn`, `Relisted`, **and
`CatalogProductPriceChanged`**. The first two are the bug. The third is a false
positive, and not a marginal one: a price change is produced by the same writable
and consumed by the same view, and `PlaceOrder` is entirely right to ignore it,
because availability does not depend on price. Post-fix the rule still fires, on
that one alone.

So "produced by a writable linked to the same view" separates cross-entity
lookups from same-entity facts, which is what it was for, but it does not
separate facts that change *whether the row exists* from facts that change *what
is in it* — and only the first kind is one an availability decision must fold.

The discriminator is visible in the projection and nowhere else:

```rescript
| CatalogProductSynced(…)       => [Set(productId, …)]
| CatalogProductPriceChanged(…) => [Update(productId, …)]   // contents
| CatalogProductWithdrawn(…)    => [Delete(productId)]      // existence
| CatalogProductRelisted(…)     => [Set(productId, …)]      // existence
```

`Delete`/`Set` versus `Update` is precisely the true/false split. That is a
property of a compiled function, not of published metadata, so a third narrowing
is available in principle only by *running* the projection — which is the same
route `lifecycle-consumed-events-payload-less.md` already notes as the second
line of defence, and it needs nothing from that file either.

**Net:** the rule stays unwritten, for a newly-identified reason that replaces the
recorded one rather than adding to it. Worth carrying to
`../lifecycle-transition-annotation.md` §5, where the rule was specified: a
future attempt that unblocks the payload-less gap and then writes this rule would
ship a check that is noisy on correct code.
