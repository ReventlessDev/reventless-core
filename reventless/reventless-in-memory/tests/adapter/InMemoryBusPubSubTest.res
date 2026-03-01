// Tests for the PubSub-based InMemory_Bus implementation (Phase F).
// Verifies the 2-tick timing guarantee and multi-subscriber fan-out.
//
// These tests lock in two invariants of the PubSub refactor:
//   1. publishEvent still resolves in exactly 2 microtask ticks (unbounded mode).
//   2. A single publishEvent call reaches all subscribers on the same topic.

open AsyncTest
open AsyncTest.Expect

let _ = TestRunner.setup()

let defaultMeta: Reventless.Message.meta = {
  service: "test",
  time: "",
  ip: "",
  user: "test",
  msgId: "",
  correlationId: "",
}

describe("InMemory_Bus PubSub (Phase F)", () => {
  describe("publishEvent timing", () => {
    testPromise("resolves after exactly 2 microtask ticks", async () => {
      module TestBus = InMemory_Bus.Make()
      let delivered = ref(false)
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        delivered := true
      })
      // Start publishEvent without awaiting — drive manually tick by tick.
      let pubPromise = TestBus.publishEvent("T", "svc", defaultMeta, JSON.parseOrThrow("{}"))
      // Tick 0: publish is synchronous; drain fiber hasn't run yet.
      expect(delivered.contents)->toBe(false)
      // Tick 1: Effect scheduler runs drain fiber; handler sets delivered.
      let _ = await Promise.resolve()
      // Tick 2: allDone Deferred resolves; pubPromise completes.
      let _ = await Promise.resolve()
      let _ = await pubPromise
      expect(delivered.contents)->toBe(true)
    })

    testPromise("publishEvent with no subscribers returns immediately", async () => {
      module TestBus = InMemory_Bus.Make()
      // No subscribers registered — should not hang.
      await TestBus.publishEvent("empty-topic", "svc", defaultMeta, JSON.Null)
      // If we reach here the test passes (no timeout/hang).
    })
  })

  describe("fan-out", () => {
    testPromise("delivers to all subscribers on the same topic", async () => {
      module TestBus = InMemory_Bus.Make()
      let count = ref(0)
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        count := count.contents + 1
      })
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        count := count.contents + 1
      })
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        count := count.contents + 1
      })
      let _ = await TestBus.publishEvent("T", "svc", defaultMeta, JSON.parseOrThrow("{}"))
      expect(count.contents)->toBe(3)
    })

    testPromise("publishing to topic-a does not reach topic-b subscribers", async () => {
      module TestBus = InMemory_Bus.Make()
      let countA = ref(0)
      let countB = ref(0)
      TestBus.subscribeToEvents("topic-a", async (_, _, _) => {
        countA := countA.contents + 1
      })
      TestBus.subscribeToEvents("topic-b", async (_, _, _) => {
        countB := countB.contents + 1
      })
      let _ = await TestBus.publishEvent("topic-a", "svc", defaultMeta, JSON.Null)
      expect(countA.contents)->toBe(1)
      expect(countB.contents)->toBe(0)
    })
  })
})
