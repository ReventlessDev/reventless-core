// The local platform's Scheduler for automations: one timer per slice and key, which
// delivers `Tick({key, at})` to the slice when its time comes, as EventBridge
// Scheduler does on AWS. A slice's declared `schedule` is started under
// `Clock.defaultKey` when the slice is made.

let timers = LocalTimers.make()

let timerName = (~slice, ~key) => `${slice}/${key}`

let tickFailed = (~slice, ~key, exn) => {
  let message = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
  ReventlessCore.EffectLogger.logError(
    ~comp="LocalAutomationSchedules",
    `tick ${key} of ${slice} failed: ${message}`,
  )->Effect.runSync
}

/** Runs `tick(~key, ~at)` at every firing of `time`, replacing the slice's schedule of that key. */
let set = (~slice, ~key, time, ~tick: (~key: string, ~at: float) => promise<unit>) =>
  timers->LocalTimers.start(timerName(~slice, ~key), time, ~setAt=Date.now(), ~fire=at => {
    let _ = tick(~key, ~at)->Promise.catch(exn => {
      tickFailed(~slice, ~key, exn)
      Promise.resolve()
    })
  })

/** Stops the slice's schedule of that key; one it does not have is no error. */
let clear = (~slice, ~key) => timers->LocalTimers.stop(timerName(~slice, ~key))

/** Stops every schedule — call in afterAll/afterEach for test isolation. */
let reset = () => timers->LocalTimers.reset
