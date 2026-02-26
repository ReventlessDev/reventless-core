// E2E tests for ReadModel_Builder.
// Verifies the full publish → EventCollector → projection → QueryDb pipeline.

open AsyncTest
open AsyncTest.Expect
open ReadModelE2EFixtures

describe("ReadModel E2E", () => {
  // Force Output chain resolution so EventCollectorChannel subscription is registered
  // before the first test runs.
  //
  // Two resolves are needed:
  //   1. rm.operations chain — triggers the outer queryDb.operations.apply(...) which
  //      calls EventCollectorChannel.connect() as a side effect.
  //   2. topicResource.name — resolves the inner resource.name.apply(...) inside connect,
  //      which registers the Bus.subscribeToEvents handler.
  let _ = beforeAllAsync(async () => {
    let _ = await rm->ItemReadModel.operations->TestRunner.resolve
    let _ = await topicResource.name->TestRunner.resolve
  })

  testPromise("ItemCreated event projects into ReadModel state", async () => {
    let _ = await publishItemCreated("item-1", "Widget")
    let states = await loadState("item-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Widget")
  })

  testPromise("query for unknown ID returns empty", async () => {
    let states = await loadState("unknown-id")
    expect(states->Array.length)->toBe(0)
  })

  testPromise("multiple events project independently", async () => {
    let _ = await publishItemCreated("item-2", "Gadget")
    let _ = await publishItemCreated("item-3", "Doohickey")
    let states2 = await loadState("item-2")
    let states3 = await loadState("item-3")
    expect(states2->Array.length)->toBe(1)
    expect(states3->Array.length)->toBe(1)
    let state2 = states2->Array.getUnsafe(0)
    let state3 = states3->Array.getUnsafe(0)
    expect(state2.name)->toBe("Gadget")
    expect(state3.name)->toBe("Doohickey")
  })
})
