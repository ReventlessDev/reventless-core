// Unit tests for HeartbeatRunner_InMemory.
// Uses fake timers to verify that the heartbeat interval fires the runtime handler.

open AsyncTest
open AsyncTest.Expect

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
// Helper: build a minimal runtime environment
// ─────────────────────────────────────────────────────────────

let makeRuntime = (
  handlerRef: ref<option<(JSON.t, unit) => promise<unit>>>,
): Reventless.Runtime.environment<HeartbeatRunner_InMemory.runtimeParts> => {
  parts: {handlerRef: handlerRef},
  resources: [],
}

describe("HeartbeatRunner_InMemory", () => {
  describe("make", () => {
    testPromise("after advanceTimersByTime(timeout * 60 * 1000), handler is called", async () => {
      let count: ref<int> = ref(0)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (_, _) => {
            count := count.contents + 1
          },
        )
      let runtime = makeRuntime(handlerRef)
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-test",
        ~remoteChannel=Obj.magic(()),
        ~timeout=1,
        ~runtime,
        ~opts={},
      )
      jest->advanceTimersByTime(1 * 60 * 1000)
      expect(count.contents)->toBe(1)
      HeartbeatRunner_InMemory.reset()
    })

    testPromise("handler fires again on each subsequent interval", async () => {
      let count: ref<int> = ref(0)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (_, _) => {
            count := count.contents + 1
          },
        )
      let runtime = makeRuntime(handlerRef)
      let _runner = HeartbeatRunner_InMemory.make(
        ~name="hb-test-2",
        ~remoteChannel=Obj.magic(()),
        ~timeout=2,
        ~runtime,
        ~opts={},
      )
      jest->advanceTimersByTime(2 * 60 * 1000)
      jest->advanceTimersByTime(2 * 60 * 1000)
      expect(count.contents)->toBe(2)
      HeartbeatRunner_InMemory.reset()
    })

    testPromise("unset handlerRef does not crash when interval fires", async () => {
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      // handlerRef intentionally left as None
      let runtime = makeRuntime(handlerRef)
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
    })
  })

  describe("reset", () => {
    testPromise("clears all intervals; subsequent advance does not fire handler", async () => {
      let count: ref<int> = ref(0)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (_, _) => {
            count := count.contents + 1
          },
        )
      let runtime = makeRuntime(handlerRef)
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
