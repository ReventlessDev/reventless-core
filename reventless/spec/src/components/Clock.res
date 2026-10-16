/**
The framework source a scheduled automation maps. When one of the slice's
schedules comes due, the platform's Scheduler fires and the slice receives
`Tick({key, at})`: which of its schedules fired (`default` for the declared one)
and the time it was scheduled for, in milliseconds since 1970 (UTC). What the tick
means is the slice's own: a mapping's `collect` makes the item, `process` sends the
command. Never written by an application.

@example
```rescript
module FromClock = Mapping.Make(
  Reventless.Clock,
  DemandReport,
  {
    open Reventless.Clock
    let collect = (Tick({key, at}), ~sourceId as _, _ctx) =>
      [(itemId(key, at), ({day: at}: DemandReport.todoItem))]
    let resolve = _ => None
  },
)
```
*/
module Id = Id.String

let name = "Clock"

@schema
type event = Tick({key: string, at: float})

/** The key a declared `schedule` is held under. */
let defaultKey = "default"

/**
The to-do item id for a tick: `<key>@<scheduled time in UTC, to the minute>`, such
as `default@2026-10-16T06:00Z`. The same tick delivered twice names the same item.
*/
let itemId = (key, at) =>
  `${key}@${at->Date.fromTime->Date.toISOString->String.slice(~start=0, ~end=16)}Z`
