# Plan: Surface translation-slice **externalSystem** in the deployed plugin structure

**Date:** 2026-07-10

**Status:** DONE (drop-site pinned; fixed + tested — 2026-07-10)

**Relates to:** [deploy-hook-dcb-slice-schema-parity.md](deploy-hook-dcb-slice-schema-parity.md)
(same "a field the framework computes is lost before it reaches deployed consumers" shape).

---

## Goal

Make a translation slice's **`externalSystem`** survive into the deployed plugin-structure
read model so a consumer rendering the graph from the platform's deployed read models (no
workspace/disk access) can draw the **external-system boundary node** — the "external box
outside the plugin" that an inbound/outbound translation slice integrates with — identically
to the authoring tool.

## Background — the drop

`externalSystem` is a first-class field on translation slices and IS computed by the static
plugin definition, but it is **lost on the way to the deployed read model**:

- A translation slice declares it in its spec, e.g. `let externalSystem = Some("SupplierFeed")`
  (an `option<string>`).
- `Plugin_Structure.res` propagates it verbatim for both directions:
  - inbound: `{ …, targetName, externalSystem: ITS.Spec.externalSystem }`,
  - outbound: `{ …, targetName, externalSystem: OTS.Spec.externalSystem }`.
- **But the deployed plugin-structure read model returns `externalSystem` as absent/empty**,
  while the **sibling `targetName` on the same record survives**. So a consumer reading the
  deployed structure cannot tell an external system exists, and the "external box" the
  authoring tool draws is missing from the deployed graph.

Evidence that this is a transit drop, not a schema omission: the derived deployed-structure
type *declares* an `externalSystem` field (so the read-model spec includes it), yet its value
arrives empty for a slice whose spec sets it. Since `Plugin_Structure` carries it and
`targetName` on the same record round-trips, the loss is specifically in the
**definition → deployed-read-model persistence** of the translation-slice record — the Sury
serialization of the structure or the projection that writes it.

`externalSystem` appears in core `src/` **only** in `Plugin_Structure.res` (the two lines
above) — nowhere in the persistence/serialization path — which is consistent with the value
never being written even though the field is declared downstream.

## Approach

1. **Pin the drop site.** Trace the translation-slice record from `Plugin_Structure` through
   the definition serialization (Sury) and the plugin-structure read-model projection.
   Confirm where `externalSystem` is not carried (likely the Sury schema for the
   translation-slice sub-record, or the projection's field mapping — the same place that
   *does* copy `targetName`).

2. **Round-trip `externalSystem`.** Add it wherever `targetName` is already threaded for the
   translation-slice records (in + outbound), so it survives serialization + projection into
   the deployed read model. Optional `string`; absent when the spec sets none.

3. **(Optional) Model the external system as a first-class graph datum.** So consumers render
   the external box identically without re-deriving it: expose an `ExternalSystem` node + the
   boundary edge (external → inbound slice, outbound slice → external) in the shared graph
   derivation, keyed off the now-available `externalSystem`. The renderer already has an
   `ExternalSystem` node kind; only the deployed *data* to instantiate it is missing.

## Resolution — drop site pinned

The plan's suspicion (Sury schema / read-model persistence) was **not** the drop. The Sury
`pluginStructure` schema (`reventless-spec/src/components/Plugin.res`, the
in/outboundTranslationSliceDef records) already declares `externalSystem`
(`@s.matches(stringOptionSchema)`, the same JSON-safe `js_nullable` form as `targetName`),
`Plugin_Structure.res` already sets it, the plugin handshake already carries the whole
`pluginStructure`, and `PluginsReadModelSpec.state.structure` already stores it — so the
AWS deployed path (`Platform_ComponentDefinitions_Lambda` spreads the raw stored
`item.structure`) already round-trips it.

The drop was on the **wire-encoding / hook surfaces** that mirror the structure for
consumers — exactly where the sibling `chapter` field was threaded (see
[done/deployed-chapter-grouping.md](done/deployed-chapter-grouping.md) point 6–7):

1. **`Platform_ComponentDefinitionsApi` encoders** — `encodeOutboundTranslationSliceDef` /
   `encodeInboundTranslationSliceDef` emitted `name`, event/command types and `chapter` but
   **not** `externalSystem`. This is the JSON shape the local/in-memory adapter serves, the
   admin's own `ADMIN_ENTRY`, and the CLI `definitions` stream. → **Fixed:** both encoders now
   emit `externalSystem` (`None → null`, `Some → inner string`), mirroring `targetName`/`chapter`.
2. **`onPluginBuilt` hook surface** (`Plugin_BuiltHook.pluginDeployedSchema`) carried
   `targetName?` for routing slices but **no** `externalSystem?` field — the concrete reason
   a consumer merging the hook surface saw `targetName` survive while `externalSystem` was
   absent. → **Fixed:** added `externalSystem?: string`; `Plugin_Builder.construct` now sets it
   on both translation routing schemas from `Spec.externalSystem`, single-sourced like `chapter`.

`Reventless.Plugin.pluginStructure`'s SDL `Platform_*TranslationSliceDef` types are **not**
touched — consistent with the chapter fix, whose consumers read the definition entries as
opaque JSON (see `ReventlessVscodeProtocol.Protocol`'s `Definitions`), not via typed field
selection. The canonical contract is the encoder JSON shape asserted by the round-trip test.

§3 (ExternalSystem node in the shared derivation) was **already satisfied**:
`DomainGraph.build` (`reventless-gwt/src/DomainGraph.res`, `addExternal`) already emits an
`ExternalSystem` node + directional boundary edge keyed off `o.externalSystem` /
`i.externalSystem`, and the renderer already has the node kind. The only missing datum was
the deployed one this plan now supplies — no renderer change.

## Definition of done

- [x] Drop site pinned and documented (encoders + hook surface, **not** the Sury schema).
- [x] Deployed plugin-structure read model returns `externalSystem` for in + outbound
      translation slices whose spec sets it (AWS raw-structure path already did; encoder path
      now does too).
- [x] Headless round-trip test: `Platform_ComponentDefinitionsApiTest` — `Some("ShipperGateway")`
      / `Some("BillingProvider")` surface the inner string for both directions; the `None`
      fixture surfaces `null`.
- [x] Shared derivation emits an `ExternalSystem` node + boundary edge from the deployed data
      (pre-existing in `DomainGraph.build`; now fed by the deployed datum).
- [x] Zero-regression build + suite (full `pnpm run build` exit 0, zero warnings; core
      plugin/admin suites 96 passed, `Platform_ComponentDefinitionsApiTest` 20 passed,
      gwt `DomainGraphTest` 19 passed).
- [x] CHANGELOG note carried by the `feat:` commit (neutral: deployed plugin structure now
      carries translation-slice `externalSystem` for deployed-graph external-system boundaries).

## Risks / notes

- **`option<string>` serialization.** The likely culprit is an `option` field omitted from a
  Sury object schema; verify `None` vs `Some` both round-trip (absent vs present).
- **Cover both directions.** Inbound and outbound translation slices both carry it; fix and
  test both.
- **Additive.** Consumers that ignore `externalSystem` are unaffected; slices without one
  render exactly as today.
