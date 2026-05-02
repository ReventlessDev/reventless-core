# Plan: Event Graph Linking

Implements the design in [event-graph-linking.md](../analysis/event-graph-linking.md).

An event-sourced system is already a directed graph — write-side components produce events, read-side components consume them — and that graph is latent in every `@schema type event` and `@schema type consumedEvent` declaration. The analysis shows the information needed to materialise the full intra-plugin and cross-plugin graph is almost entirely present today; what is missing is a small amount of extraction wiring, a rename that frees the plugin self-description from its original "Auto UI" framing, and one narrow Spec addition (`targetName`) for slices whose destination is currently opaque. This plan stages the work so each phase ships and is validated independently.

---

## ~~Phase 1 — Rename `uiDefinition` → `pluginDefinition` (breaking, pure refactor)~~ ✅ DONE (8edd6673)

**Naming decision (actual vs. planned).** The wire-level `pluginDefinition` record kept its name. The Auto-UI-shaped metadata record became **`pluginStructure`** (not `pluginDefinition` as originally proposed) to avoid a collision. All three sub-types renamed: `uiCommandDef` → `commandDef`, `uiQueryableDef` → `queryableDef`, `uiWritableDef` → `writableDef`. `makeAutoUIDefinition` → `makePluginDefinition`; the generated binding is `let pluginStructure = Platform.Plugin.makePluginDefinition(...)`. All example `Plugin.res` files regenerated.

Cross-repo impact: UI consumers must replace `uiDefinition` / `makeAutoUIDefinition` / `uiCommandDef` / `uiQueryableDef` / `uiWritableDef` with the new names (see bottom of this file).

---

## ~~Phase 2 — Tier 2a extractions (schema-derived fields, no Spec changes)~~ ✅ DONE (8edd6673)

**What landed (actual vs. planned).**

All planned fields were populated:
- `commandDef` gains `level: commandLevel` and `aggregateIdField: option<string>`
- `queryableDef` gains `consumedEventTypes` and `linkedWriteSide`
- `writableDef` gains `producedEventTypes`, `consumedEventTypes`, `linkedViews`, `consistencyRead`

**Extra: `Plugin_Structure.res` extraction.** The extraction logic was pulled out of `Plugin_Builder.Make` into a standalone [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) pure function (polymorphic over `api`/`role` phantom types via ReScript locally-abstract-type syntax `let make = (type api role, ...)`). `Plugin_Builder.makePluginDefinition` now delegates to it. This allows direct unit testing without spinning up a Platform.

**Bug fix: single-variant command schemas.** A `@schema type command = Foo({...})` with only one variant compiles to a bare `Object` schema in sury — not a `Union`. The original `extractCommandDefs` only matched `Union({anyOf})` and produced empty `commands` arrays for almost every aggregate and SCS. Fixed with a fallback case:
```rescript
| _ => toCommandDef(~isAggregate, commandSchema)->Option.mapOr([], def => [def])
```

**`DcbTag.extractVariantNames` excludes payload-less literals.** The function only processes `Object` variants with a TAG field. Payload-less variants (`| OrderPlaced`) serialize as `String({const})` and are excluded. This is correct: they carry no DCB tag data and do not participate in event-type cross-referencing. The `consistencyRead` heuristic works correctly with this behaviour (PlaceOrder SCS consumed `CatalogProductSynced` unambiguously → `Some("AvailableProducts")`; ShipOrder consumed no payload-bearing events → `None`).

**Level/aggregateIdField heuristic.** For aggregates: always `Instance`, `aggregateIdField: None`. For SCS commands: inspect the command variant's properties for any field (other than TAG) where `DcbTag.isTagged` or `DcbTag.isTaggedArray` returns true → `Instance` with that field name; if none found → `Collection`.

