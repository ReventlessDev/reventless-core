// Unit tests for HeartbeatRunner_InMemory.
// Uses fake timers to verify that the heartbeat interval fires the runtime handler.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"

// In Jest ESM mode, jest global is only available inside callbacks (not at module top level).
let _ = beforeAll(() => {
  jest->useFakeTimers
})

// ─────────────────────────────────────────────────────────────
// Restore real timers and clear heartbeat intervals after all tests
// ─────────────────────────────────────────────────────────────

let _ = afterAll(() => {
  HeartbeatRunner_InMemory.reset()
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Helper: build a minimal runtime with a completed handler Deferred
// ─────────────────────────────────────────────────────────────

let makeRuntime = (
  handler: RuntimeEnvironment_InMemory.handler,
): ReventlessCore.Runtime.environment<HeartbeatRunner_InMemory.runtimeParts> => {
  let handlerDeferred: Deferred.t<RuntimeEnvironment_InMemory.handler, unit> =
    Deferred.make()->Effect.runSync
  // Complete before any fiber waits — runSync is safe here
  Deferred.succeed(handlerDeferred, handler)->Effect.runSync->ignore
  {
    parts: {
      handlerDeferred,
      subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
    },
    resources: [],
  }
}

describe("HeartbeatRunner_InMemory", () => {
  describe("make", () => {
    testPromise("after advanceTimersByTime(timeout * 60 * 1000), handler is called", async () => {
      let count: ref<int> = ref(0)
      let runtime = makeRuntime(async (_, _) => {
        count := count.contents + 1
      })
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-test",
        ~remoteChannel=Obj.magic(()),
        ~timeout=1,
        ~runtime,
        ~opts={},
      )
      jest->advanceTimersByTime(1 * 60 * 1000)
      // Give the Effect.runPromise microtask one tick to complete
      let _ = await Promise.resolve()
      expect(count.contents)->toBe(1)
      HeartbeatRunner_InMemory.reset()
    })

    testPromise("handler fires again on each subsequent interval", async () => {
      let count: ref<int> = ref(0)
      let runtime = makeRuntime(async (_, _) => {
        count := count.contents + 1
      })
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-test-2",
        ~remoteChannel=Obj.magic(()),
        ~timeout=2,
        ~runtime,
        ~opts={},
      )
      jest->advanceTimersByTime(2 * 60 * 1000)
      let _ = await Promise.resolve()
      jest->advanceTimersByTime(2 * 60 * 1000)
      let _ = await Promise.resolve()
      expect(count.contents)->toBe(2)
      HeartbeatRunner_InMemory.reset()
    })

    testPromise("unresolved Deferred does not crash when interval fires", async () => {
      // Deferred intentionally left incomplete — simulates handler not yet registered.
      // Effect.runPromise stays pending (no crash); test verifies no exception.
      let handlerDeferred: Deferred.t<RuntimeEnvironment_InMemory.handler, unit> =
        Deferred.make()->Effect.runSync
      let runtime: ReventlessCore.Runtime.environment<HeartbeatRunner_InMemory.runtimeParts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-no-handler",
        ~remoteChannel=Obj.magic(()),
        ~timeout=1,
        ~runtime,
        ~opts={},
      )
      jest->advanceTimersByTime(1 * 60 * 1000)
      expect(true)->toBe(true)
      HeartbeatRunner_InMemory.reset()
      // Complete the Deferred to avoid open handle — interval is already cleared
      Deferred.succeed(handlerDeferred, async (_, _) => ())->Effect.runSync->ignore
    })
  })

  describe("reset", () => {
    testPromise("clears all intervals; subsequent advance does not fire handler", async () => {
      let count: ref<int> = ref(0)
      let runtime = makeRuntime(async (_, _) => {
        count := count.contents + 1
      })
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-reset",
        ~remoteChannel=Obj.magic(()),
        ~timeout=1,
        ~runtime,
        ~opts={},
      )
      HeartbeatRunner_InMemory.reset()
      jest->advanceTimersByTime(1 * 60 * 1000)
      expect(count.contents)->toBe(0)
    })
  })
})
