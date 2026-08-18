// Step 5 of docs/plans/done/aggregate-snapshotting.md — the Aggregate_Callback
// snapshot wiring: a snapshot-enabled behavior seeds cold replays from the
// latest persisted snapshot (hash-gated) and writes a fresh one every
// `interval` events, fire-and-forget. Snapshots never affect correctness — the
// OCC append is the only consistency primitive — so a drifted/absent snapshot
// degrades to full replay.
//
// The mock EventLog enforces OCC (append conflicts unless seqNr matches the
// stored count) AND records snapshot reads/writes and replay `fromSeq` offsets,
// so the tests can assert both the delta-read behavior and the "disabled ⇒ zero
// snapshot traffic" requirement.

open JestGlobals


module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "SnapshotTestAggregate"

  @schema
  type command = Add({item: string}) | Noop

  @schema
  type event = Added({item: string})

  @schema
  type error = | Never

  let moduleUrl: string = %raw(`import.meta.url`)
}

module TestBehavior = {
  module Spec = AggSpec

  @schema
  type state = {items: array<string>}

  let initialState = {items: []}

  // Snapshot every 10 events.
  let snapshot = Some({
    Reventless.Snapshot.interval: 10,
    stateSchema,
  })

  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (state: state, event: AggSpec.event): state =>
    switch event {
    | Added({item}) => {items: state.items->Array.concat([item])}
    }

  let decide = (_state: state, command: AggSpec.command): result<
    array<AggSpec.event>,
    AggSpec.error,
  > =>
    switch command {
    | Add({item}) => Ok([AggSpec.Added({item: item})])
    | Noop => Ok([])
    }
}

let testMeta: Message.meta = {
  service: "SnapshotTestAggregate",
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
  replayStreamFn: (string, ~fromSeq: int=?) => Stream.t<AggSpec.event, string, unit>,
  latestSnapshotFn: string => promise<result<option<EventLog.snapshot>, string>>,
  writeSnapshotFn: (string, EventLog.snapshot) => promise<result<unit, string>>,
  getAll: unit => array<Message.event'<string, AggSpec.event>>,
  getSnapshot: string => option<EventLog.snapshot>,
  setSnapshot: (string, EventLog.snapshot) => unit,
  replayCallCount: ref<int>,
  lastReplayFromSeq: ref<int>,
  snapshotReadCount: ref<int>,
  snapshotWriteCount: ref<int>,
  failNextWrite: ref<bool>,
  reset: unit => unit,
}

let makeMockEL = (): mockEL => {
  let stored: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
  let snapshots: dict<EventLog.snapshot> = Dict.make()
  let replayCount = ref(0)
  let lastFromSeq = ref(-1)
  let snapReads = ref(0)
  let snapWrites = ref(0)
  let failWrite = ref(false)

  let eventsFor = id => stored.contents->Array.filter(e => e.id == id)

  let appendFn = async (seqNr, id, newEvents) =>
    if seqNr != eventsFor(id)->Array.length {
      Error(EventLog.Conflict)
    } else {
      stored := stored.contents->Array.concat(newEvents)
      Ok()
    }

  let replayStreamFn = (id, ~fromSeq=0) => {
    replayCount := replayCount.contents + 1
    lastFromSeq := fromSeq
    eventsFor(id)
    ->Array.map(e => e.event)
    ->Array.filterWithIndex((_, i) => i >= fromSeq)
    ->Stream.fromIterable
  }

  let latestSnapshotFn = async id => {
    snapReads := snapReads.contents + 1
    Ok(snapshots->Dict.get(id))
  }

  let writeSnapshotFn = async (id, snap) =>
    if failWrite.contents {
      failWrite := false
      Error("mock write failure")
    } else {
      snapWrites := snapWrites.contents + 1
      snapshots->Dict.set(id, snap)
      Ok()
    }

  {
    appendFn,
    replayStreamFn,
    latestSnapshotFn,
    writeSnapshotFn,
    getAll: () => stored.contents,
    getSnapshot: id => snapshots->Dict.get(id),
    setSnapshot: (id, snap) => snapshots->Dict.set(id, snap),
    replayCallCount: replayCount,
    lastReplayFromSeq: lastFromSeq,
    snapshotReadCount: snapReads,
    snapshotWriteCount: snapWrites,
    failNextWrite: failWrite,
    reset: () => {
      stored := []
      snapshots->Dict.forEachWithKey((_, k) => snapshots->Dict.delete(k))
      replayCount := 0
      lastFromSeq := -1
      snapReads := 0
      snapWrites := 0
      failWrite := false
    },
  }
}

