// Phase 5 — GSI fidelity (CREATE INDEX statements) and TTL filtering
// for QueryDbStorage_Sqlite.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let openFreshDb = () => SqliteDriver.openDb(~path=":memory:")

let collect = stream =>
  stream
  ->Stream.runCollect
  ->Effect.catchAll(_ => Effect.succeed([]))
  ->Effect.runPromise

describe("QueryDbStorage_Sqlite — GSI", () => {
  testPromise("declared indexes produce CREATE INDEX statements", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let byOwnerIdx: Reventless.ReadModel.indexConfig = {
      index: "ByOwner",
      type_: "S",
      idField: "ownerId",
      projectionType: ALL,
    }
    let byOwnerCreatedIdx: Reventless.ReadModel.indexConfig = {
      index: "ByOwnerCreated",
      type_: "S",
      idField: "ownerId",
      subIdField: "createdAt",
      projectionType: KEYS_ONLY,
    }

    let _ = Storage.make(
      ~name="orders",
      ~indexes=[byOwnerIdx, byOwnerCreatedIdx],
      ~api=(),
      ~apiRole=(),
      ~owner=None, ~opts,
    )

    // Verify the indexes were created in sqlite_master.
    let listIndexes = DbProvider.db->SqliteDriver.prepare(
      "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='qdb_orders' ORDER BY name",
    )
    let rows = listIndexes->SqliteDriver.all([])
    let names = rows->Array.map(row =>
      switch row->Dict.get("name") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    )
    expect(names->Array.includes("idx_qdb_orders_ByOwner"))->toBe(true)
    expect(names->Array.includes("idx_qdb_orders_ByOwnerCreated"))->toBe(true)

    // Confirm the index definition references json_extract on the configured field.
    let firstSql = switch rows->Array.find(row =>
      switch row->Dict.get("name") {
      | Some(JSON.String(s)) => s == "idx_qdb_orders_ByOwner"
      | _ => false
      }
    ) {
    | Some(row) =>
      switch row->Dict.get("sql") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    | None => ""
    }
    expect(firstSql->String.includes("json_extract(item, '$.ownerId')"))->toBe(true)
  })

  testPromise("composite-key indexes use pk/sk concatenation expressions", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let compositeIdx: Reventless.ReadModel.indexConfig = {
      index: "ByTenantOwner",
      type_: "S",
      pkFields: ["tenantId", "ownerId"],
      pkSep: "|",
      projectionType: ALL,
    }

    let _ = Storage.make(
      ~name="composite",
      ~indexes=[compositeIdx],
      ~api=(),
      ~apiRole=(),
      ~owner=None, ~opts,
    )

    let listSql = DbProvider.db->SqliteDriver.prepare(
      "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_qdb_composite_ByTenantOwner'",
    )
    let row = listSql->SqliteDriver.get([])->Option.getOrThrow
    let sql = switch row->Dict.get("sql") {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
    expect(
      sql->String.includes("json_extract(item, '$.tenantId') || '|' || json_extract(item, '$.ownerId')"),
    )->toBe(true)
  })

  testPromise("index name is sanitised — special characters in index name become underscores", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let weirdIdx: Reventless.ReadModel.indexConfig = {
      index: "by-thing.v2",
      type_: "S",
      idField: "thing",
      projectionType: ALL,
    }
    let _ = Storage.make(
      ~name="rm",
      ~indexes=[weirdIdx],
      ~api=(),
      ~apiRole=(),
      ~owner=None, ~opts,
    )
    let listIndexes = DbProvider.db->SqliteDriver.prepare(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='qdb_rm'",
    )
    let names =
      listIndexes
      ->SqliteDriver.all([])
      ->Array.map(row =>
        switch row->Dict.get("name") {
        | Some(JSON.String(s)) => s
        | _ => ""
        }
      )
    expect(names->Array.includes("idx_qdb_rm_by_thing_v2"))->toBe(true)
  })
})

