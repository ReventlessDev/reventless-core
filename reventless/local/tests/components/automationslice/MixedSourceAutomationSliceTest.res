// Plan 04 integration test — AutomationSlice consumes events from two sources
// (Aggregate + DCB EventLog) and drives a single TODO list to MarkFulfilled
// commands. Verifies per-source decode dispatch, context plumbing, and that
// commands surface via publishJsons.

open JestGlobals
open MixedSourceAutomationSliceFixtures

describe("MixedSource AutomationSlice", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await aggregateResource.name->TestRunner.resolve
    let _ = await dcbResource.name->TestRunner.resolve
    // Extra microtask flushes: subscription registration in
    // LocalEventCollectorChannel.connect is fire-and-forget via
    // `Effect.runPromise->ignore`, so we need the runtime to drain those
    // microtasks before publishing events.
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
  })

  let _ = beforeEach(() => {
    publishedCommands := []
  })

  testPromise("Aggregate-source event creates a TODO and produces a command", async () => {
    publishedCommands := []
    let _ = await publishAggregateEvent(
      "env-a1",
      OrderShipped({orderId: "o1", productId: "p1"}),
    )

    // Trigger phase2 manually since we don't have a heartbeat in this test.
    let ops = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.processPending()

    expect(publishedCommands.contents->Array.length)->toBe(1)
    let cmd = publishedCommands.contents->Array.getUnsafe(0)
    expect(cmd.id)->toBe("o1:p1")
  })

  testPromise("DCB-source StockReserved creates a TODO and produces a command", async () => {
    publishedCommands := []
    let _ = await publishDcbEvent(
      "env-d1",
      StockReserved({orderId: "o2", productId: "p2"}),
    )

    let ops = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.processPending()

    expect(publishedCommands.contents->Array.length)->toBe(1)
    let cmd = publishedCommands.contents->Array.getUnsafe(0)
    expect(cmd.id)->toBe("o2:p2")
  })

  testPromise("DCB-source StockReleased after a Processing item is idempotent", async () => {
    publishedCommands := []
    // Reserve fires phase1+phase2 (inline) — produces 1 command, item becomes
    // Processing. StockReleased then resolves the item to Completed —
    // subsequent processPending calls produce no further commands for it.
    let _ = await publishDcbEvent(
      "env-d2",
      StockReserved({orderId: "o3", productId: "p3"}),
    )
    let _ = await publishDcbEvent(
      "env-d3",
      StockReleased({orderId: "o3", productId: "p3"}),
    )

    expect(publishedCommands.contents->Array.length)->toBe(1)

    // Reset and call processPending again — already-Processing/Completed item
    // shouldn't generate a duplicate.
    publishedCommands := []
    let ops = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.processPending()
    expect(publishedCommands.contents->Array.length)->toBe(0)
  })

  testPromise("both sources can drive items into the same TODO list independently", async () => {
    publishedCommands := []
    let _ = await publishAggregateEvent(
      "env-a2",
      OrderShipped({orderId: "o4", productId: "p4"}),
    )
    let _ = await publishDcbEvent(
      "env-d4",
      StockReserved({orderId: "o5", productId: "p5"}),
    )

    let ops = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.processPending()

    expect(publishedCommands.contents->Array.length)->toBe(2)
    let ids = publishedCommands.contents->Array.map(c => c.id)
    expect(ids->Array.includes("o4:p4"))->toBe(true)
    expect(ids->Array.includes("o5:p5"))->toBe(true)
  })

  testPromise("first-writer-wins idempotency across mappings sharing an ID", async () => {
    publishedCommands := []
    // Both sources produce the same composite ID — second arrival is ignored.
    let _ = await publishAggregateEvent(
      "env-a3",
      OrderShipped({orderId: "o6", productId: "p6"}),
    )
    let _ = await publishDcbEvent(
      "env-d5",
      StockReserved({orderId: "o6", productId: "p6"}),
    )

    let ops = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    await ops.processPending()

    expect(publishedCommands.contents->Array.length)->toBe(1)
  })
})
