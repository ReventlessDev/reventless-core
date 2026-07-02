// Round-trip test for EventLogStorage_Sqlite.
// Mirrors the shape of the Memory variant but uses an in-memory SQLite database.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let makeFreshDb = () => SqliteDriver.openDb(~path=":memory:")

describe("EventLogStorage_Sqlite", () => {
  testPromise("append + replay round-trips events in order", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="agg", ~opts)
    let ops = await s.operations->TestRunner.resolve

    let event1 = JSON.Encode.object(
      Dict.fromArray([("tag", JSON.Encode.string("Created"))]),
    )
    let event2 = JSON.Encode.object(
      Dict.fromArray([("tag", JSON.Encode.string("Renamed"))]),
    )

    let r1 = await ops.append(0, "id-1", [event1])
    expect(r1)->toEqual(Ok())

    let r2 = await ops.append(1, "id-1", [event2])
    expect(r2)->toEqual(Ok())

    let replayed = await ops.replay("id-1")
    expect(replayed->Array.length)->toBe(2)
    expect(replayed->Array.getUnsafe(0))->toEqual(event1)
    expect(replayed->Array.getUnsafe(1))->toEqual(event2)
  })

  testPromise("append detects concurrency conflicts via PK collision", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="agg", ~opts)
    let ops = await s.operations->TestRunner.resolve

    let e = JSON.Encode.object(Dict.fromArray([("t", JSON.Encode.string("X"))]))
    let _ = await ops.append(0, "id-c", [e])

    // Caller re-uses seqNr=0 — a genuine conflict must be the typed Conflict
    // sentinel (not a StorageFailure), so the core retry loop treats it as OCC.
    let result = await ops.append(0, "id-c", [e])
    switch result {
    | Error(ReventlessCore.EventLog.Conflict) => expect(true)->toBe(true)
    | Error(StorageFailure(msg)) => expect("expected Conflict, got StorageFailure")->toBe(msg)
    | Ok() => expect("expected conflict")->toBe("actual Ok")
    }
  })

  testPromise("multi-event append advances the expected seq via MAX(seq_nr)+1", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
    let s = Storage.make(~name="agg", ~opts)
    let ops = await s.operations->TestRunner.resolve

    let ev = i => JSON.Encode.object(Dict.fromArray([("i", JSON.Encode.int(i))]))
    // Batch of three at seq 0 → occupies seq 0,1,2.
    let r1 = await ops.append(0, "id-m", [ev(0), ev(1), ev(2)])
    expect(r1)->toEqual(Ok())
    // A stale seq (2) is a conflict; the correct next seq is 3.
    let stale = await ops.append(2, "id-m", [ev(9)])
    switch stale {
    | Error(ReventlessCore.EventLog.Conflict) => expect(true)->toBe(true)
    | _ => expect("expected Conflict")->toBe("other")
    }
    let r2 = await ops.append(3, "id-m", [ev(3)])
    expect(r2)->toEqual(Ok())
    let replayed = await ops.replay("id-m")
    expect(replayed->Array.length)->toBe(4)
  })

  testPromise("appendStream persists the whole batch in order from the starting seq", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
    let s = Storage.make(~name="agg", ~opts)
    let ops = await s.operations->TestRunner.resolve

    let ev = i => JSON.Encode.object(Dict.fromArray([("i", JSON.Encode.int(i))]))
    // Seed one event, then stream three more starting at seq 1.
    let _ = await ops.append(0, "id-s", [ev(0)])
    let _ =
      await ops.appendStream(1, "id-s", Stream.fromIterable([ev(1), ev(2), ev(3)]))
      ->Effect.runPromise
    let replayed = await ops.replay("id-s")
    expect(replayed->Array.length)->toBe(4)
    expect(replayed->Array.getUnsafe(0))->toEqual(ev(0))
    expect(replayed->Array.getUnsafe(3))->toEqual(ev(3))
  })

  testPromise("replay returns empty array for unknown id", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="agg", ~opts)
    let ops = await s.operations->TestRunner.resolve

    let replayed = await ops.replay("not-there")
    expect(replayed->Array.length)->toBe(0)
  })

  testPromise("events persist across a reopen of the database file", async () => {
    let path = `/tmp/reventless-test-eventlog-${Float.toString(Date.now())}.db`

    // Session 1: write
    {
      module TestBus = LocalBus.Make()
      module DbProvider = {
        let db = SqliteDriver.openDb(~path)
      }
      module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
      let s = Storage.make(~name="persist", ~opts)
      let ops = await s.operations->TestRunner.resolve
      let ev = JSON.Encode.object(Dict.fromArray([("v", JSON.Encode.int(42))]))
      let _ = await ops.append(0, "id-p", [ev])
      DbProvider.db->SqliteDriver.close
    }

    // Session 2: read back
    module TestBus2 = LocalBus.Make()
    module DbProvider2 = {
      let db = SqliteDriver.openDb(~path)
    }
    module Storage2 = EventLogStorage_Sqlite.Make(TestBus2, DbProvider2)
    let s2 = Storage2.make(~name="persist", ~opts)
    let ops2 = await s2.operations->TestRunner.resolve
    let replayed = await ops2.replay("id-p")
    expect(replayed->Array.length)->toBe(1)
    DbProvider2.db->SqliteDriver.close
  })
})
