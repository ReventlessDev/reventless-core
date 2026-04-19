# Plan: Event Graph Linking

Implements the design in [event-graph-linking.md](../analysis/event-graph-linking.md).

An event-sourced system is already a directed graph — write-side components produce events, read-side components consume them — and that graph is latent in every `@schema type event` and `@schema type consumedEvent` declaration. The analysis shows the information needed to materialise the full intra-plugin and cross-plugin graph is almost entirely present today; what is missing is a small amount of extraction wiring, a rename that frees the plugin self-description from its original "Auto UI" framing, and one narrow Spec addition (`targetName`) for slices whose destination is currently opaque. This plan stages the work so each phase ships and is validated independently.

---

## Phase 1 — Rename `uiDefinition` → `pluginDefinition` (breaking, pure refactor)

**Goal.** Rename the existing Auto-UI-shaped API to reflect that it describes the plugin, not a UI, so subsequent phases can extend it without perpetuating the misleading name.

**Files to change.**
- [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res) — rename the four record types and the sub-type fields at lines 100-111.
- [Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res) — rename `makeAutoUIDefinition` → `makePluginDefinition`, update the `~uiDefinition` parameter on `construct` / `make` to `~pluginDefinition`, and rename the `uiDefinition` field on the builder outputs.
- [Codegen.res](../../reventless/reventless-spec/src/generator/Codegen.res) — `renderUiDefinitionCall` emits `let pluginDefinition = Platform.Plugin.makePluginDefinition(...)`; rename the function too (e.g. `renderPluginDefinitionCall`).
- [PluginSpec.res](../../reventless/reventless-core/src/admin/PluginSpec.res) — already uses `pluginDefinition`; verify it still compiles against the renamed types.
- [Platform_Admin.res](../../reventless/reventless-core/src/admin/Platform_Admin.res) — `fakePluginDefinition` binding (line 70) already names the value correctly; types flow through from `Plugin.res`.
- [Plugin.res (infra)](../../reventless/reventless-infra/src/components/Plugin.res) — update any mirrored type signatures.
- All three examples — `Plugin.res` files under `examples/online-shop-aggregates/*/src/`, `examples/online-shop-dcb/*/src/`, `examples/online-shop-hybrid/*/src/` — regenerate via `npm run generate`.
- CHANGELOG entries: `reventless-spec`, `reventless-core`, and affected examples get a `feat!:` note.

**Concrete steps.**
1. In [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res), rename the records: `uiCommandDef` → `commandDef`, `uiQueryableDef` → `queryableDef`, `uiWritableDef` → `writableDef`, `uiDefinition` → `pluginDefinition` (standalone record — **not** the existing `@schema`-annotated `pluginDefinition` record at line 121 which is the wire-level plugin self-description). Resolve the name collision by renaming the wire-level record to `pluginWireDefinition` (or similar) and updating every reference — `PluginSpec.res`, `Platform_Admin.res`, `Admin_Callback.res`, `PluginRuntime_Builder`, `Plugin_Builder.res`. **Decide and document which of the two records owns the name `pluginDefinition`** before renaming. Recommended: the wire-level record keeps `pluginDefinition` (many downstream references); the Auto-UI-shaped record becomes `pluginDefinition` too only if it subsumes the wire record. If they remain distinct, name the Auto-UI-shaped record `pluginStructure` or similar. The analysis document uses `pluginDefinition` for the Auto-UI-shaped one — reconcile in this step.
2. Rename `makeAutoUIDefinition` → `makePluginDefinition` in `Plugin_Builder.res` (lines 687-758). Update the `~uiDefinition` optional parameter name on `construct` and `make` to whatever name the new record takes (step 1 decides this).
3. Update `Codegen.res` at lines 321-363: rename the helper, change `"let uiDefinition = Platform.Plugin.makeAutoUIDefinition("` → the new binding and function names.
4. Regenerate all example `Plugin.res` files.
5. Grep for any residual `uiDefinition` / `makeAutoUIDefinition` / `uiCommandDef` / `uiQueryableDef` / `uiWritableDef` tokens in source and CHANGELOGs; update or leave historical CHANGELOG entries untouched.

