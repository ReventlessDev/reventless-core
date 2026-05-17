// E2E test fixtures for StateViewSlice builder.
// Builds a StateViewSlice on top of a DcbEventLog and verifies projection into QueryDb.

open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// Event type definition for the DcbEventLog
// ─────────────────────────────────────────────────────────────

module ItemEventLog = {
  @schema
  type event =
    | ItemAdded({id: @s.matches(Reventless.DcbTag.string) string, name: string})
    | ItemRenamed({id: @s.matches(Reventless.DcbTag.string) string, name: string})
    | ItemRemoved({id: @s.matches(Reventless.DcbTag.string) string})
}

// ─────────────────────────────────────────────────────────────
// StateViewSlice spec: project ItemEventLog events to {id, name} state
// ─────────────────────────────────────────────────────────────

module ItemsViewSpec = {
  let name = "ItemsView"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent =
    | ItemAdded({id: string, name: string})
    | ItemRenamed({id: string, name: string})
    | ItemRemoved({id: string})

  @schema
  type state = {id: string, name: string}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

module ItemsViewProjection = {
  module Spec = ItemsViewSpec
  open ItemsViewSpec

  let moduleUrl: string = %raw(`import.meta.url`)

  let project = (event: consumedEvent) =>
    switch event {
    | ItemAdded({id, name}) => [Set(id, {id, name})]
    | ItemRenamed({id, name}) => [Update(id, s => {...s, name})]
    | ItemRemoved({id}) => [Delete(id)]
    }
}

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module ItemEventLogMaker = DcbEventLog_Builder.Make(Bus)
let eventLog = ItemEventLogMaker.make(~name="ItemEventLog", ~partitionTag=Reventless.DcbTag.Simple({key: "id"}))

// ─────────────────────────────────────────────────────────────
// Build StateViewSlice
// ─────────────────────────────────────────────────────────────

module SVMaker = StateViewSlice_Builder.Make(Bus)
module ItemsViewMaker = SVMaker.Make(ItemsViewSpec, ItemsViewProjection)
let sv = ItemsViewMaker.make(~dcbEventLog=eventLog)

// DcbEventLog eventTopic resource — needed for 2nd beforeAllAsync resolve to
// trigger EventCollectorChannel.connect registration.
let dcbEventTopicResource =
  (eventLog->ReventlessCore.Component.outputs).eventTopic.resources->Array.getUnsafe(0)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

// Encode a typed event into a raw event for appending to the DcbEventLog
let encodeEvent = (event: ItemEventLog.event): ReventlessInfra.DcbEventLog.rawEvent => {
  let json = event->Reventless.Util_Sury.toJson(ItemEventLog.eventSchema)
  let (eventType, data) = json->ReventlessCore.Message.splitMessage
  let tags = Reventless.DcbTag.extractTags(ItemEventLog.eventSchema, event)
  let meta = ReventlessCore.Message.generateMeta(~service="test")
  {eventType, data: JSON.Object(data), tags, meta}
}

// Append an event to the DcbEventLog (publishes to event topic automatically)
let appendEvent = async event => {
  let ops = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
  let _ = await ops.append([encodeEvent(event)])
}

// Load projected state from the in-memory QueryDb.
// QueryDb is registered with the base Spec.name = "ItemsView".
let loadState = async id => {
  switch Bus.getQueryDb("ItemsView") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(id)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->Reventless.Util_Sury.fromJson(ItemsViewSpec.stateSchema))
  }
}
