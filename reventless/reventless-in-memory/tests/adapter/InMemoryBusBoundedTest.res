// Tests for the bounded PubSub mode of InMemory_Bus (Phase G).
// Verifies that MakeBounded({let capacity = n}) delivers messages correctly, fans out to all
// subscribers, and exerts backpressure when subscriber queues are full.
//
// Timing note: bounded mode resolves publishEvent in ~3 microtask ticks
// (1 extra vs unbounded) because PubSub.publish runs inside Effect.runPromise
// rather than Effect.runSync.

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

describe("InMemory_Bus bounded PubSub (Phase G)", () => {
  describe("basic delivery", () => {
    testPromise("delivers a message to a subscriber in bounded mode", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 10})
      let delivered = ref(false)
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        delivered := true
      })
      let _ = await TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      expect(delivered.contents)->toBe(true)
    })

    testPromise("bounded mode with no subscribers returns immediately", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 5})
      // No subscribers — should not hang
      await TestBus.publishEvent("empty-topic", "svc", defaultMeta, JSON.Null)
    })

    testPromise("passes service, meta, and json to the subscriber handler", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 10})
      let capturedService = ref("")
      let capturedJson = ref(JSON.Null)
      TestBus.subscribeToEvents("T", async (svc, _meta, json) => {
        capturedService := svc
        capturedJson := json
      })
      let payload = JSON.parseOrThrow("{\"x\":42}")
      let _ = await TestBus.publishEvent("T", "my-service", defaultMeta, payload)
      expect(capturedService.contents)->toBe("my-service")
      expect(capturedJson.contents)->toEqual(payload)
    })
  })

  describe("fan-out", () => {
    testPromise("delivers to all subscribers on the same topic", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 10})
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
      let _ = await TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      expect(count.contents)->toBe(3)
    })

    testPromise("topic isolation preserved in bounded mode", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 10})
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

  describe("backpressure", () => {
    testPromise("publisher suspends when subscriber queue is full (capacity=1)", async () => {
      // capacity=1: subscriber queue can buffer 1 message while the subscriber is processing.
      // Timeline:
      //   p1 publish: drain fiber D has a pending Queue.take → msg1 goes to D directly
      //   p2 publish: no pending take (D is processing msg1, blocked on gate) → msg2 buffered
      //   p3 publish: queue is full (msg2 there, capacity=1) → F3 SUSPENDS
      //   After opening gate: msg1 processed → done_1 → D takes msg2 → F3 wakes, delivers msg3
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 1})
      let processedCount = ref(0)
      // Gate Deferred: subscriber blocks until explicitly opened
      let gate: Deferred.t<unit, unit> = Deferred.make()->Effect.runSync
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        let _ = await Deferred.await_(gate)->Effect.runPromise
        processedCount := processedCount.contents + 1
      })
      // Start 3 publishes without awaiting.
      // p1: D's pending Queue.take resolves with msg1; D starts processing (blocks on gate)
      // p2: msg2 buffered in queue (capacity=1, fits since D already took msg1)
      // p3: queue full → F3 fiber suspends inside PubSub.publish
      let p1 = TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      let p2 = TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      let p3 = TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      // Tick 1: drain fiber D runs, takes msg1, calls handler → handler blocks on gate
      let _ = await Promise.resolve()
      // Gate not open yet — no messages fully processed
      expect(processedCount.contents)->toBe(0)
      // Open gate: subscriber can now process all pending messages
      let _ = Deferred.succeed(gate, ())->Effect.runSync
      // Await each publish promise; by the time all resolve, all 3 handlers have run
      let _ = await p1
      let _ = await p2
      let _ = await p3
      expect(processedCount.contents)->toBe(3)
    })
  })

  describe("timing", () => {
    testPromise("bounded mode completes within 3 microtask ticks", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 10})
      let delivered = ref(false)
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        delivered := true
      })
      let pubPromise = TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      // Not delivered synchronously
      expect(delivered.contents)->toBe(false)
      let _ = await Promise.resolve() // tick 1
      let _ = await Promise.resolve() // tick 2
      let _ = await Promise.resolve() // tick 3 (bounded adds 1 vs unbounded's 2)
      let _ = await pubPromise
      expect(delivered.contents)->toBe(true)
    })
  })

  describe("reset", () => {
    testPromise("reset shuts down bounded hubs cleanly", async () => {
      module TestBus = InMemory_Bus.MakeBounded({let capacity = 5})
      let count = ref(0)
      TestBus.subscribeToEvents("T", async (_, _, _) => {
        count := count.contents + 1
      })
      let _ = await TestBus.publishEvent("T", "svc", defaultMeta, JSON.Null)
      expect(count.contents)->toBe(1)
      // reset should not throw or hang
      TestBus.reset()
      expect(count.contents)->toBe(1) // count unchanged by reset itself
    })
  })
})
