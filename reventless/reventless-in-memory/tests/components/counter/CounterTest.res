// E2E tests for Counter_Builder.
// Verifies addToCounterTarget deduplication and count persistence.

open AsyncTest
open AsyncTest.Expect
open CounterFixtures

describe("Counter E2E", () => {
  // Resolve operations once before all tests.
  let _ = beforeAllAsync(async () => {
    let _ = await resolveOps()
  })

  // Reset in-memory counter state between tests.
  let _ = beforeEach(() => {
    CounterHandler_InMemory.reset()
  })

  testPromise("addToCounterTarget increments count", async () => {
    let ops = await resolveOps()
    await ops.addToCounterTarget({counterId: "item-1", target: 1, targetRef: "ref-1"})
    expect(CounterHandler_InMemory.getCount("item-1"))->toBe(1)
  })

  testPromise("addToCounterTarget with same targetRef is deduplicated", async () => {
    let ops = await resolveOps()
    await ops.addToCounterTarget({counterId: "item-1", target: 1, targetRef: "ref-1"})
    await ops.addToCounterTarget({counterId: "item-1", target: 1, targetRef: "ref-1"})
    expect(CounterHandler_InMemory.getCount("item-1"))->toBe(1)
  })

  testPromise("addToCounterTarget with different targetRefs accumulates", async () => {
    let ops = await resolveOps()
    await ops.addToCounterTarget({counterId: "item-1", target: 1, targetRef: "ref-1"})
    await ops.addToCounterTarget({counterId: "item-1", target: 1, targetRef: "ref-2"})
    expect(CounterHandler_InMemory.getCount("item-1"))->toBe(2)
  })

  testPromise("count saves references to ReferencesDb", async () => {
    let ops = await resolveOps()
    let _ = await ops.count([{counterId: "counter-1", reference: "ref-1", inc: 1}])
    // Counter component name = "TestCounter" ++ "Counter" = "TestCounterCounter"
    // ReferencesDb name = CounterComponentName ++ "References" ++ "QueryDB"
    //                   = "TestCounterCounterReferencesQueryDB"
    let db = Bus.getQueryDb("TestCounterCounterReferencesQueryDB")
    expect(db->Option.isSome)->toBe(true)
  })
})
