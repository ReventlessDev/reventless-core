// A rejected command says who said no, on the wire a client reads. Driven through
// the producer path (`runInlineAndCollect` → `commandOutcomeToJson`) over the real
// in-memory and SQLite DCB stores: the model (`decide`), the caller (ownership),
// and the platform (exhausted retries, a failing store).

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

module Message = ReventlessCore.Message
module CommandTopic_Helpers = ReventlessCore.CommandTopic_Helpers

module OrderSlice = {
  let name = "CauseOrders"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string, customerId: string})
    | OrderCancelled({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type consumedEvent =
    | OrderPlaced({
        orderId: @s.matches(Reventless.DcbTag.string) string,
        customerId: @s.matches(Reventless.Owner.string) string,
      })
    | OrderCancelled({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type command =
    | PlaceOrder({
        orderId: @s.matches(Reventless.DcbTag.string) string,
        customerId: @s.matches(Reventless.Owner.string) string,
      })
    | CancelOrder({orderId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type error = OrderAlreadyPlaced | OrderNotFound
}

module OrderDecision = {
  type state = {placed: bool, cancelled: bool}
  let initialState = {placed: false, cancelled: false}
  let moduleUrl = OrderSlice.moduleUrl

  let evolve = (state, event: OrderSlice.consumedEvent) =>
    switch event {
    | OrderPlaced(_) => {...state, placed: true}
    | OrderCancelled(_) => {...state, cancelled: true}
    }

  let decide = (state, command: OrderSlice.command): result<
    array<OrderSlice.event>,
    OrderSlice.error,
  > =>
    switch command {
    | PlaceOrder({orderId, customerId}) =>
      state.placed ? Error(OrderAlreadyPlaced) : Ok([OrderPlaced({orderId, customerId})])
    | CancelOrder({orderId}) =>
      state.placed ? Ok([OrderCancelled({orderId: orderId})]) : Error(OrderNotFound)
    }
}

module OrderHandler = ReventlessCore.StateChangeSlice_Callback.Make(OrderSlice, OrderDecision)

let partitionTag = Reventless.DcbTag.Simple({key: "orderId"})

// ─── Callers ────────────────────────────────────────────────────────────────

external asIdentity: 'a => Reventless.Identity.t = "%identity"

let cognito = (~userId): Reventless.Identity.t =>
  asIdentity({"userId": userId, "username": userId, "groups": ["User"], "provider": "Cognito"})

let owner = cognito(~userId="cust-A")
let stranger = cognito(~userId="cust-B")

// ─── Generator → producer path ──────────────────────────────────────────────

let generated: ref<array<Message.commandJson>> = ref([])

let generate = ReventlessCore.CommandGenerator_Callback.makeGenerateCommand(
  ~publishJsons=async cmds => generated := generated.contents->Array.concat(cmds),
  ~serviceName=OrderSlice.name,
  ~commandSchema=OrderSlice.commandSchema->S.castToUnknown,
  ~componentKind=ReventlessCore.CommandGenerator_Callback.StateChangeSlice,
  ~stripIdFromParams=false,
)

let envelope = async (~command, ~args, ~identity) => {
  generated := []
  let p: ReventlessCore.CommandGenerator.payload = Obj.magic({
    "command": command,
    "arguments": Obj.magic(Dict.fromArray(args)),
    "meta": {"ip": [], "user": "test", "info": ""},
    "identity": identity,
  })
  let _ = await generate(p)->Effect.runPromise
  generated.contents->Array.getUnsafe(0)
}

let handlerOver = (eventLog): CommandTopic_Helpers.jsonCommandsHandler =>
  stream =>
    OrderHandler.handleCommands(
      ~partitionTag,
      eventLog,
      stream->Stream.map((item: CommandTopic_Helpers.topicItem<JSON.t>) => {
        ReventlessInfra.CommandTopic.command: item.command->Message.decodeCommand'(
          Reventless.Id.String.schema,
          OrderSlice.commandSchema,
        ),
        reference: item.reference,
      }),
    )

// The wire answer a client gets for one command: (`__typename`, `errorCode`, `cause`).
let send = async (eventLog, cmd: Message.commandJson) => {
  let outcomes = await CommandTopic_Helpers.runInlineAndCollect([cmd], handlerOver(eventLog))
  let json = outcomes->Array.getUnsafe(0)->CommandTopic_Helpers.commandOutcomeToJson
  let str = key =>
    json
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get(key))
    ->Option.flatMap(JSON.Decode.string)
  (str("__typename"), str("errorCode"), str("cause"))
}

let str = JSON.Encode.string
let place = (~identity) =>
  envelope(
    ~command="PlaceOrder",
    ~args=[("orderId", str("o-1")), ("customerId", str("cust-A"))],
    ~identity,
  )
let cancel = (~identity) =>
  envelope(~command="CancelOrder", ~args=[("orderId", str("o-1"))], ~identity)

// ─── Backends ───────────────────────────────────────────────────────────────

type appendMode = Real | AlwaysConflict | StoreFails

// One fresh event log per scenario; `mode` replaces the store's append to fail
// the way the platform can.
let eventLogOn = async (~name, ~mode) => {
  module Bus = LocalBus.Make()
  module Storage = LocalDcbEventLogStorage.Make(Bus)
  let s = Storage.make(
    ~name,
    ~indexes=[],
    ~partitionTag=Reventless.DcbTag.Simple({key: "orderId"}),
    ~opts,
  )
  let real = await s.operations->TestRunner.resolve
  let storage: ReventlessCore.DcbEventLog_Adapter.operations = switch mode {
  | Real => real
  | AlwaysConflict => {...real, append: async (_, ~condition as _=?) => Error(Conflict)}
  | StoreFails => {
      ...real,
      append: async (_, ~condition as _=?) => Error(StorageFailure("disk unavailable")),
    }
  }
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

let _ = beforeEach(() => {
  Reventless.OwnerScope.setElevatedGroups(["Admin"])
  OrderHandler.resetCache()
})

let counter = ref(0)
let fresh = prefix => {
  counter := counter.contents + 1
  `${prefix}-${counter.contents->Int.toString}`
}

let backends = [("in-memory", runUnderMemory), ("SQLite", runUnderSqlite)]

backends->Array.forEach(((label, runUnder)) =>
  describe(`a rejection's cause (${label} backend)`, () => {
    testPromise(
      "the model's no: a decide error arrives with DOMAIN",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("CauseDomain"), ~mode=Real)
            let first = await send(log, await place(~identity=owner))
            expect(first)->toEqual((Some("CommandAccepted"), None, None))
            let again = await send(log, await place(~identity=owner))
            expect(again)->toEqual((
              Some("CommandRejected"),
              Some("OrderAlreadyPlaced"),
              Some("DOMAIN"),
            ))
          },
        ),
    )

    testPromise(
      "the caller's no: an ownership refusal arrives with ACCESS",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("CauseAccess"), ~mode=Real)
            let _ = await send(log, await place(~identity=owner))
            let refused = await send(log, await cancel(~identity=stranger))
            expect(refused)->toEqual((Some("CommandRejected"), Some("Forbidden"), Some("ACCESS")))
          },
        ),
    )

    testPromise(
      "the platform's no: an exhausted retry loop arrives with INFRASTRUCTURE",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("CauseConflict"), ~mode=AlwaysConflict)
            let failed = await send(log, await place(~identity=owner))
            expect(failed)->toEqual((
              Some("CommandRejected"),
              Some("Conflict"),
              Some("INFRASTRUCTURE"),
            ))
          },
        ),
    )

    testPromise(
      "the platform's no: a failing store arrives with INFRASTRUCTURE",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("CauseStore"), ~mode=StoreFails)
            let failed = await send(log, await place(~identity=owner))
            expect(failed)->toEqual((
              Some("CommandRejected"),
              Some("AppendFailed"),
              Some("INFRASTRUCTURE"),
            ))
          },
        ),
    )
  })
)
