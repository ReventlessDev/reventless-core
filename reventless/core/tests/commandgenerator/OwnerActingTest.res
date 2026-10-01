open JestGlobals

// A command acts only on what its caller owns. The stamp (OwnerStampingTest)
// decides who a new thing belongs to; this decides who may act on it afterwards.
//
// Driven end to end on purpose: the generator writes the claim, a transport
// encodes the envelope, and the handler reads it back before `decide`. The rule
// is a relationship between those three, and the AppSync stamping gap showed that
// each one can be correct on its own while the chain fails open. Every row of the
// table runs on every path below — two handlers, two envelope encodings.

// ─── An owner-marked DCB slice ──────────────────────────────────────────────

module OrderSlice = {
  let name = "OwnedOrders"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string, customerId: string})
    | OrderCancelled({orderId: @s.matches(Reventless.DcbTag.string) string})

  // `customerId` on the consumed `OrderPlaced` is the declaration under test: it
  // names the owner of the order a command acts on. `ProductListed` is read
  // across partitions and marks an owner of its own, which must not count.
  @schema
  type consumedEvent =
    | OrderPlaced({
        orderId: @s.matches(Reventless.DcbTag.string) string,
        customerId: @s.matches(Reventless.Owner.string) string,
      })
    | OrderCancelled({orderId: @s.matches(Reventless.DcbTag.string) string})
    | ProductListed({
        productId: @s.matches(Reventless.DcbTag.string) string,
        sellerId: @s.matches(Reventless.Owner.string) string,
      })

  @schema
  type command =
    | PlaceOrder({
        orderId: @s.matches(Reventless.DcbTag.string) string,
        customerId: @s.matches(Reventless.Owner.string) string,
      })
    | CancelOrder({orderId: @s.matches(Reventless.DcbTag.string) string})
    | ReviewOrder({
        orderId: @s.matches(Reventless.DcbTag.string) string,
        productId: @s.matches(Reventless.DcbTag.string) string,
      })

  @schema
  type error =
    | OrderAlreadyPlaced
    | OrderNotFound
}

module OrderBehavior = {
  type state = {placed: bool, cancelled: bool}
  let initialState = {placed: false, cancelled: false}
  let moduleUrl = OrderSlice.moduleUrl

  let evolve = (state, event: OrderSlice.consumedEvent) =>
    switch event {
    | OrderPlaced(_) => {...state, placed: true}
    | OrderCancelled(_) => {...state, cancelled: true}
    | ProductListed(_) => state
    }

  let decide = (state, command: OrderSlice.command): result<
    array<OrderSlice.event>,
    OrderSlice.error,
  > =>
    switch command {
    | PlaceOrder({orderId, customerId}) =>
      state.placed ? Error(OrderAlreadyPlaced) : Ok([OrderPlaced({orderId, customerId})])
    | CancelOrder({orderId}) =>
      switch (state.placed, state.cancelled) {
      | (false, _) => Error(OrderNotFound)
      | (true, true) => Ok([])
      | (true, false) => Ok([OrderCancelled({orderId: orderId})])
      }
    | ReviewOrder(_) => state.placed ? Ok([]) : Error(OrderNotFound)
    }
}

module OrderHandler = StateChangeSlice_Callback.Make(OrderSlice, OrderBehavior)

let dcbMock = DcbFixtures.makeMockStorage()

module DcbOps: DcbEventLog_Operations.Ops = {
  let name = "OwnedOrdersEventLog"
  let serviceName = "OwnedOrdersEventLog"
  let storage = dcbMock.operations
  let publishJson = dcbMock.mockPublishJson
}
module DcbLog = DcbEventLog_Operations.Make(DcbOps)

let dcbEventLog: DcbEventLog.operations = {
  read: DcbLog.read,
  append: DcbLog.append,
  readStream: DcbLog.readStream,
  appendStream: DcbLog.appendStream,
}

let orderPartition = Reventless.DcbTag.Simple({key: "orderId"})

// ─── An owner-marked aggregate ──────────────────────────────────────────────

module AccountSpec = {
  module Id = Reventless.Id.StringPure
  let name = "OwnedAccount"

  @schema
  type command =
    | Open({holderId: @s.matches(Reventless.Owner.string) string, name: string})
    | Rename({newName: string})

  @schema
  type event =
    | Opened({holderId: @s.matches(Reventless.Owner.string) string, name: string})
    | Renamed({newName: string})

