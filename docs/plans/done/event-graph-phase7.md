# Plan: Event Graph — Phase 7 Consumer Follow-ups

Tracks the remaining core work deferred from [event-graph-linking.md](event-graph-linking.md) (Phases 1–6 complete). Three items were explicitly deferred at the end of that plan; one technical gap (cross-plugin edges) was discovered during Phase 6 implementation and documented there.

Pairs with the UI-side work tracked in `reventless-ui/docs/plans/event-graph-linking-ui-adaptation.md`.

---

## Status of deferred items

| Item | Deferred from | Status |
|---|---|---|
| Auto UI command linking | Phase 7 | ✅ Done in UI plan Phases 2–4 |
| Zero-configuration command panels | Phase 7 | ✅ Done in UI plan Phases 2–4 |
| MCP tool description enrichment | Phase 7 | ✅ Done |
| Cross-plugin edge computation | Phase 6 note | ✅ Done |
| AWS platform wiring (`Platform_EventGraph`) | Phase 6 note | ✅ Done |

---

## Phase 1 — MCP tool description enrichment

**Goal.** Append "affects views: X, Y" (and optionally "reads: Z") to the description of each generated MCP tool so that an LLM agent calling the tool understands its read-side impact.

**Information source.** `writableDef.linkedViews` (from `pluginDefinition.pluginStructure`) already carries the resolved list of StateViewSlice / readModel names that a write-side command affects. `writableDef.consistencyRead` names the StateViewSlice a DCB SCS reads before deciding.

**Files to change.**

- Find where MCP tool descriptions are generated (likely the MCP tool-spec builder or `Platform.res` resolver that emits tools). Locate the per-command tool entry construction and append the metadata.
- No changes to `Plugin.res` types — all required fields are already present.

**Concrete steps.**

1. Find the MCP tool builder (grep for `description` near `mutationField` or tool-spec generation). Confirm the `commandDef` and its parent `writableDef` are in scope at that point.
2. Format the suffix: `"Affects views: Products, Orders."` for non-empty `linkedViews`; skip suffix when the array is empty.
3. Optionally append `"Reads: ProductDemand for consistency."` when `consistencyRead` is `Some(viewName)`.
4. Update any MCP tool snapshot tests that assert on description strings.

**Validation.**
- MCP tool for `AddProduct` command has description ending `"Affects views: Products."`.
- MCP tool for `RecordProductDemand` has `"Affects views: ProductDemand. Reads: ProductDemand for consistency."`.
- MCP tool for a command with empty `linkedViews` has no suffix.

**Commit message.**
`feat: enrich MCP tool descriptions with linkedViews and consistencyRead from pluginStructure`

---

## Phase 2 — Cross-plugin edge computation

**Context.** Phase 6 built per-plugin entries in `Platform_EventGraph` with intra-plugin edges only. Cross-plugin edges (Extension↔ExtensionPoint, InboundTranslation, EventMapper cross-plugin flows) were deferred because a `StateViewSlice.project` function only processes one event at a time and cannot inspect other plugins' entries.

**Goal.** Materialise cross-plugin edges so the UI can render a complete graph across plugin boundaries.

**Proposed approach: query-time assembly via a dedicated GraphQL resolver.**

Rather than trying to compute cross-plugin edges inside `project`, add a resolver (`Platform_CrossPluginEdges` or an extension to the existing `Platform_EventGraph` query) that reads all per-plugin entries at query time and applies the matching logic:

1. For each `inboundTranslationSliceDef` with a `targetName`, find the plugin that owns a SCS or aggregate with that name → emit a cross-plugin edge.
2. For each `extensionDef` with `delegateNames`, find the plugin that owns those delegates → emit edges.
3. For each `outboundTranslationSliceDef` with a `targetName`, find the receiving plugin → emit an edge.
4. For each produced event type in one plugin that matches a consumed event type in another (EventTypeMatch), emit a cross-plugin edge with `mechanism: "EventTypeMatch"`.

The resolver has read access to all StateViewSlice entries and can do this in a single pass.

**Files to change.**

