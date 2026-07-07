# DCB runtime scope drift: `@ref` cross-partition reference reads broken on AWS

**Found:** 2026-07-07, while running the ESM Rung-3 validation on the live
`online-shop-hybrid` alpha stack (gitSha `8097bc4de`).
**Status:** **FIXED + LIVE-VERIFIED (2026-07-07, commit `4d8327fad`).** Shared
`DcbTag.deriveEffectiveScope` is now the single source of truth for both
`Dcb_Builder.res` and `DcbCommandTopicEntryPoint.mjs`; regression test in
`reventless-spec/tests/DcbTagTest.res`; verified on the real catalog specs
(`crossPartitionTagKeys=["categoryId"]`). Deployed to alpha (`5cca64c7`, includes
the fix) and re-checked live: `Catalog_AddCategory` → `Catalog_AddProduct` now
returns `CommandAccepted` on the first attempt (was deterministic
`CategoryNotFound`) and the product projects into `Catalog_Product` /
`Catalog_Products`.
**Severity:** High — every deployed DCB `StateChangeSlice` whose decision guard
validates a **cross-partition `@ref` reference** (a reference to another entity's
lifecycle) is broken on AWS: the referenced entity always reads as absent, so the
command is **always rejected**. Canonical case: `Catalog_AddProduct` →
`CategoryNotFound` even when the category exists and is projected.

## Symptom (observed live)

1. `Catalog_AddCategory(categoryId=C, name="Rung3 Cat")` → `CommandAccepted`,
   `eventCount 1`. Category projects; `Catalog_Categories` / `Catalog_Category(C)`
   return it.
2. `Catalog_AddProduct(productId=P, …, categoryId=C)` → **`CommandRejected
   { errorCode: "CategoryNotFound" }`**, deterministically, for >1 min across
   retries.

Handler logs (`CatalogDcbCmdHandler`) show the decision read is a **single clause**:

```
query: ProductAdded{productId=P, categoryId=C}
read: 0 event(s)
decide rejected: CategoryNotFound
```

It reads only `ProductAdded` (tagged by both ids) and **never reads
`CategoryAdded | CategoryArchived`**, so `AddProduct_Behavior`'s `liveCategoryIds`
stays empty and `decide` rejects.

## Root cause

The decision-read scope (`crossPartitionTagKeys`, `tagKeysByEventType`) is derived
in **two places that have drifted apart**:

- **Deploy time — correct.** `Dcb_Builder.res` was upgraded (Phase 2,
  `dcb-tag-scope-inference`) to derive scope from the global slice graph via
  `DcbScopeInference.infer`, with an all-or-nothing fallback to annotations only on
  ambiguity. The live deploy log confirms it works:
  ```
  DCB scope-inference diff: crossPartitionTagKeys annotated=[] inferred=[categoryId]
  DCB scope-inference diff: ProductAdded indexes [productId] (inferred) vs
    [productId, categoryId] (annotated) — payload now: [categoryId]
  ```
  So `effectiveCrossPartitionTagKeys = [categoryId]`; storage/GSI wiring is right.

- **Runtime — stale.** The AWS command-handler Lambda entry point
  `reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs` (lines ~144–150)
  re-derives the scope at cold start from **annotations only**:
  ```js
  const crossPartitionTagKeys = Array.from(
    new Set(producedSchemas.flatMap(s => extractCrossPartitionTagKeys(s)))
  );
  ```
  `extractCrossPartitionTagKeys` reads `@crossPartition` field annotations. It does
  **not** run `DcbScopeInference.infer`. The comment claims it mirrors
  `Dcb_Builder.res`, but it mirrors the *pre-inference* extraction (Dcb_Builder
  lines 168–170), not the Phase-2 inferred scope (lines 239–294).

online-shop-hybrid relies on **inference** — `AddProduct.categoryId` carries
`@ref("Categories")` (which sets reference + dcbTag metadata, *not* `@crossPartition`).
So at runtime `extractCrossPartitionTagKeys → []`.

