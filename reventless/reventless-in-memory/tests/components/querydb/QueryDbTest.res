// Integration tests for QueryDb_Builder with in-memory adapters.

open AsyncTest
open AsyncTest.Expect
open QueryDbFixtures

describe("QueryDb (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
  })

  testPromise("load returns empty array for unknown id", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let result = await ops.load("unknown-id")
    expect(result)->toEqual(Ok([]))
  })

  testPromise("save and load round-trip", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let state: ItemQueryDbSpec.state = {name: "Widget", count: 5}
    let _ = await ops.save("item-1", state, Init, None)
    let result = await ops.load("item-1")
    switch result {
    | Ok([s]) => expect((s.name, s.count))->toEqual(("Widget", 5))
    | _ => expect("Expected Ok([state])")->toEqual("but got different result")
    }
  })

  testPromise("save overwrites previous state", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save("item-2", {name: "Old", count: 1}, Init, None)
    let _ = await ops.save("item-2", {name: "New", count: 2}, Overwrite, None)
    let result = await ops.load("item-2")
    switch result {
    | Ok([s]) => expect(s.name)->toBe("New")
    | _ => expect("Expected Ok([state])")->toEqual("but got different result")
    }
  })

  testPromise("saveBatch saves multiple states", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let batch = [
      ("batch-1", ({name: "Alpha", count: 1}: ItemQueryDbSpec.state), None),
      ("batch-2", ({name: "Beta", count: 2}: ItemQueryDbSpec.state), None),
    ]
    let _ = await ops.saveBatch(batch)
    let r1 = await ops.load("batch-1")
    let r2 = await ops.load("batch-2")
    expect((r1->Result.isOk, r2->Result.isOk))->toEqual((true, true))
  })

  testPromise("delete removes state", async () => {
    let ops = await queryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save("item-del", {name: "ToDelete", count: 0}, Init, None)
    let _ = await ops.delete("item-del", None)
    let result = await ops.load("item-del")
    expect(result)->toEqual(Ok([]))
  })

  testPromise("registered in bus by component name", async () => {
    // QueryDb registers itself in the bus as "TestItemQueryDbQueryDB"
    // (Spec.name ++ "QueryDB")
    let db = Bus.getQueryDb("TestItemQueryDbQueryDB")
    expect(db->Option.isSome)->toBe(true)
  })
})
