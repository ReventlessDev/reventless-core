// Platform-level fixtures for OutboundTranslationSlice.
//
// The sibling callback test calls phase1/phase2 directly and passes even when
// the component is never reached by an event — it cannot observe wiring. This
// fixture builds the real thing: a DcbEventLog, a StateChangeSlice that appends
// to it, and an OutboundTranslationSlice subscribed to that log's event topic.
// A command published through `publishJsons` is the only input; the assertions
// read the TODO QueryDb and the recorded external calls.
//
// Wiring summary:
//   DcbEventLog "TestLog" — publishes events to TestLogDcbEventLogEventTopic
//   StateChangeSlice "Place" — Place command → Placed event
//   OutboundTranslationSlice "SendConfirm" — Placed event → external call

open TestFixtures
open Reventless

// ─────────────────────────────────────────────────────────────
// Place StateChangeSlice
// ─────────────────────────────────────────────────────────────

module PlaceSpec = {
  let name = "Place"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event = Placed({
    orderId: @s.matches(Reventless.DcbTag.string) string,
    customerId: string,
  })

  @schema
  type consumedEvent = Placed

  @schema
  type command = Place({
    orderId: @s.matches(Reventless.DcbTag.string) string,
    customerId: string,
  })

  @schema
  type error = AlreadyPlaced

  let commandSchema = commandSchema
}

module PlaceBehavior = {
  module Spec = PlaceSpec
  let moduleUrl: string = %raw(`import.meta.url`)

  type state = bool
  let initialState = false
  let evolve = (_state: state, _event: Spec.consumedEvent) => true
  let decide = (state: state, command: Spec.command): result<array<Spec.event>, Spec.error> =>
    if state {
      Error(AlreadyPlaced)
    } else {
      switch command {
      | Place({orderId, customerId}) => Ok([Spec.Placed({orderId, customerId})])
      }
    }
}

// ─────────────────────────────────────────────────────────────
// OutboundTranslationSlice — consumes Placed, fire-and-forget
//
// `consumedEvent` deliberately declares a strict subset of the appended event's
// fields (no customerId beyond the two it needs is added, but the stored event
// carries fields this slice ignores) — the same shape the hybrid example uses.
// ─────────────────────────────────────────────────────────────

module SendConfirmSpec = {
  let name = "SendConfirm"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent = Placed({orderId: string})

  @schema
  type outboundItem = {orderId: string}

  @schema
  type inboundCommand = unit

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = None
  let sourceNames: array<string> = []
  let externalSystem = Some("EmailService")
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let traits: array<Reventless.Trait.t> = []
}

// Two separate records so a failure says which phase stalled: `collectCalls`
// empty means the event never reached phase 1 at all, while `collectCalls`
// populated with `externalCalls` empty isolates the fault to phase 2.
let collectCalls: array<string> = []
let externalCalls: array<string> = []

module SendConfirmTranslation: OutboundTranslationSlice.Translation
  with module Spec := SendConfirmSpec = {
  let moduleUrl: string = %raw(`import.meta.url`)

  let collect = (event: SendConfirmSpec.consumedEvent, ~sourceId as _) =>
    switch event {
    | Placed({orderId}) =>
      collectCalls->Array.push(orderId)
      [(orderId, ({orderId: orderId}: SendConfirmSpec.outboundItem))]
    }

  let translate = async (_id, item: SendConfirmSpec.outboundItem, ~capabilities as _) => {
    externalCalls->Array.push(item.orderId)
    Ok(None)
  }

  let onExhausted = (_id, _item: SendConfirmSpec.outboundItem, ~lastError as _) => None
}

// ─────────────────────────────────────────────────────────────
// Bus + Pulumi mock setup
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

module DcbLogMaker = DcbEventLog_Builder.Make(Bus)
let dcbEventLog = DcbLogMaker.make(
  ~name="TestLog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "orderId"}),
)

// ─────────────────────────────────────────────────────────────
// publishJsons routes by TAG through the global handler registry.
// (Same shape AutomationSliceSelfDeadlockFixtures uses — substitutes for a real
// CommandTopic without the runtime wiring overhead.)
// ─────────────────────────────────────────────────────────────

let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmdJsons => {
  let _ =
    await cmdJsons
    ->Array.map(async cmdJson => {
      let typeName = switch cmdJson.commandJson {
      | JSON.Object(dict) =>
        dict
        ->Dict.get("TAG")
        ->Option.flatMap(j =>
          switch j {
          | JSON.String(s) => Some(s)
          | _ => None
          }
        )
        ->Option.getOr("")
      | _ => ""
      }
      let fullBody = JSON.Encode.object(
        Dict.fromArray([
          ("id", JSON.Encode.string(cmdJson.id)),
          ("meta", cmdJson.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema)),
          ("command", cmdJson.commandJson),
        ]),
      )
      let handlers = ReventlessCore.CommandTopic.getHandlers(typeName)
      let _ =
        await handlers
        ->Array.map(async entry => {
          let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {
            reference: cmdJson.id,
            command: fullBody,
          }
          let _ = await entry.handler(Stream.fromIterable([item]))->Effect.runPromise
        })
        ->Promise.all
    })
    ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make

// ─────────────────────────────────────────────────────────────
// Wire the StateChangeSlice + the OutboundTranslationSlice
// ─────────────────────────────────────────────────────────────

module PlaceMaker = StateChangeSlice_Builder.Make(PlaceSpec, PlaceBehavior)
let _placeSlice = PlaceMaker.make(~dcbEventLog, ~publishJsons=publishJsonsOutput)

let dcbTopicOutputs: ReventlessInfra.EventTopic.outputs = (
  dcbEventLog->ReventlessInfra.Component.outputs
).eventTopic

module OutboundMaker = OutboundTranslationSlice_Builder.Make(Bus)
module SendConfirm = OutboundMaker.Make(SendConfirmSpec, SendConfirmTranslation)
let sendConfirmSlice = SendConfirm.make(~dcbEventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let placeCmdJson = (orderId: string): Reventless.Message.commandJson => {
  id: orderId,
  meta: testMeta,
  commandJson: PlaceSpec.Place({orderId, customerId: "cust-" ++ orderId})
    ->Reventless.Util_Sury.toJson(PlaceSpec.commandSchema),
}

let readEventTypes = async (orderId: string) => {
  let logOps = await dcbEventLog->DcbLogMaker.operations->TestRunner.resolve
  let result = await logOps.read(
    ~query=[{tags: [{Reventless.DcbTag.key: "orderId", value: orderId}]}],
  )
  result.events->Array.map(e => e.eventType)
}

// Drains pending microtasks so detached work (phase 2, QueryDb sync) settles.
let flush = async () => {
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
}
