// Tests for the Aggregate_Callback in-process replay cache (Phase 1 of
// docs/plans/aggregate-snapshotting.md): a warm same-id command skips the
// event-log replay and decides on the cached (state, sequenceNr); the OCC
// append fences staleness — a stale cache conflicts, invalidates, and the
// retry replays cold.
//
// Unlike the other aggregate mocks, this one enforces optimistic concurrency
// (append conflicts unless seqNr matches the stored count), because the cache's
// correctness argument rests on exactly that fence. The Checkpoint command
// records the decision state's size as an event, making the cached fold state
// observable through ordinary domain behavior.

open JestGlobals

S.enableJson()

module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "CacheTestAggregate"

  @schema
  type command =
    | Add({name: string})
    | Checkpoint
    | Noop

  @schema
  type event =
    | Added({name: string})
    | CheckpointTaken({count: int})

  @schema
  type error = | Never

  let moduleUrl: string = %raw(`import.meta.url`)
}

module TestBehavior = {
  module Spec = AggSpec
  type state = {names: array<string>}

  let initialState = {names: []}

  // Hand-written behavior (no @@reventless.behavior PPX) — satisfy the
  // Behavior.T snapshot field manually.
  let snapshot = None

  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (state: state, event: AggSpec.event): state =>
    switch event {
    | Added({name}) => {names: state.names->Array.concat([name])}
    | CheckpointTaken(_) => state
    }

  let decide = (state: state, command: AggSpec.command): result<
    array<AggSpec.event>,
    AggSpec.error,
  > =>
    switch command {
    | Add({name}) => Ok([AggSpec.Added({name: name})])
    | Checkpoint => Ok([AggSpec.CheckpointTaken({count: state.names->Array.length})])
    | Noop => Ok([])
    }
}

