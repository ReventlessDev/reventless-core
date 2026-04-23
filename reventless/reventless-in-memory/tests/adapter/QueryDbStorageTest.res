// Unit tests for QueryDbStorage_InMemory.
// Covers save, loadStream, saveBatch, count, delete, deleteBatch, and scan registration.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

let opts: Pulumi.CustomResourceOptions.t = {}

describe("QueryDbStorage_InMemory", () => {
  describe("save and load", () => {
    testPromise("save stores state; loadStream retrieves it by id", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm1", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("id1", JSON.Encode.string("value1"), ReventlessCore.QueryDb.Any, None)
      let items =
        await ops.loadStream("id1")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(1)
      expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("value1"))
    })

    testPromise("loadStream returns empty for unknown id", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm2", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let items =
        await ops.loadStream("unknown")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(0)
    })

    testPromise("save overwrites previous state for same id", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm3", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("id1", JSON.Encode.string("old"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("id1", JSON.Encode.string("new"), ReventlessCore.QueryDb.Any, None)
      let items =
        await ops.loadStream("id1")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(1)
      expect(items->Array.getUnsafe(0))->toEqual(JSON.Encode.string("new"))
    })

    testPromise("load delegates to loadStream (backward-compat)", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="load-compat", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("compat-id", JSON.Encode.string("compat-val"), ReventlessCore.QueryDb.Any, None)
      let streamed = await ops.loadStream("compat-id")->Stream.runCollect->Effect.runPromise
      let loaded = await ops.load("compat-id")
      expect(loaded)->toEqual(Ok(streamed))
    })
  })

  describe("saveBatch", () => {
    testPromise("stores multiple items; loadStream retrieves each by id", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm4", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.saveBatch([
        ("a", JSON.Encode.string("val-a"), None),
        ("b", JSON.Encode.string("val-b"), None),
      ])
      let itemsA =
        await ops.loadStream("a")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      let itemsB =
        await ops.loadStream("b")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(itemsA->Array.getUnsafe(0))->toEqual(JSON.Encode.string("val-a"))
      expect(itemsB->Array.getUnsafe(0))->toEqual(JSON.Encode.string("val-b"))
    })
  })

  describe("count", () => {
    testPromise("returns the increment value (no real counting semantics)", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm5", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let result = await ops.count("id1", "field", 5)
      expect(result)->toEqual(Ok(5))
    })
  })

  describe("delete", () => {
    testPromise("removes item; loadStream returns empty", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm6", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("del-id", JSON.Encode.string("v"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.delete("del-id", None)
      let items =
        await ops.loadStream("del-id")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(items->Array.length)->toBe(0)
    })

    testPromise("deleteBatch removes multiple items", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="rm7", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.saveBatch([
        ("x", JSON.Encode.string("vx"), None),
        ("y", JSON.Encode.string("vy"), None),
      ])
      let _ = await ops.deleteBatch([("x", None), ("y", None)])
      let rx =
        await ops.loadStream("x")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      let ry =
        await ops.loadStream("y")
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
      expect(rx->Array.length)->toBe(0)
      expect(ry->Array.length)->toBe(0)
    })
  })

  describe("scan registration", () => {
    testPromise("after save, scan function returns all stored items", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="scan-rm", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("s1", JSON.Encode.string("item1"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("s2", JSON.Encode.string("item2"), ReventlessCore.QueryDb.Any, None)
      let scanFn = TestBus.getQueryDbScan("scan-rm")->Option.getOr(() => [])
      let all = scanFn()
      expect(all->Array.length)->toBe(2)
    })

    testPromise("after delete, scan function excludes deleted item", async () => {
      module TestBus = InMemory_Bus.Make()
      module Storage = QueryDbStorage_InMemory.Make(TestBus)
      let s = Storage.make(~name="scan-rm2", ~indexes=[], ~api=(), ~apiRole=(), ~opts)
      let ops = await s.operations->TestRunner.resolve
      let _ = await ops.save("keep", JSON.Encode.string("keep"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.save("gone", JSON.Encode.string("gone"), ReventlessCore.QueryDb.Any, None)
      let _ = await ops.delete("gone", None)
      let scanFn = TestBus.getQueryDbScan("scan-rm2")->Option.getOr(() => [])
      let all = scanFn()
      expect(all->Array.length)->toBe(1)
    })
  })
})
