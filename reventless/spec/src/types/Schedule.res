@schema
type year = int
@schema
type month = int
@schema
type day = int
@schema
type hour = int
@schema
type minute = int

/** A fixed length, measured from the previous firing. */
@schema
type interval =
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Weeks(int)

@schema
type weekday = Mon | Tue | Wed | Thu | Fri | Sat | Sun

/**
A wall-clock time that recurs. `Monthly` with `every: 3` fires in January, April, July
and October; a `day` a month does not have (the 31st) is skipped in that month.
*/
@schema
type calendar =
  | Daily({hour: hour, minute: minute})
  | Weekly({days: array<weekday>, hour: hour, minute: minute})
  | Monthly({day: day, hour: hour, minute: minute, every?: int})
  | Yearly({month: month, day: day, hour: hour, minute: minute})

/** A span counted once, from the moment a schedule is set; months and years by the calendar. */
@schema
type period =
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Weeks(int)
  | Months(int)
  | Years(int)

/** A wall-clock date and time, read in the schedule's zone. */
@schema
type localTime = {year: year, month: month, day: day, hour: hour, minute: minute}

/** `After` becomes `At` when the schedule is set. */
@schema
type moment = At(localTime) | After(period)

/** An IANA zone name such as `Europe/Berlin`; absent means UTC. */
@schema
type zone = string

/**
When a schedule fires: `Every` an interval, `Calendar` a wall-clock time that recurs,
or `Once` a single moment.

A calendar time in the hour skipped by daylight saving does not fire that day; one in
the repeated hour fires once, at the first.

@example
```rescript
// every 15 minutes
let every = Schedule.Every(Minutes(15))

// weekdays at 07:30 in Berlin
let weekdays = Schedule.Calendar({
  calendar: Weekly({days: [Mon, Tue, Wed, Thu, Fri], hour: 7, minute: 30}),
  zone: "Europe/Berlin",
})

// once, ten minutes after it is set
let reminder = Schedule.Once({moment: After(Minutes(10))})
```
*/
@schema
type time =
  | Every(interval)
  | Calendar({calendar: calendar, zone?: zone})
  | Once({moment: moment, zone?: zone})

/**
A named schedule.

`payload` is an opaque string forwarded to the target when the schedule fires.

@example
```rescript
let dailySync: Schedule.schedule = {
  name: "DailyCatalogSync",
  time: Calendar({calendar: Daily({hour: 2, minute: 0})}),
  payload: `{"action": "sync"}`,
}
```
*/
@schema
type schedule = {
  name: string,
  time: time,
  payload: string,
}

/** Creates a schedule in the underlying infrastructure (e.g. EventBridge Scheduler). */
type create = schedule => promise<unit>

/** Deletes a schedule by name from the underlying infrastructure. */
type delete = /* ~name: */ string => promise<unit>
