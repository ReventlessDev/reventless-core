
// ─────────────────────────────────────────────────────────────
// Aggregate spec
// ─────────────────────────────────────────────────────────────

module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestAggregate"

  @schema
  type command =
    | Create({name: string})
    | Rename({newName: string})

  @schema
  type event =
    | Created({name: string})
    | Renamed({newName: string})

  @schema
  type error =
    | AlreadyExists
    | NotFound

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Behavior
// ─────────────────────────────────────────────────────────────

module TestBehavior = {
  module Spec = AggSpec

  @schema
  type state = NotCreated | Created({name: string})

  let initialState = NotCreated

  // Hand-written behavior (no @@reventless.behavior PPX) — satisfy the
  // Behavior.T snapshot field manually.
  let snapshot = None

  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (_state: state, event: AggSpec.event): state =>
    switch event {
    | AggSpec.Created({name}) => Created({name: name})
    | AggSpec.Renamed({newName}) => Created({name: newName})
    }

  let decide = (state: state, command: AggSpec.command): result<array<AggSpec.event>, AggSpec.error> =>
    switch (state, command) {
    | (NotCreated, Create({name})) => Ok([AggSpec.Created({name: name})])
    | (NotCreated, Rename(_)) => Error(NotFound)
    | (Created(_), Create(_)) => Error(AlreadyExists)
    | (Created(_), Rename({newName})) => Ok([AggSpec.Renamed({newName: newName})])
    }
}

// ─────────────────────────────────────────────────────────────
// Mock EventLog storage
// ─────────────────────────────────────────────────────────────

type mockEL = {
  appendFn: (int, string, array<Message.event'<string, AggSpec.event>>) => promise<result<unit, EventLog.appendError>>,
  replayFn: string => promise<array<AggSpec.event>>,
  replayStreamFn: string => Stream.t<AggSpec.event, string, unit>,
  getAll: unit => array<Message.event'<string, AggSpec.event>>,
  failNextAppend: ref<bool>,
  reset: unit => unit,
}

let makeMockEL = (): mockEL => {
  let storedRef: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
  let failRef = ref(false)

  let appendFn = async (_seqNr, _id, newEvents) =>
    if failRef.contents {
      failRef := false
      Error(EventLog.StorageFailure("append failed"))
    } else {
      storedRef := storedRef.contents->Array.concat(newEvents)
      Ok(())
    }

  let replayFn = async id =>
    storedRef.contents
    ->Array.filter(e => e.id == id)
    ->Array.map(e => e.event)

  let replayStreamFn = id =>
    storedRef.contents
    ->Array.filter(e => e.id == id)
    ->Array.map(e => e.event)
    ->Stream.fromIterable

  {
    appendFn,
    replayFn,
    replayStreamFn,
    getAll: () => storedRef.contents,
    failNextAppend: failRef,
    reset: () => {
      storedRef := []
      failRef := false
    },
  }
}

// Module-level shared mock — reset in beforeEach
let mock = makeMockEL()

// ─────────────────────────────────────────────────────────────
// TestOps satisfying Aggregate_Callback.Ops
// ─────────────────────────────────────────────────────────────

// Alias to preserve outer EventLog module reference inside inner EventLog definition
module OuterEventLog = EventLog

module TestOps = {
  module Spec = AggSpec
  module EventLog = {
    module Spec = {
      module Id = AggSpec.Id
      let name = "MockEventLog"
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
      appendStream: (int, string, Stream.t<AggSpec.event, string, unit>) => Effect.t<unit, string, unit>,
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

// ─────────────────────────────────────────────────────────────
// Callback handler under test
// ─────────────────────────────────────────────────────────────

module TestHandler = Aggregate_Callback.Make(AggSpec, TestBehavior, TestOps)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "TestAggregate",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

let makeTopicItem = (~aggId="agg-1", reference, command): CommandTopic.topicItem<
  Message.command'<string, AggSpec.command>,
> => {
  command: {
    id: aggId,
    meta: testMeta,
    command,
  },
  reference,
}
