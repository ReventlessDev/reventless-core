// Integration tests for Heartbeat_Builder (in-memory).
// Verifies that makeHandler returns a callable handler and connect wires the interval.
// Adapter-level timer tests are in adapter/HeartbeatRunnerTest.res.

open AsyncTest
open AsyncTest.Expect
open HeartbeatFixtures

// ─────────────────────────────────────────────────────────────
// Fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"

let _ = beforeAll(() => {
  jest->useFakeTimers
})

let _ = afterAll(() => {
  HeartbeatRunner_InMemory.reset()
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Resolve makeHandler Output once for all tests.
// Count is per-describe block using module-level ref.
// ─────────────────────────────────────────────────────────────

let capturedCount: ref<int> = ref(0)
let mockPublish: Reventless.CommandTopic.publishJsons = async cmds => {
  capturedCount := capturedCount.contents + cmds->Array.length
}

// resolvedHandler populated in beforeAllAsync before tests run.
// makeHandler returns eventHandler<unit, 'ctx, unit> = (unit, ctx) => promise<unit>.
// The runtime handlerRef expects (JSON.t, unit) => promise<unit> — same in JS, safe to cast.
let resolvedHandler: ref<option<(unit, unit) => promise<unit>>> = ref(None)

let _ = beforeAllAsync(async () => {
  let h =
    await HeartbeatMaker.makeHandler(
      ~id="hb-id-1",
      ~timeout=1,
      ~publishToCorePluginExtensionPoint=mockPublish,
    )->TestRunner.resolve
  resolvedHandler := Some(h)
})

describe("Heartbeat_Builder.Make:", () => {
  let _ = beforeEach(() => {
    capturedCount := 0
  })

  describe("makeHandler + connect:", () => {
    testPromise("handler fires once after 1-minute interval", async () => {
      let handler = resolvedHandler.contents->Option.getUnsafe
      let heartbeat = HeartbeatMaker.make(~name="hb-test-1")
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(Some(Obj.magic(handler)))
      let runtime: ReventlessCore.Runtime.environment<HeartbeatRunner_InMemory.runtimeParts> = {
        parts: {handlerRef: handlerRef},
        resources: [],
      }
      HeartbeatMaker.connect(~runtime, ~remoteChannel=Obj.magic(()), ~timeout=1, heartbeat)
      jest->advanceTimersByTime(1 * 60 * 1000)
      expect(capturedCount.contents)->toBe(1)
      HeartbeatRunner_InMemory.reset()
    })

    testPromise("handler fires twice after two interval advances", async () => {
      let handler = resolvedHandler.contents->Option.getUnsafe
      let heartbeat = HeartbeatMaker.make(~name="hb-test-2")
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(Some(Obj.magic(handler)))
      let runtime: ReventlessCore.Runtime.environment<HeartbeatRunner_InMemory.runtimeParts> = {
        parts: {handlerRef: handlerRef},
        resources: [],
      }
      HeartbeatMaker.connect(~runtime, ~remoteChannel=Obj.magic(()), ~timeout=1, heartbeat)
      jest->advanceTimersByTime(1 * 60 * 1000)
      jest->advanceTimersByTime(1 * 60 * 1000)
      expect(capturedCount.contents)->toBe(2)
      HeartbeatRunner_InMemory.reset()
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
