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

## Phase 6 — Cross-plugin graph and `Platform_EventGraph` StateViewSlice

**Goal.** Aggregate every registered plugin's `pluginDefinition` into a platform-level event graph, project it into a StateViewSlice on the Admin plugin, and expose it via GraphQL. An equivalent value is available in-memory without event-sourcing machinery.

**Files to change.**
- New: [Platform_EventGraph/](../../reventless/reventless-core/src/admin/Platform_EventGraph/) — a new StateViewSlice directory mirroring the existing admin slices' layout.
  - `Platform_EventGraph.res` — `Spec` with `consumedEvent = Connected(pluginDefinition) | Reconnected(pluginDefinition) | Disconnected(pluginDefinition) | Activated(pluginDefinition) | Deactivated(pluginDefinition)` (subsetted from `PluginSpec.event`), `stateSchema` for the graph record, and a projection that folds each event into the aggregated graph.
  - Optional `Platform_EventGraph_Projection.res` if the projection is complex.
- [Platform_Admin.res](../../reventless/reventless-core/src/admin/Platform_Admin.res) — register the new slice via `stateViewSlices` when `Config.hooks` indicates it is enabled (or always-on).
- [PluginSpec.res](../../reventless/reventless-core/src/admin/PluginSpec.res) — no change required; the existing `Connected(pluginDefinition)` event already carries the data. (This depends on step 1 of Phase 1 resolving the name collision — the wire-level `pluginDefinition` must carry the same structural-description record, or carry a new field `structure: pluginStructure` that surfaces the Phase 2-5 fields.)
- [Platform.res (in-memory)](../../reventless/reventless-in-memory/src/Platform.res) — collect all plugin `pluginDefinition` values at `Make(plugins)` time and expose a platform-level `eventGraph` accessor that matches what the StateViewSlice serves on AWS.

**Concrete steps.**
1. Define the cross-plugin graph record in `Plugin.res` (or a new `EventGraph.res` in reventless-spec):
   ```rescript
   @schema type graphNode = {pluginName: string, componentName: string, kind: string}
   @schema type graphEdge = {
     from: graphNode, to: graphNode,
     mechanism: string,  // "EventMapper" | "Extension" | "EventTypeMatch" | "ConsistencyRead" | ...
     viaEvents: array<string>,
     implicit: bool,     // true for cross-plugin EventTypeMatch edges
   }
   @schema type platformEventGraph = {nodes: array<graphNode>, edges: array<graphEdge>}
   ```
2. Implement the fold: `(state, event) => state` where `Connected(pd)` / `Reconnected(pd)` add the plugin's nodes and intra-plugin edges and rebuild any cross-plugin edges touching this plugin; `Disconnected(pd)` / `Deactivated(pd)` remove the plugin's nodes.
3. Register the StateViewSlice in `Platform_Admin.construct` alongside existing DCB slices. The admin already supports DCB slices (see the `Dcb_Builder.Make` wiring at Platform_Admin.res line 117-134).
4. Expose a query field (the DCB builder auto-registers a GraphQL field from each StateViewSlice — verify by reading `Dcb_Builder.res` to confirm the auto-registration is inherited here, no manual resolver needed).
5. In-memory equivalent: since all plugins are wired at `InMemory_Platform.Make(plugins)` time, walk the collected `pluginDefinition` array once and compute the same `platformEventGraph` value, storing it on the platform record. This yields the same data via the same GraphQL query in the in-memory path without going through the event log.
6. Implement cross-plugin edge computation: pair each Extension's `ExtensionPoint.Spec.eventSchema` + `Delegate.name` against matching EP in another plugin (first-class); match EventMappers that cross plugins (first-class); finally match any remaining bare DCB event type names that share a plugin prefix across plugins on the same DcbEventLog scope (implicit — flag `implicit: true`).

**Validation.**
- In-memory test: register `online-shop-hybrid/catalog` and `online-shop-hybrid/ordering` plugins in one platform; query `platformEventGraph { edges { from { componentName } to { componentName } mechanism viaEvents } }`; assert the four expected cross-plugin edges appear (two Extensions + two EventMappers as documented in the analysis' cross-plugin table) with `implicit: false`.
- Disconnect the Catalog plugin; re-query; assert all Catalog nodes and every edge touching Catalog is gone.
- Rebuild-from-replay test: delete and re-project the `Platform_EventGraph` read model store from the `Connected` / `Disconnected` event history; the resulting graph equals the live graph.

**Commit message.**
`feat: Platform_EventGraph StateViewSlice aggregating cross-plugin event graph`

---

## Phase 7 — Consumer follow-ups (separate plans)

Not implemented here. Each of the following belongs in its own plan, scoped against the `pluginDefinition` and `platformEventGraph` surfaces delivered in Phases 1-6:

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
