# Plan: `@ref` on an array field reaches the manifest

**Status.** Landed — 2026-08-10. Found while verifying
`docs/plans/done/internal-views-referenceable.md` against `online-shop-hybrid`'s
`platform-local`.

**Goal.** `@ref("Entity")` on an `array<string>` field produces a
`fieldReference` in the plugin structure, as it already does on a `string` field.

---

## §1 — The defect

`commandDef.references` is empty for every array-typed `@ref` field, and
populated for the scalar ones. Observed against `platform-local`:

| Command | Field | Declared | `references` on the wire |
| --- | --- | --- | --- |
| `Catalog.AddProduct` | `categoryId: string` | `@ref("Categories")` | `[{categoryId → Categories}]` |
| `Ordering.PlaceOrder` | `productIds: array<string>` | `@ref("AvailableProducts")` | `[]` |

The two walks that build the list —
`Plugin_Structure.toCommandDef` (`:305-315`) and `toEventDef` (`:169-180`) —
both do:

```
Reventless.Reference.getTarget(fieldSchema)
```

`getTarget` (`Reference.res:43`) reads `Semantic.get` off the schema it is
handed. `Reference.to_` returns `S.t<string>` — an *element* schema — so on an
`array<string>` field the marker sits under the array, and the field schema
itself carries none. `getTarget` answers `None`, and the annotation is dropped
without a warning.

`Reference.res:11-14` already documents the array case as supported ("the `@ref`
ppx shorthand supplies [`~key`] automatically for plural `*Ids: array<string>`
fields"), so the ppx side is doing its job; the structure walk is where it is
lost.

## §2 — Why it is worth fixing rather than annotating around

The consuming side treats an explicit `@ref` as authoritative and skips the
naming heuristic entirely — so a dropped reference is not a no-op, it is a
*different* resolution. `PlaceOrder.productIds` currently resolves by heuristic
to `Catalog.Products`, cross-plugin, complete with the "add `@ref(...)` to make
this explicit" warning the author already acted on. The author's declaration is
both ignored and reported as missing.

That also makes the failure invisible in the obvious place: the form does render
a picker, just one aimed at a different entity than the one declared.

## §3 — Work

1. **Done.** `Reference.getFieldTarget` (`Reference.res`) answers "the entity
   this *field* references", following the field's own wrappers — the optional
   union and the array element, to any depth — where `getTarget` answers only
   for the schema it is handed. `getTarget` is unchanged: `SchemaType.shapeOf`
   asks it about an element schema and must keep getting the element's answer,
   or an `array<string>` field would classify as a scalar `EntityId`.

   Object properties are deliberately *not* followed. A reference declared on a
   nested record's field belongs to that field; attributing it upward would emit
   a `fieldReference` naming the wrong field.

2. **Done.** `Plugin_Structure.extractReferences` is the one collector both
   walks call, replacing the two copies §1 names. Module-level for the same
   reason `toEventDef` is (`Plugin_Structure.res:162-165`).

3. **Decided: no warning.** §3.2 asked whether a `@ref` that resolves to nothing
   should warn. It should not, because `Plugin_Structure` is not where the
   knowledge is. By the time the walk runs there is only a marker present or
   absent — nothing distinguishes "no `@ref` was written" from "a `@ref` was
   written and lost", so any warning would have to fire on every un-reffed
   field. The layer that knows a `@ref` was written is the ppx, and
   `ReferenceInference.transform_label_decl` already *errors* on any field type
   it cannot annotate ("`@ref` only supports string and array<string> fields").
   With the walk now following the field's wrappers to any depth, the two
   shapes the ppx accepts are both reached, and the silent-drop path is closed
   structurally rather than reported.

### Shared unwrap

`Semantic.unwrapOptional` was extracted from `Semantic.getFrom`, which already
followed the optional wrapper for its own purpose. `getFieldTarget` needs the
same one-level unwrap to reach an *optional array's* element, and one exported
helper is what keeps the two readers from disagreeing about what an optional
field is. `getFrom` is otherwise unchanged.

## §4 — Tests

`PluginStructureTest.res` § "plural references reach the manifest", over a new
fixture `tests/plugin/StateChangeSlice/PsReserveStock.res` — every reference
carrier plural, the mirror of `PsUploadAvatar`'s every-carrier-optional:

- A command collects `productIds → AvailableProducts` and `warehouseIds →
  Warehouses` **alongside** its scalar `customerId → Customers`, so a fix that
  reached the plural forms by breaking the scalar one cannot pass.
- `warehouseIds?: array<string>` — the plural-inside-optional shape, where the
  element sits one wrapper further down than the unwrap that handles either
  alone.
- An event with an array-typed `@ref` collects it too; `toEventDef` had the same
  bug and would otherwise have been fixed by accident or not at all.
- The declared entity wins over the one `productIds` reads like.

All four fail against the pre-fix walk (verified by reverting
`extractReferences` to `getTarget`: 4 failed), and pass after.

## §5 — Blast radius

Three declaration sites exist in the repo, all `productIds`, all declaring
`AvailableProducts`:

| Site | Was (heuristic) | Now (declared) |
| --- | --- | --- |
| `online-shop-hybrid/ordering` `PlaceOrder` | `Catalog.Products` | `Ordering.AvailableProducts` |
| `online-shop-dcb/ordering` `PlaceOrder` | `Catalog.Products` | `Ordering.AvailableProducts` |
| `online-shop-aggregates/ordering` `Order.Place` | `Catalog.Products` | `Ordering.AvailableProducts` |

Each ordering plugin owns an `AvailableProducts` view, so all three move from a
cross-plugin guess to the same-plugin view the author named. That view is
`@@reventless.visibility(Internal)` in every example — the denormalised
Ordering-side lookup mirror — which is exactly the case
`internal-views-referenceable.md` made referenceable, so the two land
consistently: the picker now reads what an order may contain rather than the
catalog's full product list.

Verified end to end against the built `online-shop-hybrid` ordering plugin:

```
PlaceOrder command references: [{"fieldName":"productIds","entity":"AvailableProducts"}]
```
