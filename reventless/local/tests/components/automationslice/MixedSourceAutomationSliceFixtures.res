// Plan 04 fixtures — AutomationSlice with two sources (Aggregate + DCB).
// Verifies mixed-source dispatch: both sources feed the same slice's TODO list,
// each going through its own per-source `collect`/`resolve`, and `process`
// produces commands for the target.

open TestFixtures
open Reventless

// ─────────────────────────────────────────────────────────────
// Source 1: simulated Aggregate — emits OrderShipped events
// ─────────────────────────────────────────────────────────────

module OrderAggregateSource = {
  module Id = Id.String
  let name = "OrderAggregateEventTopic"
  @schema
  type event =
    | OrderShipped({orderId: string, productId: string})
}

// ─────────────────────────────────────────────────────────────
// Source 2: simulated DCB EventLog — emits StockReserved events
// ─────────────────────────────────────────────────────────────

module InventoryDcbSource = {
  module Id = Id.String
  let name = "InventoryDcbEventLog"
  @schema
  type event =
    | StockReserved({orderId: string, productId: string})
    | StockReleased({orderId: string, productId: string})
}

// ─────────────────────────────────────────────────────────────
// AutomationSlice spec — joins both sources by composite key
// ─────────────────────────────────────────────────────────────

module AutoFulfillSpec = {
  let name = "AutoFulfill"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {
    orderId: string,
    productId: string,
    fromAggregate: bool, // tracks which source produced this item
  }

  @schema
  type command = MarkFulfilled({
    orderId: @s.matches(DcbTag.string) string,
    productId: @s.matches(DcbTag.string) string,
  })

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = "MarkFulfilled"
}

// Forward-declared per-source mappings live below; the merged `Automation`
// module type also exposes `mappings` + `module type Mapping`, which we
// populate after `FromOrderAggregate` / `FromInventoryDcb` are in scope.

// ─────────────────────────────────────────────────────────────
// Mapping 1: Aggregate source → todoItem (with `fromAggregate=true`)
// ─────────────────────────────────────────────────────────────

module FromOrderAggregate = AutomationSlice.Mapping.Make(
  OrderAggregateSource,
  AutoFulfillSpec,
  {
    let collect = (event: OrderAggregateSource.event, _ctx) =>
      switch event {
      | OrderShipped({orderId, productId}) => [
          (
            orderId ++ ":" ++ productId,
            ({orderId, productId, fromAggregate: true}: AutoFulfillSpec.todoItem),
          ),
        ]
      }
    let resolve = (_event: OrderAggregateSource.event) => None
  },
)

// ─────────────────────────────────────────────────────────────
// Mapping 2: DCB source → todoItem (with `fromAggregate=false`)
//   Also resolves on StockReleased — releases roll back any pending TODO.
// ─────────────────────────────────────────────────────────────

module FromInventoryDcb = AutomationSlice.Mapping.Make(
  InventoryDcbSource,
  AutoFulfillSpec,
  {
    let collect = (event: InventoryDcbSource.event, _ctx) =>
      switch event {
      | StockReserved({orderId, productId}) => [
          (
            orderId ++ ":" ++ productId,
            ({orderId, productId, fromAggregate: false}: AutoFulfillSpec.todoItem),
          ),
        ]
      | StockReleased(_) => []
      }
    let resolve = (event: InventoryDcbSource.event) =>
      switch event {
      | StockReleased({orderId, productId}) => Some(orderId ++ ":" ++ productId)
      | StockReserved(_) => None
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Mappings collection
// ─────────────────────────────────────────────────────────────

module AutoFulfillAutomation: AutomationSlice.Automation
  with module Spec := AutoFulfillSpec = {
  let process = (id, item: AutoFulfillSpec.todoItem) =>
    Some((id, AutoFulfillSpec.MarkFulfilled({orderId: item.orderId, productId: item.productId})))
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(AutoFulfillSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromOrderAggregate), module(FromInventoryDcb)]
}

// ─────────────────────────────────────────────────────────────
// allEventTopics — two entries, one per source (matches mapping sourceNames)
// ─────────────────────────────────────────────────────────────

let aggregateResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=OrderAggregateSource.name->Pulumi.Output.make,
  ~id=OrderAggregateSource.name->Pulumi.Output.make,
  ~urn=OrderAggregateSource.name->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

let dcbResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=InventoryDcbSource.name->Pulumi.Output.make,
  ~id=InventoryDcbSource.name->Pulumi.Output.make,
  ~urn=InventoryDcbSource.name->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

let allEventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
  (OrderAggregateSource.name, {ReventlessInfra.EventTopic.resources: [aggregateResource]}),
  (InventoryDcbSource.name, {ReventlessInfra.EventTopic.resources: [dcbResource]}),
])

// ─────────────────────────────────────────────────────────────
// Isolated bus + Pulumi mock mode
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build AutomationSlice
// ─────────────────────────────────────────────────────────────

module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
module AutoFulfill = AutomationSliceMaker.Make(
  AutoFulfillSpec,
  AutoFulfillAutomation,
)

// Mirrors the context that `Plugin_Builder` constructs for local deployments
// (environment from `LocalPluginSpec.environment`, platformName "local").
let testContext: Reventless.AutomationSlice.context = {
  environment: "local",
  platformName: "local",
  pluginName: "TestPlugin",
  sliceName: AutoFulfillSpec.name,
}

// publishJsons — capture commands instead of round-tripping through a CommandTopic.
let publishedCommands: ref<array<Reventless.Message.commandJson>> = ref([])
let mockPublishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
  publishedCommands := publishedCommands.contents->Array.concat(cmds)
}

let slice = AutoFulfill.make(
  ~allEventTopics,
  ~publishJsons=mockPublishJsons->Pulumi.Output.make,
  ~context=testContext,
)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let publishAggregateEvent = async (id, event: OrderAggregateSource.event) => {
  let meta = makeTestMeta(~service=OrderAggregateSource.name)
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", meta->Reventless.Util_Sury.toJson(Message.metaSchema)),
      ("event", event->Reventless.Util_Sury.toJson(OrderAggregateSource.eventSchema)),
    ]),
  )
  await Bus.publishEvent(OrderAggregateSource.name, "test", meta, eventJson)
}

let publishDcbEvent = async (id, event: InventoryDcbSource.event) => {
  let meta = makeTestMeta(~service=InventoryDcbSource.name)
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", meta->Reventless.Util_Sury.toJson(Message.metaSchema)),
      ("event", event->Reventless.Util_Sury.toJson(InventoryDcbSource.eventSchema)),
    ]),
  )
  await Bus.publishEvent(InventoryDcbSource.name, "test", meta, eventJson)
}