  @schema
  type error =
    | AlreadyOpen
    | NotFound

  let moduleUrl: string = %raw(`import.meta.url`)
}

module AccountBehavior = {
  module Spec = AccountSpec

  @schema
  type state = NotOpen | Active({name: string})

  let initialState = NotOpen

  // Configured on purpose: an owner-marked aggregate must not seed from a
  // snapshot, which holds the state but not the owner.
  let snapshot = Some({Reventless.Snapshot.interval: 1, stateSchema})

  let moduleUrl = AccountSpec.moduleUrl

  let evolve = (_state, event: AccountSpec.event) =>
    switch event {
    | Opened({name}) => Active({name: name})
    | Renamed({newName}) => Active({name: newName})
    }

  let decide = (state, command: AccountSpec.command): result<
    array<AccountSpec.event>,
    AccountSpec.error,
  > =>
    switch (state, command) {
    | (NotOpen, Open({holderId, name})) => Ok([AccountSpec.Opened({holderId, name})])
    | (NotOpen, Rename(_)) => Error(NotFound)
    | (Active(_), Open(_)) => Error(AlreadyOpen)
    | (Active(_), Rename({newName})) => Ok([AccountSpec.Renamed({newName: newName})])
    }
}

let accountEvents: ref<array<Message.event'<string, AccountSpec.event>>> = ref([])
let snapshotReads = ref(0)

module OuterEventLog = EventLog

module AccountOps = {
  module Spec = AccountSpec
  module EventLog = {
    module Spec = {
      module Id = AccountSpec.Id
      let name = "OwnedAccountEventLog"
      @schema
      type event = AccountSpec.event
    }
    type operations = {
      append: (
        int,
        string,
        array<Message.event'<string, AccountSpec.event>>,
      ) => promise<result<unit, EventLog.appendError>>,
      replay: string => promise<array<AccountSpec.event>>,
      replayStream: (string, ~fromSeq: int=?) => Stream.t<AccountSpec.event, string, unit>,
      appendStream: (
        int,
        string,
        Stream.t<AccountSpec.event, string, unit>,
      ) => Effect.t<unit, string, unit>,
      latestSnapshot: string => promise<result<option<EventLog.snapshot>, string>>,
      writeSnapshot: (string, EventLog.snapshot) => promise<result<unit, string>>,
    }
    type component = Component.t<OuterEventLog.t, OuterEventLog.outputs, operations>
    let make = (~name as _: string, ~owner as _=?, ~opts as _=?): component => Obj.magic(0)
  }
  let ofId = id => accountEvents.contents->Array.filter(e => e.id == id)->Array.map(e => e.event)
  let eventLog: EventLog.operations = {
    append: async (_seqNr, _id, newEvents) => {
      accountEvents := accountEvents.contents->Array.concat(newEvents)
      Ok()
    },
    replay: async id => ofId(id),
    replayStream: (id, ~fromSeq as _=?) => ofId(id)->Stream.fromIterable,
    appendStream: (_seqNr, _id, stream) => stream->Stream.runDrain,
    latestSnapshot: async _ => {
      snapshotReads := snapshotReads.contents + 1
      Ok(None)
    },
    writeSnapshot: async (_, _) => Ok(),
  }
}

module AccountHandler = Aggregate_Callback.Make(AccountSpec, AccountBehavior, AccountOps)

// ─── Callers ────────────────────────────────────────────────────────────────

external asIdentity: 'a => Reventless.Identity.t = "%identity"

let cognito = (~userId, ~groups): Reventless.Identity.t =>
  asIdentity({"userId": userId, "username": userId, "groups": groups, "provider": "Cognito"})

let owner = cognito(~userId="cust-A", ~groups=["User"])
let stranger = cognito(~userId="cust-B", ~groups=["User"])
let operator = cognito(~userId="ops-1", ~groups=["Admin"])
let iam: Reventless.Identity.t = asIdentity({
  "userArn": "arn:aws:sts::1:assumed-role/Ingester",
  "accountId": "1",
  "username": "Ingester",
  "provider": "IAM",
})

// ─── Generator → envelope → handler ─────────────────────────────────────────

// The two ways an envelope crosses from generator to handler: the inline body
// the local channel and the synchronous SQS path build, and the queued message
// body. Both encode `meta` through its schema, which is what carries the claim.
type hop = Inline | Queued

