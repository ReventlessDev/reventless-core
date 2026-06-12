// Integration test: ReadModel with mixed event sources.
// Verifies that a single ReadModel can project events from two independent
// EventTopics (simulating aggregate + DCB sources merged by Plugin_Builder).

open JestGlobals
open MixedSourceReadModelFixtures

describe("MixedSource ReadModel", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await rm->MixedRM.operations->TestRunner.resolve
    let _ = await aggregateResource.name->TestRunner.resolve
    let _ = await dcbResource.name->TestRunner.resolve
  })

  testPromise("aggregate event projects with source 'aggregate'", async () => {
    let _ = await publishAggregateEvent("agg-1", AggregateItemCreated({name: "Widget"}))
    let states = await loadState("agg-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Widget")
    expect(state.source)->toBe("aggregate")
  })

  testPromise("DCB event projects with source 'dcb'", async () => {
    let _ = await publishDcbEvent("dcb-1", DcbItemAdded({name: "Gadget"}))
    let states = await loadState("dcb-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Gadget")
    expect(state.source)->toBe("dcb")
  })

  testPromise("both sources coexist independently", async () => {
    let aggStates = await loadState("agg-1")
    let dcbStates = await loadState("dcb-1")
    expect(aggStates->Array.length)->toBe(1)
    expect(dcbStates->Array.length)->toBe(1)
    let agg = aggStates->Array.getUnsafe(0)
    let dcb = dcbStates->Array.getUnsafe(0)
    expect(agg.source)->toBe("aggregate")
    expect(dcb.source)->toBe("dcb")
  })

  testPromise("aggregate update modifies existing entry", async () => {
    let _ = await publishAggregateEvent("agg-1", AggregateItemRenamed({name: "Super Widget"}))
    let states = await loadState("agg-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Super Widget")
    expect(state.source)->toBe("aggregate")
  })

  testPromise("DCB update modifies existing entry", async () => {
    let _ = await publishDcbEvent("dcb-1", DcbItemNameChanged({name: "Super Gadget"}))
    let states = await loadState("dcb-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Super Gadget")
    expect(state.source)->toBe("dcb")
  })
})
