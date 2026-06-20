# Plan: Deploy-Hook Component-Schema Parity for DCB Slices

**Date:** 2026-06-20

**Status:** Implemented + build-verified (uncommitted) — CHANGELOG + publish pending

**Relates to:** [plugin-history-parity-gap.md](plugin-history-parity-gap.md) (same
"close a framework asymmetry" shape, different surface)

---

## Goal

Make the **plugin-built / plugin-deployed hook** component schema
(`pluginDeployedSchema`) carry the same routing metadata for DCB slices —
automation, inbound-translation, and outbound-translation slices — that
`Plugin_Structure` already computes for the static plugin definition. Today that
hook surface is **asymmetric**: aggregates and read models expose rich schema
(command/event/error types, query fields, field-level schemas), while every DCB
slice exposes an **empty record** `{}`. As a result, a consumer of the deploy hook
(`registerOnPluginDeployed` / `pluginDeployedInfo`) sees DCB-slice components with
no command types, no consumed event types, and no routing target — even though the
framework already knows all three at build time.

This is a framework-completeness gap, not a new feature: the data is computed once,
in `Plugin_Structure`, and then thrown away on the hook path.

---

## Background — where the asymmetry is

`Plugin_Structure.res` builds the static plugin definition and, for each routing
slice, already records its command/event wiring **and its routing target**:

- `src/plugin/component/Plugin_Structure.res:446-463` — `automationSliceDefs`:
  `{ name, consumedEventTypes, producedCommandTypes, targetName }`
  (`targetName = AS.Spec.targetName`).
- `src/plugin/component/Plugin_Structure.res:466-474` — `outboundTranslationSliceDefs`:
  `{ name, consumedEventTypes, inboundCommandTypes, targetName }`.
- `src/plugin/component/Plugin_Structure.res:476-483` — `inboundTranslationSliceDefs`:
  `{ name, commandTypes, targetName }`.

The hook path computes the per-component schema separately, in `Plugin_Builder`:

- `src/plugin/component/Plugin_Builder.res:370-386` — aggregates get a fully
  populated `pluginDeployedSchema` (and register it in `componentSchemaRegistry`,
  which the deploy hook reads back).
- `src/plugin/component/Plugin_Builder.res:388-397` — read models likewise.
- `src/plugin/component/Plugin_Builder.res:399-414` — **`mapNames`** maps every DCB
  slice kind (`StateChangeSlice`, `StateViewSlice`, `AutomationSlice`,
  `OutboundTranslationSlice`, `InboundTranslationSlice`) to a component whose schema
  is the empty record `{}`, and does **not** register it in
  `componentSchemaRegistry`. So both the built hook and the deployed hook
  (`Plugin_Helpers.res:~1463`, `componentSchemaRegistry->Dict.get(name)->getOr({})`)
  surface `{}` for these components.

The schema record type itself has no field for a routing target:

- `src/plugin/component/Plugin_BuiltHook.res:66-85` — `pluginDeployedSchema` has
  `commandTypes?`, `eventTypes?`, `consumedEventTypes?`, `producedCommandTypes?`,
  etc., but **no `targetName?`**.

The module arrays needed to recompute this are already in `Plugin_Builder`'s scope
(`~automationSlices`, `~inboundTranslationSlices`, `~outboundTranslationSlices` —
`Plugin_Builder.res:55-57`, threaded from `construct`), so the build is local — it
mirrors exactly what `Plugin_Structure` already does over the same module lists.

---

## Approach

1. **Add `targetName?: string` to `pluginDeployedSchema`**
   (`Plugin_BuiltHook.res:66-85`). Optional, so existing producers/consumers are
   unaffected. (The command/event-type fields it needs — `producedCommandTypes`,
   `commandTypes`, `consumedEventTypes` — already exist.)

2. **Replace `mapNames` for the three routing-slice kinds** in `Plugin_Builder`
   with builders that iterate the corresponding module arrays and populate a real
   `pluginDeployedSchema`, mirroring `Plugin_Structure.res:446-483`:
   - Automation slice → `{ consumedEventTypes, producedCommandTypes, targetName }`.
   - Inbound-translation slice → `{ commandTypes, targetName }`.
   - Outbound-translation slice → `{ consumedEventTypes, commandTypes (= inbound
     command types), targetName }`.
   Keep the plain `mapNames` (empty schema) for `StateChangeSlice` /
   `StateViewSlice`, which have no routing target. Use the same
   `extractAllVariantNames` (commands) / `extractVariantNames` (events) helpers
   `Plugin_Structure` uses for the variant extraction, but **without** the
   `qualify(~prefix=name, …)` plugin-name prefix — the type strings must stay
   **unqualified to match the aggregate / read-model entries already on this same
   hook surface** (`Plugin_Builder.res:373-397` emits unqualified names;
   `Plugin_Structure` additionally prefixes its static defs). Internal consistency
   of the hook surface is what matters, not byte-equality with the static structure.

