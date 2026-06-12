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

    // Caller re-uses seqNr=0 — conflict.
    let result = await ops.append(0, "id-c", [e])
    switch result {
    | Error(_) => expect(true)->toBe(true)
    | Ok() => expect("expected conflict")->toBe("actual Ok")
    }
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