let cross = (hop, cmd: Message.commandJson): JSON.t =>
  switch hop {
  | Inline => CommandTopic_Helpers.encodeCommandJson(cmd)
  | Queued => Message.toMessageBody(cmd)->JSON.parseOrThrow
  }

type outcome = Accepted | Refused(string, CommandTopic_Helpers.refusalCause) | Lost

let observed: ref<array<CommandTopic_Helpers.commandOutcomeReport>> = ref([])

let outcomeOf = (reference: string) =>
  switch observed.contents->Array.findLast(r => r.reference == reference) {
  | Some({outcome: OutcomeAccepted(_)}) => Accepted
  | Some({outcome: OutcomeRejected({errorCode, cause})}) => Refused(errorCode, cause)
  | None => Lost
  }

let generated: ref<array<Message.commandJson>> = ref([])

let generator = (~serviceName, ~commandSchema, ~componentKind) =>
  CommandGenerator_Callback.makeGenerateCommand(
    ~publishJsons=async cmds => generated := generated.contents->Array.concat(cmds),
    ~serviceName,
    ~commandSchema,
    ~componentKind,
    ~stripIdFromParams=componentKind == CommandGenerator_Callback.Aggregate,
  )

let generateOne = async (generate, ~command, ~args, ~identity) => {
  generated := []
  let p: CommandGenerator.payload = Obj.magic({
    "command": command,
    "arguments": Obj.magic(Dict.fromArray(args)),
    "meta": {"ip": [], "user": "test", "info": ""},
    "identity": identity,
  })
  let _ = await generate(p)->Effect.runPromise
  generated.contents->Array.getUnsafe(0)
}

// What an internal route publishes: an envelope the generator did not write.
let withoutClaim = (cmd: Message.commandJson) => {...cmd, meta: {...cmd.meta, callerClaim: ?None}}

let str = JSON.Encode.string

module type Path = {
  let label: string
  let reset: unit => unit
  // Creates the thing as `cust-A`, through the same path.
  let seed: unit => promise<unit>
  // Builds the command that acts on it, as a caller.
  let act: Reventless.Identity.t => promise<Message.commandJson>
  // Answers the msgId the handler received, which its outcome is keyed by.
  let deliver: Message.commandJson => promise<string>
  let historyLength: unit => int
}

let dcbGenerate = generator(
  ~serviceName=OrderSlice.name,
  ~commandSchema=OrderSlice.commandSchema->S.castToUnknown,
  ~componentKind=CommandGenerator_Callback.StateChangeSlice,
)

let deliverDcb = async (~crossPartitionTagKeys=[], ~partitionTag=orderPartition, hop, cmd) => {
  let command' =
    cross(hop, cmd)->Message.decodeCommand'(Reventless.Id.String.schema, OrderSlice.commandSchema)
  let _ = await OrderHandler.handleCommands(
    ~crossPartitionTagKeys,
    ~partitionTag,
    dcbEventLog,
    Stream.fromIterable([
      {ReventlessInfra.CommandTopic.command: command', reference: cmd.meta.msgId},
    ]),
  )->Effect.runPromise
  // A queued body is re-stamped with a fresh msgId; outcomes are keyed by the
  // envelope the handler received.
  command'.meta.msgId
}

let makeDcbPath = (hop): module(Path) =>
  module(
    {
      let label = `DCB slice, ${hop == Inline ? "inline" : "queued"} envelope`
      let reset = () => {
        dcbMock.reset()
        OrderHandler.resetCache()
      }
      let deliver = cmd => deliverDcb(hop, cmd)
      let seed = async () => {
        let _ = await deliver(
          await dcbGenerate->generateOne(
            ~command="PlaceOrder",
            ~args=[("orderId", str("o-1")), ("customerId", str("cust-A"))],
            ~identity=owner,
          ),
        )
      }
      let act = identity =>
        dcbGenerate->generateOne(~command="CancelOrder", ~args=[("orderId", str("o-1"))], ~identity)
      let historyLength = () => dcbMock.getEvents()->Array.length
    }
  )

let aggregateGenerate = generator(
  ~serviceName=AccountSpec.name,
  ~commandSchema=AccountSpec.commandSchema->S.castToUnknown,
  ~componentKind=CommandGenerator_Callback.Aggregate,
)

let deliverAggregate = async (hop, cmds: array<Message.commandJson>) => {
  let items = cmds->Array.map(cmd => {
    ReventlessInfra.CommandTopic.command: cross(hop, cmd)->Message.decodeCommand'(
      AccountSpec.Id.schema,
      AccountSpec.commandSchema,
    ),
    reference: cmd.meta.msgId,
  })
  let _ = await AccountHandler.handleCommands(Stream.fromIterable(items))->Effect.runPromise
}

