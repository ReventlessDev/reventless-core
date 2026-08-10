# Plan: `@ref` on an array field reaches the manifest

**Status.** Backlog — found 2026-08-10 while verifying
`docs/plans/internal-views-referenceable.md` against `online-shop-hybrid`'s
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

1. Unwrap one level of array before asking for a target, in both walks. The two
   sites are the ones §1 names; a shared helper keeps them from drifting, which
   is the reason `toEventDef` is module-level to begin with
   (`Plugin_Structure.res:162-165`).
2. Decide whether a `@ref` that resolves to nothing should warn. Silence is what
   made this survive; `Plugin_Structure` already warns about a missing
   `@displayName`, so the precedent is there.

## §4 — Tests

- A command with `@ref("E") ids: array<string>` encodes one `fieldReference`
  with `fieldName: "ids"`.
- The scalar case is unchanged.
- An event with an array-typed `@ref` does the same — `toEventDef` has the same
  bug and would otherwise be fixed by accident or not at all.

## §5 — Blast radius worth checking first

Fixing this *changes* resolution for every array-typed `@ref` already in a
codebase: those fields move from whatever the naming heuristic picked to the
declared entity. That is the point, but it means the example apps' generated
forms change, and the change should be looked at rather than assumed benign.
`online-shop-hybrid`'s `PlaceOrder` is the known case: `Catalog.Products` today,
`AvailableProducts` after.
