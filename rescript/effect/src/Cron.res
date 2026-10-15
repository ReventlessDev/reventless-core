/**
ReScript bindings for `Cron` — calendar times and their next occurrence in a zone.

Always give a zone: a `Cron` made without one is read in the machine's zone.

**Example**
```rescript
let utc = DateTime.zoneMakeNamed("UTC")->Option.getOrThrow
let weekdays0730 = Cron.make({
  minutes: [30],
  hours: [7],
  days: [],
  months: [],
  weekdays: [1, 2, 3, 4, 5],
  tz: utc,
})
let next = weekdays0730->Cron.next(Date.make())
```
*/
type t

/** The values a field takes; an empty array means every value. `weekdays` count from 0 (Sunday). */
type values = {
  minutes: array<int>,
  hours: array<int>,
  days: array<int>,
  months: array<int>,
  weekdays: array<int>,
  tz: DateTime.zone,
}

@module("effect/Cron")
external make: values => t = "make"

/**
The first occurrence strictly after `from`. In the hour skipped by daylight saving a
local time moves forward by the gap; in the repeated hour it occurs once, at the first.
*/
@module("effect/Cron")
external next: (t, Date.t) => Date.t = "next"

/** Parses a five-field expression (`minute hour day month weekday`), read in `zone`; throws when malformed. */
@module("effect/Cron")
external parseOrThrow: (string, DateTime.zone) => t = "unsafeParse"
