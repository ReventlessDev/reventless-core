// Unit tests for QueryEngine_InMemory.
// Verifies query (by id and key) and scan operations via the bus storage registry.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

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
      let _ = await ops.save("user-1", JSON.Encode.string("Alice"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="users",
        ~id=Reventless.QueryEngine.String("user-1"),
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
        await ops.save("prod-key", JSON.Encode.string("Widget"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="products",
        ~key="prod-key",
        ~id=Reventless.QueryEngine.String("ignored"),
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
        ~id=Reventless.QueryEngine.String("any"),
      )
      expect(items->Array.length)->toBe(0)
    })

    testPromise("query with Int id converts to string key for lookup", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="counters", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("42", JSON.Encode.int(100), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let items = await engine.query(
        ~readModelName="counters",
        ~id=Reventless.QueryEngine.Int(42),
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
      let _ = await ops.save("o1", JSON.Encode.string("order1"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("o2", JSON.Encode.string("order2"), ReventlessCore.QueryDb.Any, None)
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

  describe("scan with ~limit", () => {
    testPromise("~limit=2 on a 5-item QueryDb returns exactly 2 items", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="items", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("k1", JSON.Encode.string("a"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("k2", JSON.Encode.string("b"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("k3", JSON.Encode.string("c"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("k4", JSON.Encode.string("d"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("k5", JSON.Encode.string("e"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let result = await engine.scan(~readModelName="items", ~filterConfigs=[], ~limit=2)
      expect(result->Array.length)->toBe(2)
    })

    testPromise("~limit larger than total returns all items (no padding)", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="things", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("t1", JSON.Encode.string("x"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("t2", JSON.Encode.string("y"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let result = await engine.scan(~readModelName="things", ~filterConfigs=[], ~limit=100)
      expect(result->Array.length)->toBe(2)
    })

    testPromise("~limit=0 returns empty array", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="stuff", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("s1", JSON.Encode.string("z"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let result = await engine.scan(~readModelName="stuff", ~filterConfigs=[], ~limit=0)
      expect(result->Array.length)->toBe(0)
    })

    testPromise("~limit=3 on a 3-item QueryDb returns all 3 items", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      module QE = QueryEngine_InMemory.Make(TestBus)
      let s = Storage.make(~name="widgets", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("w1", JSON.Encode.string("p"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("w2", JSON.Encode.string("q"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("w3", JSON.Encode.string("r"), ReventlessCore.QueryDb.Any, None)
      let engine = await QE.make(Dict.make())->TestRunner.resolve
      let result = await engine.scan(~readModelName="widgets", ~filterConfigs=[], ~limit=3)
      expect(result->Array.length)->toBe(3)
    })
  })
})
