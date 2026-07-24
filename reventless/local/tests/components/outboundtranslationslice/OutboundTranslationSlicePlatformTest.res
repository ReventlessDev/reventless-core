// Platform-level regression test for OutboundTranslationSlice wiring.
//
// The callback test next door exercises phase1/phase2 directly and stays green
// while the component never receives an event. This one publishes a command
// through the real chain — StateChangeSlice → DcbEventLog → event topic →
// EventCollector → phase 1 → phase 2 — and asserts the external call lands.

open JestGlobals
open OutboundTranslationSlicePlatformFixtures

describe("OutboundTranslationSlice platform wiring:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await dcbEventLog->DcbLogMaker.operations->TestRunner.resolve
    let _ = await sendConfirmSlice->SendConfirm.operations->TestRunner.resolve
    // LocalEventCollectorChannel.connect registers the bus subscription inside a
    // fire-and-forget Effect.runPromise; flush so it is in place before publishing.
    let _ = await flush()
    let resource = dcbTopicOutputs.resources->Array.getUnsafe(0)
    let _ = await resource.name->TestRunner.resolve
  })

  testPromise("Place → Placed reaches phase 1 collect", async () => {
    let _ = await publishJsons([placeCmdJson("order-1")])
    let _ = await flush()

    let eventTypes = await readEventTypes("order-1")
    expect(eventTypes->Array.includes("Placed"))->toBe(true)

    expect(collectCalls->Array.includes("order-1"))->toBe(true)
  })

  testPromise("phase 2 translates the collected item without the heartbeat", async () => {
    let _ = await publishJsons([placeCmdJson("order-2")])
    let _ = await flush()

    expect(externalCalls->Array.includes("order-2"))->toBe(true)
  })
})