let makeAggregatePath = (hop): module(Path) =>
  module(
    {
      let label = `aggregate, ${hop == Inline ? "inline" : "queued"} envelope`
      let reset = () => {
        accountEvents := []
        snapshotReads := 0
        AccountHandler.resetCache()
      }
      let deliver = async cmd => {
        await deliverAggregate(hop, [cmd])
        cmd.meta.msgId
      }
      let seed = async () => {
        let _ = await deliver(
          await aggregateGenerate->generateOne(
            ~command="Open",
            ~args=[("id", str("acc-1")), ("holderId", str("cust-A")), ("name", str("Main"))],
            ~identity=owner,
          ),
        )
      }
      let act = identity =>
        aggregateGenerate->generateOne(
          ~command="Rename",
          ~args=[("id", str("acc-1")), ("newName", str("Renamed"))],
          ~identity,
        )
      let historyLength = () => accountEvents.contents->Array.length
    }
  )

let paths = [
  makeDcbPath(Inline),
  makeDcbPath(Queued),
  makeAggregatePath(Inline),
  makeAggregatePath(Queued),
]

let _ = beforeEach(() => {
  Reventless.OwnerScope.setElevatedGroups(["Admin"])
  observed := []
  CommandTopic_Helpers.registerCommandOutcome(r => observed := observed.contents->Array.concat([r]))
})

let _ = afterEach(() => CommandTopic_Helpers.clearCommandOutcome())

let forbidden = Refused("Forbidden", CommandTopic_Helpers.AccessRefusal)

// (caller, how the envelope is produced, expected outcome, whether the history grows)
let table: array<(string, Reventless.Identity.t, bool, outcome)> = [
  ("the owner", owner, false, Accepted),
  ("another owner", stranger, false, forbidden),
  ("an operator, on the owner's behalf", operator, false, Accepted),
  ("the platform's own IAM traffic", iam, false, Accepted),
  ("an anonymous caller", Reventless.Identity.anonymous, false, forbidden),
  // An envelope the generator did not write: an automation's follow-up. The same
  // stranger, so the only difference from row two is where the command came from.
  ("an internal route, with no claim", stranger, true, Accepted),
]

paths->Array.forEach(path => {
  module P = unpack(path)
  describe(`acting on an owned thing — ${P.label}:`, () => {
    let _ = beforeEach(() => P.reset())

    table->Array.forEach(
      ((who, identity, internal, expected)) =>
        testPromise(
          `${who}: ${expected == Accepted ? "accepted" : "refused before decide"}`,
          async () => {
            await P.seed()
            let before = P.historyLength()
            let cmd = await P.act(identity)
            let cmd = internal ? withoutClaim(cmd) : cmd
            let received = await P.deliver(cmd)
            expect((outcomeOf(received), P.historyLength() > before))->toEqual((
              expected,
              expected == Accepted,
            ))
          },
        ),
    )

    // Creating is unaffected: an empty history has no owner to protect.
    testPromise(
      "the owner's own creating command is accepted on an empty history",
      async () => {
        await P.seed()
        expect(P.historyLength())->toBe(1)
      },
    )
  })
})