**Tests.** 16 unit tests in [PluginStructureTest.res](../../reventless/reventless-core/tests/plugin/PluginStructureTest.res) covering all graph fields directly against `Plugin_Structure.make` (no Platform needed). Inline stub T modules use `Obj.magic(0)` for the `make` body.

---

## ~~Phase 3 — Tier 2b wiring (AutomationSlice, Outbound/Inbound Translation, Extension)~~ ✅ DONE (next commit)

**What landed vs. planned.**

Added four new def types to `pluginStructure` and threaded the corresponding module arrays through `Plugin_Structure.make`, `makePluginDefinition`, and `renderPluginStructureCall`:

- `automationSliceDef` — `name`, `consumedEventTypes` (from `Spec.consumedEventSchema`), `producedCommandTypes` (from `Spec.commandSchema`)
- `outboundTranslationSliceDef` — `name`, `consumedEventTypes`, `inboundCommandTypes` (from `Spec.inboundCommandSchema`; empty when `type inboundCommand = unit`)
- `inboundTranslationSliceDef` — `name`, `commandTypes` (from `Spec.commandSchema`)
- `extensionDef` — `name` (`Spec.name`), `delegateNames` (each mapping's `delegateName: string`), `eventTypes` (`Spec.eventSchema`), `commandTypes` (`Spec.commandSchema`)

The generated `pluginStructure` call in each example `Plugin.res` now includes `~automationSlices`, `~outboundTranslationSlices`, `~inboundTranslationSlices`, and `~extensions` when those arrays are non-empty. The hybrid ordering plugin exercises all three: `AutoShipOrderSlice`, `SendOrderConfirmationSlice`, and `ProductsExtensionMaker`.

**Deferred: EventMappings and SideEffects.** Neither is in `Plugin.make`'s parameter list — EventMappings are bundled into individual `Aggregate.T` modules during `Platform.Aggregate.Make(Spec, Behavior, Mappings)` and are opaque from the outside; SideEffects have no top-level wiring at all in the current generator. Threading them would require either extending `Aggregate.T` with an accessor or adding a new separate parameter. Deferred to a later phase or separate plan.

---

## ~~Phase 4 — Tier 3 Spec fields (`let targetName` on slices, validated by generator)~~ ✅ DONE

**What landed.**

Added `let targetName` to all three Spec module types:
- `AutomationSlice.Spec` — `let targetName: string` (required; names the SCS or aggregate receiving the command)
- `OutboundTranslationSlice.Spec` — `let targetName: option<string>` (None = fire-and-forget)
- `InboundTranslationSlice.Spec` — `let targetName: string` (required)

`automationSliceDef`, `outboundTranslationSliceDef`, and `inboundTranslationSliceDef` in [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res) gained the `targetName` field. [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) surfaces `Spec.targetName` into each def.

[Pairing.res](../../reventless/reventless-spec/src/generator/Pairing.res) parses `let targetName = "..."` from each slice file using `extractTargetName` and stores results in three new `Dict.t<option<string>>` fields on `resolved`. [Codegen.res](../../reventless/reventless-spec/src/generator/Codegen.res) calls `validateSliceTargets` at render time; it throws with a descriptive error if a declared `targetName` is not among the plugin's known aggregates + StateChangeSlices, or if a required `targetName` is absent.

All 6 example spec files updated: `AutoShipOrder → "ShipOrder"`, `SendOrderConfirmation → None`, `ImportProduct → "AddProduct"`. Test fixture specs in `reventless-in-memory` also updated. Build: zero warnings, 1034 tests pass.

---

## ~~Phase 5 — Namespacing (qualified event and command names)~~ ✅ DONE

**Goal.** Qualify every event and command name in `pluginDefinition` with its plugin (for DCB events/commands) or spec-package (for Extension Point events), making cross-plugin matching collision-proof.

**Files to change.**
- [Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res) — change every `extractVariantNames` call in `makePluginDefinition` to prepend the fully-qualified prefix.
- Small helper in [DcbTag.res](../../reventless/reventless-spec/src/components/DcbTag.res) OR a new `Plugin_Naming.res` — `let qualify = (~prefix, variantNames) => variantNames->Array.map(n => prefix ++ "." ++ n)`. A new file is cleaner since `DcbTag` is already crowded.
- [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res) — document on every `*EventTypes: array<string>` field that the values are qualified.

**Concrete steps.**
1. Introduce `Plugin_Naming.qualify(~prefix, names)` (or inline the one-liner in `Plugin_Builder` if that reads cleaner).
2. In `makePluginDefinition`, wrap every `extractVariantNames(Spec.eventSchema)` / `extractVariantNames(Spec.consumedEventSchema)` / `extractVariantNames(Spec.commandSchema)` call with `qualify(~prefix=pluginName, ...)` for DCB and aggregate sources.
3. For Extension Points and Extensions, use the spec-package name rather than the plugin name. The spec package name is the `@@reventless.spec("…")` attribute (see `PluginSpec.res` line 1 for the pattern). If that name is not already plumbed to `Plugin_Builder`, thread it through — likely via a new field on `ExtensionPoint.Spec` or by reading it from a module-level metadata lookup.
4. Recompute `linkedWriteSide` / `linkedViews` in Phase 2's logic against the qualified names so cross-plugin matching in Phase 6 works on the same key.

**Validation.**
- Test fixture builds the hybrid online-shop setup where Catalog has both `Catalog.ProductPriceChanged` (DCB event) and `CatalogSpec.ProductPriceChanged` (EP event). Assert the resulting `pluginDefinition` distinguishes them and that within-plugin matching still produces the expected `linkedViews`.
- The generator's output diff for each example is limited to the prefixed strings.

**What landed.**

Added `let qualify = (~prefix, names) => names->Array.map(n => prefix ++ "." ++ n)` in [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) and applied it to every `variantNames(...)` call:
- DCB types (SCS/aggregate produced, SCS/SVS consumed, AutomationSlice consumed+produced, OutboundTranslationSlice consumed+inbound, InboundTranslationSlice commands): prefix = `name` (plugin name)
- Extension types (EP eventTypes, commandTypes): prefix = `E.Spec.name` (extension point dotted name, e.g., `"Catalog.Products"`)

Cross-reference helpers (`linkedViewsFor`, `linkedWriteSideFor`, `consistencyReadFor`) work correctly because both `svsConsumed`/`allWritableProduced` and the per-component arrays are qualified with the same plugin prefix — intersection keys match. Component names returned by those helpers remain short/unqualified.

[PluginStructureTest.res](../../reventless/reventless-core/tests/plugin/PluginStructureTest.res) updated to expect `"TestPlugin.*"` qualified names. Build: zero warnings, 327 + 279 tests pass.

**Commit message.**
`feat!: qualify event and command names in pluginDefinition with plugin / spec-package prefix`

---

## ~~Phase 6 — Cross-plugin graph and `Platform_EventGraph` ReadModel~~ ✅ DONE

**What landed.**

Added `structure: option<pluginStructure>` to `pluginDefinition` so the wire-level Connect command carries component-graph metadata. Added `@schema` to all plugin structure types (`commandLevel`, `commandDef`, `queryableDef`, `writableDef`, `automationSliceDef`, `outboundTranslationSliceDef`, `inboundTranslationSliceDef`, `extensionDef`, `pluginStructure`) and to the three new graph types (`graphNode`, `graphEdge`, `platformEventGraph`). `option<string>` fields on nested types that sit inside union variant payloads (`aggregateIdField`, `consistencyRead`, `targetName`) use `@s.matches(stringOptionSchema)` to avoid sury's `undefined`-in-JSON error.

`Plugin_Builder.res` now sets `structure: pluginStructure` when constructing the `pluginDefinition` output, so every connected plugin's component graph is embedded in the heartbeat event.

**`Platform_EventGraph` ReadModel** ([src/admin/Platform_EventGraphReadModelSpec.res](../../reventless/reventless-core/src/admin/Platform_EventGraphReadModelSpec.res) + [Platform_EventGraphProjection.res](../../reventless/reventless-core/src/admin/Platform_EventGraphProjection.res)). Note: shipped as a ReadModel rather than the StateViewSlice originally proposed — adapter ownership in `Platform_Admin.construct` made the ReadModel route simpler, and the projection logic is identical.
- `consumedEvent` = subset of PluginSpec events: `Connected | Reconnected | Disconnected | Activated | Deactivated`
- `state` = `{pluginName: string, nodes: array<graphNode>, edges: array<graphEdge>}` keyed by plugin name
- `project`: Connected/Reconnected/Activated → `Set(pd.name, entry)` building nodes for all component types and intra-plugin edges (write-side→StateViewSlice via EventTypeMatch, AutomationSlice→target, InboundTranslation→target, Extension→delegates); Disconnected/Deactivated → `Delete(pd.name)`

**Cross-plugin resolver** ([src/admin/Platform_CrossPluginEdges.res](../../reventless/reventless-core/src/admin/Platform_CrossPluginEdges.res)). Pure query-time computation over all plugins' `pluginStructure` entries. Currently emits two mechanisms only — `EventTypeMatch` (write-side → cross-plugin SVS) and `Extension` (dotted EP-name prefix). Exposed as the `platformCrossPluginEdges` GraphQL query.

**Deferred from original plan.**
- Cross-plugin edge computation for the remaining mechanisms (`AutomationSlice`, `InboundTranslation`, plus EventTypeMatch into AutomationSlice/OutboundTranslationSlice consumers) — see Phase 6b.
- Platform wiring is split-state across in-memory and AWS — see Phase 6c. (Original deferral note said "AWS missing the ReadModel"; the real picture is the opposite for the ReadModel and the AWS platform is missing the cross-plugin resolver instead.)
- `platformEventGraph` as singleton state: the per-plugin keyed approach was chosen instead; the full graph can be assembled by reading all `platformEventGraph` entries.

Build: zero warnings, 1034 tests pass.

---

## ~~Phase 6b — Complete cross-plugin edge mechanisms~~ ✅ DONE

**What landed.**

Extended `Platform_CrossPluginEdges.computeEdges` ([src/admin/Platform_CrossPluginEdges.res](../../reventless/reventless-core/src/admin/Platform_CrossPluginEdges.res)) with three additional emission passes:

1. **Broadened `EventTypeMatch`.** The consumer set now unions `stateViewSlices`, `automationSlices`, and `outboundTranslationSlices`. A cross-plugin write-side → AutomationSlice or OutboundTranslationSlice event-flow now surfaces as an `EventTypeMatch` edge with the appropriate `target.kind` (`"AutomationSlice"` / `"OutboundTranslationSlice"`).
2. **`AutomationSlice` mechanism.** Every `automationSlice` whose `targetName` resolves to a writable (`aggregate` or `stateChangeSlice`) in another plugin produces an `AutomationSlice` edge with `viaEvents = producedCommandTypes` (the field is overloaded as command names — documented in the SDL comment).
3. **`InboundTranslation` mechanism.** Symmetric to (2): cross-plugin `inboundTranslationSlice.targetName` resolution produces an `InboundTranslation` edge with `viaEvents = commandTypes`.

A small `findWritableOwner(~name)` helper inside `computeEdges` shares the writable-resolution logic between (2) and (3). When the target writable lives in the same plugin (or is missing entirely), no cross-plugin edge is emitted.

**OutboundTranslation mechanism deferred.** The `outboundTranslationSlice.targetName` field is `option<string>` and no current example uses `Some(_)`. Adding this case is a one-line addition once a fixture exercises it; left as a forward-compat hook for now.

**Tests.** [tests/admin/Platform_CrossPluginEdgesTest.res](../../reventless/reventless-core/tests/admin/Platform_CrossPluginEdgesTest.res) — 10 unit tests covering each new mechanism with two-plugin fixtures (cross-plugin and same-plugin variants), plus a regression test for the existing `Extension` mechanism. Build: zero warnings, 322 tests pass.

**Commit message.** `feat(admin): emit AutomationSlice, InboundTranslation, and broader EventTypeMatch cross-plugin edges`

---

## ~~Phase 6c — In-memory PlatformEventGraph resolvers~~ ✅ DONE

**What landed.**

Wired the in-memory equivalent of the AWS `PlatformEventGraphReadModel` into all three admin GraphQL registration sites in [reventless-in-memory/src/Platform.res](../../reventless/reventless-in-memory/src/Platform.res). The implementation departs from the original "instantiate `PlatformEventGraphReadModel` and add to `Admin.construct(~readModels=…)`" plan because the in-memory platform deliberately bypasses event-driven projection wiring for admin read models — instead, it seeds synchronous in-memory stores and registers GraphQL resolvers directly. Mirroring this pattern for the event graph turned out to be a 1:1 copy of the existing `pluginStructuresStore`-backed `platformCrossPluginEdges` registration, just for a different field.

Three registration sites now expose `Platform_PlatformEventGraph` (single by id) and `Platform_PlatformEventGraphs` (list, Connection-shaped):

1. **`makePlatform` (multi-plugin)** — both resolvers compute on-demand from `pluginStructuresStore` using `Platform_EventGraphReadModelSpec.buildEntry(~pluginName, structure)`, serialized via `stateSchema->S.reverseConvertToJsonOrThrow`.
2. **`deployPlatform` (bare platform)** — stub resolvers (single returns null, list returns empty Connection) since no plugins are registered.
3. **`deployPlugin` (single plugin)** — same on-demand computation as `makePlatform`, populated from `pluginStructuresStore` after `seedPluginStructuresStore`.

The `Platform_PlatformEventGraph` SDL types are auto-generated by `PluginBaseFragment.fragment` from the third entry in `queryEntries` (already declared in [PluginBaseFragment.res:25-32](../../reventless/reventless-core/src/admin/PluginBaseFragment.res)), so no SDL additions were needed — only resolver wiring.

**Why this approach over a true ReadModel.** Wiring a real `PlatformEventGraphReadModel` through the in-memory Bus would require: (a) Plugin aggregate events to actually flow through Bus's EventCollector pipeline (not the case today — Plugin state is seeded synchronously), (b) async projection settling before the first query, (c) duplicating the QueryDb infrastructure for a read-only derived view. The on-demand resolver pattern is consistent with `platformCrossPluginEdges` and the existing `Platform_UIDefinitions` query, which all read from `pluginStructuresStore` at request time.

**Validation.** Build clean (zero warnings), 375 in-memory tests pass.

**Commit message.** `feat(in-memory): expose Platform_PlatformEventGraph[s] admin queries from pluginStructuresStore`

---

## Phase 6d — AWS cross-plugin edges resolver (deferred)

**Status.** Deferred. The in-memory side ships under Phase 6c above. The AWS-side resolver is still missing and is intentionally out of scope for this plan — it requires design choices that go beyond mechanical wiring.

**Why deferred.** AWS pushes a static AppSync SDL via `startSchemaCreation` (see [Platform.res:1029-1041](../../reventless/reventless-aws/src/Platform.res)) with managed resolvers backed by Lambda or pipeline JS. The in-memory `platformCrossPluginEdges` resolver pattern (`registerQueries` against an in-memory dict) does not map onto AppSync without designing:

1. **Schema fragment.** Extend the admin base fragment with `Platform_GraphNode`, `Platform_GraphEdge` types and the `platformCrossPluginEdges` query field — `AdminApi.baseFragment` would need a hook for cross-plugin SDL contributions.
2. **Data source.** The `PlatformEventGraphReadModel` projection landed in Phase 6 stores `{pluginName, nodes, edges}` per plugin — sufficient for the per-plugin admin query but **missing** the raw `producedEventTypes`/`consumedEventTypes`/`targetName` fields the cross-plugin matcher needs. Two options:
   - (a) Extend `Platform_EventGraphReadModelSpec.state` to embed the source `pluginStructure` (or just the matchable subset) so the resolver can operate against DDB items directly.
   - (b) Build a separate Lambda that, on query, reads the Plugin aggregate's `pluginDefinition.structure` from the Plugin DDB table.
3. **Resolver implementation.** Either an AppSync JS resolver scanning DDB, or a Lambda data source that calls `Platform_CrossPluginEdges.computeEdges`.

**Recommendation if/when picked up.** Take option (a): widen the projection's state to include the matchable subset of `pluginStructure` (`producedEventTypes`, `consumedEventTypes`, `targetName`, `commandTypes`, `producedCommandTypes`, `delegateNames`). This keeps the resolver pure (`computeEdges` already exists) and avoids a second DDB-reading Lambda. The schema widening is additive — no migration of existing entries needed.

**What's unblocked without this.** Local development (`pnpm run dev:full`), AutoUI demo, and all unit tests work today. The gap only matters for production AWS deployments that also want the cross-plugin Event Graph view.

---

## Phase 7 — Consumer follow-ups (separate plans)

Not implemented here. Each of the following belongs in its own plan, scoped against the `pluginDefinition` and `platformEventGraph` surfaces delivered in Phases 1-6b. The AutoUI consumer track is already planned in the `reventless-ui` package's own adaptation plan (Phase 6 covers querying `Admin_PlatformEventGraphs` and rewriting `AutoEventGraph` for plugin-grouped layout — that work is owned by the UI plan, not this one).

- **Auto UI command linking** — use `linkedViews`, `consistencyRead`, `level`, `aggregateIdField` to place command buttons and panels adjacent to the correct views, replacing existing naming heuristics.
- **Zero-configuration command panels** — Collection-level commands render as list-header buttons; Instance-level commands render as row context menus with the entity id injected.
- **MCP tool description enrichment** — use the graph to append "updates views: X, Y" to each generated MCP tool's description.

---

## Open gaps (Tier 4 — out of scope)

The analysis identifies four permanent gaps that no phase of this plan attempts to resolve:

1. **Task → aggregate routing.** `Task.bucketCallback` routes to any aggregate at runtime based on S3 payload content. A future opt-in `Task.Spec.targetNames: array<string>` advisory list would surface soft edges in the graph, but enforcement is impossible by construction. Flagged for a separate design pass; not included here.
2. **EventMapping `PublishAsync` actions.** Async callbacks resolve commands opaquely; flows through these nodes terminate at the EventMapper in the graph.
3. **External side-effect behavior.** `SideEffect.execute` and `OutboundTranslationSlice.translate` make external calls whose downstream effects are intentionally outside the graph.
4. **Transitive / saga-like flows.** The graph is one-hop by design. Multi-hop chains require runtime tracing, not static analysis.

---

## Cross-repo impact

UI consumers of the framework must update to the renamed types (Phase 1 already shipped in 8edd6673):

- Replace `uiDefinition` → `pluginStructure`, `makeAutoUIDefinition` → `makePluginDefinition`, `uiCommandDef` → `commandDef`, `uiQueryableDef` → `queryableDef`, `uiWritableDef` → `writableDef`.
- The platform accessor is now `pluginStructure: Pulumi.Output.t<option<Reventless.Plugin.pluginStructure>>`.
- Consumers that read `pluginStructure` fields additively (Phases 2-5) need no code changes but will benefit from the new fields once they opt in.
- The `Platform_EventGraph` GraphQL query (Phase 6) is additive and new; no migration required to continue using existing queries.
