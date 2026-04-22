// Round-trip test for QueryDbStorage_Sqlite.

open AsyncTest
open AsyncTest.Expect

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let makeFreshDb = () => SqliteDriver.openDb(~path=":memory:")

describe("QueryDbStorage_Sqlite", () => {
  testPromise("save then loadStream round-trips an item", async () => {
    module TestBus = InMemory_Bus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rm1", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.save(
      "id1",
      JSON.Encode.string("value1"),
      ReventlessCore.QueryDb.Any,
      None,
    )

    let items =
      await ops.loadStream("id1")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise

    expect(items->Array.length)->toBe(1)
    expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("value1"))
  })

  testPromise("save overwrites existing item at same (id, subKey)", async () => {
    module TestBus = InMemory_Bus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rm2", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.save("k", JSON.Encode.string("a"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k", JSON.Encode.string("b"), ReventlessCore.QueryDb.Any, None)

    let items =
      await ops.loadStream("k")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise

    expect(items->Array.length)->toBe(1)
    expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("b"))
  })

  testPromise("saveBatch atomically writes several items", async () => {
    module TestBus = InMemory_Bus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rm3", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.saveBatch([
      ("id1", JSON.Encode.string("one"), None),
      ("id2", JSON.Encode.string("two"), None),
      ("id3", JSON.Encode.string("three"), None),
    ])

    let items1 =
      await ops.loadStream("id1")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    let items2 =
      await ops.loadStream("id2")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    let items3 =
      await ops.loadStream("id3")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise

    expect(items1->Array.length)->toBe(1)
    expect(items2->Array.length)->toBe(1)
    expect(items3->Array.length)->toBe(1)
  })

  testPromise("delete removes an item from a partition", async () => {
    module TestBus = InMemory_Bus.Make()
    module DbProvider = {
      let db = makeFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rm4", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.save("k", JSON.Encode.string("a"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.delete("k", None)

    let items =
      await ops.loadStream("k")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise

    expect(items->Array.length)->toBe(0)
  })

  testPromise("items persist across a file reopen", async () => {
    let path = `/tmp/reventless-test-qdb-${Float.toString(Date.now())}.db`

    // Session 1: write
    {
      module TestBus = InMemory_Bus.Make()
      module DbProvider = {
        let db = SqliteDriver.openDb(~path)
      }
      module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
      let s = Storage.make(~name="persist", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save(
        "k",
        JSON.Encode.string("hello"),
        ReventlessCore.QueryDb.Any,
        None,
      )
      DbProvider.db->SqliteDriver.close
    }

    // Session 2: read back
    module TestBus2 = InMemory_Bus.Make()
    module DbProvider2 = {
      let db = SqliteDriver.openDb(~path)
    }
    module Storage2 = QueryDbStorage_Sqlite.Make(TestBus2, DbProvider2)
    let s2 = Storage2.make(~name="persist", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
    let ops2 = await s2.operations->TestRunner.resolve
    let items =
      await ops2.loadStream("k")
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise

    expect(items->Array.length)->toBe(1)
    expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("hello"))
    DbProvider2.db->SqliteDriver.close
  })
})