**Validation.**
- `npm run build` at the workspace root succeeds.
- All three examples regenerate without diffs other than the rename and compile.
- The existing in-memory e2e suite (the tests exercised by [online-shop-hybrid-autoui-devapp.md](online-shop-hybrid-autoui-devapp.md)) passes unchanged.

**Commit message.**
`feat!: rename uiDefinition to pluginDefinition (makeAutoUIDefinition → makePluginDefinition)`

---

## Phase 2 — Tier 2a extractions (schema-derived fields, no Spec changes)

**Goal.** Surface every graph field that can be derived purely from schemas `makePluginDefinition` already holds: consumed/produced event type names, per-command `level`, `aggregateIdField`, `linkedViews`, and `consistencyRead`.

**Files to change.**
- [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res) — extend the renamed record types:
  - `commandLevel = Collection | Instance`
  - `commandDef` gains `level: commandLevel` and `aggregateIdField: option<string>`
  - `queryableDef` gains `linkedWriteSide: array<string>` and `consumedEventTypes: array<string>`
  - `writableDef` gains `producedEventTypes: array<string>`, `consumedEventTypes: array<string>`, `linkedViews: array<string>`, and `consistencyRead: option<string>`
- [Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res) — extend `makePluginDefinition` (currently lines 687-758) to fill the new fields. `Plugin_Builder` already calls `DcbTag.extractVariantNames` at line 113 and `DcbDecode.makeDecoder` on `consumedEventSchema` at StateViewSlice construction — both prove the needed schemas are reachable from the modules already passed in.

**Concrete steps.**
1. In `Plugin.res`, extend the record definitions as above. None of the new fields require `@schema` — they are consumed by Node-side tooling only, not sent over the wire.
2. In `Plugin_Builder.makePluginDefinition`, for every `module(Aggregate.T)` / `module(StateChangeSlice.T)`:
   - Call `DcbTag.extractVariantNames(Spec.eventSchema)` for produced events.
   - Call `DcbTag.extractVariantNames(Spec.consumedEventSchema)` on StateChangeSlice for consumed events.
3. Per-command level/idField: walk each variant of `Spec.commandSchema` (same `Union({anyOf})` pattern `toCommandDef` already uses at line 695). For each variant's property set, cross-reference with `DcbTag.extractTaggedFields(Spec.stateSchema)` (DCB) or the Aggregate's `@id`-marked field (Aggregate). If the command variant contains the entity-id field → `Instance` with `aggregateIdField: Some(name)`; otherwise `Collection`. For aggregates, the id field is whichever field the aggregate's `Spec.stateSchema` identifies as the aggregate root — typically surfaced through the same DCB tag metadata pattern for DCB components, and via the Aggregate's convention for aggregates. Read [Aggregate.res](../../reventless/reventless-spec/src/components/Aggregate.res) to confirm the exact id-field lookup (likely `Spec.id` or a metadata lookup on `stateSchema`).
4. Per-view `linkedWriteSide` / `consumedEventTypes`: for each `queryableDef` (ReadModel + StateViewSlice), extract consumed-event variant names from `Spec.consumedEventSchema`. For `linkedWriteSide`, intersect the view's consumed event names with each writable's produced event names; emit the writable's name on match.
5. Per-writable `linkedViews`: inverse of step 4 — for each writable, the list of queryables whose `consumedEventTypes` contain any of the writable's `producedEventTypes`.
6. `consistencyRead` for a StateChangeSlice: the StateViewSlice whose `Spec.consumedEventSchema` variants overlap maximally with the SCS's `Spec.consumedEventSchema` variants (the analysis notes the SCS reads its decision model from a view — the view it shares the most consumed events with is the canonical tie-break). This is a heuristic; emit `Some(viewName)` only when the overlap is unambiguous (single best match), else `None`.

