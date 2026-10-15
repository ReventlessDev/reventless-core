// When each shape of a Schedule.time fires, and that the AWS expression of a calendar
// time names the same firings the local timer waits for.

open JestGlobals
open Reventless.Schedule

let at = iso => Date.fromString(iso)->Date.getTime
let iso = millis => millis->Date.fromTime->Date.toISOString

/** The first `n` firings of `time` after `from`, in UTC. */
let firings = (time, ~from, ~n) => {
  let out = []
  let rec loop = after =>
    switch out->Array.length < n ? ScheduleTime.nextFiring(time, ~after) : None {
    | Some(next) =>
      out->Array.push(next->iso)
      loop(next)
    | None => ()
    }
  loop(from->at)
  out
}

describe("ScheduleTime.nextFiring", () => {
  testSync("Every counts from the previous firing, with no zone", () => {
    expect(firings(Every(Hours(2)), ~from="2026-03-29T00:30:00Z", ~n=2))->toEqual([
      "2026-03-29T02:30:00.000Z",
      "2026-03-29T04:30:00.000Z",
    ])
  })

  testSync("Daily is a wall-clock time in its zone, across both daylight-saving changes", () => {
    let daily = Calendar({calendar: Daily({hour: 6, minute: 0}), zone: "Europe/Berlin"})
    expect(firings(daily, ~from="2026-03-28T12:00:00Z", ~n=2))->toEqual([
      "2026-03-29T04:00:00.000Z",
      "2026-03-30T04:00:00.000Z",
    ])
    expect(firings(daily, ~from="2026-10-24T12:00:00Z", ~n=2))->toEqual([
      "2026-10-25T05:00:00.000Z",
      "2026-10-26T05:00:00.000Z",
    ])
  })

  testSync("a time in the skipped hour does not fire that day; in the repeated hour, once", () => {
    let night = Calendar({calendar: Daily({hour: 2, minute: 30}), zone: "Europe/Berlin"})
    expect(firings(night, ~from="2026-03-27T12:00:00Z", ~n=2))->toEqual([
      "2026-03-28T01:30:00.000Z",
      "2026-03-30T00:30:00.000Z",
    ])
    expect(firings(night, ~from="2026-10-24T12:00:00Z", ~n=2))->toEqual([
      "2026-10-25T00:30:00.000Z",
      "2026-10-26T01:30:00.000Z",
    ])
  })

  testSync("Weekly fires on its days only", () => {
    let weekdays = Calendar({calendar: Weekly({days: [Mon, Fri], hour: 7, minute: 30})})
    expect(firings(weekdays, ~from="2026-10-16T08:00:00Z", ~n=3))->toEqual([
      "2026-10-19T07:30:00.000Z",
      "2026-10-23T07:30:00.000Z",
      "2026-10-26T07:30:00.000Z",
    ])
  })

  testSync("Monthly on the 29th to 31st skips the months without that day", () => {
    let on = day => Calendar({calendar: Monthly({day, hour: 6, minute: 0})})
    expect(firings(on(29), ~from="2027-01-30T00:00:00Z", ~n=1))->toEqual([
      "2027-03-29T06:00:00.000Z",
    ])
    expect(firings(on(30), ~from="2027-01-31T00:00:00Z", ~n=1))->toEqual([
      "2027-03-30T06:00:00.000Z",
    ])
    expect(firings(on(31), ~from="2026-04-01T00:00:00Z", ~n=2))->toEqual([
      "2026-05-31T06:00:00.000Z",
      "2026-07-31T06:00:00.000Z",
    ])
  })

  testSync("Monthly with every fires every so many months, from January", () => {
    let quarterly = Calendar({calendar: Monthly({day: 1, hour: 6, minute: 0, every: 3})})
    expect(firings(quarterly, ~from="2026-02-15T00:00:00Z", ~n=4))->toEqual([
      "2026-04-01T06:00:00.000Z",
      "2026-07-01T06:00:00.000Z",
      "2026-10-01T06:00:00.000Z",
      "2027-01-01T06:00:00.000Z",
    ])
  })

  testSync("Yearly on 29 February fires in leap years", () => {
    let leap = Calendar({calendar: Yearly({month: 2, day: 29, hour: 6, minute: 0})})
    expect(firings(leap, ~from="2026-01-01T00:00:00Z", ~n=2))->toEqual([
      "2028-02-29T06:00:00.000Z",
      "2032-02-29T06:00:00.000Z",
    ])
  })

  testSync("Once at a local time fires once, read in its zone; once past, never", () => {
    let newYear = Once({
      moment: At({year: 2026, month: 12, day: 31, hour: 23, minute: 59}),
      zone: "Europe/Berlin",
    })
    expect(firings(newYear, ~from="2026-10-16T00:00:00Z", ~n=3))->toEqual([
      "2026-12-31T22:59:00.000Z",
    ])
    expect(firings(newYear, ~from="2027-01-01T00:00:00Z", ~n=1))->toEqual([])
  })
})

