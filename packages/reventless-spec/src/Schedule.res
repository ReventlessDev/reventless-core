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

@schema
type rate =
  | Single(year, month, day, hour, minute)
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Daily(hour, minute)
  | Weekdays(hour, minute)
  | WeekdaysAndSaturday(hour, minute)

@schema
type schedule = {
  name: string,
  rate: rate,
  payload: string,
}

type create = schedule => Js.Promise.t<unit>
type delete = /* ~name: */ string => Js.Promise.t<unit>
