open JestGlobals
open EventMapperFixtures

let _ = beforeEach(() => resetMocks())

// ─────────────────────────────────────────────────────────────
// MakeCounterHandler.handleCounterEvents
// ─────────────────────────────────────────────────────────────

describe("MakeCounterHandler.handleCounterEvents:", () => {
  describe("event with matching source mapping", () => {
    testPromise("publishes command JSON for OrderPlaced", async () => {
      let eventJson =
        makeEventJson(
          "src-1",
          CmdSourceSpec.OrderPlaced({orderId: "order-1", amount: 99.99})->Message.encode(
            CmdSourceSpec.eventSchema,
          ),
        )
      await TestCounterHandler.handleCounterEvents(Stream.fromIterable([eventJson]))->Effect.runPromise
      // publishJsons should have been called with 1 command
      expect(capturedCmds.contents->Array.length)->toBe(1)
    })
  })

  describe("event with unknown service", () => {
    testPromise("skipped — no publish", async () => {
      let eventJson =
        makeEventJson(
          ~service="UnknownService",
          "src-1",
          CmdSourceSpec.OrderPlaced({orderId: "order-1", amount: 50.0})->Message.encode(
            CmdSourceSpec.eventSchema,
          ),
        )
      await TestCounterHandler.handleCounterEvents(Stream.fromIterable([eventJson]))->Effect.runPromise
      expect(capturedCmds.contents->Array.length)->toBe(0)
    })
  })

  describe("invalid event JSON", () => {
    testPromise("skipped gracefully — no throw, no publish", async () => {
      let invalidJson = JSON.Encode.string("not-an-object")
      await TestCounterHandler.handleCounterEvents(Stream.fromIterable([invalidJson]))->Effect.runPromise
      expect(capturedCmds.contents->Array.length)->toBe(0)
    })
  })
})

// ─────────────────────────────────────────────────────────────
// MakeEventCollectorHandler.handleJsonEvents
// ─────────────────────────────────────────────────────────────

describe("MakeEventCollectorHandler.handleJsonEvents:", () => {
  describe("Count action", () => {
    testPromise("calls count with the countItem", async () => {
      let countItem: ReventlessInfra.Counter.countItem = {
        counterId: "c1",
        reference: "ref-1",
        inc: 1,
      }
      mockCommonHandler :=
        async _ => (Promise.resolve([]), [Counter.Count(countItem)])
      await TestECHandler.handleJsonEvents(Stream.fromIterable([JSON.Encode.null]))->Effect.runPromise
      expect(capturedCountItems.contents)->toEqual([countItem])
    })
  })

  describe("AddToCounterTarget action", () => {
    testPromise("calls addToCounterTarget with the counterTargetRef", async () => {
      let target: ReventlessInfra.Counter.counterTargetRef = {
        counterId: "c1",
        target: 5,
        targetRef: "ref-1",
      }
      mockCommonHandler :=
        async _ => (Promise.resolve([]), [Counter.AddToCounterTarget(target)])
      await TestECHandler.handleJsonEvents(Stream.fromIterable([JSON.Encode.null]))->Effect.runPromise
      expect(capturedCounterTargets.contents)->toEqual([target])
    })
  })

  describe("Publisher action", () => {
    testPromise("calls publishJsons with the command", async () => {
      let cmd: Message.commandJson = {
        id: "agg-1",
        meta: evtMapTestMeta,
        commandJson: JSON.Encode.string("DoSomething"),
      }
      mockCommonHandler := async _ => (Promise.resolve([cmd]), [])
      await TestECHandler.handleJsonEvents(Stream.fromIterable([JSON.Encode.null]))->Effect.runPromise
      expect(capturedCmds.contents->Array.length)->toBe(1)
    })
  })

  describe("mixed actions", () => {
    testPromise("both publish and count called", async () => {
      let countItem: ReventlessInfra.Counter.countItem = {
        counterId: "c1",
        reference: "ref-1",
        inc: 2,
      }
      let cmd: Message.commandJson = {
        id: "agg-1",
        meta: evtMapTestMeta,
        commandJson: JSON.Encode.string("Cmd"),
      }
      mockCommonHandler :=
        async _ => (Promise.resolve([cmd]), [Counter.Count(countItem)])
      await TestECHandler.handleJsonEvents(Stream.fromIterable([JSON.Encode.null]))->Effect.runPromise
      expect((
        capturedCmds.contents->Array.length,
        capturedCountItems.contents->Array.length,
      ))->toEqual((1, 1))
    })
  })

  describe("doCount retry", () => {
    testPromise("retries when count throws, eventually succeeds", async () => {
      let countItem: ReventlessInfra.Counter.countItem = {
        counterId: "c1",
        reference: "ref-1",
        inc: 1,
      }
      // Fail on first call, succeed on second
      mockCountFailUntil := 1
      mockCommonHandler :=
        async _ => (Promise.resolve([]), [Counter.Count(countItem)])
      await TestECHandler.handleJsonEvents(Stream.fromIterable([JSON.Encode.null]))->Effect.runPromise
      // count was called at least twice (1 failure + 1 success)
      expect(mockCountCallCount.contents >= 2)->toBe(true)
    })
  })
})