describe("ScheduleTime.resolveOnce", () => {
  let resolved = (period, ~from, ~zone="UTC") =>
    switch Once({moment: After(period), zone})->ScheduleTime.resolveOnce(~from=from->at) {
    | Once({moment: At(localTime)}) => Some(localTime)
    | _ => None
    }

  testSync("a month from 31 January is the last day of February", () => {
    expect(resolved(Months(1), ~from="2026-01-31T09:00:00Z"))->toEqual(
      Some({year: 2026, month: 2, day: 28, hour: 9, minute: 0}),
    )
  })

  testSync("a day keeps the wall-clock time across a daylight-saving change", () => {
    expect(resolved(Days(1), ~from="2026-03-28T05:00:00Z", ~zone="Europe/Berlin"))->toEqual(
      Some({year: 2026, month: 3, day: 29, hour: 6, minute: 0}),
    )
  })

  testSync("24 hours are elapsed time across the same change", () => {
    expect(resolved(Hours(24), ~from="2026-03-28T05:00:00Z", ~zone="Europe/Berlin"))->toEqual(
      Some({year: 2026, month: 3, day: 29, hour: 7, minute: 0}),
    )
  })

  testSync("minutes are counted from the moment it is set, to the minute", () => {
    expect(resolved(Minutes(10), ~from="2026-10-15T14:02:37Z"))->toEqual(
      Some({year: 2026, month: 10, day: 15, hour: 14, minute: 12}),
    )
  })
})

describe("ScheduleTime.toAws", () => {
  let setAt = "2026-10-15T14:02:00Z"->at

  testSync("an interval is a rate, starting one interval later", () => {
    let aws = Every(Weeks(2))->ScheduleTime.toAws(~setAt)
    expect(aws.expression)->toBe("rate(14 days)")
    expect(aws.startDate)->toEqual(Some(setAt +. 14. *. 24. *. 60. *. 60_000.))
    expect(aws.timezone)->toEqual(None)
    expect((Every(Minutes(1))->ScheduleTime.toAws(~setAt)).expression)->toBe("rate(1 minute)")
  })

  testSync("a calendar time is a cron with its zone, UTC when it has none", () => {
    let daily = Calendar({calendar: Daily({hour: 6, minute: 0})})->ScheduleTime.toAws(~setAt)
    expect(daily.expression)->toBe("cron(0 6 * * ? *)")
    expect(daily.timezone)->toEqual(Some("UTC"))
    let weekly = Calendar({
      calendar: Weekly({days: [Mon, Tue, Wed, Thu, Fri], hour: 7, minute: 30}),
      zone: "Europe/Berlin",
    })->ScheduleTime.toAws(~setAt)
    expect(weekly.expression)->toBe("cron(30 7 ? * MON,TUE,WED,THU,FRI *)")
    expect(weekly.timezone)->toEqual(Some("Europe/Berlin"))
    expect(
      (
        Calendar({calendar: Monthly({day: 1, hour: 6, minute: 0, every: 3})})->ScheduleTime.toAws(
          ~setAt,
        )
      ).expression,
    )->toBe("cron(0 6 1 1/3 ? *)")
    expect(
      (
        Calendar({calendar: Yearly({month: 12, day: 24, hour: 18, minute: 0})})->ScheduleTime.toAws(
          ~setAt,
        )
      ).expression,
    )->toBe("cron(0 18 24 12 ? *)")
  })

  testSync("a once-only time is an at in its zone, deleted after it fires", () => {
    let aws = Once({moment: After(Days(3)), zone: "Europe/Berlin"})->ScheduleTime.toAws(~setAt)
    expect(aws.expression)->toBe("at(2026-10-18T16:02:00)")
    expect(aws.timezone)->toEqual(Some("Europe/Berlin"))
    expect(aws.deleteAfterCompletion)->toBe(true)
  })
})

