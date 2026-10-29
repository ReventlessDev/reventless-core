// The chain from a provider's event to a consumer's command carries stable ids:
// an extension point's mapping run twice on one stored event publishes the same
// `msgId`, an Extension's mapping run twice on one published event sends a
// command with the same `msgId`, and each message names its parent as its cause.
// That is what lets a handler drop a redelivered fact.

open JestGlobals

module Port = {
  let name = "Ordering.Orders"

  @schema
  type command = Noop

  @schema
  type event = ItemOrdered({productId: string, orderId: string})

  @schema
  type directive = NoDirective

  let moduleUrl: string = %raw(`import.meta.url`)
}

module Order = {
  module Id = Reventless.Id.String
  let name = "Order"

  @schema
  type command = Place({orderId: string})

  @schema
  type event = OrderPlaced({orderId: string, productId: string})

  @schema
  type error = unit

  let moduleUrl: string = %raw(`import.meta.url`)
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAuthenticated
  type lifecycleState = unit
  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
  let traits: array<Reventless.Trait.t> = []
}

module Demand = {
  module Id = Reventless.Id.String
  let name = "RecordProductDemand"

  @schema
  type command = RecordDemand({productId: string, orderId: string})

  @schema
  type event = DemandRecorded({productId: string, orderId: string})

  @schema
  type error = unit

  let moduleUrl: string = %raw(`import.meta.url`)
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAuthenticated
  type lifecycleState = unit
  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
  let traits: array<Reventless.Trait.t> = []
}

// The provider's port: Order events become ItemOrdered on the extension point.
module PortMapping = ReventlessInfra.ExtensionPointMapping.Make({
  module ExtensionPoint = Port
  module Delegate = Order
  let moduleUrl: string = %raw(`import.meta.url`)
  let mapIncomingCommand = (_id, _command: Port.command, _meta) => []
  let mapOutgoingEvent = Some(
    (id, event: Order.event, _meta, _queryEngine) =>
      switch event {
      | OrderPlaced({orderId, productId}) => [
          ReventlessInfra.ExtensionPointMapping.PublishEvent(
            id,
            Port.ItemOrdered({productId, orderId}),
          ),
        ]
      },
  )
  let publishedEvents = []
  let acceptedCommands = []
})

// The consumer's Extension: ItemOrdered becomes a RecordDemand command.
module DemandExtension = ReventlessInfra.ExtensionMapping.Make({
  module ExtensionPoint = Port
  module Delegate = Demand
  let moduleUrl: string = %raw(`import.meta.url`)
  let delegateModuleUrl = Demand.moduleUrl
  let mapIncomingEvent = (_id, event: Port.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        ReventlessInfra.ExtensionMapping.PublishAggregateCommand(
          productId,
          Demand.RecordDemand({productId, orderId}),
        ),
      ]
    }
  let mapOutgoingEvent = None
  let handledEvents = []
  let issuedCommands = []
})

let queryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}
let createSchedule: Reventless.Schedule.create = async _ => ()
let deleteSchedule: Reventless.Schedule.delete = async _ => ()

let pluginDefinition: Reventless.Plugin.pluginDefinition = {
  id: "Catalog@1",
  name: "Catalog",
  version: "1",
  extensionPoints: [],
  extensions: [{name: "Catalog", extensionPointName: Port.name}],
  eventCollector: "eventCollector",
  extensionProtocols: [],
  apiSchemaFragment: None,
  structure: None,
  kind: Domain,
}

// The stored Order event, as the slice handler wrote it: its msgId is stable
// across stream redeliveries because it was derived once and stored.
let storedMeta: Message.meta = {
  service: Order.name,
  time: "2024-01-01T00:00:00Z",
  msgId: "order-event-msg",
  correlationId: "place-order-cmd",
  causationId: "place-order-cmd",
}
let storedEventJson' = Reventless.Message.composeEventJson'(
  "order-1",
  storedMeta,
  Order.OrderPlaced({orderId: "order-1", productId: "product-1"})->Reventless.Message.encode(
    Order.eventSchema,
  ),
)

let msgIdOf = (eventJson': JSON.t) =>
  eventJson'
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("meta"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(m => m->Dict.get("msgId"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("")

let publishOnce = () =>
  switch (PortMapping.mapOutgoingEvent->Option.getOrThrow)(
    storedEventJson',
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) {
  | [ReventlessInfra.ExtensionPointMapping.AbstractPublishEvent(_, meta, eventJson')] => (
      meta,
      eventJson',
    )
  | _ => JsError.throwWithMessage("expected one published event")
  }

let commandOnce = (published: Message.meta) =>
  switch DemandExtension.mapIncomingEvent(
    {
      id: "product-1",
      meta: published,
      event: ItemOrdered({productId: "product-1", orderId: "order-1"}),
    },
    pluginDefinition,
    queryEngine,
  ) {
  | [ReventlessInfra.ExtensionMapping.AbstractPublishAggregateCommand(_, cmdJson)] => cmdJson
  | _ => JsError.throwWithMessage("expected one delegate command")
  }

describe("a derived message's id is stable along the chain", () => {
  testSync("the extension point publishes the same msgId for the same stored event", () => {
    let (first, firstJson') = publishOnce()
    let (again, againJson') = publishOnce()
    expect(first.msgId)->toBe(again.msgId)
    expect(first.service)->toBe(Port.name)
    expect(first.causationId)->toEqual(Some(storedMeta.msgId))
    expect(first.correlationId)->toBe(storedMeta.correlationId)
    expect(msgIdOf(firstJson'))->toBe(msgIdOf(againJson'))
    expect(msgIdOf(firstJson'))->toBe(first.msgId)
  })

  testSync("the Extension sends the same command msgId for the same published event", () => {
    let (published, _) = publishOnce()
    let first = commandOnce(published)
    let again = commandOnce(published)
    expect(first.meta.msgId)->toBe(again.meta.msgId)
    expect(first.meta.service)->toBe(Demand.name)
    expect(first.meta.causationId)->toEqual(Some(published.msgId))
    expect(first.meta.correlationId)->toBe(storedMeta.correlationId)
    // Three distinct ids along the chain: the stored event, the published event,
    // the command.
    expect(
      [storedMeta.msgId, published.msgId, first.meta.msgId]
      ->Belt.Set.String.fromArray
      ->Belt.Set.String.size,
    )->toBe(3)
  })
})
