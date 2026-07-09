# Plan: DCB StateChangeSlices expose only one mutation per slice (not one per command)

**Status:** Done (2026-07-09). Reproduced against the real `SyncCatalogProduct` slice
(before: single `Ordering_SyncCatalogProduct(id: ID!)` with all payload args dropped;
after: `Ordering_SyncCatalogProduct_SyncNewProduct` + `Ordering_SyncCatalogProduct_ChangeSyncedPrice`,
each with its own args + subscription). Single-command slices verified byte-identical
(`Catalog_AddCategory` unchanged). All suites green (reventless-local 481, reventless-aws 209,
online-shop-dcb 104, online-shop-hybrid 116).

## Implementation

Centralised the single-vs-multi naming rule in `Api_Naming.sliceMutationFields`
/ `sliceMutationFieldFor` (single API-exposed constructor → byte-identical
`Plugin_Slice`; multi → aggregate-style `Plugin_Slice_Ctor` per constructor, `@noApi`
filtered). Rewired the five slice-naming sites in `Dcb_Builder.res` (both
`mutationResolverHook` blocks, both `mutationBindHook` blocks binding the one
TAG-agnostic `generateCommand` to every field, `dcbMutationData` emitting one
`(field, TAG)` per constructor, and `mutationEntriesFromSlices` carrying multi
`fieldNames` + per-constructor `fieldPermissions`) plus `Plugin_Structure.res`'s
`mutationFieldFor`. Fixed the in-memory `registerDcb` to derive each field's TAG
from its own field name instead of hardcoding constructor[0]. The AWS resolver layer
(`makeDcb` zips fieldNames×tags), the deployed `DcbCommandTopicEntryPoint.mjs`
(routes by payload TAG, `handlersByType` keyed by every constructor), the SDL
generator (`constructorNameOf` = trailing `_` segment), and the subscription
generator (iterates `fieldNames`) were already multi-command-capable and needed no
change. Acceptance test added to `GraphQL_SchemaInspectorTest.res`.

---
_Original plan below._

## Summary

A DCB `StateChangeSlice` whose `command` is a union of several constructors exposes **only one
GraphQL mutation, named after the slice** — it silently drops every non-primary command
constructor. So a slice that models both an upsert command and a remove command (e.g.
`Sync…` + `Remove…` in one `command` union) can invoke only the first via GraphQL; the remove
command is dispatchable internally (its `decide` branch, events, and projections all work) but
has **no mutation field**, so no client/caller can trigger it.

This diverges from **aggregates**, which emit one mutation *per command constructor*.

## Root cause

[`Dcb_Builder.res`](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res)
names the slice mutation from the **slice name**, once:

```
~fields=[Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)]
```

(lines ~413/426/449/474/717). It never iterates the command union's constructors.

Contrast — the aggregate path
([`Plugin_Builder.res`](../../reventless/reventless-core/src/plugin/component/Plugin_Builder.res)
~line 156) emits one field per constructor:

```
let constructorNames    = DcbTag.extractAllVariantNames(M.Spec.commandSchema)
let filteredConstructorNames = ApiNoApiHelpers.filterNoApiVariants(constructorNames, commandSchema)
let fieldNames = filteredConstructorNames->Array.map(cname =>
  Api_Naming.aggregateMutationField(extra, M.Spec.name, cname))
```

The subscription generator
([`Plugin_SubscriptionSchema.res`](../../reventless/reventless-core/src/plugin/component/Plugin_SubscriptionSchema.res))
already documents and implements "**one field per command variant**" over
`entry.fieldNames`. So the mutation-side DCB generator is the sole place still keyed on the
slice name rather than the command constructors.

Verified: for a slice with `command = SyncX | RemoveX`,
`extractAllVariantNames` + `filterNoApiVariants` return **both** constructors — nothing filters
`RemoveX`. Yet the deployed schema fragment contains `Platform_SyncX` and **no** `Platform_RemoveX`.

## Impact

Any multi-command DCB slice is under-exposed. The concrete trigger: a reconcile flow that
issues per-command removes (a caller invoking `Platform_Remove…` after a diff) fails every
remove — the field doesn't exist. Because such callers are typically fire-and-forget, the
failure is silent (see also: surface command-rejection / unknown-field errors from the caller).

## Fix

Make the DCB slice mutation generator emit **one mutation per (filtered) command constructor**,
mirroring the aggregate path and the subscription generator:

- In `Dcb_Builder`, replace the single `sliceMutationField(~slice=Spec.name)` with a map over
  `filterNoApiVariants(extractAllVariantNames(Spec.commandSchema), Spec.commandSchema)`,
  producing a field per constructor (naming: reuse `aggregateMutationField`/an equivalent DCB
  naming so a single-command slice keeps its current `Platform_<Slice>` name — i.e. when the
  slice name equals its sole constructor, the name is unchanged; multi-command slices gain
  `Platform_<Constructor>` fields).
- Ensure each generated mutation's argument shape is that command constructor's fields (today
  the single field already uses the first constructor's shape — extend to each).
- Thread the same per-constructor field set into the subscription generator (it already
  iterates `fieldNames`) and the `@aws_iam` / auth stamping (so a `systemCallable` slice's
  remove mutation is authorized like its sync mutation).
- Backward-compat: a slice with exactly one command constructor whose name equals the slice
  name must keep the identical field name (no schema churn for the common case).

## Acceptance

- A DCB slice with `command = SyncX | RemoveX` generates both `Platform_SyncX` and
  `Platform_RemoveX` (each with its own argument shape), and both dispatch to the correct
  `decide` branch.
- Single-command slices are byte-identical in the generated SDL (no rename).
- A schema-diff test over a two-command slice asserts both mutation fields + both subscriptions
  are present; reverting the generator drops the second field (red).

## Notes

- Framework parity item: aligns DCB StateChangeSlices with aggregates and with the existing
  subscription generator. No PPX change — the constructor list is already available from the
  compiled `commandSchema` via `extractAllVariantNames`.
