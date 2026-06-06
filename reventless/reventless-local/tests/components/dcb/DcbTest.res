// E2E tests for DcbEventLog and StateChangeSlice builders.
// Verifies the full command → DcbEventLog → event topic pipeline.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open DcbFixtures

describe("DcbEventLog E2E", () => {
  // Force Output chain resolution so StateChangeSlice handlers are registered
  // before the first test runs (handlers are wired inside Output.apply).
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("AddItem command publishes 1 event to event topic", async () => {
    let cmd =
      AddItemSpec.AddItem({id: "item-1", name: "Widget"})
      ->ReventlessCore.Message.encode(AddItemSpec.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate AddItem produces 0 events (ItemAlreadyExists)", async () => {
    // item-1 was already created in the previous test — same aggregate state persists
    let cmd =
      AddItemSpec.AddItem({id: "item-1", name: "Widget"})
      ->ReventlessCore.Message.encode(AddItemSpec.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("AddItem for new id produces 1 event", async () => {
    let cmd =
      AddItemSpec.AddItem({id: "item-2", name: "Gadget"})
      ->ReventlessCore.Message.encode(AddItemSpec.commandSchema)
    await dispatch(cmd, "item-2")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("direct read of DcbEventLog returns appended events", async () => {
    // Tests 1 and 3 appended 2 events total (item-1 and item-2)
    let ops = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
    let result = await ops.read(~query=[])
    expect(result.events->Array.length > 0)->toBe(true)
  })

  testPromise("direct read with eventTypes filter returns matching events", async () => {
    let ops = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
    let result = await ops.read(~query=[{eventTypes: ["ItemAdded"]}])
    expect(result.events->Array.length > 0)->toBe(true)
  })
})
