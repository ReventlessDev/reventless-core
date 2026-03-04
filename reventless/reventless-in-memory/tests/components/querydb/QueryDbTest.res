// Integration tests for QueryDb_Builder with in-memory adapters.

open AsyncTest
open AsyncTest.Expect
open QueryDbFixtures

describe("QueryDb (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
  })

  testPromise("loadStream returns empty for unknown id", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let result = await ops.loadStream("unknown-id")->Stream.runCollect->Effect.runPromise
    expect(result)->toEqual([])
  })

  testPromise("save and loadStream round-trip", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let state: ItemQueryDbSpec.state = {name: "Widget", count: 5}
    let _ = await ops.save("item-1", state, Init, None)
    let result = await ops.loadStream("item-1")->Stream.runCollect->Effect.runPromise
    switch result {
    | [s] => expect((s.name, s.count))->toEqual(("Widget", 5))
    | _ => expect("Expected [state]")->toEqual("but got different result")
    }
  })

  testPromise("save overwrites previous state", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save("item-2", {name: "Old", count: 1}, Init, None)
    let _ = await ops.save("item-2", {name: "New", count: 2}, Overwrite, None)
    let result = await ops.loadStream("item-2")->Stream.runCollect->Effect.runPromise
    switch result {
    | [s] => expect(s.name)->toBe("New")
    | _ => expect("Expected [state]")->toEqual("but got different result")
    }
  })

  testPromise("saveBatch saves multiple states", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let batch = [
      ("batch-1", ({name: "Alpha", count: 1}: ItemQueryDbSpec.state), None),
      ("batch-2", ({name: "Beta", count: 2}: ItemQueryDbSpec.state), None),
    ]
    let _ = await ops.saveBatch(batch)
    let r1 = await ops.loadStream("batch-1")->Stream.runCollect->Effect.runPromise
    let r2 = await ops.loadStream("batch-2")->Stream.runCollect->Effect.runPromise
    expect((r1->Array.length > 0, r2->Array.length > 0))->toEqual((true, true))
  })

  testPromise("delete removes state", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save("item-del", {name: "ToDelete", count: 0}, Init, None)
    let _ = await ops.delete("item-del", None)
    let result = await ops.loadStream("item-del")->Stream.runCollect->Effect.runPromise
    expect(result)->toEqual([])
  })

  testPromise("loadStream emits saved states", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save("stream-item", {name: "Streamed", count: 42}, Init, None)
    let arr =
      await ops.loadStream("stream-item")->Stream.runCollect->Effect.runPromise
    expect(arr->Array.length)->toBe(1)
    let s = arr->Array.getUnsafe(0)
    expect((s.name, s.count))->toEqual(("Streamed", 42))
  })

  testPromise("loadStream returns empty for unknown id", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let arr =
      await ops.loadStream("no-such-id")->Stream.runCollect->Effect.runPromise
    expect(arr->Array.length)->toBe(0)
  })

  testPromise("registered in bus by component name", async () => {
    // QueryDb registers itself in the bus with the base Spec.name
    let db = Bus.getQueryDb("TestItemQueryDb")
    expect(db->Option.isSome)->toBe(true)
  })
})
