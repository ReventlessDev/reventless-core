# Plan: an optional field hides its semantic marker from every schema walk

**Date:** 2026-07-30
**Status:** Backlog
**Repos:** `reventless-core` only.
**Prompted by:** `docs/plans/done/product-image-optional-storage-ref.md`, which made
`Catalog` product images optional and hit this as a *blocking risk*. It did not materialize there
only because one carrier (`ChangeProductImage.imageUrl`) legitimately stayed required, so the
`Catalog.productImages` store kept exactly one declarer. The gap itself was left unfixed.

## The defect

Semantic markers (`@storageRef`, `@ref`, the branded scalars, `dateTime`) are sury **metadata**
attached to the field's schema. For an **optional** field the ppx injects `@s.matches` on the inner
`string`, and sury-ppx then wraps it — the field schema becomes
`Union({anyOf: [<inner, carrying the metadata>, Undefined/Null]})`. The outer union node carries no
metadata of its own.

Every reader goes through one function — [Semantic.res:94](../../reventless/spec/src/semantic/Semantic.res#L94):

```rescript
let get = (fieldSchema: S.t<'a>): option<t> => S.Metadata.get(fieldSchema, ~id=semanticId)
```

It reads the *outer* schema and does not follow the wrapper, so **an optional semantic field reads
as carrying no semantic at all**. Five call sites inherit the blind spot:

| Reader | Consequence when the field is optional |
|---|---|
| [StorageRef.res:121](../../reventless/spec/src/semantic/StorageRef.res#L121) `getStore` | field drops out of `requiredStores` → out of `capabilities.json` → out of the generated `PlatformCapabilities.res`; if **all** carriers of a store are optional the object store is no longer provisioned and the upload path breaks |
| [Reference.res:44](../../reventless/spec/src/components/Reference.res#L44) `getTarget` | the cross-entity reference vanishes from `commandDef.references` / `eventDef.references`, and `SchemaType` stops classifying the field as `EntityId` |
| [DateTime.res:29](../../reventless/spec/src/types/DateTime.res#L29) `isDateTime` | an optional timestamp degrades to a plain string in the API IR |
| [SchemaType.res:42](../../reventless/core/src/components/Api/SchemaType.res#L42) `fromSury` | the `Semantic(...)` wrapper is dropped from the shape, so branded scalars (Email, Url, Percent, …) lose their brand when optional |
| `Semantic.has` | same, for every consumer of it |

### Live evidence

`examples/online-shop-hybrid/catalog/src/capabilities.json` declares `Catalog.productImages` from
`ChangeProductImage.imageUrl` **only**. `AddProduct.imageUrl`, `ImportProduct.imageUrl` and
`Products.imageUrl` all carry the same `@storageRef("productImages")` and are all optional — all
three are silently absent from `declaredBy`.

## The fix

Make `Semantic.get` follow an option/nullable wrapper to the inner schema before reading the
metadata. One change, one place — it is the single funnel all five readers already share, and it
mirrors what schema walkers elsewhere in the tree already do for the same wrapper shape
(`SchemaType.fromSury`'s `Union({anyOf})` arm, `Plugin_Structure.isLabelShape` / `isStatusShape`'s
`Nullable(inner)` arm, `SchemaWalker.isOptionalSchema`).

Shape of the unwrap (the union has exactly one non-`Null`/`Undefined` variant):

```rescript
let rec get = (fieldSchema: S.t<'a>): option<t> =>
  switch S.Metadata.get(fieldSchema, ~id=semanticId) {
  | Some(_) as found => found
  | None =>
    switch fieldSchema->S.castToUnknown {
    | Union({anyOf}) =>
      switch anyOf->Array.filter(v => switch v { | Null(_) | Undefined(_) => false | _ => true }) {
      | [inner] => get(inner)
      | _ => None
      }
    | _ => None
    }
  }
```

Reading the outer schema *first* keeps a marker that was attached to the wrapper itself winning, so
nothing that works today changes behaviour.

**Rejected alternative:** unwrapping at each call site (`storesFromProperties`, the two
`references` walks, …). It leaves the next reader to rediscover the same trap, and the
already-shipped product-image work proves readers get added faster than the trap gets remembered.

## Blast radius to check

Fixing the funnel makes markers appear where they previously did not — that is the point, but three
downstream shapes need a look:

- `SchemaType.fromSury` will now emit `Semantic(sem, Nullable(...))` for an optional branded field.
  Confirm `GraphQL_FragmentGenerator` (which has its own `Nullable(inner)` arm) and
  `SuryToJsonSchema` still render nullable + branded correctly rather than double-wrapping.
- An optional `@ref` field becomes `EntityId` and gains a `fieldReference` entry — check the AutoUI
  resolver provisioning that consumes `commandDef.references` tolerates a nullable reference.
- `capabilities.json` / `PlatformCapabilities.res` in `examples/online-shop-hybrid` gain three
  `declaredBy` entries for `Catalog.productImages`. Both are generated artifacts and must be
  regenerated and committed with the fix.

## Steps

1. `reventless/spec/src/semantic/Semantic.res` — `get` follows a single-non-null-variant union.
2. `reventless/spec/tests/SemanticScalarsTest.res` — assert an **optional** branded field still
   reports its semantic (there is no optional-marker case in the suite today).
3. Core coverage for the store walk: a spec with an optional `@storageRef` field must appear in
   `requiredStores`. Nearest existing home is the `Plugin_Structure` store-walk tests.
4. Core coverage for the reference walk: an optional `@ref` field appears in `commandDef.references`.
5. Regenerate `examples/online-shop-hybrid/catalog/src/capabilities.json` and
   `examples/online-shop-hybrid/platform-aws/src/PlatformCapabilities.res`; confirm all four
   `productImages` carriers now declare the store.

## Validation

- `pnpm run build`: zero warnings.
- Full spec + core suites green (watch the API IR / GraphQL fragment tests — they are the ones the
  blast radius touches).
- `capabilities.json` lists all four `Catalog.productImages` declarers.
- A local `pulumi preview` of `examples/online-shop-hybrid/platform-aws` still provisions the S3
  object store (it must not *depend* on the optional carriers, but it must not lose it either).