With `crossPartitionTagKeys = []`, `DcbTag.buildQueryFromCommand` takes the
non-fan-out branch (`hasCrossPartition = false`) and emits a **single composite
clause** `{ProductAdded, tags:[productId ∧ categoryId]}`. `narrowEventTypesForTags`
keeps only event types indexed by *both* tags (just `ProductAdded`), dropping
`CategoryAdded | CategoryArchived` (indexed by `categoryId` alone). The category
lifecycle is never read ⇒ `liveCategoryIds = []` ⇒ `CategoryNotFound`.

## Why CI/tests missed it

- The `AddProduct_GWT` happy path (`givenEvents([CategoryAdded…]) → AddProduct →
  ProductAdded`) seeds behavior state **directly**, bypassing read-scope inference —
  it validates `evolve`/`decide`, not the runtime query build.
- `reventless-local` builds the full in-process composition (Dcb_Builder with
  inference), so local runs get `[categoryId]` and pass — the drift only manifests
  on the **AWS runtime entry-point** path.
- No on-AWS test asserts accept/reject for a reference-guarded command.

## Fix (implemented)

Chose the "single shared derivation" spirit of option 1, but as a **pure function**
rather than `HANDLER_CONFIG` serialization (no threading through the runtime
builder; both sides recompute from the same slice schemas with identical logic):

- **New:** `DcbTag.deriveEffectiveScope(slices: array<sliceSchemas>)` in
  `reventless-spec/src/components/DcbTag.res` — runs `DcbScopeInference.infer` and
  falls back to the annotation-derived scope only on ambiguity (all-or-nothing),
  matching `Dcb_Builder`. Returns `{crossPartitionTagKeys, tagKeysByEventType}`.
- **`Dcb_Builder.res`** now takes its `effective*` values from this helper (keeps
  its deploy-time diff/ambiguity logging).
- **`DcbCommandTopicEntryPoint.mjs`** now calls `deriveEffectiveScope` over the
  loaded `{name, commandSchema, consumedEventSchema, eventSchema}` instead of
  `extractCrossPartitionTagKeys` / `extractTagKeysByEventType`.

Both call one function, so the runtime decision query cannot diverge from the
storage/GSI scope again.

Considered but not chosen: serializing `effectiveCrossPartitionTagKeys` into
`HANDLER_CONFIG`. Equivalent result, more plumbing; the shared pure function is
simpler and testable in isolation.

## Verification

- **Unit (regression guard):** `reventless-spec/tests/DcbTagTest.res` —
  `deriveEffectiveScope` on an AddCategory+AddProduct fixture yields
  `crossPartitionTagKeys=["categoryId"]` and `ProductAdded` indexed by `[productId]`;
  a companion assert pins that annotation-only extraction returns `[]` (the pre-fix
  behavior). Full DCB suites green (spec 83, core dcb 160).
- **Integration:** the real `online-shop-hybrid` catalog specs run through
  `deriveEffectiveScope` (as the entry point now does) → `["categoryId"]` /
  `["productId"]`.
- **Live (pending next alpha push + redeploy):** `AddCategory(C)` →
  `AddProduct(…, categoryId=C)` must return `CommandAccepted` and project into
  `Catalog_Products`.

## Deploy note

The fix reaches AWS on the next alpha push: CI republishes `reventless-spec`
(carrying `deriveEffectiveScope`) + rebuilds the Lambda layer + redeploys. The DCB
command Lambda bundles `reventless-core`/`reventless-aws` locally but resolves
`reventless-spec` from the layer, so a plain local `pulumi up` **without** a
`reventless-spec` republish would import the old (helper-less) module and fail at
cold start. Optional hardening: add `@reventlessdev/reventless-spec` to
`packageDirs` in `StateChangeSliceRuntime_Builder_Single.res` (same rationale as the
existing core/aws local-bundle) to make the bundle self-contained.

## Residue

Left in alpha (disposable per the alpha-wipe convention): one `Catalog` category
"Rung3 Cat" (`eb7ba1c4-dd8a-4bce-8412-c04038635b9d`) + its `CategoryAdded` event.
No product was created (the bug blocked it).
