// The schedules of one automation slice: a row per key, kept in the slice's schedules
// store. The rows are the truth and the platform's schedules follow them. Shared by
// the runtime and the GWT DSL, so a scenario folds `reschedule` as the runtime does.

/** The `setBy` of the row a spec's declared `schedule` writes. */
let declared = "declared"

@schema
type row = {
  key: string,
  /** The time as the JSON text of `Reventless.Schedule.timeSchema`, an `After` set by an event
      already counted from when the event was recorded. Absent when an event cleared
      the slice-wide key, so a deploy does not put the declared time back. */
  time?: string,
  /** The id of the event that set or cleared it, or `declared`. */
  setBy: string,
  setAt: string,
}

/** What the platform is told after a row changed. */
type platformChange =
  | Put({key: string, time: Reventless.Schedule.time})
  | Remove({key: string})

let encodeTime = (time: Reventless.Schedule.time) =>
  time->Reventless.Util_Sury.toJson(Reventless.Schedule.timeSchema)->JSON.stringify
let decodeTime = (text: string): Reventless.Schedule.time =>
  text->JSON.parseOrThrow->Reventless.Util_Sury.fromJson(Reventless.Schedule.timeSchema)
let timeOf = (row: row) => row.time->Option.map(decodeTime)

let iso = millis => millis->Date.fromTime->Date.toISOString

// The slice-wide key keeps a row saying it was cleared; any other key's row goes.
let clearRow = (rows: dict<row>, ~key, ~setBy, ~setAt) =>
  if key == Reventless.Clock.defaultKey {
    rows->Dict.set(key, {key, setBy, setAt})
  } else {
    rows->Dict.delete(key)
  }

/**
Applies one change an event made, recorded at `recordedAt`, and returns what the
platform is told. A time that cannot fire is refused with every problem it has, and
changes nothing.
*/
let apply = (
  rows: dict<row>,
  change: Reventless.AutomationSlice.scheduleChange,
  ~setBy,
  ~recordedAt,
): result<platformChange, string> =>
  switch change {
  | Set({key, time: wanted}) =>
    switch ScheduleTime.errors(wanted) {
    | [] =>
      let resolved = wanted->ScheduleTime.resolveOnce(~from=recordedAt)
      rows->Dict.set(key, {key, time: encodeTime(resolved), setBy, setAt: iso(recordedAt)})
      Ok(Put({key, time: resolved}))
    | errs => Error(`schedule ${key}: ${errs->Array.join("; ")}`)
    }
  | Clear({key: cleared}) =>
    clearRow(rows, ~key=cleared, ~setBy, ~setAt=iso(recordedAt))
    Ok(Remove({key: cleared}))
  }

/** A tick of `key` arrived: a once-only schedule has fired, so its row goes. */
let fired = (rows: dict<row>, ~key) =>
  rows
  ->Dict.get(key)
  ->Option.forEach(row =>
    switch row->timeOf {
    | Some(Once(_)) => clearRow(rows, ~key, ~setBy=row.setBy, ~setAt=row.setAt)
    | _ => ()
    }
  )

/**
Brings the spec's declared time into the rows under `Reventless.Clock.defaultKey`: written when
no event has set or cleared that key, replaced when the declaration changed, and
removed when the spec no longer declares one.
*/
let declare = (rows: dict<row>, declaredTime: option<Reventless.Schedule.time>, ~now) => {
  let key = Reventless.Clock.defaultKey
  let write = time =>
    rows->Dict.set(key, {key, time: encodeTime(time), setBy: declared, setAt: iso(now)})
  switch (declaredTime, rows->Dict.get(key)) {
  | (Some(time), None) => write(time)
  | (Some(time), Some(row)) if row.setBy == declared && row.time != Some(encodeTime(time)) =>
    write(time)
  | (None, Some(row)) if row.setBy == declared => rows->Dict.delete(key)
  | _ => ()
  }
}

// A once-only time already past fires no more.
let isPast = (time: Reventless.Schedule.time, ~now) =>
  switch time {
  | Once(_) => time->ScheduleTime.nextFiring(~after=now)->Option.isNone
  | _ => false
  }

/**
Brings the platform in line with the rows, after the declared time is brought in: a
schedule missing from the platform is put, the declared one is put again in case its
time changed, and one the rows do not hold is removed. A once-only time already past
is not put again, and its row goes. A row an event changed reached the platform when
it changed, so it is not put again.
*/
let reconcile = async (
  rows: dict<row>,
  platform: ReventlessInfra.AutomationSlice.platformSchedules,
  ~declaredTime,
  ~now,
) => {
  declare(rows, declaredTime, ~now)
  let live =
    rows
    ->Dict.valuesToArray
    ->Array.filterMap(row =>
      switch row->timeOf {
      | Some(time) if isPast(time, ~now) =>
        clearRow(rows, ~key=row.key, ~setBy=row.setBy, ~setAt=row.setAt)
        None
      | Some(time) => Some((row, time))
      | None => None
      }
    )
  let held = await platform.names()
  for i in 0 to live->Array.length - 1 {
    let (row, time) = live->Array.getUnsafe(i)
    if row.setBy == declared || !(held->Array.includes(platform.nameOf(row.key))) {
      await platform.put(~key=row.key, time)
    }
  }
  let wanted = live->Array.map(((row, _)) => platform.nameOf(row.key))
  let extra = held->Array.filter(name => !(wanted->Array.includes(name)))
  for i in 0 to extra->Array.length - 1 {
    await platform.removeName(extra->Array.getUnsafe(i))
  }
}

/** Tells the platform what the rows' changes were, in order. */
let tell = async (platform: ReventlessInfra.AutomationSlice.platformSchedules, changes) =>
  for i in 0 to changes->Array.length - 1 {
    switch changes->Array.getUnsafe(i) {
    | Put({key, time}) => await platform.put(~key, time)
    | Remove({key}) => await platform.removeName(platform.nameOf(key))
    }
  }
