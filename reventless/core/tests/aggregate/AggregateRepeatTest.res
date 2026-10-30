// A command with a stable id (one an Extension derived from a published event)
// that the stream already holds events for is accepted again with nothing new.
// A command with a random id is decided every time, as before.

open JestGlobals

module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "RepeatTestAggregate"

  @schema
  type command = Count({by: int})

  @schema
  type event = Counted({by: int})

  @schema
  type error = Never

  let moduleUrl: string = %raw(`import.meta.url`)
}

// No idempotency rule of its own: every Count appends, which is what makes the
// framework's drop visible.
module TestDecision = {
  module Spec = AggSpec
  type state = {total: int}
  let initialState = {total: 0}
  let snapshot = None
  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (state: state, event: AggSpec.event): state =>
    switch event {
    | Counted({by}) => {total: state.total + by}
    }

  let decide = (_state: state, command: AggSpec.command): result<
    array<AggSpec.event>,
    AggSpec.error,
  > =>
    switch command {
    | Count({by}) => Ok([AggSpec.Counted({by: by})])
    }
}

// An event log with real optimistic concurrency, holding envelopes so the
// `causationId`s survive.
let stored: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
let eventsFor = id => stored.contents->Array.filter(e => e.id == id)

module OuterEventLog = EventLog

module TestOps = {
  module Spec = AggSpec
  module EventLog = {
    module Spec = {
      module Id = AggSpec.Id
      let name = "RepeatMockEventLog"
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
      replayEnvelopes: (
        string,
        ~fromSeq: int=?,
      ) => Stream.t<Message.event'<string, AggSpec.event>, string, unit>,
      appendStream: (
        int,
        string,
        Stream.t<AggSpec.event, string, unit>,
      ) => Effect.t<unit, string, unit>,
      latestSnapshot: string => promise<result<option<EventLog.snapshot>, string>>,
      writeSnapshot: (string, EventLog.snapshot) => promise<result<unit, string>>,
    }
    type component = Component.t<OuterEventLog.t, OuterEventLog.outputs, operations>
    let make = (~name as _: string, ~owner as _=?, ~opts as _=?): component => Obj.magic(0)
  }
  let eventLog: EventLog.operations = {
    append: async (seqNr, id, newEvents) =>
      if seqNr != eventsFor(id)->Array.length {
        Error(OuterEventLog.Conflict)
      } else {
        stored := stored.contents->Array.concat(newEvents)
        Ok()
      },
    replay: async id => eventsFor(id)->Array.map(e => e.event),
    replayStream: (id, ~fromSeq=0) =>
      eventsFor(id)->Array.map(e => e.event)->Array.slice(~start=fromSeq)->Stream.fromIterable,
    replayEnvelopes: (id, ~fromSeq=0) =>
      eventsFor(id)->Array.slice(~start=fromSeq)->Stream.fromIterable,
    appendStream: (_seqNr, _id, stream) => stream->Stream.runDrain,
    latestSnapshot: async _ => Ok(None),
    writeSnapshot: async (_, _) => Ok(),
  }
}

module TestHandler = Aggregate_Callback.Make(AggSpec, TestDecision, TestOps)

// The published event an Extension would have mapped the command from.
let publishedMeta: Message.meta = {
  service: "Ordering.Orders",
  time: "2024-01-01T00:00:00Z",
  msgId: "published-event-msg",
  correlationId: "root",
}

let run = async (meta: Message.meta) =>
  await TestHandler.handleCommands(
    Stream.fromIterable([
      {
        ReventlessInfra.CommandTopic.command: {
          Message.id: "counter-1",
          meta,
          command: AggSpec.Count({by: 1}),
        },
        reference: meta.msgId,
      },
    ]),
  )->Effect.runPromise

let _ = beforeEach(() => {
  stored := []
  TestHandler.resetCache()
})

describe("Aggregate_Callback drops a repeated command", () => {
  testPromise("a command with a stable id appends once however often it arrives", async () => {
    // What ExtensionMapping produces for one published event: the same meta each time.
    let derived = Message.deriveStableMeta(~parent=publishedMeta, ~service=AggSpec.name, ~index=0)
    let first = await run(derived)
    expect(first)->toEqual([Ok(derived.msgId)])
    let again = await run(derived)
    expect(again)->toEqual([Ok(derived.msgId)]) // accepted, not rejected
    let third = await run(derived)
    expect(third)->toEqual([Ok(derived.msgId)])
    expect(stored.contents->Array.length)->toBe(1)
    expect((stored.contents->Array.getUnsafe(0)).meta.causationId)->toEqual(Some(derived.msgId))
  })

  testPromise("a second derived command for another input still appends", async () => {
    let one = Message.deriveStableMeta(~parent=publishedMeta, ~service=AggSpec.name, ~index=0)
    let two = Message.deriveStableMeta(
      ~parent={...publishedMeta, msgId: "another-published-event"},
      ~service=AggSpec.name,
      ~index=0,
    )
    let _ = await run(one)
    let _ = await run(two)
    let _ = await run(one)
    expect(stored.contents->Array.length)->toBe(2)
  })

  testPromise("a command with a random id is decided every time", async () => {
    // What the API or a person sends: `deriveMeta` strips the mark and mints a
    // fresh id, so nothing is dropped.
    let fresh = () => Message.deriveMeta(~parent=publishedMeta, ~service=AggSpec.name)
    let a = fresh()
    let _ = await run(a)
    let _ = await run(a) // the very same envelope, redelivered without a stable id
    expect(stored.contents->Array.length)->toBe(2)
  })

  testPromise("two copies in one batch append once", async () => {
    let derived = Message.deriveStableMeta(~parent=publishedMeta, ~service=AggSpec.name, ~index=0)
    let item = {
      ReventlessInfra.CommandTopic.command: {
        Message.id: "counter-1",
        meta: derived,
        command: AggSpec.Count({by: 1}),
      },
      reference: derived.msgId,
    }
    let results = await TestHandler.handleCommands(
      Stream.fromIterable([item, item]),
    )->Effect.runPromise
    expect(results)->toEqual([Ok(derived.msgId), Ok(derived.msgId)])
    expect(stored.contents->Array.length)->toBe(1)
  })
})
