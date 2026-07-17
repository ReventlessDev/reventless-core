// Regression test for the AutomationSlice self-deadlock fix.
// See AutomationSliceSelfDeadlockFixtures.res for the wiring rationale.
//
// Without the fix, `publishJsons([Place])` never returns: phase 2 publishes a
// Ship command on the originating subscriber fiber, Ship appends Shipped, and
// the bus blocks waiting for that same fiber to dequeue Shipped. The wall-clock
// timeout below catches that.

open JestGlobals
open AutomationSliceSelfDeadlockFixtures

describe("AutomationSlice self-deadlock regression:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await dcbEventLog->DcbLogMaker.operations->TestRunner.resolve
    let _ = await autoShipSlice->ReventlessCore.Component.operations->TestRunner.resolve
    // LocalEventCollectorChannel.connect registers the bus subscription
    // inside a fire-and-forget Effect.runPromise; flush a couple of microtasks
    // so the AutoShip subscription is in place before we publish.
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let resource = dcbTopicOutputs.resources->Array.getUnsafe(0)
    let _ = await resource.name->TestRunner.resolve
  })

  testPromise("Place → Placed → AutoShip → Ship → Shipped completes", async () => {
    // The originating publish must return inside the timeout. With phase 2
    // awaited inline (the pre-fix shape), this hangs until Jest times out.
    let outcome = await withTimeout(publishJsons([placeCmdJson("order-1")]), ~ms=1500)
    expect(
      switch outcome {
      | Ok(_) => "ok"
      | Error(msg) => msg
      },
    )->toBe("ok")

    // Drain microtasks so the detached phase 2 chain has a chance to publish
    // Ship and the Ship slice can append Shipped.
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()

    let eventTypes = await readEventTypes("order-1")
    expect(eventTypes->Array.includes("Placed"))->toBe(true)
    expect(eventTypes->Array.includes("Shipped"))->toBe(true)
  })
})
