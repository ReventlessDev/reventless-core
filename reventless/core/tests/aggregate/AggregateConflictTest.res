// Tests for Aggregate_Callback conflict retry logic.
// Verifies that on optimistic locking conflict, the callback re-replays and re-processes.

open JestGlobals

S.enableJson()

module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "ConflictTestAggregate"

  @schema
  type command = | Create({name: string})

  @schema
  type event = | Created({name: string})

  @schema
  type error = | AlreadyExists

  let moduleUrl: string = %raw(`import.meta.url`)
}

module TestBehavior = {
  module Spec = AggSpec
  type state = {name: string}

  let initialState = {name: ""}

  // Hand-written behavior (no @@reventless.behavior PPX) — satisfy the
  // Behavior.T snapshot field manually.
  let snapshot = None

  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (_state: state, event: AggSpec.event): state =>
    switch event {
    | Created({name}) => {name: name}
    }

  let decide = (_state: state, command: AggSpec.command): result<array<AggSpec.event>, AggSpec.error> =>
    switch command {
    | Create({name}) => Ok([AggSpec.Created({name: name})])
    }
}

type mockEL = {
  appendFn: (int, string, array<Message.event'<string, AggSpec.event>>) => promise<result<unit, EventLog.appendError>>,
  replayFn: string => promise<array<AggSpec.event>>,
  replayStreamFn: string => Stream.t<AggSpec.event, string, unit>,
  getAll: unit => array<Message.event'<string, AggSpec.event>>,
  failNextAppendsWithConflict: ref<int>,
  appendCallCount: ref<int>,
  replayCallCount: ref<int>,
  reset: unit => unit,
}

let makeMockEL = (): mockEL => {
  let storedRef: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
  let failConflictRef = ref(0)
  let appendCount = ref(0)
  let replayCount = ref(0)

  let appendFn = async (_seqNr, _id, newEvents) => {
    appendCount := appendCount.contents + 1
    if failConflictRef.contents > 0 {
      failConflictRef := failConflictRef.contents - 1
      Error(EventLog.Conflict)
    } else {
      storedRef := storedRef.contents->Array.concat(newEvents)
      Ok(())
    }
  }

  let replayFn = async id => {
    replayCount := replayCount.contents + 1
    storedRef.contents
    ->Array.filter(e => e.id == id)
    ->Array.map(e => e.event)
  }

  let replayStreamFn = id => {
    replayCount := replayCount.contents + 1
    storedRef.contents
    ->Array.filter(e => e.id == id)
    ->Array.map(e => e.event)
    ->Stream.fromIterable
  }

  {
    appendFn,
    replayFn,
    replayStreamFn,
    getAll: () => storedRef.contents,
    failNextAppendsWithConflict: failConflictRef,
    appendCallCount: appendCount,
    replayCallCount: replayCount,
    reset: () => {
      storedRef := []
      failConflictRef := 0
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
      let name = "ConflictMockEventLog"
      @schema
      type event = AggSpec.event
    }
    type operations = {
      append: (int, string, array<Message.event'<string, AggSpec.event>>) => promise<result<unit, EventLog.appendError>>,
      replay: string => promise<array<AggSpec.event>>,
      replayStream: (string, ~fromSeq: int=?) => Stream.t<AggSpec.event, string, unit>,
      appendStream: (int, string, Stream.t<AggSpec.event, string, unit>) => Effect.t<unit, string, unit>,
      latestSnapshot: string => promise<result<option<EventLog.snapshot>, string>>,
      writeSnapshot: (string, EventLog.snapshot) => promise<result<unit, string>>,
    }
    type component = Component.t<OuterEventLog.t, OuterEventLog.outputs, operations>
    let make = (~name as _: string, ~opts as _=?): component => Obj.magic(0)
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

let testMeta: Message.meta = {
  service: "ConflictTestAggregate",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

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

let _ = beforeEach(() => {
  mock.reset()
  TestHandler.resetCache()
})

describe("Aggregate_Callback — conflict retry:", () => {
  testPromise("1 conflict retries and succeeds", async () => {
    mock.failNextAppendsWithConflict := 1
    let results = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    expect(results)->toEqual([Ok("ref-1")])
    // 1 initial append (conflict) + 1 retry append (success) = 2
    expect(mock.appendCallCount.contents)->toBe(2)
  })

  testPromise("conflict triggers re-replay", async () => {
    mock.failNextAppendsWithConflict := 1
    let _ = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    // 1 initial replay + 1 retry replay = 2
    expect(mock.replayCallCount.contents)->toBe(2)
  })

  testPromise("2 conflicts retry twice and succeed", async () => {
    mock.failNextAppendsWithConflict := 2
    let results = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    expect(results)->toEqual([Ok("ref-1")])
    expect(mock.appendCallCount.contents)->toBe(3)
  })

  testPromise("max retries exhausted returns Error with detail message", async () => {
    // 4 conflicts exhaust 3 retries (1 initial + 3 retries = 4 attempts)
    mock.failNextAppendsWithConflict := 4
    let results = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    expect(results)->toEqual([Error("concurrent modification (3 retries exhausted): conflict")])
    expect(mock.appendCallCount.contents)->toBe(4)
  })

  testPromise("successful append after conflict stores event", async () => {
    mock.failNextAppendsWithConflict := 1
    let _ = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    expect(mock.getAll()->Array.length)->toBe(1)
  })

  testPromise("no conflict does not retry", async () => {
    let results = await Stream.fromIterable([
      makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
    ])->TestHandler.handleCommands->Effect.runPromise
    expect(results)->toEqual([Ok("ref-1")])
    expect(mock.appendCallCount.contents)->toBe(1)
    expect(mock.replayCallCount.contents)->toBe(1)
  })
})
