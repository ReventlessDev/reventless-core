# Plan: Plugin EventCollector runtime rewire — generic (user extensions + plugin RMs)

## Status

Follow-up to [plugin-eventcollector-runtime-rewire.md](./plugin-eventcollector-runtime-rewire.md) (the "minimal" plan). That plan wires the built-in `PluginConnectExtension` only, so admin-issued `UnknownPluginDetected` events round-trip into `Connect` and the Plugin RM populates. This plan extends the same entry-point and HANDLER_CONFIG mechanics to:

- **User-declared extensions** (`@@reventless.extension`-annotated `*_Extension.res` files — already used in `examples/online-shop-*/`).
- **Plugin-local read models** that those extensions feed into (`publishToReadModels` + `readModelNamesForSourceName`).
- **Multiple aggregates per plugin** publishing commands from extension handlers (`publishToAggregates` populated with real queue URLs, not just the admin's Plugin aggregate).

Prerequisite: the minimal plan must be complete and verified. The HANDLER_CONFIG schema, register pattern, and entry-point structure introduced there form the foundation here. This plan only adds fields and code paths; no breaking changes.

Explicitly **out of scope** (deferred to a third plan): the cross-plugin runtime subscribe/unsubscribe path (`DoConnectPlugin`/`DoDisconnectPlugin` → `Spec.runtimeOps.topicSubscription.subscribeChannelToTopic`). That's a separate, larger change requiring peer-plugin EP outputs to be serialised through HANDLER_CONFIG.

## Problem

Even after the minimal plan lands:

1. `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res` declares an extension that subscribes to Ordering's `Orders_ExtensionPoint` and emits `RecordProductDemand` state-change-slice commands. With the minimal plan's HANDLER_CONFIG, this extension never reaches the catalog plugin's bundled Lambda — the runtime only knows about `PluginConnectExtension`. Catalog's `CatalogPluginEventColl-689371d` would receive `ItemOrdered` events (once cross-plugin subscriptions exist) but have no handler.
2. Plugin-local read models that user extensions feed into (e.g. `ProductDemands` populated from `RecordProductDemand` slice events) need `readModelNamesForSourceName` + `publishToReadModels` populated in the Extension_Operations Ops. The minimal plan stubs both as `{}` — fine for ConnectPlugin, broken for any user extension that writes to a plugin RM.
3. User extensions whose `mapIncomingEvent` returns `PublishAggregateCommand(<aggName>, <cmd>)` need `publishToAggregates` keyed by the plugin's *own* aggregates, not just the admin's Plugin aggregate. The minimal plan only ever puts `Plugin` in that map.

## Fix

Extend the HANDLER_CONFIG shape and the register/serialise pipeline to carry user-extension and plugin-local-RM metadata. Reuse the entry-point's existing `config.extensions.map(…)` and Extension_Operations.Make instantiation loop — just feed it richer config.

The plan splits into:
- **Step 1** — HANDLER_CONFIG schema extension (what to add, who needs each field)
- **Step 2** — PPX / blueprint-side propagation (each `@@reventless.extension` file's moduleUrl flows to the runtime)
- **Step 3** — Deploy-side wiring (`Plugin_Helpers` populates the richer context)
- **Step 4** — Entry-point Ops construction (real `publishToAggregates`, `publishToReadModels`, `readModelNamesForSourceName`)
- **Step 5** — Live verification on alpha with the existing online-shop-hybrid example

---

## Step 1 — HANDLER_CONFIG schema extension

The minimal plan's HANDLER_CONFIG already has an `extensions: [{specModule, mappingsModule, extensionPointName}]` array. Extend each entry:

```json
"extensions": [
  {
    "name": "Orders_Extension",
    "specModule": "@reventlessdev/online-shop-hybrid-catalog/src/Extension/Orders_Extension.res.mjs",
    "mappingsModule": "@reventlessdev/online-shop-hybrid-catalog/src/Extension/Orders_Extension.res.mjs",
    "extensionPointName": "Ordering.Orders",
    "aggregateNames": ["RecordProductDemand"],
    "readModelNames": ["ProductDemands"]
  },
  {
    "name": "Connect",
    "specModule": "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs",
    "mappingsModule": "@reventlessdev/reventless-core/src/admin/PluginConnectExtension_Builder.res.mjs",
    "extensionPointName": "Core.Plugin",
    "aggregateNames": [],
    "readModelNames": []
  }
]
```

Top-level additions:

```json
"publishToAggregates": {
  "Plugin": "PTA_Plugin_QUEUE_URL",
  "RecordProductDemand": "PTA_RecordProductDemand_QUEUE_URL"
},
"readModelTables": {
  "ProductDemands": "ProductDemands-<hash>"
}
```

The `aggregateNames` / `readModelNames` per extension are derived from each Extension's `outputs.aggregateNames` and from `readModelNamesForSourceName` (which is currently built deploy-side by inverting the readmodel ↔ source-name index). Carrying them per-extension lets the entry-point construct each Extension_Operations.Ops with the *subset* the extension actually touches — keeps the bundled handler from holding refs to unrelated infra.

Top-level `publishToAggregates` carries the union; per-extension `aggregateNames` is a filter into it.

### Checklist

```
Step 1
  [ ] 1.1  Update the HANDLER_CONFIG schema doc block in AdminEventCollectorEntryPoint.mjs
  [ ] 1.2  Update parseHandlerConfig asserts (Step 1 of the minimal plan) to recognise the new fields with sensible defaults (empty arrays for legacy admin config)
  [ ]      Verify: admin lambda still cold-starts with its admin-only HANDLER_CONFIG (no extensions, no plugin aggregates)
```

---

## Step 2 — Propagate Extension moduleUrls from blueprints to the deploy-side context

The minimal plan defers this decision to "Step 4.1 (a) or (b)". Pick option (b) — **register pattern via the existing PPX**. Rationale:

- `@@reventless.extension` already injects boilerplate; adding a `let moduleUrl: string = %raw('import.meta.url')` injection is one line in the PPX (matches `@@reventless.spec` and friends).
- Every Extension blueprint module already conforms to `ReventlessInfra.Extension.Blueprint` which has `let moduleUrl: string` in its module type (line 54 of `Extension.res`). The user-facing files don't define one today — they rely on the PPX.
- The Plugin generator (`generate-plugin`) walks each plugin's `src/Extension/` and emits the wiring; that wiring already references each blueprint by module path — easy place to grab the path string.

The deploy-side context's `extensions[]` then carries `{specModule, mappingsModule, extensionPointName, aggregateNames, readModelNames}` populated from each blueprint module's exports plus deploy-time outputs (`aggregateNames` lives on `Extension.outputs`).

The merged-per-EP case (multiple `_Extension.res` files for one EP get combined in `Plugin_Helpers.connect` around line 158-174) needs special handling: the runtime needs to be able to call ONE `Extension_Operations.Make` per merged group, not per blueprint. Either:
- (i) Pass merged groups in HANDLER_CONFIG with `mappingsModule[]` arrays, or
- (ii) Have the entry point do the merge itself by grouping `extensions[]` by `extensionPointName` and concatenating mappings arrays after dynamic import.

Option (ii) is simpler — the entry point already has every loaded mappings module in hand by the time it instantiates Ops, so grouping is a one-liner.

### Checklist

```
Step 2
  [ ] 2.1  Update reventless-ppx @@reventless.extension transformer to auto-inject moduleUrl if absent (mirrors @@reventless.spec)
  [ ] 2.2  Rebuild ppx-macos + ppx-linux binaries (Docker for Linux per MEMORY.md feedback_ppx_linux_rebuild)
  [ ] 2.3  Confirm existing user-facing extension files compile cleanly with the new injection (no double moduleUrl)
  [ ]      Verify: any *_Extension.res.mjs file exports a non-empty moduleUrl string at runtime
```

---

## Step 3 — Deploy-side wiring populates the richer context

File: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` (around the existing `mergeExtensionsByExtensionPointName` block at line 145-194).

Inside the `Pulumi.Output.apply` that resolves `extensionsOutputs`, walk each blueprint and emit one entry per Extension component (post-merge). For each:

```rescript
{
  name: extensionOutputs.name,
  specModule: First.Spec.moduleUrl->Util_Bundle.getModuleSpecifier,  // ExtensionPoint spec
  mappingsModule: First.moduleUrl->Util_Bundle.getModuleSpecifier,   // The merged blueprint's URL (use first member's)
  extensionPointName: First.Spec.name,
  aggregateNames: extensionOutputs.aggregateNames,
  readModelNames: deriveReadModelNamesForExtension(extensionOutputs, readModelNamesForSourceName),
}
```

For top-level `publishToAggregates`:
- The admin's `Plugin` aggregate is already covered today (queue URL flows through the `PTA_Plugin_QUEUE_URL` env var pattern set up for `CorePluginExtPointCmdTopic`).
- For plugin-local aggregates (`RecordProductDemand`, etc.), reuse the same env-var-name convention. The plugin's `allCommandTopics` (already in scope in `Plugin_Builder`) gives the mapping; thread it into `forPluginEventCollector` via the new register call from the minimal plan's Step 3.

For top-level `readModelTables`: similar — the plugin's own RMs are in scope in `Plugin_Builder`. Pass the `name → table-name` dict via the register call.

### Checklist

```
Step 3
  [ ] 3.1  Extend `eventCollectorContext` (from minimal plan Step 3) with the new fields
  [ ] 3.2  Update `Plugin_Helpers.MakeEventCollectorHelper.connect` to populate them from `extensionsOutputs`, `allCommandTopics`, plugin-local RM outputs
  [ ] 3.3  Extend the HANDLER_CONFIG JSON template in `forPluginEventCollector` to serialise the new fields
  [ ]      Verify: `pulumi preview` shows a CatalogPluginEventColl HANDLER_CONFIG carrying Orders_Extension with the right extensionPointName + aggregateNames
```

---

## Step 4 — Entry-point Ops construction (real publishToAggregates / publishToReadModels)

File: `reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs` (the entry point rewritten in the minimal plan's Step 2).

Inside the `extHandlers.map(async (ext) => …)` loop, replace the minimal plan's stub Ops with:

```js
// Build a per-extension publishToAggregates dict filtered to ext.aggregateNames
const extPublishToAggregates = {};
for (const aggName of ext.aggregateNames) {
  const envVar = config.publishToAggregates[aggName];
  if (!envVar) continue;
  const queueUrl = process.env[envVar];
  if (!queueUrl) continue;
  extPublishToAggregates[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
}

// Build readModelNamesForSourceName: which read models on THIS plugin
// subscribe to the source serviceName carried by incoming events. Today's
// deploy code computes this dict-by-inversion; pass it in HANDLER_CONFIG.
const extReadModelNamesForSourceName = config.readModelNamesForSourceName?.[ext.extensionPointName] || [];

// Build publishToReadModels: name → enqueueEvent function bound to the RM's table.
const extPublishToReadModels = {};
for (const rmName of ext.readModelNames) {
  const tableName = config.readModelTables[rmName];
  if (!tableName) continue;
  extPublishToReadModels[rmName] = makeRmEnqueueEvent(makeTableRef(tableName));
}

const ops = extensionOperationsMake(specMod)(mappingsModule)({
  publishToAggregates: extPublishToAggregates,
  publishToPluginExtensionPoint: sqsPublishJsons(makeQueueRef(config.pluginExtensionPointCmdTopicUrl), "SQS_FIFO"),
  readModelNamesForSourceName: { [ext.extensionPointName]: extReadModelNamesForSourceName },
  publishToReadModels: extPublishToReadModels,
  queryEngine,
});
```

The `makeRmEnqueueEvent` helper needs to mirror what `EventCollectorChannel`-based read models do today when receiving events. Likely candidate: an SQS-based publish to the read-model's own EventColl queue, or a direct DynamoDB write — depends on the chosen RM channel implementation. Check `EventCollectorChannel_DynamoDbStream_Runtime` and `EventCollectorChannel_SQS_Runtime` for the shape; pick whichever the plugin RM uses.

### Checklist

```
Step 4
  [ ] 4.1  Implement extPublishToAggregates per-extension subset construction
  [ ] 4.2  Implement extPublishToReadModels using the right channel adapter (likely SQS — confirm by inspecting one of the plugin RM lambdas' triggers)
  [ ] 4.3  Wire readModelNamesForSourceName from HANDLER_CONFIG (admin's deploy-side dict)
  [ ]      Verify: a user-extension whose mapIncomingEvent emits PublishAggregateCommand("RecordProductDemand", cmd) successfully delivers to the RecordProductDemand command queue
```

---

## Step 5 — Live verification with online-shop-hybrid

The hybrid example already has user-declared extensions (`Orders_Extension` in catalog, `Products_Extension` in ordering). It's the natural end-to-end test.

Verification sequence:

1. Deploy online-shop-hybrid to the alpha stack (or rebuild + manually patch layer as we've been doing).
2. Place an order via the AppSync API (`mutation Place(…)`).
3. Order aggregate emits `Placed` → admin's EventColl maps to `ItemOrdered` events published to Ordering's `Orders_ExtensionPoint` EventTopic.
4. Catalog's `CatalogPluginEventColl` is subscribed to that EventTopic (assumes minimal plan's cross-plugin subscribe step is done OR admin pre-wires the subscription). Receives `ItemOrdered`.
5. `Orders_Extension.mapIncomingEvent` returns `[PublishStateChangeSliceCommand(RecordDemand(…))]` → entry point's `applyIncomingCommandAction` calls `extPublishToAggregates["RecordProductDemand"](…)`.
6. RecordProductDemand slice processes the command → emits domain event → `ProductDemands` RM enqueues via `extPublishToReadModels["ProductDemands"]` → row appears in `ProductDemands-<hash>` table.

Each step has CloudWatch logs to assert against; the final `aws dynamodb scan --table-name ProductDemands-<hash>` is the success criterion.

### Checklist

```
Step 5
  [ ] 5.1  Trigger Place order via AppSync (or admin's mutation handler)
  [ ] 5.2  Order aggregate's EventLog has the Placed event (DynamoDB scan)
  [ ] 5.3  CatalogPluginEventColl logs "incoming event: ItemOrdered" + "EP→RecordProductDemand: RecordDemand"
  [ ] 5.4  RecordProductDemand slice's lambda receives the command (log group exists, processes it)
  [ ] 5.5  ProductDemands RM table has a row for the ordered productId
  [ ]      Verify: full cross-plugin extension chain is functional on alpha
```

---

## Honest concerns / unresolved

1. **`readModelNamesForSourceName` is a deploy-time inversion.** Today it's built from each read model's `subscribeTo` (or equivalent) field, inverted to `sourceName → [rmName]`. The entry point needs the inverted dict; computing it deploy-side is straightforward but a code path that doesn't exist for the bundled-Lambda model yet. Worth a small refactor that exposes the existing computation as a helper.

2. **The `extPublishToReadModels` enqueue mechanism.** Today, RM event delivery happens via SQS/DDB-stream subscriptions established deploy-side; the Extension's runtime `enqueueEvent` is provided as a closure that publishes to the relevant SQS queue or invokes the RM's processing lambda. The bundled handler needs to reconstruct that closure from a queue URL or table name. Concrete check: which channel does `EventCollector_Builder` pick for an RM? If SQS, we already have `sqsPublishJsons`; if DynamoDB stream, this gets harder (you can't synthesise stream events runtime-side — would need a different routing strategy, e.g. publish to an intermediate SQS).

3. **Multi-extension-per-EP merging.** Option (ii) in Step 2 (entry-point-side grouping) is simpler but means each Extension's `aggregateNames` / `readModelNames` need to be merged when building Ops — otherwise the Ops dict is the union but `extensionPointName` keys collide. Solvable but worth thinking through with a test case (two `*_Extension.res` files in `catalog/src/Extension/` both targeting `Ordering.Orders`).

4. **Subscription bootstrap.** Even with Step 5's full chain wired, the catalog plugin only receives `ItemOrdered` events if its EventColl SQS is subscribed to Ordering's `Orders_ExtensionPoint` EventTopic. Today that subscription happens via `Spec.runtimeOps.topicSubscription.subscribeChannelToTopic` invoked from the `DoConnectPlugin` callHandler — which is the cross-plugin path explicitly deferred in the minimal plan. For Step 5 to work without the cross-plugin path, the admin must pre-create subscriptions at deploy time (already happens for some EventTopics? confirm by looking at the SNS subscription list for an existing EP topic). If deploy-time pre-subscription already covers this, great; if not, this becomes a soft prereq for verification.

## Phasing recommendation

Don't combine this plan with the minimal one in a single PR. Ship the minimal plan first (smaller blast radius, easier to verify, gets Plugin RM populated which is the user-visible deliverable). Land this plan as a follow-up once the minimal one is stable.

The cross-plugin subscribe path (currently out of scope of both plans) becomes Phase 3 — a third plan documenting how peer-plugin EP outputs flow into HANDLER_CONFIG and how the runtime maintains SNS subscriptions reactively.

## References

- [Plugin_Helpers.connect (deploy-side wiring)](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L304) — current source of truth for the merged-per-EP Extension list, `publishToAggregates`, `publishToReadModels`
- [Extension_Operations.Make](../../reventless/reventless-core/src/components/Extension/Extension_Operations.res#L24) — the runtime constructor the entry point will call per merged extension group
- [Plugin_Callback.Make](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L16) — service-name-keyed dispatch (already wired by the minimal plan)
- `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res` — the example that will be the verification fixture
- The minimal plan: [plugin-eventcollector-runtime-rewire.md](./plugin-eventcollector-runtime-rewire.md)
