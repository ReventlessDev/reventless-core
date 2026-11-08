// A slice whose `consumedEvent` is `unit` decides from nothing: it records each command without
// asking the event log to read, and appends without a condition.

open JestGlobals

let mock = DcbFixtures.makeMockStorage()

module LogOps = DcbEventLog_Operations.Make({
  let name = "ReadsNothingLog"
  let serviceName = "ReadsNothingLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
})

// The event log, with every read and every append's condition noted.
let reads = ref(0)
let conditions: ref<array<option<Reventless.DcbTag.appendCondition>>> = ref([])
let eventLog: DcbEventLog.operations = {
  read: LogOps.read,
  readStream: (~query, ~after=?, ~strongConsistency=?) => {
    reads := reads.contents + 1
    LogOps.readStream(~query, ~after?, ~strongConsistency?)
  },
  append: (events, ~condition=?) => {
    conditions := conditions.contents->Array.concat([condition])
    LogOps.append(events, ~condition?)
  },
  appendStream: LogOps.appendStream,
}

module NoteSpec = {
  let name = "NoteFault"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event = FaultNoted({chargerId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type consumedEvent = unit

  @schema
  type command = NoteFault({chargerId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type error = unit
}

module NoteDecision = {
  type state = unit
  let initialState = ()
  let moduleUrl = NoteSpec.moduleUrl
  let evolve = (state, _event) => state
  let decide = (_state, command: NoteSpec.command): result<array<NoteSpec.event>, NoteSpec.error> =>
    switch command {
    | NoteFault({chargerId}) => Ok([FaultNoted({chargerId: chargerId})])
    }
}

module NoteHandler = StateChangeSlice_Callback.Make(NoteSpec, NoteDecision)

let note = reference =>
  NoteHandler.handleCommands(
    eventLog,
    Stream.fromIterable([
      {
        ReventlessInfra.CommandTopic.command: {
          Message.id: Reventless.Id.String.makeFromString("cmd-" ++ reference),
          meta: DcbFixtures.testMeta,
          command: NoteSpec.NoteFault({chargerId: "charger-1"}),
        },
        reference,
      },
    ]),
  )->Effect.runPromise

let _ = beforeEach(() => {
  mock.reset()
  NoteHandler.resetCache()
  reads := 0
  conditions := []
})

describe("a slice that consumes nothing", () => {
  testPromise("records each command without a read and without a condition", async () => {
    let first = await note("ref-1")
    let second = await note("ref-2")
    expect((
      first,
      second,
      mock.getEvents()->Array.length,
      reads.contents,
      conditions.contents,
    ))->toEqual(([Ok("ref-1")], [Ok("ref-2")], 2, 0, [None, None]))
  })
})

describe("DcbTag.readsNothing", () => {
  testSync("a query of clauses with no event type reads nothing", () =>
    expect((
      Reventless.DcbTag.readsNothing([{eventTypes: [], tags: [{key: "chargerId", value: "c1"}]}]),
      Reventless.DcbTag.readsNothing([
        {eventTypes: []},
        {eventTypes: ["FaultNoted"], tags: [{key: "chargerId", value: "c1"}]},
      ]),
      // An empty query keeps its meaning: every event.
      Reventless.DcbTag.readsNothing([]),
      Reventless.DcbTag.readsNothing([{tags: [{key: "chargerId", value: "c1"}]}]),
    ))->toEqual((true, false, false, false))
  )
})