3. **Register the enriched schema in `componentSchemaRegistry`** (as aggregates and
   read models already do at `Plugin_Builder.res:384,395`) so the **deployed** hook —
   not just the built hook — surfaces it. The deployed hook reads the registry back
   in `Plugin_Helpers.res:~1463`.

4. **Verification** — see "Verification (implemented)" below. Note: core has **no
   plugin-construction test harness** (the existing `PluginStructureTest` /
   `ManifestVisibilityTest` deliberately test `Plugin_Structure.make` directly and
   never instantiate the `Plugin_Builder.Make` functor), and stubbing a full
   `AutomationSlice.T` (a real `Automation` module with `process` / `mappings` /
   per-mapping `SourceId` / `sourceEventSchema` / `collect` / `resolve`) is heavy and
   fragile. Behavioral coverage of the routing metadata therefore lives **downstream**,
   in the consumer's synthetic-stream tests (which assert `targetName` flows once the
   consumer reads `c.schema.targetName`). Core-side correctness rests on the
   type-checked accessors (identical to `Plugin_Structure`'s production derivation)
   plus a zero-regression full suite.

---

## Why this is clean / low-risk

- **No write-side change** — `Plugin_Builder` already constructs these components;
  only the per-component schema payload changes.
- **Optional field, additive** — `targetName?` and newly-populated arrays cannot
  break existing consumers that ignore them; today they only ever read `{}` for
  these components.
- **Single source of truth restored** — the routing metadata is computed the same
  way in both `Plugin_Structure` and `Plugin_Builder`; consider a shared helper if
  the two derivations drift.

---

## Definition of done

- [x] `pluginDeployedSchema` carries `targetName?` (`Plugin_BuiltHook.res`).
- [x] `Plugin_Builder` populates `producedCommandTypes` / `commandTypes`,
      `consumedEventTypes`, and `targetName` for automation / inbound / outbound
      translation slice components, and registers them in `componentSchemaRegistry`.
- [x] Zero-warning build (`rescript build` exit 0, 400 modules); full suite shows
      **no new failures** (the 64 pre-existing failures are an environmental
      `uuid@3.4.0` ESM-interop issue under jest — `Uuid.v4 is not a function` in
      `Message.res.mjs` — reproduced identically on a clean HEAD with this change
      stashed; every plugin-construction/structure suite passes).
- [ ] Behavioral coverage of the routing metadata — owned **downstream** by the
      consumer's synthetic-stream tests (see Approach §4 rationale: no core
      construction harness; functor stubbing of `AutomationSlice.T` is fragile).
- [ ] CHANGELOG note (neutral, framework framing: "plugin hooks now expose
      command/event/target metadata for DCB routing slices, at parity with
      aggregates and read models").

---

## Verification (implemented 2026-06-20)

- `Plugin_BuiltHook.res` — added `targetName?: string` to `pluginDeployedSchema`.
- `Plugin_Builder.res` — replaced the `mapNames` calls for `AutomationSlice` /
  `OutboundTranslationSlice` / `InboundTranslationSlice` with a `routingComponents`
  builder: it derives an unqualified `pluginDeployedSchema` per slice from the
  in-scope module arrays (`producedCommandTypes`/`commandTypes` via
  `extractAllVariantNames`, automation `consumedEventTypes` as the deduped union of
  per-mapping `sourceEventSchema` via `extractVariantNames`, `targetName` from the
  spec — outbound's optional target passed through with `?`), registers it in
  `componentSchemaRegistry`, and still derives the component **set** from the DCB
  outputs dict so membership is unchanged. `StateChangeSlice` / `StateViewSlice` keep
  the empty-schema `mapNames`.
- Build: `rescript build` exit 0, zero warnings. (Local note: the core repo's
  `node_modules/sury` was missing — the documented two-installs-diverge gotcha;
  symlinked from the sibling business repo, versions identical `11.0.0-alpha.4`.)
- Tests: full `jest` run — no regressions attributable to this change (proven by
  stash-rebuild-rerun on clean HEAD).

**Remaining before a consumer can use this:** publish the bumped core and update
downstream deps; then the consumer reads `c.schema.targetName` /
`producedCommandTypes` off the deploy-hook payload.

---

## Notes

- This only fixes the **hook** surface. The static `pluginStructure`
  (`Plugin_Structure`) is already complete and unchanged.
- `StateChangeSlice` / `StateViewSlice` intentionally keep an empty schema — they
  have no routing target; this plan does not invent one for them.
