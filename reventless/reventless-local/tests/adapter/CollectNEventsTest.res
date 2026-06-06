// Tests for TestRunner.collectNEvents utility (Phase J of stream-handler-implementation plan).

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

let meta: Reventless.Message.meta = {
  service: "svc",
  time: "",
  ip: "",
  user: "u",
  msgId: "",
  correlationId: "",
}

describe("TestRunner.collectNEvents", () => {
  testPromise("resolves after exactly n events", async () => {
    module Bus = LocalBus.Make()
    let collecting = TestRunner.collectNEvents(Bus.subscribeToEvents, "T", 3)
    let json = JSON.parseOrThrow("{}")
    await Bus.publishEvent("T", "svc", meta, json)
    await Bus.publishEvent("T", "svc", meta, json)
    await Bus.publishEvent("T", "svc", meta, json)
    let events = await collecting
    expect(events->Array.length)->toBe(3)
  })

  testPromise("captures service, meta, and json from each event", async () => {
    module Bus = LocalBus.Make()
    let collecting = TestRunner.collectNEvents(Bus.subscribeToEvents, "T", 2)
    let j1 = JSON.parseOrThrow(`{"id":1}`)
    let j2 = JSON.parseOrThrow(`{"id":2}`)
    await Bus.publishEvent("T", "svc", meta, j1)
    await Bus.publishEvent("T", "svc", meta, j2)
    let events = await collecting
    let e0 = events->Array.getUnsafe(0)
    let e1 = events->Array.getUnsafe(1)
    expect(e0.json)->toEqual(j1)
    expect(e1.json)->toEqual(j2)
  })

  testPromise("resolves immediately for n = 0", async () => {
    module Bus = LocalBus.Make()
    let events = await TestRunner.collectNEvents(Bus.subscribeToEvents, "T", 0)
    expect(events->Array.length)->toBe(0)
  })

  testPromise("does not resolve before n events arrive", async () => {
    module Bus = LocalBus.Make()
    let collecting = TestRunner.collectNEvents(Bus.subscribeToEvents, "T", 3)
    let json = JSON.parseOrThrow("{}")
    let resolved = ref(false)
    let _ = collecting->Promise.then(events => {
      resolved := true
      Promise.resolve(events)
    })
    await Bus.publishEvent("T", "svc", meta, json)
    await Bus.publishEvent("T", "svc", meta, json)
    // Only 2 events so far — promise should not yet be resolved.
    // One extra tick to let any spurious resolution propagate.
    let _ = await Promise.resolve()
    expect(resolved.contents)->toBe(false)
    // Third event resolves it.
    await Bus.publishEvent("T", "svc", meta, json)
    let _ = await collecting
    expect(resolved.contents)->toBe(true)
  })

  testPromise("works with multiple independent topics", async () => {
    module Bus = LocalBus.Make()
    let collectingA = TestRunner.collectNEvents(Bus.subscribeToEvents, "A", 1)
    let collectingB = TestRunner.collectNEvents(Bus.subscribeToEvents, "B", 2)
    let json = JSON.parseOrThrow("{}")
    await Bus.publishEvent("A", "svc", meta, json)
    await Bus.publishEvent("B", "svc", meta, json)
    await Bus.publishEvent("B", "svc", meta, json)
    let eventsA = await collectingA
    let eventsB = await collectingB
    expect(eventsA->Array.length)->toBe(1)
    expect(eventsB->Array.length)->toBe(2)
  })
})
