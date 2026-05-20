# Plan: Plugin EventCollector runtime rewire — DCB EventLog cross-plugin routing (Phase 4)

## Status

Follow-up to Phases 1-3. Prerequisites:
- [Phase 1 — minimal](./plugin-eventcollector-runtime-rewire.md)
- [Phase 2 — generic](./plugin-eventcollector-runtime-rewire-generic.md)
- [Phase 3 — cross-plugin subscriptions](./plugin-eventcollector-runtime-rewire-cross-plugin.md)

Phase 3 wires admin-mediated SNS subscriptions for **ExtensionPoint** EventTopics — when plugin A's `Orders_Extension` declares `extensionPointName: "Ordering.Orders"`, the admin creates an SNS subscription from Ordering's `Orders_ExtensionPoint` EventTopic → Catalog's EventCollector SQS. This plan covers the parallel case for **DCB EventLogs**: when plugin A's extension mappings declare a `Source` named `"OrderingDcbEventLog"`, the admin should create a subscription from Ordering's DCB EventTopic → Catalog's EventCollector SQS.

## Problem

A plugin's DCB EventLog is its own first-class event source — separate from ExtensionPoint EventTopics. Extensions can declare a `Source` module by `name = "<plugin>DcbEventLog"` to consume those events (see `examples/online-shop-hybrid/catalog/src/CatalogActivity/ReadModel/CatalogActivity_Projections.res` — a projection that ingests events from BOTH the Category Aggregate AND the catalog plugin's DCB EventLog).

Today:

