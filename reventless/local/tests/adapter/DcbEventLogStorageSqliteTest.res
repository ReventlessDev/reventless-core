// Round-trip test for DcbEventLogStorage_Sqlite.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

let stored = (eventType, tags, data): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data,
  tags,
  meta: ReventlessCore.Message.generateMeta(~service="test"),
}

// Render a typed appendError for assertion diagnostics: an "expected Ok" guard
// surfaces the real error message on failure instead of a meaningless literal.
let appendErrMsg = e =>
  switch e {
  | ReventlessInfra.DcbEventLog.Conflict => "conflict"
  | StorageFailure(m) => m
  }

describe("DcbEventLogStorage_Sqlite", () => {
  testPromise("append + read round-trips events with tags", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-rt",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let tag1: Reventless.DcbTag.tag = {key: "itemId", value: "x1"}
      let e1 = stored(
        "ItemAdded",
        [tag1],
        JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string("widget"))])),
      )
      let result = await ops.append([e1])
      switch result {
      | Ok(_) => expect(true)->toBe(true)
      | Error(e) => expect(appendErrMsg(e))->toBe("Ok")
      }

      let read = await ops.read(~query=[])
      expect(read.events->Array.length)->toBe(1)
      let first = read.events->Array.getUnsafe(0)
      expect(first.eventType)->toBe("ItemAdded")
      expect(first.tags->Array.length)->toBe(1)
      expect((first.tags->Array.getUnsafe(0)).key)->toBe("itemId")
      expect((first.tags->Array.getUnsafe(0)).value)->toBe("x1")
    })
  })

  testPromise("read filters by tag", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-tagfilter",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let mk = (id, name) =>
        stored(
          "ItemAdded",
          [{key: "itemId", value: id}],
          JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string(name))])),
        )

      let _ = await ops.append([mk("a1", "alpha")])
      let _ = await ops.append([mk("b1", "beta")])
      let _ = await ops.append([mk("a1", "again")])

      let read = await ops.read(~query=[{tags: [{key: "itemId", value: "a1"}]}])
      expect(read.events->Array.length)->toBe(2)
    })
  })

  // Backend contract: an empty tag value (an absent composite-partition member) is
  // legitimate — it appends, is recorded verbatim, and keeps matching through both
  // the partition read and a composite read. Held identically by the in-memory and
  // DynamoDB backends. See docs/plans/done/dcb-empty-tag-values-break-append.md.
  testPromise("an empty tag value appends and stays readable", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-emptytag",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "itemId"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let tags = [{Reventless.DcbTag.key: "itemId", value: "i1"}, {key: "variantId", value: ""}]
      let result = await ops.append([stored("ItemAdded", tags, JSON.Encode.string("x"))])
      switch result {
      | Ok(_) => expect(true)->toBe(true)
      | Error(e) => expect(appendErrMsg(e))->toBe("Ok")
      }

      let byPartition = await ops.read(~query=[{tags: [{key: "itemId", value: "i1"}]}])
      expect(byPartition.events->Array.length)->toBe(1)
      expect((byPartition.events->Array.getUnsafe(0)).tags->Array.map(t => (t.key, t.value)))
      ->toEqual([("itemId", "i1"), ("variantId", "")])

      let byComposite = await ops.read(~query=[{tags: tags}])
      expect(byComposite.events->Array.length)->toBe(1)
    })
  })

  testPromise("batched tag hydration preserves per-event tags and order", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-multitag",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      // e1 carries three tags (declaration order matters); e2 carries one; e3 none.
      let e1 = stored(
        "Multi",
        [
          {key: "a", value: "1"},
          {key: "b", value: "2"},
          {key: "c", value: "3"},
        ],
        JSON.Encode.string("first"),
      )
      let e2 = stored("Single", [{key: "only", value: "z"}], JSON.Encode.string("second"))
      let e3 = stored("None", [], JSON.Encode.string("third"))
      let _ = await ops.append([e1])
      let _ = await ops.append([e2])
      let _ = await ops.append([e3])

      let read = await ops.read(~query=[])
      expect(read.events->Array.length)->toBe(3)
      let first = read.events->Array.getUnsafe(0)
      // Order and grouping survive the single batched IN query.
      expect(first.tags->Array.map(t => t.key))->toEqual(["a", "b", "c"])
      expect(first.tags->Array.map(t => t.value))->toEqual(["1", "2", "3"])
      let second = read.events->Array.getUnsafe(1)
      expect(second.tags->Array.length)->toBe(1)
      expect((second.tags->Array.getUnsafe(0)).key)->toBe("only")
      let third = read.events->Array.getUnsafe(2)
      expect(third.tags->Array.length)->toBe(0)
    })
  })

  testPromise("append with a non-conflicting condition succeeds", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-noconflict",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let _ = await ops.append([stored("Created", [{key: "id", value: "x"}], JSON.Encode.string("a"))])
      // Condition queries a tag value that does not exist → anyMatch is false →
      // the append is allowed.
      let cond: Reventless.DcbTag.appendCondition = {
        query: [{tags: [{key: "id", value: "other"}]}],
      }
      let result = await ops.append(
        [stored("Created", [{key: "id", value: "other"}], JSON.Encode.string("b"))],
        ~condition=cond,
      )
      switch result {
      | Ok(_) => expect(true)->toBe(true)
      | Error(e) => expect(appendErrMsg(e))->toBe("Ok")
      }
      let read = await ops.read(~query=[])
      expect(read.events->Array.length)->toBe(2)
    })
  })

  testPromise("append with conflicting condition returns Error", async () => {
    await runUnderSqlite(async () => {
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="dcb-conflict",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve

      let e = stored(
        "Created",
        [{key: "id", value: "x"}],
        JSON.Encode.string("first"),
      )
      let _ = await ops.append([e])

      let cond: Reventless.DcbTag.appendCondition = {
        query: [{tags: [{key: "id", value: "x"}]}],
      }
      let result = await ops.append([e], ~condition=cond)
      switch result {
      | Error(_) => expect(true)->toBe(true)
      | Ok(_) => expect("expected conflict")->toBe("got Ok")
      }
    })
  })

  testPromise("events persist across a file reopen", async () => {
    let path = `/tmp/reventless-test-dcb-${Float.toString(Date.now())}.db`

    {
      let db = SqliteDriver.openDb(~path)
      BackendState.setSqlite(~db, ~path)
      module TestBus = LocalBus.Make()
      module Storage = LocalDcbEventLogStorage.Make(TestBus)
      let s = Storage.make(
        ~name="persist",
        ~indexes=[],
        ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let ops = await s.operations->TestRunner.resolve
      let e = stored(
        "Created",
        [{key: "id", value: "p"}],
        JSON.Encode.int(1),
      )
      let _ = await ops.append([e])
      db->SqliteDriver.close
      BackendState.setMemory()
    }

    let db2 = SqliteDriver.openDb(~path)
    BackendState.setSqlite(~db=db2, ~path)
    module TestBus2 = LocalBus.Make()
    module Storage2 = LocalDcbEventLogStorage.Make(TestBus2)
    let s2 = Storage2.make(
      ~name="persist",
      ~indexes=[],
      ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
      ~opts,
    )
    let ops2 = await s2.operations->TestRunner.resolve
    let read = await ops2.read(~query=[])
    expect(read.events->Array.length)->toBe(1)
    db2->SqliteDriver.close
    BackendState.setMemory()
  })
})