describe("QueryDb — indexed equality lookup (B4 push-down)", () => {
  let byOwner: Reventless.ReadModel.indexConfig = {
    index: "ByOwner",
    type_: "S",
    idField: "ownerId",
    projectionType: ALL,
  }
  let item = (owner: string) => {
    let o = Dict.make()
    o->Dict.set("ownerId", JSON.Encode.string(owner))
    JSON.Encode.object(o)
  }

  testPromise("sqlite lookup returns only rows whose indexed field matches", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
    let s = Storage.make(~name="orders", ~indexes=[byOwner], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve
    let _ = await ops.save("k1", item("o1"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k2", item("o2"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k3", item("o1"), ReventlessCore.QueryDb.Any, None)

    let lookup = TestBus.getQueryDbIndexLookup("orders")->Option.getOrThrow
    expect(lookup("ownerId", "o1")->Array.length)->toBe(2)
    expect(lookup("ownerId", "o2")->Array.length)->toBe(1)
    expect(lookup("ownerId", "absent")->Array.length)->toBe(0)
  })

  testPromise("sqlite lookup excludes expired rows", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)
    let s = Storage.make(~name="orders", ~indexes=[byOwner], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve
    let aMinuteAgo = Float.toInt(Date.now() /. 1000.0) - 60
    let _ = await ops.save("k1", item("o1"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k2", item("o1"), ReventlessCore.QueryDb.Any, Some(aMinuteAgo))
    let lookup = TestBus.getQueryDbIndexLookup("orders")->Option.getOrThrow
    expect(lookup("ownerId", "o1")->Array.length)->toBe(1)
  })

  testPromise("in-memory lookup matches the sqlite result (backend parity)", async () => {
    module TestBus = LocalBus.Make()
    module Storage = QueryDbStorage_InMemory.Make(TestBus)
    let s = Storage.make(~name="orders", ~indexes=[byOwner], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve
    let _ = await ops.save("k1", item("o1"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k2", item("o2"), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.save("k3", item("o1"), ReventlessCore.QueryDb.Any, None)
    let lookup = TestBus.getQueryDbIndexLookup("orders")->Option.getOrThrow
    expect(lookup("ownerId", "o1")->Array.length)->toBe(2)
    expect(lookup("ownerId", "o2")->Array.length)->toBe(1)
    expect(lookup("ownerId", "absent")->Array.length)->toBe(0)
  })
})

describe("QueryDbStorage_InMemory — lazy scan snapshot (B4 dirty-flag)", () => {
  testPromise("interleaved save/scan reflects each write without stale reads", async () => {
    module TestBus = LocalBus.Make()
    module Storage = LocalQueryDbStorage.Make(TestBus)
    let s = Storage.make(~name="lazy", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve
    let scanFn = TestBus.getQueryDbScan("lazy")->Option.getOrThrow
    expect(scanFn()->Array.length)->toBe(0)
    let _ = await ops.save("a", JSON.Encode.string("va"), ReventlessCore.QueryDb.Any, None)
    expect(scanFn()->Array.length)->toBe(1)
    let _ = await ops.save("b", JSON.Encode.string("vb"), ReventlessCore.QueryDb.Any, None)
    expect(scanFn()->Array.length)->toBe(2)
    let _ = await ops.delete("a", None)
    expect(scanFn()->Array.length)->toBe(1)
  })
})

describe("QueryDbStorage_Sqlite — TTL", () => {
  testPromise("save with TTL in the future returns the item", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rt-future", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve

    let oneHourFromNow = Float.toInt(Date.now() /. 1000.0) + 3600
    let _ = await ops.save(
      "k",
      JSON.Encode.string("alive"),
      ReventlessCore.QueryDb.Any,
      Some(oneHourFromNow),
    )

    let items = await ops.loadStream("k")->collect
    expect(items->Array.length)->toBe(1)
  })

  testPromise("save with TTL already in the past hides the item from reads", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rt-past", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve

    let aMinuteAgo = Float.toInt(Date.now() /. 1000.0) - 60
    let _ = await ops.save(
      "k",
      JSON.Encode.string("expired"),
      ReventlessCore.QueryDb.Any,
      Some(aMinuteAgo),
    )

    let items = await ops.loadStream("k")->collect
    expect(items->Array.length)->toBe(0)
  })

  testPromise("save without TTL is treated as never expiring", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="rt-none", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.save("k", JSON.Encode.string("forever"), ReventlessCore.QueryDb.Any, None)

    let items = await ops.loadStream("k")->collect
    expect(items->Array.length)->toBe(1)
  })

  testPromise("scanAll skips expired rows", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="scan-ttl", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve

    let _ = await ops.save("alive", JSON.Encode.string("a"), ReventlessCore.QueryDb.Any, None)
    let aMinuteAgo = Float.toInt(Date.now() /. 1000.0) - 60
    let _ = await ops.save(
      "expired",
      JSON.Encode.string("e"),
      ReventlessCore.QueryDb.Any,
      Some(aMinuteAgo),
    )

    let scan = TestBus.getQueryDbScan("scan-ttl")
    switch scan {
    | Some(fn) => expect(fn()->Array.length)->toBe(1)
    | None => expect("scan registered")->toBe("scan missing")
    }
  })

  testPromise("overwriting an expired row with a non-expired one makes it visible again", async () => {
    module TestBus = LocalBus.Make()
    module DbProvider = {
      let db = openFreshDb()
    }
    module Storage = QueryDbStorage_Sqlite.Make(TestBus, DbProvider)

    let s = Storage.make(~name="overwrite-ttl", ~indexes=[], ~api=(), ~apiRole=(), ~owner=None, ~opts)
    let ops = await s.operations->TestRunner.resolve

    let aMinuteAgo = Float.toInt(Date.now() /. 1000.0) - 60
    let _ = await ops.save(
      "k",
      JSON.Encode.string("expired"),
      ReventlessCore.QueryDb.Any,
      Some(aMinuteAgo),
    )

    let items1 = await ops.loadStream("k")->collect
    expect(items1->Array.length)->toBe(0)

    let _ = await ops.save(
      "k",
      JSON.Encode.string("revived"),
      ReventlessCore.QueryDb.Any,
      None,
    )
    let items2 = await ops.loadStream("k")->collect
    expect(items2->Array.length)->toBe(1)
    expect(items2->Array.getUnsafe(0))->toEqual(JSON.Encode.string("revived"))
  })
})