1. `Plugin_Callback` has special-case logic ([Plugin_Callback.res:35-50](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L35-L50)) for `ownDcbEventLogServiceName = "${plugin.name}DcbEventLog"` — silences the "unmatched service" warning for events this plugin published from its own DCB log but that no extension consumes. This implies the framework already expects DCB events to flow through the same EventCollector pipeline that handles ExtensionPoint events.
2. The deploy-time `pluginOutputs.dcbEventLog: option<DcbEventLog.outputs>` is populated and serialised into intermediate state ([Plugin_Helpers.res:30, 939, 997, 1147](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L30)). But the `pluginDefinition` schema published in `Connected` events ([Plugin.res:241-254](../../reventless/reventless-spec/src/components/Plugin.res#L241-L254)) does NOT include the DCB EventLog's EventTopic ARN — it only carries `extensionPoints[]` (each with its own EventTopic). So the admin (which uses `pluginDefinition` from the Connected event payload to drive Phase 3's `manageSubscriptions`) has no way to discover that pluginX has a DCB EventLog and where its topic lives.
3. Each plugin's bundled `Plugin_Builder` extends its own EventCollector subscription list with the plugin's own DCB EventTopic (intra-plugin routing) but cross-plugin DCB consumption has no wiring at all. A catalog extension declaring `Source { name: "OrderingDcbEventLog" }` is dead at runtime.

The cross-plugin DCB story is a structural gap, not a runtime stub. Phase 3's `manageSubscriptions` solves the equivalent gap for ExtensionPoints; this plan extends the same mechanism to DCB topics.

## Fix

Two coordinated changes:

1. **Schema**: add `dcbEventLog: option<dcbEventLogDefinition>` to `Plugin.pluginDefinition`, where `dcbEventLogDefinition` carries `{name: string, eventTopicArn: string}`. Populated when the plugin builds the DCB EventLog component, propagated through `Connected`/`Reconnected`/`Disconnected` events, and projected into the Plugin RM.
2. **Subscription**: extend Phase 3's `manageSubscriptions` to also walk each plugin's extension mappings, find references to `<peer>DcbEventLog` source names, and create/destroy SNS subscriptions to peer DCB EventTopics in parallel with ExtensionPoint subscriptions.

The plan splits into the schema change, the deploy-side wiring, the admin's `manageSubscriptions` extension, and verification with an existing DCB-consuming projection.

---

## Step 1 — Extend `pluginDefinition` with `dcbEventLog`

File: `reventless/reventless-spec/src/components/Plugin.res`

Add:

```rescript
@schema
type dcbEventLogDefinition = {
  /** Service name carried in event meta — convention: `${plugin.name}DcbEventLog`. */
  name: string,
  /** SNS topic ARN for the DCB EventLog's EventTopic. */
  eventTopicArn: string,
}

@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  extensionProtocols: array<extensionProtocol>,
  apiSchemaFragment: @s.matches(apiSchemaFragmentOptionSchema) option<apiSchemaFragment>,
  apiTarget: @s.matches(stringOptionSchema) option<string>,
  dcbEventLog: @s.matches(dcbEventLogOptionSchema) option<dcbEventLogDefinition>,  // NEW
}
```

Backwards-compat: the field is optional. Plugins without a DCB EventLog (e.g. pure aggregate plugins like the existing examples that have a DCB log AND aggregates side-by-side — only the DCB part matters here) leave it `None`. Existing Connected events in event logs decode cleanly because sury's option-as-nullable serialisation accepts missing field as `None`.

### Checklist

```
Step 1
  [x] 1.1  Add dcbEventLogDefinition type + schema in Plugin.res
  [x] 1.2  Add dcbEventLog field to pluginDefinition with sury optional encoding
  [x] 1.3  Confirm existing Connected events in PluginAggrEventLog still decode (sury option treats missing field as None)
  [ ]      Verify: pnpm test passes; round-trip a Connected event with dcbEventLog=None and =Some(…)
```

---

## Step 2 — Deploy-side: populate `dcbEventLog` when the plugin has one

File: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

The pluginDefinition is built inside `Plugin_Helpers` (and copied into Connect commands by the heartbeat path or by the deploy-time bootstrap). Wherever pluginDefinition is constructed, check whether `pluginOutputs.dcbEventLog` is `Some`, and if so extract the topic ARN.

Reusable pattern (same as the EP eventTopicArn extraction we already do):

```rescript
let dcbEventLogDef =
  pluginOutputs.dcbEventLog->Pulumi.Output.flatMap(opt =>
    switch opt {
    | None => Pulumi.Output.make(None)
    | Some(dcbOutputs) =>
      dcbOutputs.eventTopic->Pulumi.Output.flatMap(et =>
        switch et.resources->Array.get(0) {
        | Some(r) =>
          r.urn->Pulumi.Output.apply(arn => Some({
            Reventless.Plugin.name: `${pluginName}DcbEventLog`,
            eventTopicArn: arn,
          }))
        | None => Pulumi.Output.make(None)
        }
      )
    }
  )
```

Thread `dcbEventLogDef` into the pluginDefinition construction site(s). The Connect command's `pluginDefinition` payload then carries it.

### Checklist

```
Step 2
  [x] 2.1  Extract dcbEventLog topic ARN where pluginDefinition is built in Plugin_Helpers
  [x] 2.2  Set pluginDefinition.dcbEventLog = Some(…) when the plugin has a DcbEventLog component, None otherwise
  [ ] 2.3  Verify the Connected event payload in PluginAggrEventLog carries dcbEventLog with the right ARN for a plugin that has DCB
  [ ]      Verify: aws dynamodb scan on PluginAggrEventLog shows a Connected entry with dcbEventLog populated
```

---

## Step 3 — Project `dcbEventLog` into the Plugin RM

File: `reventless/reventless-core/src/admin/PluginProjection.res`

The Plugin RM is what admin's `manageSubscriptions` scans to learn about peers. The projection currently maps Connected → state with extensionPoints, extensions, eventCollector, etc. Add `dcbEventLog: option<dcbEventLogDefinition>` to the state schema and the projection's mapping.

File: `reventless/reventless-core/src/admin/PluginReadModelSpec.res`

Extend the state schema to include `dcbEventLog: option<dcbEventLogDefinition>`.

### Checklist

```
Step 3
  [x] 3.1  Add dcbEventLog field to PluginReadModelSpec state
  [x] 3.2  Map dcbEventLog from Connected payload in PluginProjection.PluginMapping
  [x] 3.3  Same for Reconnected (preserves value); on Deactivated/Disconnected/Activated, preserve (no overwrite needed since dcbEventLog is immutable per plugin version)
  [ ]      Verify: Plugin-<hash> DynamoDB table shows dcbEventLog populated for plugins that have DCB
```

---

## Step 4 — Extend `manageSubscriptions` to cover DCB topics

File: `reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs` (the admin entry point rewritten in Phase 1, with `manageSubscriptions` added in Phase 3)

Today's Phase 3 `manageSubscriptions` walks `pluginDef.extensions[].extensionPointName` to find peer EPs. Add a parallel scan for DCB source names. Convention: an extension that consumes plugin X's DCB events declares a Source with `name = "${X.name}DcbEventLog"`.

But — extensions' Source-name interest isn't carried in the current `pluginDefinition.extensions[]` (each `extensionDefinition` only has `name` + `extensionPointName`). Options:

- (a) **Extend `extensionDefinition`** with `dcbSources: array<string>` listing DCB EventLog names this extension consumes. Populated at deploy time by scanning the extension's mappings for Source modules with non-EP name conventions.
- (b) **Infer at runtime in admin** from peer plugins' `dcbEventLog.name`: when processing Connect for pluginX, for each connected peer pluginY whose dcbEventLog.name appears as a Source-name reference in any of pluginX's extension's mappings, subscribe pluginX's EventCollector to pluginY's DCB topic. But "scan mappings" requires importing pluginX's extension code into the admin — admin doesn't currently dynamic-import per-plugin code.

(a) is cleaner; (b) leaks plugin code into the admin. Go with (a).

The augmented `manageSubscriptions` flow (additions in **bold**):

```js
async function manageSubscriptions(pluginDef, action) {
  const allPlugins = await scanPluginRm(config.pluginReadModelTableName);

  if (action === "connect") {
    // ExtensionPoint subscriptions (Phase 3)
    for (const ext of pluginDef.extensions) {
      for (const peer of allPlugins) {
        const peerEp = peer.extensionPoints.find(ep => ep.name === ext.extensionPointName);
        if (peerEp && peer.status === "Connected") {
          await snsSubscribe(peerEp.eventTopicArn, pluginDef.eventCollector);
        }
      }
    }
    // EP-side: subscribe peer plugins' extensions to this plugin's EPs (Phase 3)
    for (const ep of pluginDef.extensionPoints) {
      for (const peer of allPlugins) {
        if (peer.id === pluginDef.id) continue;
        const matchingExt = peer.extensions.find(e => e.extensionPointName === ep.name);
        if (matchingExt && peer.status === "Connected") {
          await snsSubscribe(ep.eventTopicArn, peer.eventCollector);
        }
      }
    }

    // === Phase 4: DCB topic subscriptions ===
    // **For each DCB source name this plugin's extensions reference, find the peer
    // plugin owning that DCB log and subscribe.**
    for (const ext of pluginDef.extensions) {
      for (const dcbSourceName of (ext.dcbSources || [])) {
        const peer = allPlugins.find(p =>
          p.dcbEventLog && p.dcbEventLog.name === dcbSourceName && p.status === "Connected"
        );
        if (peer) {
          await snsSubscribe(peer.dcbEventLog.eventTopicArn, pluginDef.eventCollector);
        }
      }
    }
    // **If THIS plugin has a DCB EventLog, subscribe peer plugins whose extensions reference it.**
    if (pluginDef.dcbEventLog) {
      const myDcbName = pluginDef.dcbEventLog.name;
      for (const peer of allPlugins) {
        if (peer.id === pluginDef.id) continue;
        const consuming = peer.extensions.some(e => (e.dcbSources || []).includes(myDcbName));
        if (consuming && peer.status === "Connected") {
          await snsSubscribe(pluginDef.dcbEventLog.eventTopicArn, peer.eventCollector);
        }
      }
    }
  } else if (action === "disconnect") {
    // Symmetric removals for both EP and DCB topics (same idempotent list+remove pattern).
    // …
  }
}
```

### Checklist

```
Step 4
  [x] 4.1  Extend extensionDefinition with dcbSources: array<string> (default [])
  [~] 4.2  Deploy-side: walk each extension blueprint's mappings, collect non-EP Source names (DCB names by convention), populate dcbSources
       — DEFERRED: current Extension blueprint model has a single EP Spec per
         Mapping with no per-Source declarations. Plumbing in place
         (`extractExtensionDefinitions` returns `dcbSources: []`); populating
         it requires extending the Extension model to support multiple Sources.
  [x] 4.3  Extend manageSubscriptions's connect branch with DCB cases (both directions: this plugin consumes peer DCB; peers consume this plugin's DCB)
  [x] 4.4  Extend disconnect branch with symmetric unsubscribes
  [x] 4.5  IAM: confirm admin's sns:Subscribe perms already cover DCB topic ARNs (naming convention `*DcbEventLog*EventTopic-*`); widen if needed
       — Confirmed: PluginRuntime_Builder.res:443-460 grants admin EC role
         `sns:Subscribe`/`Unsubscribe`/`ListSubscriptionsByTopic` on
         `AllResources`, which already covers DCB topics — no widening needed.
  [ ]      Verify: deploy a plugin that consumes another's DCB events; aws sns list-subscriptions-by-topic on the producer's DCB EventTopic shows the consumer's EventCollector as a subscriber
```

---

## Step 5 — Live verification with online-shop-hybrid

`examples/online-shop-hybrid/catalog/src/CatalogActivity/ReadModel/CatalogActivity_Projections.res` declares a projection feeding from BOTH the Category Aggregate AND the catalog plugin's own DCB EventLog. The intra-plugin DCB path already works (Plugin_Builder pre-subscribes the EventColl to its own DCB EventTopic at deploy time). For cross-plugin DCB verification, need to either:

- Use an existing example where one plugin's extension consumes another's DCB events (check examples directory), OR
- Add a small fixture: a new extension in `catalog` that declares `Source { name: "OrderingDcbEventLog" }` and processes some DCB events from ordering.

For the verification scenario:

1. Deploy two plugins with the new schema (Phase 1-3 + this plan's Steps 1-4).
2. Plugin A's Connect → admin's manageSubscriptions creates SNS subscription from B's DCB EventTopic → A's EventCollector.
3. Trigger a DCB write on plugin B (e.g. a state-change-slice command).
4. SNS delivers the DCB event to A's EventCollector SQS.
5. A's `Extension_Operations.incomingJsonEventsHandler` dispatches via the Source-keyed mapping path.
6. A's downstream command publish lands on the target aggregate / RM update.

### Checklist

```
Step 5
  [~] 5.1  Identify or add a fixture: extension that consumes another plugin's DCB events
       — DEFERRED: blocked on Step 4.2 (extensions can't declare DCB Sources
         in the current Blueprint model). No fixture can populate
         extensionDefinition.dcbSources today.
  [~] 5.2  Deploy both plugins; aws sns list-subscriptions-by-topic confirms the cross-plugin DCB subscription
       — Requires 5.1; deferred together.
  [~] 5.3  Trigger a DCB write on the producer plugin
  [~] 5.4  Consumer plugin's EventCollector lambda logs "incoming event: <DCB event> from <ProducerDcbEventLog>"
  [~] 5.5  Consumer's downstream side-effect (command publish, RM write) completes
  [~]      Verify: full cross-plugin DCB event flow + symmetric teardown on Disconnect
```

**Phase 4 wrap-up.** All structural pieces landed: pluginDefinition carries
`dcbEventLog`, extensionDefinition carries `dcbSources`, Plugin RM projects
both, and `manageSubscriptions` walks both directions to subscribe peer
EventCollectors. Live verification is deferred behind the Extension Blueprint
work needed to populate `dcbSources` (Step 4.2). The current schema is
deploy-safe — old Connected events decode cleanly because the new fields are
nullable.

---

## Honest concerns / unresolved

1. **dcbSources discovery at deploy time.** Step 4.2 says "walk each extension blueprint's mappings, collect non-EP Source names." Today the framework distinguishes Sources by convention (name ends in "DcbEventLog") rather than by type. If a user names their Source `"BulkImportLog"` (no DcbEventLog suffix), this scan misses it. A more robust signal would be: each Source declares its kind in metadata. Out of scope for this plan; document the naming convention as load-bearing.

2. **Re-subscribe on plugin version bump.** When pluginX redeploys with a new version (different `id` like `Catalog@1.0.0-alpha.45`), it Connects as a fresh plugin. Phase 3's manageSubscriptions creates fresh subscriptions. The old subscriptions (pointing at `Catalog@1.0.0-alpha.44`'s eventCollector) get cleaned up on the old version's Disconnect. If the old version doesn't cleanly Disconnect (eg lambda just stops heartbeating), the old subscriptions linger. Same edge case as ExtensionPoint subs; not DCB-specific.

3. **Schema migration of in-flight Connected events.** Phase 4 adds a new field to `pluginDefinition`. Existing Connected events in PluginAggrEventLog decode as `dcbEventLog = None`. The Plugin RM (rebuilt by replay) ends up with all pre-existing plugins as `dcbEventLog = None` → those plugins' DCB events stay unrouted until their next Connect (heartbeat-triggered, ~5min interval). Acceptable.

4. **Filter policies on DCB topics.** DCB EventLogs can fan-event-types into one topic; consumers may only want specific variant subsets. SNS subscription filter policies could narrow delivery. Same as Phase 3's note — out of scope.

## What changes downstream

After Phase 4, the architectural picture is:
- **Phase 1** — Connect roundtrip → Plugin RM populated (foundation)
- **Phase 2** — User extensions can dispatch to per-plugin aggregates & local RMs
- **Phase 3** — Admin-mediated SNS subscriptions for ExtensionPoint EventTopics
- **Phase 4** — Admin-mediated SNS subscriptions for DCB EventTopics (this plan)
- **Future** — Translation slices runtime rewire (parallel pattern; out of scope), test coverage, observability, doc updates

This completes the cross-plugin event routing story for the two source types Reventless supports today (ExtensionPoint EventTopic + DcbEventLog EventTopic). New source types added later would extend the same admin-mediated mechanism with parallel schema fields and parallel branches in `manageSubscriptions`.

## References

- [Plugin_Callback ownDcbEventLogServiceName handling](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L35-L50) — current intra-plugin DCB awareness
- [Plugin_Helpers.dcbEventLog wiring (deploy-time)](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L939) — where the DCB topic ARN already flows at deploy time (just not into pluginDefinition)
- [Plugin.pluginDefinition schema](../../reventless/reventless-spec/src/components/Plugin.res#L241-L254) — where the new `dcbEventLog` field lands
- [Phase 3's manageSubscriptions](./plugin-eventcollector-runtime-rewire-cross-plugin.md) — the mechanism this plan extends
- `examples/online-shop-hybrid/catalog/src/CatalogActivity/ReadModel/CatalogActivity_Projections.res` — existing intra-plugin DCB consumer; the cross-plugin variant becomes the verification fixture
