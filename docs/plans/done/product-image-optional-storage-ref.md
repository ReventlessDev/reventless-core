# Plan: model the product image as an optional storage-ref (drop the `""` sentinel)

**Date:** 2026-07-30
**Status:** Done (implemented on alpha 2026-07-30). Phase 0 proved unnecessary — see below.
**Repos:** `reventless-core` only.
**Prompted by:** `reventless/spec/src/semantic/StorageRef.res` L104–110, whose own comment already
anticipates this — *"Making these fields properly optional would let the sentinel go."* Today every
storage-ref image field is a required `string` that carries `""` to mean "no image", and a producer
with no image (the supplier-feed import) is forced to invent that sentinel.

## Why now rather than later

The framework is in alpha with no external consumers. This changes the shape of the `ProductAdded`
and `ProductImageChanged` **events**, so on any store with existing events those events no longer
parse against the new schema — the alpha EventLog is **wiped**, not migrated (the standing
convention for alpha). That cost is only ever lower before there is production data. Modelling
"a product may have no image" as `option` instead of a magic empty string is also the honest domain
model: absence is a first-class value, not a reserved string.

## The change in one line

`@storageRef("productImages") imageUrl: string` → `@storageRef("productImages") imageUrl?: string`
everywhere the field is a *carrier* of a possibly-absent image, so an image-less product stores
nothing rather than `""`.

**Syntax constraint (verified):** use the ReScript `?:` shorthand, **not** `option<string>`. The
storage-ref ppx (`StorageRefInference.ml`, `is_string_type`) only matches a bare `string`;
`imageUrl?: string` keeps `pld_type = string` plus a `@res.optional` attribute (ppx injects
`@s.matches` on the `string`, sury-ppx then wraps it `S.option(...)` → nullable GraphQL), whereas
`imageUrl: option<string>` fails the type gate and raises *"@storageRef only supports string and
array<string> fields"* at compile time.

## Outcome (2026-07-30)

Implemented Phases 1–4. **Phase 0 was not needed.** `ChangeProductImage` legitimately keeps a
**required** `@storageRef("productImages") imageUrl: string` (this command always sets a real image),
so it continues to declare the store even though `AddProduct` / `ImportProduct` / `Products` became
optional and dropped out of the provenance walk. `capabilities.json` and the generated
`PlatformCapabilities.res` still carry `ObjectStore({plugin: "Catalog", store: "productImages"})` —
verified — so the S3 store is still provisioned. The general framework gap (the store-provisioning
walk not unwrapping an optional to read the marker) is **left as a tracked follow-up**, not fixed
here, since no productImages site needed all its declarers to be optional. It is tracked as
`docs/plans/Backlog/semantic-marker-hidden-by-optional-wrapper.md`, which widens it to the real
scope: the blind spot is in `Semantic.get`, so it costs `@ref`, `dateTime` and the branded scalars
their markers on optional fields too, not just `@storageRef`.

Validation performed: catalog + seed-data + platform-local + platform-aws build clean (zero
warnings); all catalog Product GWT suites (37) and the platform-local HybridFlow GWT (3) pass; a
fresh local reseed returns `imageUrl: null` for the supplier-feed imports and a served ref for
generated products; `capabilities.json` still declares the store (via `ChangeProductImage`).

Syntax notes for the record: the ppx requires the `imageUrl?: string` shorthand (not
`option<string>`); pattern-binding an optional field as an option uses `{imageUrl: ?imageUrl}`;
constructing/spreading uses `imageUrl: ?opt`; and `option<string>` unboxes in JS
(`Some(x)`→`x`, `None`→`undefined`), so some compiled `.res.mjs` are byte-identical despite `.res`
changes.

## Blocking risk (did not materialize) — optional storage-ref drops the store declaration

`Plugin_Structure.storesFromProperties` reads the storage-ref marker via
`StorageRef.getStore(fieldSchema)` **directly on the field schema**. For an optional field the marker
sits on the *inner* schema; the outer `S.option`/Union node carries no metadata and this walker does
**not** unwrap it (unlike `SchemaType.shapeOf`, which does). Consequence: an optional storage-ref
field disappears from `requiredStores` → from `catalog/src/capabilities.json` → from generated
`platform-aws/.../PlatformCapabilities.res`. If **all** `productImages` sites become optional, the
`catalog.productImages` store requirement vanishes and the S3 object store may no longer be
provisioned — breaking the upload path. (The analogous `@ref` walk has the same
option-hides-the-marker gap.)

