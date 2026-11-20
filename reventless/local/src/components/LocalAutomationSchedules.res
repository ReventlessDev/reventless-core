// The local platform's Scheduler for automations: one timer per slice and key, which
// delivers `Tick({key, at})` to the slice when its time comes, as EventBridge
// Scheduler does on AWS. A slice registers how it is ticked when it is made; its
// schedules are put by its rows, through `platformFor`.

let timers = LocalTimers.make()

let ticks: dict<(~key: string, ~at: float) => promise<unit>> = Dict.make()

/** Each schedule put, by its timer's name: its slice, its key and its time, resolved, so it can
    be listed with when it next fires. */
type scheduled = {slice: string, key: string, time: Reventless.Schedule.time}

let scheduled: dict<scheduled> = Dict.make()

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
  put: async (~key, time) => {
    let setAt = Date.now()
    timers->LocalTimers.start(timerName(~slice, ~key), time, ~setAt, ~fire=at =>
      fire(~slice, ~key, at)
    )
    scheduled->Dict.set(
      timerName(~slice, ~key),
      {slice, key, time: time->ReventlessCore.ScheduleTime.resolveOnce(~from=setAt)},
    )
  },
  removeName: async key => {
    timers->LocalTimers.stop(timerName(~slice, ~key))
    scheduled->Dict.delete(timerName(~slice, ~key))
  },
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

/** A schedule as a caller sees it: its slice, its key, and when it next fires, if it does. */
type listed = {slice: string, key: string, next?: float}

/** The schedules put, each with its next firing after now, the soonest first. */
let list = (~now=Date.now()): array<listed> =>
  scheduled
  ->Dict.valuesToArray
  ->Array.map(s => {
    slice: s.slice,
    key: s.key,
    next: ?ReventlessCore.ScheduleTime.nextFiring(s.time, ~after=now),
  })
  ->Array.toSorted((a, b) =>
    Float.compare(
      a.next->Option.getOr(Float.Constants.maxValue),
      b.next->Option.getOr(Float.Constants.maxValue),
    )
  )

/** Ticks a slice's schedule now, at the current time, as if it were due: nothing is backdated,
    and its next firing stays where it was. Error when no such schedule is put. */
let fireNow = async (~slice, ~key, ~now=Date.now()): result<float, string> =>
  switch (scheduled->Dict.get(timerName(~slice, ~key)), ticks->Dict.get(slice)) {
  | (Some(_), Some(tick)) =>
    await tick(~key, ~at=now)
    Ok(now)
  | (None, _) => Error(`no schedule ${key} of ${slice}`)
  | (Some(_), None) => Error(`the slice ${slice} is not registered`)
  }

/** Stops every schedule and forgets every slice — call in afterAll/afterEach for test isolation. */
let reset = () => {
  timers->LocalTimers.reset
  scheduled->Dict.keysToArray->Array.forEach(name => scheduled->Dict.delete(name))
  ticks->Dict.keysToArray->Array.forEach(slice => ticks->Dict.delete(slice))
}
