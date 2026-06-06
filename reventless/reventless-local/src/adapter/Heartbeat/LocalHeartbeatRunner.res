// In-memory HeartbeatRunner — satisfies Heartbeat_Adapter.Runner.
//
// Instead of creating a CloudWatch Event Rule (as in AWS), sets up a setInterval
// that fires the heartbeat handler directly at the configured timeout interval.
//
// Awaits the handler Deferred on each tick — no None check, no warning log.
// After the first tick the Deferred is already completed, so subsequent await_
// calls return immediately.
//
// Usage: pass LocalHeartbeatRunner to Plugin_Builder.Make as the HeartbeatRunner
// parameter when building a plugin in test/local mode.
//
// Call reset() in afterAll/afterEach to clear active timers between test suites.

type runtimeParts = LocalRuntimeEnvironment.parts

type timerHandle

@val
external setIntervalJs: (unit => unit, int) => timerHandle = "setInterval"
@val
external clearIntervalJs: timerHandle => unit = "clearInterval"

let activeTimers: ref<dict<timerHandle>> = ref(Dict.make())

let make: ReventlessCore.Heartbeat_Adapter.runnerMaker<runtimeParts> = (
  ~name,
  ~remoteChannel as _,
  ~timeout,
  ~runtime,
  ~opts as _,
) => {
  let handlerDeferred = runtime.parts.handlerDeferred
  let intervalMs = timeout * 60 * 1000
  let handle = setIntervalJs(
    () => {
      // Await the handler Deferred on each tick. Since the Deferred is completed
      // during make() setup, this resolves immediately after the first tick.
      handlerDeferred
      ->Deferred.await_
      ->Effect.flatMap(handler =>
        Effect.promise(() => handler(Obj.magic(()), ()))
      )
      ->Effect.runPromise
      ->ignore
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