**Fix (preferred):** teach the store-provisioning walk to unwrap the optional before reading the
marker — mirror what `SchemaType.shapeOf` already does. Concretely, make `StorageRef.getStore` (and
`Semantic.get` at the call site) follow a `Nullable`/`S.option` wrapper to the inner schema, or have
`storesFromProperties` unwrap before calling. This keeps the store declared even when every carrier
is optional, and incidentally fixes the same class of bug for `@ref`. Regenerate
`capabilities.json` and `PlatformCapabilities.res` afterwards and confirm `productImages` is still
listed.

Reject the cheaper alternative (keep one site non-optional so the store stays declared): it
re-introduces a sentinel by the back door and leaves the framework gap unfixed.

## Phases

### Phase 0 — framework fix (unblocks everything)
- `reventless/spec/src/semantic/StorageRef.res` — `getStore` unwraps an optional/Nullable wrapper to
  read the marker off the inner schema.
- `reventless/core/src/plugin/component/Plugin_Structure.res` (`storesFromProperties`, ~L491–517) —
  confirm the unwrap flows through; add coverage for an optional storage-ref field.
- Add/extend a ppx-or-core test with an **optional** `@storageRef` field (there is none in the tree
  today — this becomes the first) asserting the store still shows up in `requiredStores`.

### Phase 1 — catalog domain
- `AddProduct.res` — command L21 and event `ProductAdded` L37: `imageUrl?: string`.
- `ChangeProductImage.res` — `consumedEvent` `ProductAdded({imageUrl?: ...})` L8 to match the event;
  keep the **command** L13 and the `ProductImageChanged` event L20–23 required (this command always
  sets a real image; clearing is out of scope).
- `AddProduct_Behavior.res` L27/L33 — pass the optional through unchanged.
- `ChangeProductImage_Behavior.res` — `currentImageUrl` L3 optional, `initialState` L5 `None`,
  evolve L9/L10–13, idempotency compare L21 in terms of `option` equality.
- `Products.res` read-model state L20: `imageUrl?: string`; `consumedEvent` L8/L12 match.
- `Products_Projection.res` L5–7 set `Some`/absent from `ProductAdded`; L13–15 `ProductImageChanged`
  sets `Some`.

### Phase 2 — import translation (the genuine no-image producer)
- `ImportProduct.res` L26 — target command field `imageUrl?: string`; rewrite the L22–25 sentinel
  comment (state the field is simply absent when the feed carries no image).
- `ImportProduct_Translation.res` L21 — omit `imageUrl` (i.e. `None`) instead of `""`.

### Phase 3 — seed harness
- `reventless-seed`: `Seed.value` — confirm/add a nullable arm so an optional GraphQL arg can be
  omitted/null (today `DemoCommands` only ever emits `String(imageUrl)`); add `Seed.optString` or
  equivalent.
- `DemoData.res` — `product.imageUrl` L125 optional; `buildProducts` L218 `None`.
- `DemoCommands.res` — `addProduct` L45/L53 emit the optional arg; `changeProductImage` unchanged.
- `HybridSeedData.res` — `uploadProductImages` sets `Some(servedRef)`; **delete**
  `seedImportedProductImages` and the placeholder generator `DemoData.productSvg` (imports now carry
  no image); keep `DemoData.productImageSvg` for generated products; drop the placeholder-upload call
  in `run`. Update the skip-uploads report text.

### Phase 4 — tests + generated artifacts
- GWT: `AddProduct_GWT.res`, `ChangeProductImage_GWT.res`, `Products_GWT.res`,
  `ImportProduct_GWT.res` (expected translated command → no `imageUrl`), and
  `platform-local/tests/Flow/HybridFlow_GWT.res`.
- Regenerate `catalog/src/capabilities.json` and `platform-aws/.../PlatformCapabilities.res`; assert
  `productImages` still present (Phase 0 guarantees it).
- Prose: `catalog/CHANGELOG.md`, `examples/online-shop-hybrid/README.md`.

## Validation
- `pnpm run build` in catalog + seed-data: zero warnings.
- All catalog + platform-local GWT suites green.
- Local reseed (fresh store): generated products carry an image; imported products carry **no**
  `imageUrl` (query returns null, not `""`).
- `capabilities.json` still declares the `productImages` store; a local `pulumi preview` of
  `platform-aws` still provisions the S3 object store.
- Alpha: wipe the EventLog on deploy (events changed shape).

## Out of scope
- Any consumer-side rendering of an absent image — tracked separately, outside this repo.