- New: `src/admin/Platform_CrossPluginEdges.res` — or extend `Platform_EventGraph.res` with a resolver field.
- [Platform.res (in-memory)](../../reventless/reventless-in-memory/src/Platform.res) — register the new resolver or field.
- [graphNode / graphEdge schema](../../reventless/reventless-spec/src/components/Plugin.res) — no type changes needed; `implicit: bool` on `graphEdge` already handles inferred edges.

**Concrete steps.**

1. Decide on the GraphQL shape: either a top-level `platformCrossPluginEdges: [graphEdge!]!` query or a new field on each `platformEventGraph` entry `{ crossPluginEdges: [graphEdge!]! }`. The top-level query is simpler.
2. Implement the assembly logic as a pure function over `array<{pluginName, nodes, edges}>` (the current per-plugin state shape).
3. Register the resolver; it has no internal state and computes on demand.
4. Add tests with the hybrid online-shop fixture (Ordering imports from Catalog; expect edges Catalog.Products→Ordering.AvailableProducts via EventTypeMatch, and Ordering.AutoShipOrder→Ordering.ShipOrder via command).

**Validation.**
- Querying `platformCrossPluginEdges` (or equivalent) returns at least one EventTypeMatch edge between Catalog and Ordering plugins in the dev-app.
- Intra-plugin edges are not duplicated in the cross-plugin result.

**Commit message.**
`feat: cross-plugin edge assembly for Platform_EventGraph via query-time resolver`

---

## Phase 3 — AWS platform wiring for `Platform_EventGraph`

**Context.** Phase 6 registered `Platform_EventGraph` only in the in-memory platform. The AWS platform (`reventless-aws`) must pass the same `PlatformEventGraphT` module to `Admin.construct`, analogous to how the in-memory platform does it.

**Goal.** Make `Platform_EventGraph` queryable in AWS-deployed stacks without requiring app developers to wire it manually.

**Files to change.**

- Find the AWS `Platform_Admin.construct` call path (likely in `reventless-aws/src/Platform.res` or `Admin.res`).
- Thread `module(PlatformEventGraphT)` into the `~stateViewSlices` array the same way the in-memory platform does at [Platform.res (in-memory):~stateViewSlices line](../../reventless/reventless-in-memory/src/Platform.res).
- The `StateViewSlice.T` instance needs a DynamoDB backing store and an SQS FIFO queue — confirm these are automatically allocated by `Admin.construct` for admin-registered slices or add the necessary Pulumi resource allocation.

**Concrete steps.**

1. Audit how `Admin.construct` handles the admin slice set in the AWS platform. Confirm whether `StateViewSliceMaker.Make(ReventlessCore.Platform_EventGraph)` can be called there with the same signature.
2. If Pulumi resources need allocating (DynamoDB table for the graph state), add them inside `Admin.construct` alongside existing admin resources.
3. Emit the correct IAM permissions for the Lambda that handles admin events to write to the graph table.
4. Add an e2e test (or extend the existing AWS e2e plan) asserting that `platformEventGraph` returns entries after the plugins connect.

**Validation.**
- A deployed AWS stack responds to `{ platformEventGraph { pluginName nodes { componentName kind } } }` with non-empty data.
- No new Pulumi resource naming conflicts in stacks that already use `Admin.construct`.

**Commit message.**
`feat: wire Platform_EventGraph into AWS platform Admin.construct`

---

## Out of scope (Tier 4 permanent gaps)

Carried over from the original plan; these are not addressed here:

1. **Task → aggregate routing.** Runtime dispatch; only an advisory `Task.Spec.targetNames: array<string>` is possible. Separate design pass when/if needed.
2. **EventMapping `PublishAsync` actions.** Async callbacks are opaque; graph terminates at the EventMapper node.
3. **External side-effect behavior.** `SideEffect.execute` and `OutboundTranslationSlice.translate` external calls are outside framework visibility.
4. **Transitive / saga-like flows.** One-hop by design; multi-hop requires runtime tracing.

---

## Cross-repo coordination

| Core phase | UI plan phase | Notes |
|---|---|---|
| Phase 1 (MCP enrichment) | — | Backend / tooling only; no UI change |
| Phase 2 (cross-plugin edges) | UI Phase 6 | UI graph visualisation becomes complete once cross-plugin edges land |
| Phase 3 (AWS wiring) | — | Infrastructure only; no UI change |
