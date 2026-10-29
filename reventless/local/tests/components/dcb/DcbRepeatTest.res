// Another plugin's fact arrives through an Extension and a slice, and delivery is
// at-least-once. The slice here has no check of its own — every RecordDemand
// appends — so what keeps a redelivered ItemOrdered from counting twice is the
// framework: the Extension's command carries a stable id, and the handler drops a
// command the partition already holds events for. On both local backends, and
// for two concurrent copies.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

module Message = ReventlessCore.Message

// ─── The provider's extension point and the consumer's slice ────────────────

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

module DemandSlice = {
  let name = "RecordDemandNoCheck"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  // The produced event joins a product and an order, so the partition is
  // declared, as the shop's RecordProductDemand does.
  @schema
  type event =
    DemandRecorded({productId: @s.matches(Reventless.DcbTag.partition) string, orderId: string})

  @schema
  type consumedEvent =
    DemandRecorded({productId: @s.matches(Reventless.DcbTag.string) string, orderId: string})

  @schema
  type command =
    RecordDemand({productId: @s.matches(Reventless.DcbTag.string) string, orderId: string})

  @schema
  type error = Never

  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAuthenticated
  type lifecycleState = unit
  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
  let traits: array<Reventless.Trait.t> = []
}

module DemandDecision = {
  type state = {orders: array<string>}
  let initialState = {orders: []}
  let moduleUrl = DemandSlice.moduleUrl

  let evolve = (state, event: DemandSlice.consumedEvent) =>
    switch event {
    | DemandRecorded({orderId}) => {orders: state.orders->Array.concat([orderId])}
    }

  // Deliberately no "already counted" rule.
  let decide = (_state, command: DemandSlice.command): result<
    array<DemandSlice.event>,
    DemandSlice.error,
  > =>
    switch command {
    | RecordDemand({productId, orderId}) => Ok([DemandRecorded({productId, orderId})])
    }
}

module DemandHandler = ReventlessCore.StateChangeSlice_Callback.Make(DemandSlice, DemandDecision)

let partitionTag = Reventless.DcbTag.Simple({key: "productId"})

