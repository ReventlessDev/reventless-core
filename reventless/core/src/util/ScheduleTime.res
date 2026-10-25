// When a `Schedule.time` fires, read the same way by the local timers and the AWS
// expression, so the two platforms agree. A calendar time in the hour skipped by
// daylight saving does not fire that day, as EventBridge Scheduler does.
open Reventless.Schedule

exception InvalidTime(string)

let utc = "UTC"
let zoneName = (zone: option<zone>) => zone->Option.getOr(utc)

let zoneOrThrow = name =>
  switch DateTime.zoneMakeNamed(name) {
  | Some(zone) => zone
  | None => throw(InvalidTime(`unknown time zone "${name}"`))
  }

let minuteMs = 60_000.

let intervalMs = (interval: interval) =>
  switch interval {
  | Minutes(n) => n->Int.toFloat *. minuteMs
  | Hours(n) => n->Int.toFloat *. 60. *. minuteMs
  | Days(n) => n->Int.toFloat *. 24. *. 60. *. minuteMs
  | Weeks(n) => n->Int.toFloat *. 7. *. 24. *. 60. *. minuteMs
  }

let weekdayIndex = (day: weekday) =>
  switch day {
  | Sun => 0
  | Mon => 1
  | Tue => 2
  | Wed => 3
  | Thu => 4
  | Fri => 5
  | Sat => 6
  }

let weekdayName = (day: weekday) =>
  switch day {
  | Mon => "MON"
  | Tue => "TUE"
  | Wed => "WED"
  | Thu => "THU"
  | Fri => "FRI"
  | Sat => "SAT"
  | Sun => "SUN"
  }

let errors = (time: time) => {
  let errs = []
  let check = (ok, message) => ok ? () : errs->Array.push(message)
  let positive = (n, what) => check(n >= 1, `${what} must be at least 1, got ${n->Int.toString}`)
  let clock = (hour, minute) => {
    check(hour >= 0 && hour <= 23, `hour must be 0 to 23, got ${hour->Int.toString}`)
    check(minute >= 0 && minute <= 59, `minute must be 0 to 59, got ${minute->Int.toString}`)
  }
  let dayOfMonth = day =>
    check(day >= 1 && day <= 31, `day must be 1 to 31, got ${day->Int.toString}`)
  let monthOfYear = month =>
    check(month >= 1 && month <= 12, `month must be 1 to 12, got ${month->Int.toString}`)
  let zoneKnown = zone =>
    zone->Option.forEach(name =>
      check(DateTime.zoneMakeNamed(name)->Option.isSome, `unknown time zone "${name}"`)
    )
  switch time {
  | Every(Minutes(n) | Hours(n) | Days(n) | Weeks(n)) => positive(n, "an interval")
  | Calendar({calendar, ?zone}) =>
    zoneKnown(zone)
    switch calendar {
    | Daily({hour, minute}) => clock(hour, minute)
    | Weekly({days, hour, minute}) =>
      check(days->Array.length > 0, "a weekly time needs at least one day")
      clock(hour, minute)
    | Monthly({day, hour, minute, ?every}) =>
      dayOfMonth(day)
      clock(hour, minute)
      every->Option.forEach(every =>
        check(every >= 1 && every <= 12, `every must be 1 to 12, got ${every->Int.toString}`)
      )
    | Yearly({month, day, hour, minute}) =>
      monthOfYear(month)
      dayOfMonth(day)
      clock(hour, minute)
    }
  | Once({moment, ?zone}) =>
    zoneKnown(zone)
    switch moment {
    | At({month, day, hour, minute}) =>
      monthOfYear(month)
      dayOfMonth(day)
      clock(hour, minute)
    | After(Minutes(n) | Hours(n) | Days(n) | Weeks(n) | Months(n) | Years(n)) =>
      positive(n, "a period")
    }
  }
  errs
}

/** Throws `InvalidTime` naming every problem of `time`, for a schedule about to be set. */
let validate = time =>
  switch time->errors {
  | [] => ()
  | errs => throw(InvalidTime(errs->Array.join("; ")))
  }

let localTimeOf = (millis, ~zone): localTime => {
  let parts = DateTime.makeZonedFromMillis(millis, ~zone)->DateTime.toParts
  {
    year: parts.year,
    month: parts.month,
    day: parts.day,
    hour: parts.hours,
    minute: parts.minutes,
  }
}

/**
The moment a period after `from` falls on, in `zone`. Minutes and hours are elapsed time;
days and longer keep the wall-clock time, and a month from 31 January is the last day
of February.
*/
let afterPeriod = (period: period, ~from, ~zone) => {
  let start = DateTime.makeZonedFromMillis(from, ~zone)
  switch period {
  | Minutes(n) => from +. n->Int.toFloat *. minuteMs
  | Hours(n) => from +. n->Int.toFloat *. 60. *. minuteMs
  | Days(n) => start->DateTime.add({days: n})->DateTime.toEpochMillis
  | Weeks(n) => start->DateTime.add({weeks: n})->DateTime.toEpochMillis
  | Months(n) => start->DateTime.add({months: n})->DateTime.toEpochMillis
  | Years(n) => start->DateTime.add({years: n})->DateTime.toEpochMillis
  }
}

/** `time` with an `After` turned into the `At` it falls on when counted from `from`. */
let resolveOnce = (time, ~from) =>
  switch time {
  | Once({moment: After(period), ?zone}) =>
    let tz = zoneOrThrow(zone->zoneName)
    Once({moment: At(afterPeriod(period, ~from, ~zone=tz)->localTimeOf(~zone=tz)), ?zone})
  | time => time
  }

