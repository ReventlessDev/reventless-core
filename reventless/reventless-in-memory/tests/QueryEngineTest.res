// Unit tests for QueryEngine_InMemory.
// Verifies query (by id and key) and scan operations via the bus storage registry.

open AsyncTest
open AsyncTest.Expect

let _ = TestRunner.setup()

let opts: Pulumi.CustomResourceOptions.t = {}

describe("QueryEngine_InMemory", () => {
  describe("query", () => {
    testPromise("query by id returns items saved in the matching QueryDbStorage", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="users", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("user-1", JSON.Encode.string("Alice"), Reventless.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="users",
        ~id=ReventlessSpec.QueryEngine.String("user-1"),
      )
      expect(items->Array.length)->toBe(1)
      expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("Alice"))
    })

    testPromise("query with explicit key overrides the id parameter", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="products", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ =
        await ops.save("prod-key", JSON.Encode.string("Widget"), Reventless.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="products",
        ~key="prod-key",
        ~id=ReventlessSpec.QueryEngine.String("ignored"),
      )
      expect(items->Array.length)->toBe(1)
      expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("Widget"))
    })

    testPromise("query for unknown readModelName returns empty array", async () => {
      module TestBus = InMemory_Bus.Make()
      module QE = QueryEngine_InMemory.Make(TestBus)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="no-such-model",
        ~id=ReventlessSpec.QueryEngine.String("any"),
      )
      expect(items->Array.length)->toBe(0)
    })

    testPromise("query with Int id converts to string key for lookup", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="counters", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("42", JSON.Encode.int(100), Reventless.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="counters",
        ~id=ReventlessSpec.QueryEngine.Int(42),
      )
      expect(items->Array.length)->toBe(1)
    })
  })

  describe("scan", () => {
    testPromise("scan returns all items from the matching QueryDbStorage", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="orders", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("o1", JSON.Encode.string("order1"), Reventless.QueryDb.Any, None)
      let _ = await ops.save("o2", JSON.Encode.string("order2"), Reventless.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.scan(~readModelName="orders", ~filterConfigs=[], ~limit=100)
      expect(items->Array.length)->toBe(2)
    })

    testPromise("scan for unknown readModelName returns empty array", async () => {
      module TestBus = InMemory_Bus.Make()
      module QE = QueryEngine_InMemory.Make(TestBus)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.scan(~readModelName="no-such-model", ~filterConfigs=[], ~limit=100)
      expect(items->Array.length)->toBe(0)
    })
  })
})
