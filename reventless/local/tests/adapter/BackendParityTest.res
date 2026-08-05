// Behavioural parity between Memory, Sqlite, and Postgres backends at the adapter
// layer. Each test runs the same scenario against every BackendState setting.
//
// The Postgres arm is exercised only when PG_URL is set (so the default test run
// stays dependency-free), and only for EventLog scenarios: under Backend.Postgres
// the read-model (QueryDb) path routes to the in-memory arm by design (the sync
// LocalBus registrations can't consume async pg — see LocalQueryDbStorage), so a
// QueryDb "runUnderPostgres" would just re-test Memory. Event logs, however, are
// genuinely Postgres-backed and must match Memory/Sqlite exactly.

open JestGlobals


let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let pgPool =
  NodeProcess.env
  ->Dict.get("PG_URL")
  ->Option.map(url => ReventlessPostgres.PgDriver.makePool({connectionString: url}))

afterAll(() =>
  switch pgPool {
  | Some(pool) => ignore(pool->ReventlessPostgres.PgDriver.endPool)
  | None => ()
  }
)

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

// No-op when PG_URL is unset. Resets the schema before each scenario for isolation.
let runUnderPostgres = async fn =>
  switch pgPool {
  | Some(pool) =>
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    await ReventlessPostgres.PgSchema.truncateAll(pool)
    BackendState.setPostgres(~pool)
    await fn()
    BackendState.setMemory()
  | None => ()
  }

describe("Backend parity (Memory vs Sqlite)", () => {
  testPromise("EventLog: append + replay returns the same events under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalEventLogStorage.Make(TestBus)
      let s = Storage.make(~name="parity-events", ~owner=None, ~opts)
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
    await runUnderPostgres(scenario)
  })

  testPromise("QueryDb: save + loadStream returns the same item under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-qdb", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
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
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-count", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
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

  testPromise("QueryDb: an expired-TTL item is filtered from loadStream under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-ttl", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      let item = k => JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string(k))]))
      let readCount = async k =>
        (
          await ops.loadStream(k)
          ->Stream.runCollect
          ->Effect.catchAll(_ => Effect.succeed([]))
          ->Effect.runPromise
        )->Array.length

      // A live item (no TTL) and one whose absolute expiry (epoch second 1) is
      // long past — the expired one must not surface under either backend.
      let _ = await ops.save("live", item("live"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("dead", item("dead"), ReventlessCore.QueryDb.Any, Some(1))

      expect(await readCount("live"))->toBe(1)
      expect(await readCount("dead"))->toBe(0)
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: a first save is Added and a second is Updated under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-kind", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      let kinds = []
      TestBus.subscribeToStateChanges("parity-kind", descriptor =>
        descriptor
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("changeKind"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.forEach(k => kinds->Array.push(k))
      )

      let item = (k, v) =>
        JSON.Encode.object(
          Dict.fromArray([("id", JSON.Encode.string(k)), ("v", JSON.Encode.string(v))]),
        )

      // The distinction a list view depends on: a row it has never seen arrives
      // as Added (and is inserted), a row it holds arrives as Updated.
      let _ = await ops.save("p1", item("p1", "one"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("p1", item("p1", "two"), ReventlessCore.QueryDb.Any, None)
      // A distinct key is its own first insert, not an update of the store.
      let _ = await ops.save("p2", item("p2", "one"), ReventlessCore.QueryDb.Any, None)
      // Deleting frees the key, so saving it again is an insert once more.
      let _ = await ops.delete("p1", None)
      let _ = await ops.save("p1", item("p1", "three"), ReventlessCore.QueryDb.Any, None)

      expect(kinds)->toEqual(["Added", "Updated", "Added", "Removed", "Added"])
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: a descriptor carries the saved row and a rising seq under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(
        ~name="parity-payload",
        ~indexes=[],
        ~api=(),
        ~apiRole=(),
        ~owner=None,
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let descriptors = []
      TestBus.subscribeToStateChanges("parity-payload", d => descriptors->Array.push(d))

      let field = (d, key) => d->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
      let item = (k, v) =>
        JSON.Encode.object(
          Dict.fromArray([("id", JSON.Encode.string(k)), ("v", JSON.Encode.string(v))]),
        )
      let stateAt = i => descriptors->Array.get(i)->Option.flatMap(d => field(d, "state"))

      let _ = await ops.save("p1", item("p1", "one"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("p1", item("p1", "two"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.delete("p1", None)

      // The point of the payload: a subscriber can apply the row it was handed
      // instead of spending a round-trip to fetch what the platform already had.
      expect(stateAt(0))->toEqual(Some(item("p1", "one")))
      expect(stateAt(1))->toEqual(Some(item("p1", "two")))
      // A delete has no new row to carry.
      expect(stateAt(2))->toEqual(None)

      // seq only has to rise — it is monotonic, not consecutive, so a client can
      // reject a stale payload but cannot count gaps.
      let seqs =
        descriptors->Array.filterMap(d =>
          field(d, "seq")->Option.flatMap(JSON.Decode.string)->Option.flatMap(Float.fromString)
        )
      expect(seqs->Array.length)->toBe(3)
      let rising =
        seqs->Array.everyWithIndex((v, i) => i == 0 || v > seqs->Array.getUnsafe(i - 1))
      expect(rising)->toBe(true)
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: saveBatch reports Added then Updated for a repeated key under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-batch", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      let kinds = []
      TestBus.subscribeToStateChanges("parity-batch", descriptor =>
        descriptor
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("changeKind"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.forEach(k => kinds->Array.push(k))
      )

      let item = k => JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.string(k))]))
      let _ = await ops.saveBatch([
        ("a", item("a"), None),
        ("b", item("b"), None),
        ("a", item("a"), None),
      ])

      expect(kinds)->toEqual(["Added", "Added", "Updated"])
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("QueryDb: a counter's first increment is Added under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalQueryDbStorage.Make(TestBus)
      let s = Storage.make(~name="parity-ckind", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      let kinds = []
      TestBus.subscribeToStateChanges("parity-ckind", descriptor =>
        descriptor
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("changeKind"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.forEach(k => kinds->Array.push(k))
      )

      let _ = await ops.count("prod-1", "orderCount", 1)
      let _ = await ops.count("prod-1", "orderCount", 1)

      expect(kinds)->toEqual(["Added", "Updated"])
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
  })

  testPromise("EventLog: conflict detection works under both", async () => {
    let scenario = async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalEventLogStorage.Make(TestBus)
      let s = Storage.make(~name="parity-conflict", ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      let e = JSON.Encode.object(Dict.fromArray([("t", JSON.Encode.string("C"))]))
      let _ = await ops.append(0, "cid", [e])

      // Reusing seqNr=0 must conflict under every backend.
      let result = await ops.append(0, "cid", [e])
      switch result {
      | Error(_) => expect(true)->toBe(true)
      | Ok() => expect("expected conflict")->toBe("actual Ok")
      }
    }

    await runUnderMemory(scenario)
    await runUnderSqlite(scenario)
    await runUnderPostgres(scenario)
  })
})
