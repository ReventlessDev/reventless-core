/**
ReScript bindings for `DateTime` — instants read in a named time zone, with
calendar arithmetic in that zone.

Only what scheduling needs is bound: naming a zone, reading an instant in it,
building one from wall-clock parts, adding to it and taking its parts.

**Example**
```rescript
let berlin = DateTime.zoneMakeNamed("Europe/Berlin")->Option.getOrThrow
let lastOfFebruary =
  DateTime.makeZonedFromMillis(Date.UTC(2026., 0., 31., 9., 0.), ~zone=berlin)
  ->DateTime.add({months: 1})
```
*/
type t

/** A time zone; build one with `zoneMakeNamed`. */
type zone

@module("effect/DateTime")
external zoneMakeNamedRaw: string => EffectOption.t<zone> = "zoneMakeNamed"

/** The IANA zone of this name (`Europe/Berlin`, `UTC`), or `None` when there is none. */
let zoneMakeNamed = name => name->zoneMakeNamedRaw->EffectOption.toOption

type zonedOptions = {timeZone: zone, adjustForTimeZone?: bool}

@module("effect/DateTime")
external unsafeMakeZoned: (float, zonedOptions) => t = "unsafeMakeZoned"

/** The instant `millis` (since 1970, UTC), read in `zone`. */
let makeZonedFromMillis = (millis, ~zone) => unsafeMakeZoned(millis, {timeZone: zone})

/** Wall-clock parts; `month` counts from 1. */
type parts = {
  year: int,
  month: int,
  day: int,
  hours: int,
  minutes: int,
  seconds?: int,
  millis?: int,
}

@module("effect/DateTime")
external makeZonedRaw: (parts, zonedOptions) => EffectOption.t<t> = "makeZoned"

/**
The instant showing `parts` on a wall clock in `zone`. A time in the hour skipped by
daylight saving moves forward by the gap; one that occurs twice is the first.
*/
let makeZonedFromParts = (parts, ~zone) =>
  makeZonedRaw(parts, {timeZone: zone, adjustForTimeZone: true})->EffectOption.toOption

/** Amounts to add; each counts on the wall clock of the value's zone. */
type amount = {
  minutes?: int,
  hours?: int,
  days?: int,
  weeks?: int,
  months?: int,
  years?: int,
}

/**
Adds `amount` in the value's zone: a month from 31 January is the last day of
February. Units of a day or more keep the wall-clock time across a daylight-saving
change, and so does `hours: 24`; add a fixed length to the epoch milliseconds instead.
*/
@module("effect/DateTime")
external add: (t, amount) => t = "add"

/** Milliseconds since 1970, UTC. */
@module("effect/DateTime")
external toEpochMillis: t => float = "toEpochMillis"

/** Wall-clock parts in the value's zone; `month` counts from 1, `weekDay` from 0 (Sunday). */
type wallClock = {
  year: int,
  month: int,
  day: int,
  hours: int,
  minutes: int,
  seconds: int,
  millis: int,
  weekDay: int,
}

@module("effect/DateTime")
external toParts: t => wallClock = "toParts"