let mock = makeMockEL()

module OuterEventLog = EventLog

module MakeOps = (B: {let name: string}) => {
  module Spec = AggSpec
  module EventLog = {
    module Spec = {
      module Id = AggSpec.Id
      let name = B.name
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
    let make = (~name as _: string, ~owner as _=?, ~opts as _=?): component => Obj.magic(0)
  }
  let eventLog: EventLog.operations = {
    append: mock.appendFn,
    replay: async id => await mock.replayStreamFn(id)->Stream.runCollect->Effect.runPromise,
    replayStream: mock.replayStreamFn,
    appendStream: (_startingSeqNr, _id, stream) => stream->Stream.runDrain,
    latestSnapshot: mock.latestSnapshotFn,
    writeSnapshot: mock.writeSnapshotFn,
  }
}

module TestOps = MakeOps({let name = "SnapshotMockEventLog"})
module TestHandler = Aggregate_Callback.Make(AggSpec, TestBehavior, TestOps)

// A second behavior with snapshots DISABLED, sharing the same mock, to prove
// disabled aggregates do zero snapshot traffic.
module PlainBehavior = {
  module Spec = AggSpec

  @schema
  type state = {items: array<string>}

  let initialState = {items: []}
  let snapshot = None
  let moduleUrl: string = %raw(`import.meta.url`)

