# Mixed-source AutomationSlice (Plan 04)

An `AutomationSlice` can consume events from multiple sources — Aggregate `EventTopic`s alongside its own (or another) `DcbEventLog` `EventTopic` — react via the same TODO list pattern, and emit commands targeting a downstream slice. After Plan 04, an Aggregate event can directly trigger a DCB command without an intermediate ReadModel + polling/trigger orchestration.

## When to use

Choose mixed-source automation when:

- A reactive process must observe events from **both** sides of the framework (Aggregates and DCB) for the same logical entity.
- You need the standard automation guarantees — exactly-once command emission, retries, heartbeat sweeps, TODO-list correlation — but the events you observe come from heterogeneous sources.
- The alternative would be a ReadModel + an external poller/trigger; mixed-source automation collapses both into one runtime component.

The motivating commercial use case is a **platform-inspector** automation: the framework's `Plugin` Aggregate runs a runtime state machine (`NotConnected → Detected → Connected → Disconnected`), and a downstream DCB slice tracks the inspector's `(environment, platformName, pluginName)`-partitioned state. A mixed-source automation reacts to the Aggregate events and emits DCB commands to keep the inspector's state in sync — replacing the deploy-time hooks that previously wired this orchestration.

## Anatomy

A mixed-source automation slice is split across three files:

```
slices/AutoFulfill/
  AutoFulfill.res             // Spec — types and config
  AutoFulfill_Automation.res  // process() only
  AutoFulfill_Mappings.res    // per-source Mapping.Make + mappings collection
```

- **Spec** (`AutoFulfill.res`) — `todoItem`, `command`, `maxRetries`, `heartbeatInterval`, `targetName`. **No `consumedEvent`** — the framework derives the consumed-event set from each mapping's `sourceEventSchema`.
- **Automation** (`AutoFulfill_Automation.res`) — only `process: (string, todoItem) => option<(string, command)>`. `process` is source-agnostic: it operates on `todoItem` regardless of which mapping created it.
- **Mappings** (`AutoFulfill_Mappings.res`) — one `Mapping.Make` instance per source plus a `mappings` array. Each mapping carries its own `collect` and `resolve` functions, scoped to that source's `event` type.

## Per-source mapping

Each source contributes one `Reventless.AutomationSlice.Mapping.Make` instance:

```rescript
// AutoFulfill_Mappings.res
open Reventless.AutomationSlice

// Source 1 — events from an Aggregate.
module FromOrderShipped = Mapping.Make(
  OrderSpec,                   // Aggregate spec module (provides .name and .event)
  AutoFulfillSpec,             // this slice's spec
  {
    let collect = (event, _ctx) =>
      switch event {
      | OrderSpec.OrderShipped({orderId, productId}) => [
          (orderId ++ ":" ++ productId, ({orderId, productId}: AutoFulfillSpec.todoItem)),
        ]
      | _ => []
      }
    let resolve = _ => None
  },
)

// Source 2 — events from this plugin's own DcbEventLog.
module InventoryDcbSource = {
  module Id = Reventless.Id.String
  let name = "InventoryDcbEventLog"   // MUST match Plugin_Builder's topic key
  @schema
  type event =
    | StockReserved({orderId: string, productId: string})
    | StockReleased({orderId: string, productId: string})
}

module FromStockReserved = Mapping.Make(
  InventoryDcbSource,
  AutoFulfillSpec,
  {
    let collect = (event, _ctx) =>
      switch event {
      | StockReserved({orderId, productId}) => [
          (orderId ++ ":" ++ productId, ({orderId, productId}: AutoFulfillSpec.todoItem)),
        ]
      | StockReleased(_) => []
      }
    let resolve = event =>
      switch event {
      | StockReleased({orderId, productId}) => Some(orderId ++ ":" ++ productId)
      | StockReserved(_) => None
      }
  },
)

module M = Mappings.Make(AutoFulfillSpec)
module type Mapping = M.Mapping
let moduleUrl: string = %raw(`import.meta.url`)
let mappings: array<module(Mapping)> = [module(FromOrderShipped), module(FromStockReserved)]
```

### Source-name conventions

The `Source.name` of each mapping must match the topic key under which `Plugin_Builder` registers the source's `EventTopic` in `allEventTopics`:

| Source kind | Convention |
|---|---|
| Aggregate | `Source.name == AggregateSpec.name` (the Aggregate's own name) |
| DCB EventLog | `Source.name == "<pluginName>DcbEventLog"` |

The slice fails plugin assembly with a clear error if any mapping's `sourceName` doesn't resolve to a registered topic — see _Failure modes_ below.

### Ambient context

`collect` and `resolve` receive an ambient `Reventless.AutomationSlice.context`:

```rescript
type context = {
  environment: string,
  platformName: string,
  pluginName: string,
  sliceName: string,
}
```

`Plugin_Builder` constructs this per slice from its existing `~environment` and plugin `name` parameters and threads it through. Use it to complete partial event payloads (e.g., when a DCB tag field is supplied by deployment metadata rather than the source event).

The `context` record is intentionally narrow. Extending it requires an explicit framework PR — runtime registry lookups and open dicts are deliberately out of scope.

### Validation

There's no per-mapping validation hook. Push validation to the layer that owns the data:

- **`collect` returns `[]`** for events that shouldn't enter the TODO list. This is the cheapest gate — invalid items never get persisted.
- **`@s.matches(DcbTag.string)` and `@compositePartitionTag` on the command schema** enforce DCB-tag invariants at encode time. Sury-encode failures mark the item `Failed` (counts toward `maxRetries`) — the same retry path as publish failures. Use this for partition-key validation.
- **Deployment-time checks** for `context` invariants (e.g., "platformName is non-empty") belong in `Plugin_Builder.Spec` validation, not per-item — a misconfigured deployment fails every item, so fail it once at startup.

## Plugin assembly

The Plugin generator emits the new 3-arg form automatically. After authoring `AutoFulfill.res`, `AutoFulfill_Automation.res`, and `AutoFulfill_Mappings.res`, run `pnpm run generate` (or rely on the `prebuild` hook). The generated `Plugin.res` contains:

```rescript
module AutoFulfillSlice = Platform.AutomationSlice.Make(
  AutoFulfill,
  AutoFulfill_Automation,
  AutoFulfill_Mappings,
)
```

…and registers `AutoFulfillSlice` under `~automationSlices`.

## Runtime behaviour

```
Aggregate / DCB events
        │
        ▼
   meta.service ── matches ──► dispatch to Mapping with that sourceName
        │                                │
        │                                ├─► collect(sourceEvent, context) ──► TODO list (Pending)
        │                                └─► resolve(sourceEvent)         ──► TODO list (Completed)
        ▼
   phase 2 (per item):
      Automation.process(id, item) ─ Some(targetId, command) ──► encode + publish
                                     None                    ──► stays Pending, retried by heartbeat
                                     encode/publish failure  ──► mark Failed, retry up to maxRetries
```

Multiple mappings may share a `sourceName` (e.g., two mappings reading the same Aggregate's events for different reasons). All matching mappings run.

The first writer wins for `collect`: if two mappings produce the same TODO id, only the first arrival inserts; subsequent ones are skipped.

## Failure modes

| Failure | When | What happens |
|---|---|---|
| Source-name typo | Plugin assembly | `JsError` with the bad name and a list of valid source names. Catches Aggregate-name typos and DCB-source typos (e.g. `"FooDcb"` instead of `"FooDcbEventLog"`). |
| Sury encode failure (e.g., `@s.matches(DcbTag.string)` violation) | Per-item, at command-encode time | Item marked `Failed`, `retryCount` incremented. Eligible for retry on next heartbeat sweep until `maxRetries`. |
| `publishJsons` throws | Phase 2, after encode | All `Processing` items reverted to `Failed`, `retryCount` incremented. |
| Decode failure on a mapping | Per-event | Silently skipped for that mapping. Other mappings with the same `sourceName` still try. |
| Cross-plugin DCB consumption | At runtime | Out of scope for v1 — `allEventTopics` is per-plugin. A cross-plugin source-name will fail the plugin-assembly check above. |

## Backfill / replay

Mixed-source slices start from current — same convention as Aggregates. There is no automatic historical replay. If you need to backfill from existing events for a specific use case, ship it as an explicit one-shot tool rather than baking it into normal slice operation.

## Backward compatibility

A single-source slice is a special case where the `Mappings` array has exactly one mapping. The existing `AutoShipOrder` example slice (in both `online-shop-dcb` and `online-shop-hybrid`) is migrated to this shape: its `_Automation` file now only carries `process`, and a sibling `_Mappings` file declares the one mapping that consumes its own DcbEventLog. The pattern composes cleanly with multi-source slices.

## Reference

- Spec module types: [`reventless-spec/src/components/AutomationSlice.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/reventless-spec/src/components/AutomationSlice.res)
- Builder: [`reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res)
- Callback (per-source dispatch + retry): [`reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res)
- Integration test (canonical demo): [`reventless-in-memory/tests/components/automationslice/MixedSourceAutomationSlice*.res`](https://github.com/ReventlessDev/reventless-core/tree/main/reventless/reventless-in-memory/tests/components/automationslice/)
- Single-source example slice (post-Plan-04 shape): [`examples/online-shop-hybrid/ordering/src/Order/AutomationSlice/`](https://github.com/ReventlessDev/reventless-core/tree/main/examples/online-shop-hybrid/ordering/src/Order/AutomationSlice/)
- Plan: [`docs/plans/done/mixed-source-automationslice.md`](https://github.com/ReventlessDev/reventless-core/blob/main/docs/plans/done/mixed-source-automationslice.md) (after merge)
