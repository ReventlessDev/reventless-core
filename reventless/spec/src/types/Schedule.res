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

/**
The repetition rule for a scheduled event.

- `Single(year, month, day, hour, minute)` — fires once at an absolute UTC time
- `Minutes(n)` / `Hours(n)` / `Days(n)` — fires every n minutes / hours / days
- `Daily(hour, minute)` — fires every day at the given UTC time
- `Weekdays(hour, minute)` — fires Monday–Friday at the given UTC time
- `WeekdaysAndSaturday(hour, minute)` — fires Monday–Saturday at the given UTC time

@example
```rescript
// Fire every 15 minutes
let rate = Schedule.Minutes(15)

// Fire once on 2024-12-31 at 23:59 UTC
let oneTime = Schedule.Single(2024, 12, 31, 23, 59)
```
*/
@schema
type rate =
  | Single(year, month, day, hour, minute)
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Daily(hour, minute)
  | Weekdays(hour, minute)
  | WeekdaysAndSaturday(hour, minute)

/**
A named recurring or one-time schedule.

`payload` is an opaque string forwarded to the task handler when the schedule fires.

@example
```rescript
let dailySync: Schedule.schedule = {
  name: "DailyCatalogSync",
  rate: Daily(2, 0),  // 02:00 UTC every day
  payload: `{"action": "sync"}`,
}
```
*/
@schema
type schedule = {
  name: string,
  rate: rate,
  payload: string,
}

/** Creates a schedule in the underlying infrastructure (e.g. EventBridge Scheduler). */
type create = schedule => promise<unit>

/** Deletes a schedule by name from the underlying infrastructure. */
type delete = /* ~name: */ string => promise<unit>