  let evolve = (state: state, event: AggSpec.event): state =>
    switch event {
    | Added({item}) => {items: state.items->Array.concat([item])}
    }
  let decide = (_state, command: AggSpec.command) =>
    switch command {
    | Add({item}) => Ok([AggSpec.Added({item: item})])
    | Noop => Ok([])
    }
}

module PlainOps = MakeOps({let name = "PlainMockEventLog"})
module PlainHandler = Aggregate_Callback.Make(AggSpec, PlainBehavior, PlainOps)

let makeItem = (~id="agg-1", reference, command): CommandTopic.topicItem<
  Message.command'<string, AggSpec.command>,
> => {
  command: {id, meta: testMeta, command},
  reference,
}

let run = async (~handler, ~id="agg-1", command) =>
  await Stream.fromIterable([makeItem(~id, "ref", command)])
  ->handler
  ->Effect.runPromise

// A microtask tick so fire-and-forget snapshot writes settle before assertions.
let tick = () => Promise.resolve()->Promise.then(_ => Promise.resolve())

let _ = beforeEach(() => {
  mock.reset()
  TestHandler.resetCache()
  PlainHandler.resetCache()
})

describe("Aggregate_Callback — snapshots:", () => {
  testPromise("writes a snapshot each time an interval boundary is crossed", async () => {
    // 25 single-event commands → boundaries at 10 and 20 (not 25).
    for i in 1 to 25 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `i${i->Int.toString}`}))
    }
    let _ = await tick()
    expect(mock.snapshotWriteCount.contents)->toBe(2)
    // Keep-one: the surviving snapshot is the latest boundary (seq 20).
    switch mock.getSnapshot("agg-1") {
    | Some(snap) => expect(snap.seqNr)->toBe(20)
    | None => expect("expected a snapshot")->toBe("none")
    }
  })

  testPromise("cold replay seeds from the snapshot and reads only the delta", async () => {
    for i in 1 to 12 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `i${i->Int.toString}`}))
    }
    let _ = await tick()
    // A snapshot exists at seq 10. Evict the in-process cache to force a cold read.
    TestHandler.resetCache()
    mock.replayCallCount := 0
    let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: "i13"}))
    // Cold read consulted the snapshot and replayed only events 10..12 (delta).
    expect(mock.snapshotReadCount.contents >= 1)->toBe(true)
    expect(mock.lastReplayFromSeq.contents)->toBe(10)
    // Correct final state: 13 events appended in total.
    expect(mock.getAll()->Array.length)->toBe(13)
  })

  testPromise("state seeded from snapshot equals a full-replay fold", async () => {
    for i in 1 to 15 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `x${i->Int.toString}`}))
    }
    let _ = await tick()
    // Snapshot-seeded cold read (snapshot at seq 10, delta 10..15).
    TestHandler.resetCache()
    let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Noop)
    let seededSnap = mock.getSnapshot("agg-1")
    // Force a boundary to capture the seeded state as a fresh snapshot: add up to
    // seq 20 and compare its item count to the true event count.
    for i in 16 to 20 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `x${i->Int.toString}`}))
    }
    let _ = await tick()
    switch mock.getSnapshot("agg-1") {
    | Some(snap) =>
      expect(snap.seqNr)->toBe(20)
      // 20 items folded through the seeded state — no double-count, no gap.
      let decoded = snap.state->Reventless.Util_Sury.fromJson(TestBehavior.stateSchema)
      expect(decoded.items->Array.length)->toBe(20)
    | None => expect("expected snapshot at 20")->toBe("none")
    }
    // sanity: the earlier seeded snapshot was the seq-10 one
    switch seededSnap {
    | Some(s) => expect(s.seqNr)->toBe(10)
    | None => expect("expected seeded snapshot")->toBe("none")
    }
  })

  testPromise("schema-drift snapshot is ignored → full replay from 0", async () => {
    for i in 1 to 12 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `i${i->Int.toString}`}))
    }
    let _ = await tick()
    // Corrupt the stored snapshot's hash to simulate a state-shape change.
    switch mock.getSnapshot("agg-1") {
    | Some(snap) => mock.setSnapshot("agg-1", {...snap, schemaHash: "STALE-HASH"})
    | None => ()
    }
    TestHandler.resetCache()
    mock.replayCallCount := 0
    let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Noop)
    // Drifted hash → seed discarded → full replay from seq 0.
    expect(mock.lastReplayFromSeq.contents)->toBe(0)
  })

  testPromise("snapshot write failure does not fail the command", async () => {
    for i in 1 to 9 {
      let _ = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: `i${i->Int.toString}`}))
    }
    // The 10th append crosses the boundary; make its snapshot write fail.
    mock.failNextWrite := true
    let result = await run(~handler=TestHandler.handleCommands, AggSpec.Add({item: "i10"}))
    let _ = await tick()
    // Command still succeeds; the event is persisted.
    expect(result)->toEqual([Ok("ref")])
    expect(mock.getAll()->Array.length)->toBe(10)
    // The failed write left no snapshot behind.
    expect(mock.getSnapshot("agg-1"))->toEqual(None)
  })

  testPromise("disabled aggregate does zero snapshot reads and writes", async () => {
    for i in 1 to 12 {
      let _ = await run(~handler=PlainHandler.handleCommands, AggSpec.Add({item: `i${i->Int.toString}`}))
    }
    let _ = await tick()
    PlainHandler.resetCache()
    let _ = await run(~handler=PlainHandler.handleCommands, AggSpec.Noop)
    expect((mock.snapshotReadCount.contents, mock.snapshotWriteCount.contents))->toEqual((0, 0))
    // And a cold read always replays from 0 (no snapshot seeding).
    expect(mock.lastReplayFromSeq.contents)->toBe(0)
  })
})
