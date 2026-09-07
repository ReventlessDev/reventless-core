// E2E fixtures for the @displayName overlay on a StateViewSlice.
// A slice's state carries the same synthetic `displayName` a read model's does;
// this builds one by hand (the ppx writes the field and the metadata) so the
// projection path can be asserted to compose it.

open Reventless.Projection

module OrderEventLog = {
  @schema
  type event =
    | OrderPlaced({id: @s.matches(Reventless.DcbTag.string) string, placedAt: string})
    | OrderShipped({id: @s.matches(Reventless.DcbTag.string) string, shippedAt: string})
}

module OrdersViewSpec = {
  let name = "DnOrdersView"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent =
    | OrderPlaced({id: string, placedAt: string})
    | OrderShipped({id: string, shippedAt: string})

  @schema
  type state = {
    id: string,
    placedAt: string,
    shippedAt: string,
    displayName: option<string>,
  }

  // What the ppx emits for `@displayName placedAt`.
  let stateSchema =
    stateSchema->S.Metadata.set(
      ~id=Reventless.DisplayName.displayNameId,
      {Reventless.DisplayName.fields: ["placedAt"], separator: " "},
    )

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

module OrdersViewProjection = {
  module Spec = OrdersViewSpec
  open OrdersViewSpec

  let moduleUrl: string = %raw(`import.meta.url`)

  let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
    switch event {
    | OrderPlaced({id, placedAt}) =>
      [Set(id, {id, placedAt, shippedAt: "", displayName: None})]
    | OrderShipped({id, shippedAt}) => [Update(id, s => {...s, shippedAt})]
    }
}

module Bus = LocalBus.Make()

let _ = TestRunner.setup()

module OrderEventLogMaker = DcbEventLog_Builder.Make(Bus)
let eventLog = OrderEventLogMaker.make(
  ~name="DnOrderEventLog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "id"}),
)

module SVMaker = StateViewSlice_Builder.Make(Bus)
module OrdersViewMaker = SVMaker.Make(OrdersViewSpec, OrdersViewProjection)
let sv = OrdersViewMaker.make(~dcbEventLog=eventLog)

let dcbEventTopicResource =
  (eventLog->ReventlessCore.Component.outputs).eventTopic.resources->Array.getUnsafe(0)

let encodeEvent = (event: OrderEventLog.event): ReventlessInfra.DcbEventLog.rawEvent => {
  let json = event->Reventless.Util_Sury.toJson(OrderEventLog.eventSchema)
  let (eventType, data) = json->ReventlessCore.Message.splitMessage
  let tags = Reventless.DcbTag.extractTags(OrderEventLog.eventSchema, event)
  let meta = ReventlessCore.Message.generateMeta(~service="test")
  {eventType, data: JSON.Object(data), tags, meta}
}

let appendEvent = async event => {
  let ops = await eventLog->OrderEventLogMaker.operations->TestRunner.resolve
  let _ = await ops.append([encodeEvent(event)])
}

let loadState = async id => {
  switch Bus.getQueryDb("DnOrdersView") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(id)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->Reventless.Util_Sury.fromJson(OrdersViewSpec.stateSchema))
  }
}
