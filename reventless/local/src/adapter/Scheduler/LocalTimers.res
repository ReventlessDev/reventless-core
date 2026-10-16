// Timers that wait for each firing of a `Schedule.time`, as `ScheduleTime.nextFiring`
// names it, and call `fire` with the scheduled time. Shared by the scheduled publisher
// and the automations' schedules, so both fire when AWS would.

type timerHandle

@val
external setTimeoutJs: (unit => unit, float) => timerHandle = "setTimeout"
@val
external clearTimerJs: timerHandle => unit = "clearTimeout"

/** The pending wait of each timer, by name. */
type t = ref<dict<timerHandle>>

let make = (): t => ref(Dict.make())

// Node fires a delay above 2^31 - 1 ms at once, so a far firing is reached a day at a time.
let maxWaitMs = 86_400_000.

let stop = (timers: t, name) =>
  switch timers.contents->Dict.get(name) {
  | Some(handle) =>
    clearTimerJs(handle)
    timers.contents->Dict.delete(name)
  | None => ()
  }

let rec waitUntil = (timers: t, name, at, fire) => {
  let delay = at -. Date.now()
  let handle =
    delay > maxWaitMs
      ? setTimeoutJs(() => waitUntil(timers, name, at, fire), maxWaitMs)
      : setTimeoutJs(fire, Math.max(delay, 0.))
  timers.contents->Dict.set(name, handle)
}

let rec arm = (timers: t, name, time, ~after, ~fire) =>
  switch ReventlessCore.ScheduleTime.nextFiring(time, ~after) {
  | None => timers.contents->Dict.delete(name)
  | Some(at) =>
    waitUntil(timers, name, at, () => {
      fire(at)
      arm(timers, name, time, ~after=at, ~fire)
    })
  }

/**
Fires `fire(at)` at every firing of `time` after `setAt`, replacing a timer of the
same name. A once-only time fires once; one already past never. Throws
`ScheduleTime.InvalidTime` for a time that cannot fire.
*/
let start = (timers: t, name, time, ~setAt, ~fire) => {
  ReventlessCore.ScheduleTime.validate(time)
  stop(timers, name)
  arm(timers, name, time->ReventlessCore.ScheduleTime.resolveOnce(~from=setAt), ~after=setAt, ~fire)
}

/** Clears every timer — call in afterAll/afterEach for test isolation. */
let reset = (timers: t) => {
  timers.contents->Dict.valuesToArray->Array.forEach(clearTimerJs)
  timers.contents = Dict.make()
}
