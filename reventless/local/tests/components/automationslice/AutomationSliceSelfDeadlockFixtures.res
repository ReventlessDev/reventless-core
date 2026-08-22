// Regression fixtures for the AutomationSlice self-deadlock.
//
// Reproduces the shape that hung the AutoUI hybrid-example PlaceOrder popup:
// a DCB StateChangeSlice publishes an event to a topic the AutomationSlice
// subscribes to. Phase 2 publishes a follow-up command whose StateChangeSlice
// appends a second event to the same topic. If phase 2 is awaited inside the
// subscriber fiber, the bus's allDone for the second event needs that very
// fiber to dequeue it — self-deadlock. The companion test issues the first
// command via `publishJsons` and asserts the chain completes.
//
// Wiring summary:
//   DcbEventLog "TestLog" — publishes events to TestLogDcbEventLogEventTopic
//   StateChangeSlice "Place" — Place command → Placed event
//   StateChangeSlice "Ship"  — Ship command  → Shipped event (consumes Placed)
//   AutomationSlice "AutoShip" — Placed event → Ship command (resolves on Shipped)
//   publishJsons routes commands by TAG through the global handler registry,
//     mirroring the in-memory CommandTopic filtering handler.

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
  type event = Placed({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type consumedEvent = Placed

  @schema
  type command = Place({orderId: @s.matches(Reventless.DcbTag.string) string})

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
      | Place({orderId}) => Ok([Spec.Placed({orderId: orderId})])
      }
    }
}

// ─────────────────────────────────────────────────────────────
// Ship StateChangeSlice — consumes Placed (read), produces Shipped
// ─────────────────────────────────────────────────────────────

module ShipSpec = {
  let name = "Ship"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event = Shipped({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type consumedEvent =
    | Placed({orderId: string})
    | Shipped

  @schema
  type command = Ship({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type error = NotPlaced

  let commandSchema = commandSchema
}

module ShipBehavior = {
  module Spec = ShipSpec
  let moduleUrl: string = %raw(`import.meta.url`)

  type state = {placed: bool, shipped: bool}
  let initialState = {placed: false, shipped: false}
  let evolve = (state: state, event: Spec.consumedEvent) =>
    switch event {
    | Placed(_) => {...state, placed: true}
    | Shipped => {...state, shipped: true}
    }
  let decide = (state: state, command: Spec.command): result<array<Spec.event>, Spec.error> =>
    switch command {
    | Ship({orderId}) =>
      if !state.placed {
        Error(NotPlaced)
      } else if state.shipped {
        Ok([])
      } else {
        Ok([Spec.Shipped({orderId: orderId})])
      }
    }
}

// ─────────────────────────────────────────────────────────────
// AutomationSlice — listens to TestLog events, drives Ship
// ─────────────────────────────────────────────────────────────

module DcbSource = {
  module Id = Reventless.Id.String
  let name = "TestLogDcbEventLog"
  @schema
  type event =
    | Placed({orderId: string})
    | Shipped({orderId: string})
}

module AutoShipSpec = {
  let name = "AutoShip"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = Ship({orderId: @s.matches(Reventless.DcbTag.string) string})

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = "Ship"
}

module FromDcb = AutomationSlice.Mapping.Make(
  DcbSource,
  AutoShipSpec,
  {
    let collect = (event: DcbSource.event, _ctx) =>
      switch event {
      | Placed({orderId}) => [(orderId, ({orderId: orderId}: AutoShipSpec.todoItem))]
      | Shipped(_) => []
      }
    let resolve = (event: DcbSource.event) =>
      switch event {
      | Shipped({orderId}) => Some(orderId)
      | Placed(_) => None
      }
  },
)

module AutoShipAutomation: AutomationSlice.Automation with module Spec := AutoShipSpec = {
  let process = (id, _item: AutoShipSpec.todoItem) =>
    Some((id, AutoShipSpec.Ship({orderId: id})))
  let onExhausted = (_id, _item: AutoShipSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(AutoShipSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromDcb)]
}

// ─────────────────────────────────────────────────────────────
// Bus + Pulumi mock setup
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module DcbLogMaker = DcbEventLog_Builder.Make(Bus)
let dcbEventLog = DcbLogMaker.make(
  ~name="TestLog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "orderId"}),
)

// ─────────────────────────────────────────────────────────────
// publishJsons routes by TAG through the global handler registry.
// (Same shape DcbReadModelE2EFixtures uses — substitutes for a real
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
// Wire StateChangeSlices to the DcbEventLog + AutomationSlice to the topic
// ─────────────────────────────────────────────────────────────

module PlaceMaker = StateChangeSlice_Builder.Make(PlaceSpec, PlaceBehavior)
let _placeSlice = PlaceMaker.make(~dcbEventLog, ~publishJsons=publishJsonsOutput)

module ShipMaker = StateChangeSlice_Builder.Make(ShipSpec, ShipBehavior)
let _shipSlice = ShipMaker.make(~dcbEventLog, ~publishJsons=publishJsonsOutput)

let dcbTopicOutputs: ReventlessInfra.EventTopic.outputs = (dcbEventLog->ReventlessInfra.Component.outputs).eventTopic
let allEventTopics: ReventlessInfra.EventTopic.allOutputs = Dict.fromArray([
  (DcbSource.name, dcbTopicOutputs),
])

let testContext: Reventless.AutomationSlice.context = {
  environment: "test",
  platformName: "local",
  pluginName: "TestPlugin",
  sliceName: AutoShipSpec.name,
}

module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
module AutoShip = AutomationSliceMaker.Make(AutoShipSpec, AutoShipAutomation)
let autoShipSlice = AutoShip.make(
  ~allEventTopics,
  ~publishJsons=publishJsonsOutput,
  ~context=testContext,
)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let placeCmdJson = (orderId: string): Reventless.Message.commandJson => {
  id: orderId,
  meta: testMeta,
  commandJson: PlaceSpec.Place({orderId: orderId})
    ->Reventless.Util_Sury.toJson(PlaceSpec.commandSchema),
}

// Promise-based timeout used to fail fast if the chain self-deadlocks.
@val external setTimeout: (unit => unit, int) => 'a = "setTimeout"

let withTimeout = async (p: promise<'a>, ~ms: int): result<'a, string> => {
  let timeout = Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(Error("timed out")), ms)
  })
  let work = p->Promise.thenResolve(v => Ok(v))
  await Promise.race([work, timeout])
}

let readEventTypes = async (orderId: string) => {
  let logOps = await dcbEventLog->DcbLogMaker.operations->TestRunner.resolve
  let result = await logOps.read(
    ~query=[{tags: [{Reventless.DcbTag.key: "orderId", value: orderId}]}],
  )
  result.events->Array.map(e => e.eventType)
}
