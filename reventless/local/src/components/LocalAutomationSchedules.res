// The local platform's Scheduler for automations: one timer per slice and key, which
// delivers `Tick({key, at})` to the slice when its time comes, as EventBridge
// Scheduler does on AWS. A slice registers how it is ticked when it is made; its
// schedules are put by its rows, through `platformFor`.

let timers = LocalTimers.make()

let ticks: dict<(~key: string, ~at: float) => promise<unit>> = Dict.make()

let timerName = (~slice, ~key) => `${slice}/${key}`

let tickFailed = (~slice, ~key, message) =>
  ReventlessCore.EffectLogger.logError(
    ~comp="LocalAutomationSchedules",
    `tick ${key} of ${slice} failed: ${message}`,
  )->Effect.runSync

/** How the slice is ticked when one of its schedules comes due. */
let register = (~slice, tick) => ticks->Dict.set(slice, tick)

let fire = (~slice, ~key, at) =>
  switch ticks->Dict.get(slice) {
  | Some(tick) =>
    let _ = tick(~key, ~at)->Promise.catch(exn => {
      tickFailed(
        ~slice,
        ~key,
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"),
      )
      Promise.resolve()
    })
  | None => tickFailed(~slice, ~key, "the slice is not registered")
  }

/** The slice's schedules on the local platform, named by their keys. */
let platformFor = (~slice): ReventlessInfra.AutomationSlice.platformSchedules => {
  put: async (~key, time) =>
    timers->LocalTimers.start(timerName(~slice, ~key), time, ~setAt=Date.now(), ~fire=at =>
      fire(~slice, ~key, at)
    ),
  removeName: async key => timers->LocalTimers.stop(timerName(~slice, ~key)),
  names: async () => {
    let prefix = timerName(~slice, ~key="")
    timers.contents
    ->Dict.keysToArray
    ->Array.filterMap(name =>
      name->String.startsWith(prefix)
        ? Some(name->String.slice(~start=prefix->String.length))
        : None
    )
  },
  nameOf: key => key,
}

/** Stops every schedule and forgets every slice — call in afterAll/afterEach for test isolation. */
let reset = () => {
  timers->LocalTimers.reset
  ticks->Dict.keysToArray->Array.forEach(slice => ticks->Dict.delete(slice))
}