**Validation.**
- Add a unit test in [reventless-core/test/](../../reventless/reventless-core/test/) that builds the DCB hybrid catalog plugin modules in-process and asserts, for `PlaceOrder` SCS: `producedEventTypes` contains `"OrderPlaced"`, `linkedViews` contains `"OrdersView"`, `consistencyRead` is `Some("AvailableProducts")`, and for `ShipOrder` command `level` is `Instance` with `aggregateIdField: Some("orderId")`.
- Manual: the in-memory dev app's `pluginDefinition` JSON dump now contains populated `linkedViews` / `consistencyRead` / `level` / `aggregateIdField` / `producedEventTypes` / `consumedEventTypes` fields.

**Commit message.**
`feat: extract produced/consumed events, level, aggregateIdField, linkedViews, consistencyRead in makePluginDefinition`

---

## Phase 3 — Tier 2b wiring (EventMapper, SideEffect, AutomationSlice, Outbound/Inbound Translation, Extension)

**Goal.** Pass the remaining component module arrays through to `makePluginDefinition` so their schema-derived edges appear in the graph. EventMapper edges are the highest-value addition and land first.

**Files to change.**
- [Plugin.res](../../reventless/reventless-spec/src/components/Plugin.res) — add new record types for these components in `pluginDefinition`:
  - `eventMapperDef = {name: string, sourceAggregate: string, sourceEventTypes: array<string>, targetName: string}`
  - `sideEffectDef = {name: string, sourceAggregate: string, triggeringEventTypes: array<string>}`
  - `automationSliceDef = {name: string, consumedEventTypes: array<string>, producedCommandTypes: array<string>, targetName: option<string>}` (targetName populated in Phase 4)
  - `outboundTranslationSliceDef`, `inboundTranslationSliceDef`, `extensionDef` analogously
  - add `eventMappers`, `sideEffects`, `automationSlices`, `outboundTranslationSlices`, `inboundTranslationSlices`, `extensions` arrays on `pluginDefinition`
- [Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res) — extend `makePluginDefinition` signature with `~eventMappers`, `~sideEffects`, `~automationSlices`, `~outboundTranslationSlices`, `~inboundTranslationSlices`, `~extensions` optional parameters; populate the new record fields.
- [Codegen.res](../../reventless/reventless-spec/src/generator/Codegen.res) — `renderPluginDefinitionCall` (renamed in Phase 1) must emit all new module-list arguments. Use the `resolved` payload from [Pairing.res](../../reventless/reventless-spec/src/generator/Pairing.res) to enumerate each component kind the same way `render` already does for `make`.
- Every example `Plugin.res` regenerates with the new arguments.

**Concrete steps.**
1. Land EventMapper first: add `~eventMappers` parameter; for each mapper module extract `Mapping.Source.name`, `extractVariantNames(Mapping.Source.eventSchema)`, and `Target.name`; append to `pluginDefinition.eventMappers`.
2. Add SideEffect: same pattern on `Source.name` and `extractVariantNames(Source.eventSchema)`.
3. Add AutomationSlice: extract `Spec.consumedEventSchema` + `Spec.commandSchema` variant names; leave `targetName: None` until Phase 4.
4. Add OutboundTranslationSlice: extract consumed events from `Spec.consumedEventSchema`; record that `inboundCommand` may be `unit` (terminal) or a variant — surface variant names when non-unit so the graph distinguishes terminal slices from loop-closing ones.
5. Add InboundTranslationSlice: extract `Spec.command` variant names.
6. Add Extension: extract `ExtensionPoint.Spec.eventSchema` variant names and `Delegate.name`.
7. Update `Codegen.renderPluginDefinitionCall` to emit every additional module list, matching the existing `resolved.eventMappers` / `resolved.sideEffects` / etc. naming in `Pairing.res`. Verify by reading `Pairing.resolved` type (probably at the top of [Pairing.res](../../reventless/reventless-spec/src/generator/Pairing.res)).
8. Regenerate all examples; verify the generator still succeeds when a plugin has zero mappers / zero side effects.

