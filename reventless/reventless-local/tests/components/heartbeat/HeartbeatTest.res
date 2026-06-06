// Integration tests for Heartbeat_Builder (in-memory).
// Verifies that makeHandler returns a callable handler and connect wires the interval.
// Adapter-level timer tests are in adapter/HeartbeatRunnerTest.res.

open TestFixtures
open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open HeartbeatFixtures

describe("Heartbeat_Builder.Make:", () => {
  let _ = beforeEach(() => {
    capturedCount := 0
  })

  describe("makeHandler + connect:", () => {
    testPromise("handler fires once after 1-minute interval", async () => {
      let handler = resolvedHandler.contents->Option.getUnsafe
      let heartbeat = HeartbeatMaker.make(~name="hb-test-1")
      let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
        Deferred.make()->Effect.runSync
      Deferred.succeed(handlerDeferred, Obj.magic(handler))->Effect.runSync->ignore
      let runtime: ReventlessCore.Runtime.environment<LocalHeartbeatRunner.runtimeParts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      HeartbeatMaker.connect(~runtime, ~remoteChannel=Obj.magic(()), ~timeout=1, heartbeat)
      jest->advanceTimersByTime(1 * 60 * 1000)
      // Give the Effect.runPromise microtask one tick to complete
      let _ = await Promise.resolve()
      expect(capturedCount.contents)->toBe(1)
      LocalHeartbeatRunner.reset()
    })

    testPromise("handler fires twice after two interval advances", async () => {
      let handler = resolvedHandler.contents->Option.getUnsafe
      let heartbeat = HeartbeatMaker.make(~name="hb-test-2")
      let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
        Deferred.make()->Effect.runSync
      Deferred.succeed(handlerDeferred, Obj.magic(handler))->Effect.runSync->ignore
      let runtime: ReventlessCore.Runtime.environment<LocalHeartbeatRunner.runtimeParts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      HeartbeatMaker.connect(~runtime, ~remoteChannel=Obj.magic(()), ~timeout=1, heartbeat)
      jest->advanceTimersByTime(1 * 60 * 1000)
      let _ = await Promise.resolve()
      jest->advanceTimersByTime(1 * 60 * 1000)
      let _ = await Promise.resolve()
      expect(capturedCount.contents)->toBe(2)
      LocalHeartbeatRunner.reset()
    })
  })

  describe("make:", () => {
    testPromise("creates a heartbeat component without throwing", async () => {
      let heartbeat = HeartbeatMaker.make(~name="hb-make-smoke")
      // Just verify component creation succeeds
      let _ = heartbeat
      expect(true)->toBe(true)
    })
  })
})
