// Integration tests for SideEffectHandler builder (in-memory).
// Publishes events to the bus and verifies side effect execute is called.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open SideEffectHandlerFixtures

// ─────────────────────────────────────────────────────────────
// Resolve Output chain before tests run (same pattern as ReadModelTest).
//
// Two resolves:
//   1. seh operations — triggers EventCollector.make → EventCollectorRuntimeBuilder.forEventCollector
//      → EventCollectorChannel_InMemory.connect (starts resource.name.apply subscription chain).
//   2. topicResource.name — resolves the inner resource.name Output, registering
//      Bus.subscribeToEvents for the side effect handler.
// ─────────────────────────────────────────────────────────────

let _ = beforeAllAsync(async () => {
  let _ = await seh->ReventlessCore.Component.operations->TestRunner.resolve
  let _ = await topicResource.name->TestRunner.resolve
})

describe("SideEffectHandler (in-memory)", () => {
  let _ = beforeEach(() => resetMocks())

  testPromise("OrderPlaced event triggers execute with correct id and orderId", async () => {
    await publishOrderPlaced("order-1", "ord-abc")
    expect(capturedOrders.contents->Array.length)->toBe(1)
    let entry = capturedOrders.contents->Array.getUnsafe(0)
    let (aggId, orderId) = entry
    expect(aggId)->toBe("order-1")
    expect(orderId)->toBe("ord-abc")
  })

  testPromise("multiple events trigger execute for each", async () => {
    await publishOrderPlaced("order-2", "ord-def")
    await publishOrderPlaced("order-3", "ord-ghi")
    expect(capturedOrders.contents->Array.length)->toBe(2)
  })
})
