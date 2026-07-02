// Behavioural parity between Memory and Sqlite backends at the adapter layer.
// Each test runs the same scenario against both BackendState settings.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let runUnderMemory = async fn => {
  BackendState.setMemory()
  await fn()
}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

describe("Backend parity (Memory vs Sqlite)", () => {
  testPromise("EventLog: append + replay returns the same events under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = EventLogStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="parity-events", ~opts)
      let ops = await s.operations->TestRunner.resolve

      let e1 = JSON.Encode.object(Dict.fromArray([("t", JSON.Encode.string("A"))]))
      let e2 = JSON.Encode.object(Dict.fromArray([("t", JSON.Encode.string("B"))]))

      let _ = await ops.append(0, "id-x", [e1])
      let _ = await ops.append(1, "id-x", [e2])

      let replayed = await ops.replay("id-x")
      expect(replayed->Array.length)->toBe(2)
      expect(replayed->Array.getUnsafe(0))->toEqual(e1)
      expect(replayed->Array.getUnsafe(1))->toEqual(e2)
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: save + loadStream returns the same item under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="parity-qdb", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve

      let _ = await ops.save(
        "k",
        JSON.Encode.string("val"),
        ReventlessCore.QueryDb.Any,
        None,
      )

      let items =
        await ops.loadStream("k")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(1)
      expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("val"))
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: count returns a running total and loadStream reflects it under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="parity-count", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve

      // First increment creates the counter item and returns the new total.
      let r1 = await ops.count("prod-1", "orderCount", 3)
      expect(r1)->toEqual(Ok(3))
      // Second increment accumulates (not just echoes the increment).
      let r2 = await ops.count("prod-1", "orderCount", 2)
      expect(r2)->toEqual(Ok(5))

      // loadStream must see the persisted counter — count is not a side channel.
      let items =
        await ops.loadStream("prod-1")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(1)
      let field =
        items
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("orderCount"))
        ->Option.flatMap(JSON.Decode.float)
        ->Option.mapOr(0, Float.toInt)
      expect(field)->toBe(5)
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("EventLog: conflict detection works under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = EventLogStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="parity-conflict", ~opts)
      let ops = await s.operations->TestRunner.resolve

      let e = JSON.Encode.object(Dict.fromArray([("t", JSON.Encode.string("C"))]))
      let _ = await ops.append(0, "cid", [e])

      // Reusing seqNr=0 must conflict under both backends.
      let result = await ops.append(0, "cid", [e])
      switch result {
      | Error(_) => expect(true)->toBe(true)
      | Ok() => expect("expected conflict")->toBe("actual Ok")
      }
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })
})