let testMeta: Message.meta = {
  service: "CacheTestAggregate",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

type mockEL = {
  appendFn: (
    int,
    string,
    array<Message.event'<string, AggSpec.event>>,
  ) => promise<result<unit, EventLog.appendError>>,
  replayFn: string => promise<array<AggSpec.event>>,
  replayStreamFn: string => Stream.t<AggSpec.event, string, unit>,
  getAll: unit => array<Message.event'<string, AggSpec.event>>,
  // Appends directly to storage, bypassing the handler — simulates a second
  // writer the warm cache doesn't know about.
  injectExternal: (string, AggSpec.event) => unit,
  appendCallCount: ref<int>,
  replayCallCount: ref<int>,
  reset: unit => unit,
}

let makeMockEL = (): mockEL => {
  let storedRef: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
  let appendCount = ref(0)
  let replayCount = ref(0)

  let eventsFor = id => storedRef.contents->Array.filter(e => e.id == id)

  // Real OCC: the append succeeds only when seqNr matches the current count.
  let appendFn = async (seqNr, id, newEvents) => {
    appendCount := appendCount.contents + 1
    if seqNr != eventsFor(id)->Array.length {
      Error(EventLog.Conflict)
    } else {
      storedRef := storedRef.contents->Array.concat(newEvents)
      Ok(())
    }
  }

  let replayFn = async id => {
    replayCount := replayCount.contents + 1
    eventsFor(id)->Array.map(e => e.event)
  }

  let replayStreamFn = id => {
    replayCount := replayCount.contents + 1
    eventsFor(id)->Array.map(e => e.event)->Stream.fromIterable
  }

  {
    appendFn,
    replayFn,
    replayStreamFn,
    getAll: () => storedRef.contents,
    injectExternal: (id, event) =>
      storedRef := storedRef.contents->Array.concat([{Message.id, meta: testMeta, event}]),
    appendCallCount: appendCount,
    replayCallCount: replayCount,
    reset: () => {
      storedRef := []
      appendCount := 0
      replayCount := 0
    },
  }
}

let mock = makeMockEL()

module OuterEventLog = EventLog

module TestOps = {
  module Spec = AggSpec
  module EventLog = {
    module Spec = {
      module Id = AggSpec.Id
      let name = "CacheMockEventLog"
      @schema
      type event = AggSpec.event
    }
    type operations = {
      append: (
        int,
        string,
        array<Message.event'<string, AggSpec.event>>,
      ) => promise<result<unit, EventLog.appendError>>,
      replay: string => promise<array<AggSpec.event>>,
      replayStream: (string, ~fromSeq: int=?) => Stream.t<AggSpec.event, string, unit>,
      appendStream: (int, string, Stream.t<AggSpec.event, string, unit>) => Effect.t<
        unit,
        string,
        unit,
      >,
      latestSnapshot: string => promise<result<option<EventLog.snapshot>, string>>,
      writeSnapshot: (string, EventLog.snapshot) => promise<result<unit, string>>,
    }
    type component = Component.t<OuterEventLog.t, OuterEventLog.outputs, operations>
    // Never called — satisfies module type only
    let make = (~name as _: string, ~owner as _=?, ~opts as _=?): component => Obj.magic(0)
  }
  let eventLog: EventLog.operations = {
    append: mock.appendFn,
    replay: mock.replayFn,
    replayStream: (id, ~fromSeq as _=?) => mock.replayStreamFn(id),
    appendStream: (_startingSeqNr, _id, stream) => stream->Stream.runDrain,
    latestSnapshot: async _ => Ok(None),
    writeSnapshot: async (_, _) => Ok(),
  }
}

module TestHandler = Aggregate_Callback.Make(AggSpec, TestBehavior, TestOps)

let makeTopicItem = (reference, command): CommandTopic.topicItem<
  Message.command'<string, AggSpec.command>,
> => {
  command: {
    id: "agg-1",
    meta: testMeta,
    command,
  },
  reference,
}

let run = async command =>
  await Stream.fromIterable([makeTopicItem("ref", command)])
  ->TestHandler.handleCommands
  ->Effect.runPromise

let _ = beforeEach(() => {
  mock.reset()
  TestHandler.resetCache()
})

describe("Aggregate_Callback — replay cache:", () => {
  testPromise("warm same-id command skips the replay", async () => {
    let r1 = await run(AggSpec.Add({name: "a"}))
    let r2 = await run(AggSpec.Add({name: "b"}))
    expect((r1, r2))->toEqual(([Ok("ref")], [Ok("ref")]))
    // Only the first command replayed; the second decided on the cached state.
    expect(mock.replayCallCount.contents)->toBe(1)
    // Both appends landed at their correct OCC positions (no conflict retries).
    expect((mock.appendCallCount.contents, mock.getAll()->Array.length))->toEqual((2, 2))
  })

  testPromise("cached fold state equals a cold replay of the log", async () => {
    let _ = await run(AggSpec.Add({name: "a"}))
    let _ = await run(AggSpec.Add({name: "b"}))
    let _ = await run(AggSpec.Add({name: "c"}))
    // Warm checkpoint: decided on the cached state (no replay since call 1).
    let _ = await run(AggSpec.Checkpoint)
    expect(mock.replayCallCount.contents)->toBe(1)
    // Cold checkpoint: same aggregate replayed from the log.
    TestHandler.resetCache()
    let _ = await run(AggSpec.Checkpoint)
    expect(mock.replayCallCount.contents)->toBe(2)
    // Both checkpoints observed the same state — cached fold ≡ replayed fold.
    let checkpoints =
      mock.getAll()
      ->Array.filterMap(e =>
        switch e.event {
        | CheckpointTaken({count}) => Some(count)
        | _ => None
        }
      )
    expect(checkpoints)->toEqual([3, 3])
  })

  testPromise("stale cache conflicts, invalidates, and self-heals", async () => {
    let _ = await run(AggSpec.Add({name: "a"}))
    // A second writer appends behind the warm cache's back.
    mock.injectExternal("agg-1", AggSpec.Added({name: "external"}))
    // Warm path appends at the stale seq → OCC conflict → invalidate →
    // cold retry reads the authoritative log and succeeds.
    let results = await run(AggSpec.Add({name: "b"}))
    expect(results)->toEqual([Ok("ref")])
    // Replays: initial cold + post-conflict cold (the warm attempt skipped).
    expect(mock.replayCallCount.contents)->toBe(2)
    expect(mock.getAll()->Array.length)->toBe(3)
    // The refreshed state includes the external event.
    let _ = await run(AggSpec.Checkpoint)
    let last = mock.getAll()->Array.getUnsafe(3)
    expect(last.event)->toEqual(AggSpec.CheckpointTaken({count: 3}))
  })

  testPromise("Ok([]) keeps the read snapshot warm", async () => {
    let _ = await run(AggSpec.Add({name: "a"}))
    let _ = await run(AggSpec.Noop)
    let _ = await run(AggSpec.Add({name: "b"}))
    // Neither the Noop nor the third command replayed.
    expect(mock.replayCallCount.contents)->toBe(1)
    expect(mock.getAll()->Array.length)->toBe(2)
  })

  testPromise("resetCache forces the next command to replay cold", async () => {
    let _ = await run(AggSpec.Add({name: "a"}))
    TestHandler.resetCache()
    let _ = await run(AggSpec.Add({name: "b"}))
    expect(mock.replayCallCount.contents)->toBe(2)
    expect(mock.getAll()->Array.length)->toBe(2)
  })
})
