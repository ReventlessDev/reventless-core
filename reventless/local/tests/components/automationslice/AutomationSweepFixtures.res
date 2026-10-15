// A deadline, as an automation writes one today: `collect` records when an order
// is due, and `process` sends nothing until then. Only a sweep moves the item
// once its time has come, since no further event arrives. `clock` stands in
// for the wall clock `process` reads.

open TestFixtures
open Reventless

module OrderSource = {
  module Id = Id.String
  let name = "DeadlineOrderEventTopic"
  @schema
  type event = OrderPlaced({orderId: string, dueAt: float})
}

module CancelUnshippedSpec = {
  let name = "CancelUnshipped"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {orderId: string, dueAt: float}

  @schema
  type command = CancelOrder({orderId: @s.matches(DcbTag.string) string})

  let maxRetries = 2
  let heartbeatInterval = 60
  let targetName = "CancelOrder"
}

module FromOrders = AutomationSlice.Mapping.Make(
  OrderSource,
  CancelUnshippedSpec,
  {
    let collect = (event: OrderSource.event, ~sourceId as _, _ctx) =>
      switch event {
      | OrderPlaced({orderId, dueAt}) => [
          (orderId, ({orderId, dueAt}: CancelUnshippedSpec.todoItem)),
        ]
      }
    let resolve = (_event: OrderSource.event) => None
  },
)

let clock = ref(0.)

module CancelUnshippedAutomation: AutomationSlice.Automation
  with module Spec := CancelUnshippedSpec = {
  let process = (id, item: CancelUnshippedSpec.todoItem) =>
    clock.contents >= item.dueAt
      ? Some((id, CancelUnshippedSpec.CancelOrder({orderId: item.orderId})))
      : None
  let onExhausted = (_id, _item: CancelUnshippedSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(CancelUnshippedSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromOrders)]
}

let orderResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=OrderSource.name->Pulumi.Output.make,
  ~id=OrderSource.name->Pulumi.Output.make,
  ~urn=OrderSource.name->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

let allEventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
  (OrderSource.name, {ReventlessInfra.EventTopic.resources: [orderResource]}),
])

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
module CancelUnshipped = AutomationSliceMaker.Make(CancelUnshippedSpec, CancelUnshippedAutomation)

// Commands are captured; `failPublish` makes the next publishes throw.
let publishedCommands: ref<array<Reventless.Message.commandJson>> = ref([])
let failPublish = ref(false)
let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
  if failPublish.contents {
    JsError.throwWithMessage("command topic unavailable")
  } else {
    publishedCommands := publishedCommands.contents->Array.concat(cmds)
  }

let slice = CancelUnshipped.make(
  ~allEventTopics,
  ~publishJsons=publishJsons->Pulumi.Output.make,
  ~context={
    environment: "local",
    platformName: "local",
    pluginName: "TestPlugin",
    sliceName: CancelUnshippedSpec.name,
  },
)

let placeOrder = async (orderId, ~dueAt) => {
  let meta = makeTestMeta(~service=OrderSource.name)
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", orderId->JSON.Encode.string),
      ("meta", meta->Reventless.Util_Sury.toJson(Message.metaSchema)),
      (
        "event",
        OrderSource.OrderPlaced({orderId, dueAt})->Reventless.Util_Sury.toJson(
          OrderSource.eventSchema,
        ),
      ),
    ]),
  )
  await Bus.publishEvent(OrderSource.name, "test", meta, eventJson)
  // The event's own phase 2 runs detached; let it finish.
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
}

/** The stored to-do row of `id`, as the query store holds it. */
let storedRow = id =>
  Bus.getQueryDbScan(CancelUnshipped.queryDbName)
  ->Option.map(scan => scan())
  ->Option.getOr([])
  ->Array.find(row =>
    row->JSON.Decode.object->Option.flatMap(o => o->Dict.get("id")) == Some(id->JSON.Encode.string)
  )
  ->Option.map(row =>
    row->Reventless.Util_Sury.fromJson(ReventlessCore.AutomationSlice_Callback.todoRowSchema)
  )
