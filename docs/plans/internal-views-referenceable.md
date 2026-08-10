# Plan: Internal views stay referenceable

**Status.** Proposed — 2026-08-10. Written after a `@ref` at an
`@@reventless.visibility(Internal)` view was found to silently degrade to a
free-text input in the generated form, for every caller including admins.

**Sibling plan:** `reventless-ui: docs/plans/shell-static-manifest-and-end-user-mode.md`
— the consuming half. Core ships the datum; the shell unions it into the ref
registry. Neither half is useful alone.

**Dependent plan:** `docs/plans/ui-manifest-baked-emission.md` — must land
**after** this one. A baked manifest has to carry `internalQueryables`, and a
shell reading one never falls back to the admin API, so a reference target
absent from the baked file is absent permanently.

**Goal.** A `@ref` targeting a view marked `@@reventless.visibility(Internal)`
resolves to a real entity picker, while that view remains absent from the
generated menu, pages and panels.

**Non-goal.** Changing what `Internal` means, or making it an access-control
mechanism. `Visibility.res:4-7` is right and stays as written.

---

## §1 — The defect: one filter doing two jobs

`Visibility.res:4-7` defines `Internal` narrowly:

> `Internal` is a UX hint, NOT a security boundary. Internal components remain
> queryable via GraphQL, retain their resolvers, and stay in the platform's
> event graph — they are only hidden from AutoUI's menu / panel enumeration.

The implementation is broader than the contract. `isPublicQueryable`
(`reventless/core/src/admin/Platform_ComponentDefinitionsApi.res:78`) is applied
at the transport, removing Internal views from the
`Platform_ComponentDefinitions` payload entirely
(`:184-192`). The manifest is also the only source from which a client can learn
that a view exists, its `queryField` and its `labelField` — i.e. everything
needed to resolve a reference. So hiding a view from the menu also, and
unintentionally, denies it as a **reference target**.

Those are different questions. A denormalised lookup view is precisely the thing
an author wants referenceable but not navigable; today the annotation forces a
choice between the two.

The failure is silent and total, not partial: the consuming side logs
`explicit @ref to "…" did not resolve to a registered entity. Falling back to
text input` and renders a plain string field. Nothing surfaces server-side.

**The runtime side is already correct.** Verified against the in-memory platform:
a caller in a non-elevated group reads an Internal `StateViewSliceStream` over
the domain API in full — the field is in the SDL, the resolver runs, the caller
is authorized. Only the manifest entry is missing. This plan adds no query path
and no permission; it publishes a fact the client is already entitled to.

## §2 — Shape: additive, not a contract change

Keep `readModels` and `stateViewSlices` filtered exactly as they are, and add a
third list carrying only what the filter removed:

```
type Platform_ComponentDefinitionEntry {
  pluginId: String!
  readModels: [Platform_ReadSideDef!]!          # unchanged, public only
  stateViewSlices: [Platform_ReadSideDef!]!     # unchanged, public only
  internalQueryables: [Platform_ReadSideDef!]!  # NEW — the complement
  …
}
```

`Platform_ReadSideDef` already declares `visibility`
(`Platform_ComponentDefinitionsApi.res:28`) and `encodeQueryableDef` already
emits it (`:98`), so an entry in the new list is self-describing. No new type, no
new encoder, no change to any existing field's contents.

**Why additive rather than shipping Internal in the main lists and filtering
client-side at enumeration.** The latter is a breaking change to the manifest
contract: every consumer that enumerates `readModels` / `stateViewSlices` to
build a surface would need auditing in lockstep, and any consumer missed — or
pinned to an older shell — starts rendering Internal views as pages. The
additive field cannot regress: existing consumers read byte-identical arrays and
ignore a field they do not select.

The cost is one denormalised list. That is the right trade for a datum whose
whole purpose is "exists, but is not a surface".

## §3 — The two transports filter in different places

This is the part that makes the change larger than one edit, and it is worth
stating precisely before starting.

