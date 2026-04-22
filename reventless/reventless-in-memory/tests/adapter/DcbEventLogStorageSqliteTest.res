// Round-trip test for DcbEventLogStorage_Sqlite.

open AsyncTest
open AsyncTest.Expect

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
}

describe("DcbEventLogStorage_Sqlite", () => {
  testPromise("append + read round-trips events with tags", async () => {
    await runUnderSqlite(async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = DcbEventLogStorage_InMemory.Make(TestBus)
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
      | Error(m) => expect(m)->toBe("Ok")
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
      module TestBus = InMemory_Bus.Make()
      module Storage = DcbEventLogStorage_InMemory.Make(TestBus)
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

  testPromise("append with conflicting condition returns Error", async () => {
    await runUnderSqlite(async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = DcbEventLogStorage_InMemory.Make(TestBus)
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
      module TestBus = InMemory_Bus.Make()
      module Storage = DcbEventLogStorage_InMemory.Make(TestBus)
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
    module TestBus2 = InMemory_Bus.Make()
    module Storage2 = DcbEventLogStorage_InMemory.Make(TestBus2)
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