**Validation.**
- Unit test asserts the Catalog hybrid plugin's `pluginDefinition.eventMappers` contains an entry with `sourceAggregate: "Category"`, `targetName: "CategoriesReadModel"`, and the three `CategoryAdded` / `CategoryRenamed` / `CategoryArchived` produced events.
- A second assertion: `pluginDefinition.automationSlices` contains `AutoShipOrder` with consumed `["OrderPlaced", "OrderShipped"]` and produced commands `["ShipOrder"]`.
- Regenerated examples diff cleanly (only additions).

**Commit message.**
`feat: thread eventMappers, sideEffects, automationSlices, translation slices, extensions through makePluginDefinition`

---

## Phase 4 — Tier 3 Spec fields (`let targetName` on slices, validated by generator)

**Goal.** Make the outbound command target of AutomationSlice / OutboundTranslationSlice / InboundTranslationSlice statically declarable, closing the last structural gap for interactive command flows.

**Files to change.**
- [AutomationSlice.res](../../reventless/reventless-spec/src/components/AutomationSlice.res) — add `let targetName: string` to `Spec`.
- [OutboundTranslationSlice.res](../../reventless/reventless-spec/src/components/OutboundTranslationSlice.res) — add `let targetName: option<string>` to `Spec` (optional because some slices are pure fire-and-forget).
- [InboundTranslationSlice.res](../../reventless/reventless-spec/src/components/InboundTranslationSlice.res) — add `let targetName: string` to `Spec`.
- [Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res) — surface `Spec.targetName` into the Phase 3 slice records.
- [Pairing.res](../../reventless/reventless-spec/src/generator/Pairing.res) and [Codegen.res](../../reventless/reventless-spec/src/generator/Codegen.res) — validation pass that checks each slice's declared `targetName` resolves to a known aggregate / StateChangeSlice / other command receiver in the same plugin.
- Every example AutomationSlice / OutboundTranslationSlice / InboundTranslationSlice spec file adds the `targetName` declaration — for example, `AutoShipOrder` in `examples/online-shop-hybrid/ordering/src/AutoShipOrder/` needs `let targetName = "ShipOrder"`.

**Concrete steps.**
1. Add the `let targetName` fields to the three Spec module types. This is a **non-breaking-for-runtime but compile-breaking-for-spec** change: every existing spec file that defines one of these slice kinds must add the declaration, so this phase is `feat!:`.
2. In `Plugin_Builder`, populate `automationSliceDef.targetName` (and the analogous fields on the outbound/inbound records) from `Spec.targetName`.
3. In `generate-plugin`, after `Pairing.resolve`, gather the set of known command receivers (aggregate names + StateChangeSlice names + other slice names that accept commands). For each slice with a declared `targetName`, assert membership; fail with a clear error citing the slice file path and the valid candidate names.
4. Update every example to declare the correct `targetName`; re-run the generator to confirm validation passes.

**Validation.**
- `generate-plugin` on the hybrid ordering example now populates `pluginDefinition.automationSlices[AutoShipOrder].targetName = Some("ShipOrder")`.
- Deliberately introducing a typo (`targetName = "ShipOrde"`) causes `generate-plugin` to exit non-zero with an error naming `AutoShipOrder.res` and suggesting the closest match.
- Unit test: each regenerated example's `pluginDefinition` serialises a non-empty `targetName` for every slice that has one.

**Commit message.**
`feat!: add targetName to AutomationSlice/OutboundTranslationSlice/InboundTranslationSlice Spec with generator validation`

---

## Phase 5 — Namespacing (qualified event and command names)

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

UI consumers of the framework must update to the renamed types after Phase 1 lands:

- Any consumer that references `uiDefinition`, `uiCommandDef`, `uiQueryableDef`, `uiWritableDef`, or calls `makeAutoUIDefinition` directly needs to adopt `pluginDefinition`, `commandDef`, `queryableDef`, `writableDef`, `makePluginDefinition`.
- Consumers that read `pluginDefinition` fields additively (Phases 2-5) need no code changes but will benefit from the new fields once they opt in.
- The `Platform_EventGraph` GraphQL query (Phase 6) is additive and new; no migration required to continue using existing queries.

Coordinate the UI-side update with Phase 1's merge so the UI remains buildable against the renamed API.