| Path | Where the filter lives | What §4 changes |
| --- | --- | --- |
| In-memory | `Platform_ComponentDefinitionsApi.encodePluginStructureEntry:184-192` | emit the complement list |
| AWS, per-plugin | `Platform_ComponentDefinitions_Lambda_Ops.filterStructure:119-131`, applied by `toEntryWith(~filter)` at `:149` | emit the complement list |
| AWS, built-in admin entry | `encodePluginStructureEntry` at deploy time (`Platform_ComponentDefinitions_Lambda.res:110`), baked into the code archive as `adminEntry.json` | rides the in-memory fix for free |

On AWS the persisted plugin structure is **pre-filter** — it still carries
Internal components, as `Platform_ComponentDefinitions_Lambda.res:9-12` records —
and the handler re-applies the filter at query time. So the AWS fix is a
handler-side twin of the in-memory one, not a consequence of it. The two must
land together; a shell that reads `internalQueryables` against a platform that
emits it on only one transport gets working pickers locally and silent text
inputs when deployed, which is the transport-drift failure this codebase has hit
before.

`Platform_PluginStructures` is deliberately unfiltered already
(`Platform_PluginStructuresApi.res:65`) and needs no change.

## §4 — Work

1. **SDL.** Add `internalQueryables: [Platform_ReadSideDef!]!` to
   `Platform_ComponentDefinitionEntry`
   (`Platform_ComponentDefinitionsApi.res:33`). Non-null list, `[]` when a plugin
   has no Internal views — the honest answer, and it keeps the shape uniform for
   decoders.
2. **In-memory encoder.** In `encodePluginStructureEntry`, emit the complement:
   `readModels ++ stateViewSlices` where `!isPublicQueryable`, each through the
   existing `encodeQueryableDef`. The two existing keys keep their current
   `->Array.filter(isPublicQueryable)`.
3. **AWS handler.** In `filterStructure` (`…_Lambda_Ops.res:119-131`), set
   `internalQueryables` to the complement of the same predicate over both source
   arrays, alongside the two `Dict.set` calls already there. Leave the
   `complete` (unfiltered) path untouched — `Platform_PluginStructures` carries
   Internal components inline and must not grow a duplicate list.
4. **Healing.** `healStructure` runs before `filterStructure`; confirm a
   structure persisted before this change heals to `internalQueryables: []`
   rather than a missing key, since the SDL list is non-null.

## §5 — Tests

- `Platform_ComponentDefinitionsApiTest`: an entry mixing Public and Internal
  views encodes the Internal ones into `internalQueryables` **and** keeps them
  out of `readModels` / `stateViewSlices`. Assert both directions — the point of
  the feature is the separation, so a test that only checks presence would pass
  on a change that also leaked them into the main lists. The file already builds
  a mixed fixture at `:261`.
- `Platform_ComponentDefinitionsApiTest`: an all-Public entry encodes
  `"internalQueryables":[]`, not a missing key.
- SDL assertion (the file already does this at `:172`): the new field is
  declared on the entry type.
- Ops-handler test: `toEntryWith(~filter=true, …)` produces the same split as the
  in-memory encoder for an equivalent persisted structure — the transport-parity
  assertion §3 argues for. `toEntryWith(~filter=false, …)` is unchanged.

## §6 — Verification in the example

`online-shop-hybrid` demonstrates the case without new fixtures:
`ordering/src/Order/StateChangeSlice/PlaceOrder.res:26` declares
`@ref("AvailableProducts")` against
`ordering/src/CatalogProduct/StateViewSliceStream/AvailableProducts.res:7`, which
is `Internal`.

Against `platform-local`, `Platform_ComponentDefinitions` should report the
`Ordering` entry carrying `Orders` in `stateViewSlices` and `AvailableProducts`
in `internalQueryables` — and, with the sibling ui plan in place, the generated
`PlaceOrder` form should offer a product picker while no `AvailableProducts`
entry appears anywhere in the nav.

Repeat against a deployed stack before calling the AWS half done; §3 is the
reason the local result does not imply it.
