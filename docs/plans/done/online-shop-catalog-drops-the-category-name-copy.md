# Plan: the Products view stops carrying a copy of the category's name

**Status.** Done 2026-09-07. Scoped to `examples/online-shop-hybrid` — this is
domain modelling in the example, not a framework capability.

Two things went further than §4 said, both because the field they served left
with `categoryName`: `CategoryAdded`'s `name` is gone from `AddProduct`'s
`consumedEvent` (the `naming` fold was its only reader), and the GWT case
"a category renamed before the product is added is captured under the new name"
is deleted rather than shrunk — `CategoryRenamed` is no longer a consumed
constructor, so the scenario has no `given` to write. The other `AddProduct`
cases shrank as §6 asked. The derived lifecycle edge is unchanged
(`AddProduct → Listed`); only its scenario count moved, 6 → 5, which is §6's
"no decision outcome changed" confirmed by the artifact.

**Goal.** `Products` names its category by the id it already holds. The
`categoryName` copy leaves the state, the event and the decision model, and
`@groupBy` moves onto `categoryId`.

---

## §1 — What the field is

[`Products.res`](../../examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/Products.res)
declares `@groupBy categoryName: option<string>` beside `@index categoryId`. It
is written once, from `ProductAdded`, and never again — no other consumed
constructor touches it.

The value comes from a fold in
[`AddProduct_Behavior.res`](../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/AddProduct_Behavior.res):
the decision model consumes `CategoryAdded` and `CategoryRenamed` to maintain a
`categoryNames` association list, and `decide` copies the current name onto the
emitted event. Its own comment is explicit that this is not a decision input —
"nothing here accepts or rejects on what a category is called". The fold exists
solely to carry a value through.

## §2 — Why it cannot be right

**The projection cannot maintain it.** `Products` is keyed by `productId`. A
`CategoryRenamed` would have to rewrite every product filed under that category,
which a single-key projection cannot do — the field's own comment says so. So the
copy is not a cache: there is no path by which it is ever refreshed.

**Nothing reads it as history.** A product's category is immutable in this
domain — the consumed set has no `ProductCategoryChanged`. The only way the copy
can diverge from the reference is a category rename, and a rename here is a
correction to a label, which is the case where the new value should be visible
everywhere rather than preserved.

**The genuine freeze already exists elsewhere and stays.**
[`Orders.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateViewSliceStream/Orders.res)
freezes `orderLine.name` and `unitPrice` at placement, and that is correct: those
are terms of a transaction, and the view must not go and ask the catalog what
anything is called or costs now. `categoryName` is not a term of anything — and
notably, `Orders` never carries it. The catalog category a product sits in is a
live classification, not a recorded fact about a purchase.

## §3 — What keeping it costs

- A decision model folding two constructors and maintaining an association list
  that `decide` never consults.
- An optional field on `ProductAdded`, permanently, for every future event.
- A state field that can disagree with the reference on the same row, with
  nothing distinguishing which of the two is current.

## §4 — The change

| Where | Change |
|---|---|
| `Products.res` | Drop `categoryName` from `state`; drop it from the `ProductAdded` constructor in `consumedEvent`; move `@groupBy` onto `categoryId` (joining `@index`). |
| `Products_Projection.res` | Stop destructuring and writing `categoryName`. |
| `AddProduct.res` | Drop `categoryName?` from the `ProductAdded` event constructor. |
| `AddProduct_Behavior.res` | Drop `categoryNames` from `state` and `initialState`, drop the `naming` helper, drop the lookup in `decide`. `CategoryAdded` and `CategoryArchived` stay — `liveCategoryIds` is a real decision input. `CategoryRenamed` no longer needs to be consumed at all. |
| GWTs | `Products_GWT.res`, `AddProduct_GWT.res`, `HybridFlow_GWT.res` — remove the field from every given/then. |
| `schema/domain-api.graphql` | Remove `categoryName: String` (line 130). |
| `Products.model.json` | Nothing to do: the ppx emits it as a build sidecar and it is untracked, so it was already stale for other reasons and the build rewrites it. |

`@groupBy` and `@index` on one field is legal: the ppx's only rule is at most one
`@groupBy` per record ([`StateAnnotations.ml:1892-1901`](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml#L1892-L1901)),
and it places no constraint on the field's type.

**Old events keep an ignored field.** Dropping `categoryName` from the payload
shrinks the schema; events already in the log carry a key the projection stops
reading. No migration.

## §5 — Precondition

Grouping on a reference field hands a client identifiers as group keys.
Presenting them readably is the same resolution a client already performs for any
`*Id` field — it holds the reference and the view it points at. That capability
has to be in place first, or this change trades a stale name for a raw id.

Land that side first; this plan is the second half.

## §6 — Verification

- `pnpm test` in `examples/online-shop-hybrid` — the GWTs are the specification
  here, and the `AddProduct` ones asserting a named category are the ones that
  should shrink rather than be deleted: the command still rejects a missing or
  archived category, and that is what those cases are for.
- Confirm `CategoryRenamed` can be dropped from `AddProduct_Behavior`'s consumed
  set without changing any decision outcome.
- A fresh projection over the existing log produces rows without the field, and
  the catalog list still sections by category.

## §7 — A related trap, not fixed here

`@hidden` marks a field as one no consumer should ask for, and a consumer that
honours it by omitting the field from its query no longer receives the value
grouping depends on. So `@hidden` and `@groupBy` on one field is a contradiction:
the annotations instruct a consumer to drop a value and to section rows by it.
The ppx validates only that at most one `@groupBy` exists per record
([`StateAnnotations.ml:1892-1901`](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml#L1892-L1901))
— the combination is unguarded. Worth a rejection at annotation time, in its own
plan.