describe("the two platforms agree", () => {
  // The AWS cron, read as the five-field expression Effect parses, and the local
  // nextFiring give the same next ten firings. Daylight saving is AWS's documented rule.
  let fromAws = (calendar, ~zone) => {
    let fields =
      calendar
      ->ScheduleTime.cronExpressionOf
      ->String.slice(~start=5, ~end=-1)
      ->String.split(" ")
      ->Array.map(f => f == "?" ? "*" : f)
    let expression = fields->Array.slice(~start=0, ~end=5)->Array.join(" ")
    let tz = ScheduleTime.zoneOrThrow(zone)
    let (hour, minute) = calendar->ScheduleTime.wallClockOf
    let cron = Cron.parseOrThrow(expression, tz)
    let out = []
    let rec loop = after =>
      if out->Array.length < 10 {
        let next = cron->ScheduleTime.nextOnWallClock(~after, ~hour, ~minute, ~zone=tz)
        out->Array.push(next->iso)
        loop(next)
      }
    loop("2026-01-01T00:00:00Z"->at)
    out
  }

  let cases: array<(string, calendar, string)> = [
    ("daily", Daily({hour: 6, minute: 0}), "UTC"),
    ("daily in the skipped hour", Daily({hour: 2, minute: 30}), "Europe/Berlin"),
    (
      "weekdays",
      Weekly({days: [Mon, Tue, Wed, Thu, Fri], hour: 7, minute: 30}),
      "America/New_York",
    ),
    ("weekends", Weekly({days: [Sat, Sun], hour: 23, minute: 59}), "Australia/Sydney"),
    ("monthly on the 31st", Monthly({day: 31, hour: 6, minute: 0}), "Europe/Berlin"),
    ("quarterly", Monthly({day: 15, hour: 9, minute: 15, every: 3}), "Asia/Kolkata"),
    ("every five months", Monthly({day: 1, hour: 0, minute: 0, every: 5}), "UTC"),
    ("yearly", Yearly({month: 3, day: 29, hour: 2, minute: 30}), "Europe/London"),
  ]

  cases->Array.forEach(((label, calendar, zone)) =>
    testSync(
      label,
      () => {
        expect(fromAws(calendar, ~zone))->toEqual(
          firings(Calendar({calendar, zone}), ~from="2026-01-01T00:00:00Z", ~n=10),
        )
      },
    )
  )
})

describe("ScheduleTime.validate", () => {
  testSync("names every problem of a time", () => {
    let message = switch ScheduleTime.validate(
      Calendar({calendar: Weekly({days: [], hour: 24, minute: 0}), zone: "Mars/Base"}),
    ) {
    | () => ""
    | exception ScheduleTime.InvalidTime(message) => message
    }
    expect(
      message,
    )->toBe(`unknown time zone "Mars/Base"; a weekly time needs at least one day; hour must be 0 to 23, got 24`)
  })

  testSync("accepts a time that can fire", () => {
    expect(
      ScheduleTime.errors(Once({moment: After(Years(1)), zone: "Pacific/Auckland"})),
    )->toEqual([])
  })
})
