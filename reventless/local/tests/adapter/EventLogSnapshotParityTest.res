// Backend-parity tests for the EventLog snapshot ops
// (docs/plans/aggregate-snapshotting.md): the in-memory and SQLite backends
// must behave identically for latestSnapshot / writeSnapshot (keep-one) and
// the replayStream ~fromSeq delta read, so GWT/local tests of
// snapshot-enabled aggregates give the same results under either backend.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let makeMemoryOps = () => {
  let s = EventLogStorage_InMemory.make(~name="parity", ~owner=None, ~opts)
  s.operations->TestRunner.resolve
}

let makeSqliteOps = () => {
  module TestBus = LocalBus.Make()
  module DbProvider = {
    let db = SqliteDriver.openDb(~path=":memory:")
  }
  module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
  let s = Storage.make(~name="parity", ~owner=None, ~opts)
  s.operations->TestRunner.resolve
}

let backends = [("memory", makeMemoryOps), ("sqlite", makeSqliteOps)]

describe("EventLog snapshot backend parity", () => {
  backends->Array.forEach(((label, makeOps)) => {
    testPromise(`${label}: latestSnapshot is None before any write`, async () => {
      let ops = await makeOps()
      expect(await ops.latestSnapshot("id-1"))->toEqual(Ok(None))
    })

    testPromise(`${label}: snapshot round-trips and keep-one overwrites`, async () => {
      let ops = await makeOps()
      let state = JSON.Encode.object(Dict.fromArray([("n", JSON.Encode.int(1))]))
      expect(
        await ops.writeSnapshot(
          "id-1",
          {ReventlessCore.EventLog.seqNr: 2, state, schemaHash: "h1"},
        ),
      )->toEqual(Ok())
      expect(await ops.latestSnapshot("id-1"))->toEqual(
        Ok(Some({ReventlessCore.EventLog.seqNr: 2, state, schemaHash: "h1"})),
      )
      let state2 = JSON.Encode.object(Dict.fromArray([("n", JSON.Encode.int(9))]))
      let _ = await ops.writeSnapshot(
        "id-1",
        {ReventlessCore.EventLog.seqNr: 9, state: state2, schemaHash: "h2"},
      )
      expect(await ops.latestSnapshot("id-1"))->toEqual(
        Ok(Some({ReventlessCore.EventLog.seqNr: 9, state: state2, schemaHash: "h2"})),
      )
    })

    testPromise(`${label}: snapshots are per-aggregate-id`, async () => {
      let ops = await makeOps()
      let state = JSON.Encode.object(Dict.fromArray([("n", JSON.Encode.int(1))]))
      let _ = await ops.writeSnapshot(
        "id-a",
        {ReventlessCore.EventLog.seqNr: 1, state, schemaHash: "h"},
      )
      expect(await ops.latestSnapshot("id-b"))->toEqual(Ok(None))
    })

    testPromise(`${label}: replayStream ~fromSeq equals the tail of a full replay`, async () => {
      let ops = await makeOps()
      let ev = i => JSON.Encode.object(Dict.fromArray([("i", JSON.Encode.int(i))]))
      let _ = await ops.append(0, "id-1", [ev(0), ev(1), ev(2), ev(3), ev(4)])
      let delta = await ops.replayStream("id-1", ~fromSeq=3)->Stream.runCollect->Effect.runPromise
      expect(delta)->toEqual([ev(3), ev(4)])
      // fromSeq at the head yields nothing; omitted fromSeq yields everything.
      let empty = await ops.replayStream("id-1", ~fromSeq=5)->Stream.runCollect->Effect.runPromise
      expect(empty)->toEqual([])
      let full = await ops.replayStream("id-1")->Stream.runCollect->Effect.runPromise
      expect(full->Array.length)->toBe(5)
    })
  })
})