describe("acting on an owned thing — DCB specifics:", () => {
  let _ = beforeEach(() => {
    dcbMock.reset()
    OrderHandler.resetCache()
  })

  let seedOrder = async () => {
    let _ = await deliverDcb(
      Inline,
      await dcbGenerate->generateOne(
        ~command="PlaceOrder",
        ~args=[("orderId", str("o-1")), ("customerId", str("cust-A"))],
        ~identity=owner,
      ),
    )
  }

  let rawEvent = (~eventType, ~fields, ~tags): DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Encode.object(Dict.fromArray(fields)),
    tags: tags->Array.map(((key, value)) => {Reventless.DcbTag.key, value}),
    meta: DcbFixtures.testMeta,
  }

  // The plan's catalog case: a product the command names is read across
  // partitions and records a seller. Counting it would make every order two
  // owners and refuse everyone; only the order's own partition says whose it is.
  testPromise("an owner recorded in another partition does not count", async () => {
    await seedOrder()
    let _ = await dcbMock.operations.append([
      rawEvent(
        ~eventType="ProductListed",
        ~fields=[("productId", str("p-1")), ("sellerId", str("seller-Z"))],
        ~tags=[("productId", "p-1")],
      ),
    ])
    let review = await dcbGenerate->generateOne(
      ~command="ReviewOrder",
      ~args=[("orderId", str("o-1")), ("productId", str("p-1"))],
      ~identity=owner,
    )
    let _ = await deliverDcb(~crossPartitionTagKeys=["productId"], Inline, review)
    expect(outcomeOf(review.meta.msgId))->toEqual(Accepted)
  })

  // The owner rides in the projection cache with the state. A warm command reads
  // only the events after the cached head, which never include the one that
  // recorded the owner.
  testPromise("a warm, delta-read command is still checked against the owner", async () => {
    await seedOrder()
    let mine = await dcbGenerate->generateOne(
      ~command="CancelOrder",
      ~args=[("orderId", str("o-1"))],
      ~identity=owner,
    )
    let _ = await deliverDcb(Inline, mine)
    dcbMock.readAfters := []
    let theirs = await dcbGenerate->generateOne(
      ~command="CancelOrder",
      ~args=[("orderId", str("o-1"))],
      ~identity=stranger,
    )
    let _ = await deliverDcb(Inline, theirs)
    expect((
      dcbMock.readAfters.contents->Array.some(Option.isSome),
      outcomeOf(theirs.meta.msgId),
    ))->toEqual((true, forbidden))
  })

  testPromise("two owners in one partition refuse even an operator", async () => {
    await seedOrder()
    let _ = await dcbMock.operations.append([
      rawEvent(
        ~eventType="OrderPlaced",
        ~fields=[("orderId", str("o-1")), ("customerId", str("cust-B"))],
        ~tags=[("orderId", "o-1")],
      ),
    ])
    let cmd = await dcbGenerate->generateOne(
      ~command="CancelOrder",
      ~args=[("orderId", str("o-1"))],
      ~identity=operator,
    )
    let _ = await deliverDcb(Inline, cmd)
    expect(outcomeOf(cmd.meta.msgId))->toEqual(forbidden)
  })

  // A partition the handler cannot name is one whose owner it cannot read.
  // Reading that as "no owner yet" would admit everybody.
  testPromise("an unnameable partition refuses an owner and admits an operator", async () => {
    await seedOrder()
    let unnamed = Reventless.DcbTag.ByEventType(Dict.make())
    let mine = await dcbGenerate->generateOne(
      ~command="CancelOrder",
      ~args=[("orderId", str("o-1"))],
      ~identity=owner,
    )
    let _ = await deliverDcb(~partitionTag=unnamed, Inline, mine)
    let ops = await dcbGenerate->generateOne(
      ~command="CancelOrder",
      ~args=[("orderId", str("o-1"))],
      ~identity=operator,
    )
    let _ = await deliverDcb(~partitionTag=unnamed, Inline, ops)
    expect((outcomeOf(mine.meta.msgId), outcomeOf(ops.meta.msgId)))->toEqual((forbidden, Accepted))
  })
})

describe("acting on an owned thing — aggregate specifics:", () => {
  let _ = beforeEach(() => {
    accountEvents := []
    snapshotReads := 0
    AccountHandler.resetCache()
  })

  // One batch, one replay: the owner the first command records is the one the
  // second is checked against.
  testPromise(
    "a command later in the same batch is checked against an owner just recorded",
    async () => {
      let opened = await aggregateGenerate->generateOne(
        ~command="Open",
        ~args=[("id", str("acc-1")), ("holderId", str("cust-A")), ("name", str("Main"))],
        ~identity=owner,
      )
      let renamed = await aggregateGenerate->generateOne(
        ~command="Rename",
        ~args=[("id", str("acc-1")), ("newName", str("Mine now"))],
        ~identity=stranger,
      )
      await deliverAggregate(Inline, [opened, renamed])
      expect((outcomeOf(opened.meta.msgId), outcomeOf(renamed.meta.msgId)))->toEqual((
        Accepted,
        forbidden,
      ))
    },
  )

  testPromise("an owner-marked aggregate never seeds from a snapshot", async () => {
    let opened = await aggregateGenerate->generateOne(
      ~command="Open",
      ~args=[("id", str("acc-1")), ("holderId", str("cust-A")), ("name", str("Main"))],
      ~identity=owner,
    )
    await deliverAggregate(Inline, [opened])
    expect(snapshotReads.contents)->toBe(0)
  })
})