// The consumer's Extension, as the catalog's Orders_Extension is written.
module DemandExtension = ReventlessInfra.ExtensionMapping.Make({
  module ExtensionPoint = Port
  module Delegate = DemandSlice
  let moduleUrl: string = %raw(`import.meta.url`)
  let delegateModuleUrl = DemandSlice.moduleUrl
  let mapIncomingEvent = (_id, event: Port.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        ReventlessInfra.ExtensionMapping.PublishStateChangeSliceCommand(
          DemandSlice.RecordDemand({productId, orderId}),
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

// One published ItemOrdered, as the extension point stored and published it;
// every delivery of it carries this same envelope.
let published: Message.event'<string, Port.event> = {
  id: "order-1",
  meta: {
    service: Port.name,
    time: "2024-01-01T00:00:00Z",
    msgId: "item-ordered-msg",
    correlationId: "place-order-cmd",
    causationId: "order-placed-event",
  },
  event: ItemOrdered({productId: "product-1", orderId: "order-1"}),
}

// What the Extension sends for one delivery of `published`.
let commandOf = (event': Message.event'<string, Port.event>) =>
  switch DemandExtension.mapIncomingEvent(event', pluginDefinition, queryEngine) {
  | [ReventlessInfra.ExtensionMapping.AbstractPublishAggregateCommand(_, cmdJson)] => cmdJson
  | _ => JsError.throwWithMessage("expected one slice command")
  }

// ─── Backends ───────────────────────────────────────────────────────────────

let eventLogOn = async (~name) => {
  module Bus = LocalBus.Make()
  module Storage = LocalDcbEventLogStorage.Make(Bus)
  let s = Storage.make(~name, ~indexes=[], ~partitionTag, ~opts)
  let storage = await s.operations->TestRunner.resolve
  module Log = ReventlessCore.DcbEventLog_Operations.Make({
    let name = name
    let serviceName = name
    let storage = storage
    let publishJson = async (_, _, _) => ()
  })
  let eventLog: ReventlessCore.DcbEventLog.operations = {
    read: Log.read,
    append: Log.append,
    readStream: Log.readStream,
    appendStream: Log.appendStream,
  }
  eventLog
}

let runUnderMemory = async fn => {
  BackendState.setMemory()
  await fn()
}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

let deliver = (eventLog, cmd: Message.commandJson) =>
  DemandHandler.handleCommands(
    ~partitionTag,
    eventLog,
    Stream.fromIterable([
      {
        ReventlessInfra.CommandTopic.command: cmd
        ->ReventlessCore.CommandTopic_Helpers.encodeCommandJson
        ->Message.decodeCommand'(Reventless.Id.String.schema, DemandSlice.commandSchema),
        reference: cmd.meta.msgId,
      },
    ]),
  )->Effect.runPromise

let recordedDemands = async (eventLog: ReventlessCore.DcbEventLog.operations) =>
  (await eventLog.read(~query=[{eventTypes: ["DemandRecorded"]}])).events

let counter = ref(0)
let fresh = prefix => {
  counter := counter.contents + 1
  `${prefix}-${counter.contents->Int.toString}`
}

let _ = beforeEach(() => DemandHandler.resetCache())

let backends = [("in-memory", runUnderMemory), ("SQLite", runUnderSqlite)]

backends->Array.forEach(((label, runUnder)) =>
  describe(`a redelivered fact is recorded once (${label} backend)`, () => {
    testPromise(
      "the same published event delivered twice appends one event",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("RepeatOnce"))
            let first = await deliver(log, commandOf(published))
            let again = await deliver(log, commandOf(published))
            expect(first->Array.length)->toBe(1)
            expect(again)->toEqual(first) // accepted both times
            let events = await recordedDemands(log)
            expect(events->Array.length)->toBe(1)
            // The command is the stored event's cause, and the published event the command's.
            let cmd = commandOf(published)
            expect((events->Array.getUnsafe(0)).meta.causationId)->toEqual(Some(cmd.meta.msgId))
            expect(cmd.meta.causationId)->toEqual(Some(published.meta.msgId))
          },
        ),
    )

    testPromise(
      "a different order for the same product still counts",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("RepeatOther"))
            let _ = await deliver(log, commandOf(published))
            let second: Message.event'<string, Port.event> = {
              id: "order-2",
              meta: {...published.meta, msgId: "item-ordered-msg-2"},
              event: Port.ItemOrdered({productId: "product-1", orderId: "order-2"}),
            }
            let _ = await deliver(log, commandOf(second))
            let _ = await deliver(log, commandOf(published))
            let _ = await deliver(log, commandOf(second))
            expect((await recordedDemands(log))->Array.length)->toBe(2)
          },
        ),
    )

    testPromise(
      "a command with a random id is decided every time",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("RepeatRandom"))
            let cmd = commandOf(published)
            // The envelope of a command nobody derived: fresh id, no mark.
            let plain = {...cmd, meta: Message.deriveMeta(~parent=cmd.meta)}
            let _ = await deliver(log, plain)
            let _ = await deliver(log, plain)
            expect((await recordedDemands(log))->Array.length)->toBe(2)
          },
        ),
    )

    testPromise(
      "two concurrent copies append one event",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("RepeatConcurrent"))
            let cmd = commandOf(published)
            // Both read an empty partition; the second append conflicts, re-reads,
            // and finds the first one's event.
            let (a, b) = await Promise.all2((deliver(log, cmd), deliver(log, cmd)))
            expect(a->Array.length)->toBe(1)
            expect(b->Array.length)->toBe(1)
            expect(a->Array.getUnsafe(0)->Result.isOk && b->Array.getUnsafe(0)->Result.isOk)->toBe(
              true,
            )
            expect((await recordedDemands(log))->Array.length)->toBe(1)
          },
        ),
    )
  })
)