/** The instant an `At` falls on; a time in the skipped hour moves forward by the gap. */
let instantOf = ({year, month, day, hour, minute}: localTime, ~zone) =>
  switch DateTime.makeZonedFromParts({year, month, day, hours: hour, minutes: minute}, ~zone) {
  | Some(dateTime) => dateTime->DateTime.toEpochMillis
  | None =>
    throw(
      InvalidTime(
        `no such time: ${year->Int.toString}-${month->Int.toString}-${day->Int.toString}`,
      ),
    )
  }

let wallClockOf = (calendar: calendar) =>
  switch calendar {
  | Daily({hour, minute})
  | Weekly({hour, minute})
  | Monthly({hour, minute})
  | Yearly({hour, minute}) => (hour, minute)
  }

let monthsEvery = every =>
  every <= 1 ? [] : Array.fromInitializer(~length=11 / every + 1, i => 1 + i * every)

let cronOf = (calendar: calendar, ~zone): Cron.t => {
  let (hour, minute) = calendar->wallClockOf
  let at = (~days=[], ~months=[], ~weekdays=[]) =>
    Cron.make({minutes: [minute], hours: [hour], days, months, weekdays, tz: zone})
  switch calendar {
  | Daily(_) => at()
  | Weekly({days}) => at(~weekdays=days->Array.map(weekdayIndex))
  | Monthly({day, ?every}) => at(~days=[day], ~months=every->Option.getOr(1)->monthsEvery)
  | Yearly({month, day}) => at(~days=[day], ~months=[month])
  }
}

/**
The first firing of `cron` strictly after `after` whose wall-clock time is
`hour:minute`: a time the skipped hour moved is passed over.
*/
let nextOnWallClock = (cron, ~after, ~hour, ~minute, ~zone) => {
  let rec loop = (from, tries) => {
    let next = cron->Cron.next(Date.fromTime(from))->Date.getTime
    let parts = DateTime.makeZonedFromMillis(next, ~zone)->DateTime.toParts
    (parts.hours == hour && parts.minutes == minute) || tries >= 8 ? next : loop(next, tries + 1)
  }
  loop(after, 0)
}

/**
The first firing of `time` strictly after `after`, or `None` when a once-only time is
already past. For `Every`, `after` is the previous firing, or the moment it was set.
*/
let nextFiring = (time, ~after) =>
  switch time->resolveOnce(~from=after) {
  | Every(interval) => Some(after +. interval->intervalMs)
  | Calendar({calendar, ?zone}) =>
    let tz = zoneOrThrow(zone->zoneName)
    let (hour, minute) = calendar->wallClockOf
    Some(calendar->cronOf(~zone=tz)->nextOnWallClock(~after, ~hour, ~minute, ~zone=tz))
  | Once({moment: At(localTime), ?zone}) =>
    let at = localTime->instantOf(~zone=zoneOrThrow(zone->zoneName))
    at > after ? Some(at) : None
  | Once({moment: After(_)}) => None
  }

/** What EventBridge Scheduler is given for a time. */
type awsSchedule = {
  expression: string,
  timezone?: string,
  startDate?: float,
  deleteAfterCompletion: bool,
}

let pad2 = n => n < 10 ? `0${n->Int.toString}` : n->Int.toString

let rateOf = (n, unit) => `rate(${n->Int.toString} ${unit}${n == 1 ? "" : "s"})`

let cronExpressionOf = (calendar: calendar) => {
  let (hour, minute) = calendar->wallClockOf
  let fields = switch calendar {
  | Daily(_) => "* * ? *"
  | Weekly({days}) => `? * ${days->Array.map(weekdayName)->Array.join(",")} *`
  | Monthly({day, ?every}) =>
    let month = switch every {
    | Some(every) if every > 1 => `1/${every->Int.toString}`
    | _ => "*"
    }
    `${day->Int.toString} ${month} ? *`
  | Yearly({month, day}) => `${day->Int.toString} ${month->Int.toString} ? *`
  }
  `cron(${minute->Int.toString} ${hour->Int.toString} ${fields})`
}

/**
The EventBridge Scheduler form of `time`, set at `setAt`. An `Every` starts one interval
later, as the local timer does; without a start date AWS fires at once.
*/
let toAws = (time, ~setAt) =>
  switch time->resolveOnce(~from=setAt) {
  | Every(interval) => {
      expression: switch interval {
      | Minutes(n) => rateOf(n, "minute")
      | Hours(n) => rateOf(n, "hour")
      | Days(n) => rateOf(n, "day")
      | Weeks(n) => rateOf(n * 7, "day")
      },
      startDate: setAt +. interval->intervalMs,
      deleteAfterCompletion: false,
    }
  | Calendar({calendar, ?zone}) => {
      expression: calendar->cronExpressionOf,
      timezone: zone->zoneName,
      deleteAfterCompletion: false,
    }
  | Once({moment: At({year, month, day, hour, minute}), ?zone}) => {
      expression: `at(${year->Int.toString}-${month->pad2}-${day->pad2}T${hour->pad2}:${minute->pad2}:00)`,
      timezone: zone->zoneName,
      deleteAfterCompletion: true,
    }
  | Once({moment: After(_)}) => throw(InvalidTime("unresolved once-only time"))
  }
