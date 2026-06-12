// E2E tests for StateViewSlice_Builder.
// Verifies the full DcbEventLog.append → event topic → EventCollector → projection → QueryDb pipeline.

open JestGlobals
open StateViewSliceFixtures

describe("StateViewSlice E2E", () => {
  // TWO resolves needed (same pattern as ReadModel E2E):
  //   1. sv.operations chain — triggers queryDb.operations.apply which creates EventCollector
  //      and calls EventCollectorRuntimeBuilder.forEventCollector as a side effect.
  //   2. dcbEventTopicResource.name — triggers EventCollectorChannel.connect inner
  //      resource.name.apply, which registers the Bus.subscribeToEvents handler.
  let _ = beforeAllAsync(async () => {
    let _ = await sv->ItemsViewMaker.operations->TestRunner.resolve
    let _ = await dcbEventTopicResource.name->TestRunner.resolve
  })

  testPromise("ItemAdded event projects to QueryDb state", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-1", name: "Widget"}))
    let states = await loadState("item-1")
    expect(states->Array.length)->toBe(1)
    let s = states->Array.getUnsafe(0)
    expect(s.name)->toBe("Widget")
  })

  testPromise("ItemRenamed event updates existing state", async () => {
    // item-1 already exists from previous test (shared state across tests in this describe)
    let _ = await appendEvent(ItemEventLog.ItemRenamed({id: "item-1", name: "SuperWidget"}))
    let states = await loadState("item-1")
    expect(states->Array.length)->toBe(1)
    let s = states->Array.getUnsafe(0)
    expect(s.name)->toBe("SuperWidget")
  })

  testPromise("multiple items projected independently", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-2", name: "Gadget"}))
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-3", name: "Doohickey"}))
    let states2 = await loadState("item-2")
    let states3 = await loadState("item-3")
    expect(states2->Array.length)->toBe(1)
    expect(states3->Array.length)->toBe(1)
    let s2 = states2->Array.getUnsafe(0)
    let s3 = states3->Array.getUnsafe(0)
    expect(s2.name)->toBe("Gadget")
    expect(s3.name)->toBe("Doohickey")
  })

  testPromise("ItemRemoved event deletes state from QueryDb", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-4", name: "Temp"}))
    let _ = await appendEvent(ItemEventLog.ItemRemoved({id: "item-4"}))
    let states = await loadState("item-4")
    expect(states->Array.length)->toBe(0)
  })

  testPromise("query for unknown ID returns empty", async () => {
    let states = await loadState("no-such-item")
    expect(states->Array.length)->toBe(0)
  })
})
