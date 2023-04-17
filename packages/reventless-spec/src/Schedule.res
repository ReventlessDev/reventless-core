@decco
type year = int
@decco
type month = int
@decco
type day = int
@decco
type hour = int
@decco
type minute = int

@decco
type rate =
  | Single(year, month, day, hour, minute)
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Daily(hour, minute)
  | Weekdays(hour, minute)
  | WeekdaysAndSaturday(hour, minute)

@decco
type schedule = {
  name: string,
  rate: rate,
  payload: string,
}

type create = (. schedule) => Js.Promise.t<unit>
type delete = (. /* ~name: */ string) => Js.Promise.t<unit>
