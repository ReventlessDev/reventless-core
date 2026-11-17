// A slice that reads a key across partitions reads it through an eventually
// consistent index. Before it decides, it checks that it read every event the
// key's fence counted, and reads again while the index is behind.

open JestGlobals

let mock = DcbFixtures.makeMockStorage()

module LogOps = DcbEventLog_Operations.Make({
  let name = "FenceCountLog"
  let serviceName = "FenceCountLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
})

// An index that misses every stored event for its first `staleReads` reads.
let staleReads = ref(0)
let reads = ref(0)
let appends = ref(0)
let conditions: ref<array<option<Reventless.DcbTag.appendCondition>>> = ref([])
let counted = ref(true)
let student: Reventless.DcbTag.tag = {key: "studentId", value: "S1"}

let eventLog: DcbEventLog.operations = {
  read: LogOps.read,
  readStream: (~query, ~after=?, ~strongConsistency=?) => {
    reads := reads.contents + 1
    let stale = reads.contents <= staleReads.contents
    LogOps.readStream(~query, ~after?, ~strongConsistency?)->Stream.filter(_ => !stale)
  },
  append: (events, ~condition=?) => {
    appends := appends.contents + 1
    conditions := conditions.contents->Array.concat([condition])
    LogOps.append(events, ~condition?)
  },
  appendStream: LogOps.appendStream,
  readFences: async tags =>
    tags->Array.map((tag): Reventless.DcbFenceCount.fence => {
      tag,
      counted: counted.contents,
      counts: Dict.fromArray([
        (
          "StudentSubscribed",
          mock.getEvents()
          ->Array.filter(e => e.tags->Array.some(t => t.key == tag.key && t.value == tag.value))
          ->Array.length,
        ),
      ]),
    }),
}

module SubscribeSpec = {
  let name = "Subscribe"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | StudentSubscribed({
        courseId: @s.matches(Reventless.DcbTag.string) string,
        studentId: @s.matches(Reventless.DcbTag.string) string,
      })

  @schema
  type consumedEvent =
    | StudentSubscribed({
        courseId: @s.matches(Reventless.DcbTag.string) string,
        studentId: @s.matches(Reventless.DcbTag.string) string,
      })

  @schema
  type command =
    | Subscribe({
        courseId: @s.matches(Reventless.DcbTag.string) string,
        studentId: @s.matches(Reventless.DcbTag.string) string,
      })

  @schema
  type error = AlreadySubscribedElsewhere
}

// A student takes one course at a time.
module SubscribeDecision = {
  type state = bool
  let initialState = false
  let moduleUrl = SubscribeSpec.moduleUrl
  let evolve = (_state, _event: SubscribeSpec.consumedEvent) => true
  let decide = (subscribed, command: SubscribeSpec.command): result<
    array<SubscribeSpec.event>,
    SubscribeSpec.error,
  > =>
    switch command {
    | Subscribe(_) if subscribed => Error(AlreadySubscribedElsewhere)
    | Subscribe({courseId, studentId}) => Ok([StudentSubscribed({courseId, studentId})])
    }
}

module SubscribeHandler = StateChangeSlice_Callback.Make(SubscribeSpec, SubscribeDecision)

let subscribe = (reference, courseId) =>
  SubscribeHandler.handleCommands(
    ~crossPartitionTagKeys=["studentId"],
    ~partitionTag=Reventless.DcbTag.Simple({key: "courseId"}),
    eventLog,
    Stream.fromIterable([
      {
        ReventlessInfra.CommandTopic.command: {
          Message.id: Reventless.Id.String.makeFromString("cmd-" ++ reference),
          meta: DcbFixtures.testMeta,
          command: SubscribeSpec.Subscribe({courseId, studentId: student.value}),
        },
        reference,
      },
    ]),
  )->Effect.runPromise

// The student is already in course C1; the index has not shown it yet.
let givenSubscribedThenStale = async n => {
  let _ = await subscribe("first", "C1")
  SubscribeHandler.resetCache()
  reads := 0
  appends := 0
  staleReads := n
}

let _ = beforeEach(() => {
  mock.reset()
  SubscribeHandler.resetCache()
  reads := 0
  appends := 0
  conditions := []
  staleReads := 0
  counted := true
})

describe("a read of a counted cross-partition fence", () => {
  testPromise("reads again until the index shows what was counted", async () => {
    await givenSubscribedThenStale(1)
    let result = await subscribe("second", "C2")
    // The second read saw the first subscription, so nothing was appended.
    expect((result, mock.getEvents()->Array.length, reads.contents, appends.contents))->toEqual((
      [Ok("second")],
      1,
      2,
      0,
    ))
  })

  testPromise("answers a conflict when the index stays behind", async () => {
    await givenSubscribedThenStale(10)
    let result = await subscribe("second", "C2")
    expect((result, mock.getEvents()->Array.length, reads.contents, appends.contents))->toEqual((
      [Error("second")],
      1,
      4,
      0,
    ))
  })

  testPromise("a fence not yet counted is not checked", async () => {
    counted := false
    await givenSubscribedThenStale(1)
    let _ = await subscribe("second", "C2")
    // Decided on the stale read, as before counting existed: only the append's
    // condition catches it, and the retry reads again.
    expect((mock.getEvents()->Array.length, reads.contents, appends.contents))->toEqual((1, 2, 1))
  })

  testPromise("the append carries the count it read", async () => {
    let _ = await subscribe("first", "C1")
    expect(conditions.contents->Array.map(c => c->Option.flatMap(c => c.fenceCounts)))->toEqual([
      Some([{Reventless.DcbTag.tag: student, eventType: "StudentSubscribed", count: 0}]),
    ])
  })
})
