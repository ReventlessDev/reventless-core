// In-memory HeartbeatRunner — satisfies Heartbeat_Adapter.Runner.
//
// Instead of creating a CloudWatch Event Rule (as in AWS), sets up a setInterval
// that fires the heartbeat handler directly at the configured timeout interval.
//
// Usage: pass HeartbeatRunner_InMemory to Plugin_Builder.Make as the HeartbeatRunner
// parameter when building a plugin in test/local mode.
//
// Call reset() in afterAll/afterEach to clear active timers between test suites.

type runtimeParts = RuntimeEnvironment_InMemory.parts

type timerHandle

@val
external setIntervalJs: (unit => unit, int) => timerHandle = "setInterval"
@val
external clearIntervalJs: timerHandle => unit = "clearInterval"

let activeTimers: ref<dict<timerHandle>> = ref(Dict.make())

let make: Reventless.Heartbeat_Adapter.runnerMaker<runtimeParts> = (
  ~name,
  ~remoteChannel as _,
  ~timeout,
  ~runtime,
  ~opts as _,
) => {
  let handlerRef = runtime.parts.handlerRef
  let intervalMs = timeout * 60 * 1000
  let handle = setIntervalJs(
    () => {
      switch handlerRef.contents {
      | Some(handler) =>
        // Heartbeat callback ignores both arguments; Obj.magic converts unit to JSON.t.
        handler(Obj.magic(()), ())->ignore
      | None => ()
      }
    },
    intervalMs,
  )
  activeTimers.contents->Dict.set(name, handle)
  {resources: []}
}

// Clear all active heartbeat timers. Call in afterAll for test isolation.
let reset = () => {
  activeTimers.contents->Dict.valuesToArray->Array.forEach(clearIntervalJs)
  activeTimers.contents = Dict.make()
}
