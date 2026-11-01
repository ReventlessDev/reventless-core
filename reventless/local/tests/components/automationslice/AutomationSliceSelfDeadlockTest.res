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

  // The automation's command continues the flow of the event that created its
  // row: one correlation id from the first command to the last event, and each
  // message caused by the one before it.
  testPromise("the automation's command and its events stay in the event's flow", async () => {
    sentCommands := []
    let _ = await withTimeout(publishJsons([placeCmdJson("order-2")]), ~ms=1500)
    let shipped = async () =>
      (await readEvents("order-2"))->Array.find(e => e.eventType == "Shipped")
    let waited = ref(0)
    while (await shipped())->Option.isNone && waited.contents < 100 {
      await pause(10)
      waited := waited.contents + 1
    }

    let events = await readEvents("order-2")
    let placed = events->Array.find(e => e.eventType == "Placed")->Option.getOrThrow
    let shipped = events->Array.find(e => e.eventType == "Shipped")->Option.getOrThrow
    let ship =
      sentCommands.contents
      ->Array.find(c => c.id == "order-2" && c.meta.msgId != TestFixtures.testMeta.msgId)
      ->Option.getOrThrow

    expect(placed.meta.correlationId)->toBe(TestFixtures.testMeta.correlationId)
    expect(ship.meta.correlationId)->toBe(TestFixtures.testMeta.correlationId)
    expect(shipped.meta.correlationId)->toBe(TestFixtures.testMeta.correlationId)
    expect(ship.meta.causationId)->toEqual(Some(placed.meta.msgId))
    expect(shipped.meta.causationId)->toEqual(Some(ship.meta.msgId))
    expect(ship.meta.user)->toEqual(TestFixtures.testMeta.user)
  })
})
