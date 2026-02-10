/* Import moment directly in raw JS blocks below */

/* duration */
module Duration = {
  type t
  @send external humanize: t => string = "humanize"
  @send external milliseconds: t => int = "milliseconds"
  @send external asMilliseconds: t => float = "asMilliseconds"
  @send external seconds: t => int = "seconds"
  @send external asSeconds: t => float = "asSeconds"
  @send external minutes: t => int = "minutes"
  @send external asMinutes: t => float = "asMinutes"
  @send external hours: t => int = "hours"
  @send external asHours: t => float = "asHours"
  @send external days: t => int = "days"
  @send external asDays: t => float = "asDays"
  @send external weeks: t => int = "weeks"
  @send external asWeeks: t => float = "asWeeks"
  @send external months: t => int = "months"
  @send external asMonths: t => float = "asMonths"
  @send external years: t => int = "years"
  @send external asYears: t => float = "asYears"
  @send external toJSON: t => string = "toJSON"
  @send external toISOString: t => string = "toISOString"
  @send
  external asUnitOfTime: (
    t,
    [
      | #years
      | #quarters
      | #months
      | #weeks
      | #days
      | #hours
      | #minutes
      | #seconds
      | #milliseconds
    ],
  ) => float = "as"
}

@module("moment") @scope("default") external _duration: (float, 'a) => Duration.t = "duration"
@module("moment") @scope("default") external _durationMillis: float => Duration.t = "duration"
@module("moment") @scope("default") external _durationFormat: string => Duration.t = "duration"

let duration = (value, unit) => _duration(value, unit)
let durationMillis = value => _durationMillis(value)
let durationFormat = format => _durationFormat(format)

module Moment = {
  type t
  @send external clone: t => t = "clone"
  @send external mutableAdd: (t, Duration.t) => unit = "add"
  let add = (moment, ~duration) => {
    let clone = clone(moment)
    mutableAdd(clone, duration)
    clone
  }
  @send external mutableSubtract: (t, Duration.t) => unit = "subtract"
  let subtract = (moment, ~duration) => {
    let clone = clone(moment)
    mutableSubtract(clone, duration)
    clone
  }
  @send
  external mutableStartOf: (
    t,
    [
      | #year
      | #quarter
      | #month
      | #week
      | #isoWeek
      | #day
      | #hour
      | #minute
      | #second
      | #millisecond
    ],
  ) => unit = "startOf"
  let startOf = (moment, timeUnit) => {
    let clone = clone(moment)
    mutableStartOf(clone, timeUnit)
    clone
  }
  @send
  external mutableEndOf: (
    t,
    [
      | #year
      | #quarter
      | #month
      | #week
      | #isoWeek
      | #day
      | #hour
      | #minute
      | #second
      | #millisecond
    ],
  ) => unit = "endOf"
  let endOf = (moment, timeUnit) => {
    let clone = clone(moment)
    mutableEndOf(clone, timeUnit)
    clone
  }
  @send external mutableSetMillisecond: (t, int) => unit = "millisecond"
  let setMillisecond = (moment, millisecond) => {
    let clone = clone(moment)
    mutableSetMillisecond(clone, millisecond)
    clone
  }
  @send external mutableSetSecond: (t, int) => unit = "second"
  let setSecond = (moment, second) => {
    let clone = clone(moment)
    mutableSetSecond(clone, second)
    clone
  }
  @send external mutableSetMinute: (t, int) => unit = "minute"
  let setMinute = (moment, minute) => {
    let clone = clone(moment)
    mutableSetMinute(clone, minute)
    clone
  }
  @send external mutableSetHour: (t, int) => unit = "hour"
  let setHour = (moment, hour) => {
    let clone = clone(moment)
    mutableSetHour(clone, hour)
    clone
  }
  @send external mutableSetDate: (t, int) => unit = "date"
  let setDate = (moment, date) => {
    let clone = clone(moment)
    mutableSetDate(clone, date)
    clone
  }
  @send external mutableSetDay: (t, int) => unit = "day"
  let setDay = (moment, day) => {
    let clone = clone(moment)
    mutableSetDay(clone, day)
    clone
  }
  @send external mutableSetWeekday: (t, int) => unit = "weekday"
  let setWeekday = (moment, weekday) => {
    let clone = clone(moment)
    mutableSetWeekday(clone, weekday)
    clone
  }
  @send external mutableSetIsoWeekday: (t, int) => unit = "isoWeekday"
  let setIsoWeekday = (moment, isoWeekday) => {
    let clone = clone(moment)
    mutableSetIsoWeekday(clone, isoWeekday)
    clone
  }
  @send external mutableSetDayOfYear: (t, int) => unit = "dayOfYear"
  let setDayOfYear = (moment, dayOfYear) => {
    let clone = clone(moment)
    mutableSetDayOfYear(clone, dayOfYear)
    clone
  }
  @send external mutableSetWeek: (t, int) => unit = "week"
  let setWeek = (moment, week) => {
    let clone = clone(moment)
    mutableSetWeek(clone, week)
    clone
  }
  @send external mutableSetIsoWeek: (t, int) => unit = "isoWeek"
  let setIsoWeek = (moment, isoWeek) => {
    let clone = clone(moment)
    mutableSetIsoWeek(clone, isoWeek)
    clone
  }
  @send external mutableSetQuarter: (t, int) => unit = "quarter"
  let setQuarter = (moment, quarter) => {
    let clone = clone(moment)
    mutableSetQuarter(clone, quarter)
    clone
  }
  @send external mutableSetWeekYear: (t, int) => unit = "weekYear"
  let setWeekYear = (moment, weekYear) => {
    let clone = clone(moment)
    mutableSetWeekYear(clone, weekYear)
    clone
  }
  @send external mutableSetIsoWeekYear: (t, int) => unit = "isoWeekYear"
  let setIsoWeekYear = (moment, isoWeekYear) => {
    let clone = clone(moment)
    mutableSetWeekYear(clone, isoWeekYear)
    clone
  }
  @send external mutableSetMonth: (t, int) => unit = "month"
  let setMonth = (moment, month) => {
    let clone = clone(moment)
    mutableSetMonth(clone, month)
    clone
  }
  @send external mutableSetYear: (t, int) => unit = "year"
  let setYear = (moment, year) => {
    let clone = clone(moment)
    mutableSetYear(clone, year)
    clone
  }
  @send
  external get: (
    t,
    [
      | #year
      | #quarter
      | #month
      | #week
      | #day
      | #date
      | #hour
      | #minute
      | #second
      | #millisecond
    ],
  ) => int = "get"
  @send external millisecond: t => int = "millisecond"
  @send external second: t => int = "second"
  @send external minute: t => int = "minute"
  @send external hour: t => int = "hour"
  @send external day: t => int = "day"
  @send external date: t => int = "date"
  @send external week: t => int = "week"
  @send external month: t => int = "month"
  @send external year: t => int = "year"
  @send external weekday: t => int = "weekday"
  @send external isValid: t => bool = "isValid"
  @send external isBefore: (t, t) => bool = "isBefore"
  @send external isAfter: (t, t) => bool = "isAfter"
  @send
  external isAfterWithGranularity: (
    t,
    t,
    [
      | #year
      | #month
      | #week
      | #isoWeek
      | #day
      | #hour
      | #minute
      | #second
    ],
  ) => bool = "isAfter"
  @send
  external isSameOrBeforeWithGranularity: (
    t,
    t,
    [
      | #year
      | #month
      | #week
      | #isoWeek
      | #day
      | #hour
      | #minute
      | #second
    ],
  ) => bool = "isSameOrBefore"
  @send external isSame: (t, t) => bool = "isSame"
  @send
  external isSameWithGranularity: (t, t, [#year | #month | #day]) => bool = "isSame"
  @send external isSameOrBefore: (t, t) => bool = "isSameOrBefore"
  @send external isSameOrAfter: (t, t) => bool = "isSameOrAfter"
  @send external isBetween: (t, t, t) => bool = "isBetween"
  @send external isDST: t => bool = "isDST"
  @send external isLeapYear: t => bool = "isLeapYear"
  /* display */
  @send external format: (t, string) => string = "format"
  @send external defaultFormat: t => string = "format"
  @send external utc: (t, string) => t = "utc"
  @send external defaultUtc: t => t = "utc"
  @send external locale: (t, string) => t = "locale"
  @send
  external fromNow: (t, ~withoutSuffix: option<bool>) => string = "fromNow"
  @send
  external fromMoment: (t, ~other: t, ~format: option<string>) => string = "from"
  @send external toNow: (t, ~withoutSuffix: option<bool>) => string = "toNow"
  @send
  external toMoment: (t, ~other: t, ~format: string) => string = "to"
  @send external valueOf: t => float = "valueOf"
  @send external daysInMonth: t => int = "daysInMonth"
  @send external toJSON: t => Null.t<string> = "toJSON"
  let toJSON = moment => toJSON(moment)->Null.toOption
  @send external toDate: t => Date.t = "toDate"
  @send external toUnix: t => int = "unix"
  @send external toISOString: (t, ~keepOffset: bool=?) => string = "toISOString"
}

/* parse */
@module("moment") external _momentNow: unit => Moment.t = "default"
@module("moment") external _momentDefaultFormat: string => Moment.t = "default"
@module("moment") external _momentWithFormat: (string, string) => Moment.t = "default"
@module("moment") external _momentWithDate: Date.t => Moment.t = "default"
@module("moment") external _momentWithFormats: (string, array<string>) => Moment.t = "default"
@module("moment") external _momentWithTimestampMS: float => Moment.t = "default"
@module("moment") external _momentWithComponents: list<int> => Moment.t = "default"
@module("moment") @scope("default") external _momentUtcWithFormats: (string, array<string>) => Moment.t = "utc"
@module("moment") @scope("default") external _momentUtcDefaultFormat: string => Moment.t = "utc"

let momentNow = () => _momentNow()
let momentDefaultFormat = value => _momentDefaultFormat(value)
let momentWithFormat = (value, format) => _momentWithFormat(value, format)
let momentWithDate = date => _momentWithDate(date)
let momentWithFormats = (value, formats) => _momentWithFormats(value, formats)
let momentWithTimestampMS = timestamp => _momentWithTimestampMS(timestamp)
let momentWithComponents = components => _momentWithComponents(components)
let momentUtcWithFormats = (value, formats) => _momentUtcWithFormats(value, formats)
let momentUtcDefaultFormat = value => _momentUtcDefaultFormat(value)

let momentWithUnix = (timestamp: int) => momentWithTimestampMS(Int.toFloat(timestamp) *. 1000.0)

@send
external diff: (
  Moment.t,
  Moment.t,
  [
    | #years
    | #quarters
    | #months
    | #weeks
    | #days
    | #hours
    | #minutes
    | #seconds
    | #milliseconds
  ],
) => float = "diff"

@send
external diffWithPrecision: (
  Moment.t,
  Moment.t,
  [
    | #years
    | #quarters
    | #months
    | #weeks
    | #days
    | #hours
    | #minutes
    | #seconds
    | #milliseconds
  ],
  bool,
) => float = "diff"

let momentUtc = (~format=?, value) =>
  switch format {
  | Some(f) => momentUtcWithFormats(value, f)
  | None => momentUtcDefaultFormat(value)
  }

let moment = (~format=?, value) =>
  switch format {
  | Some(f) => momentWithFormats(value, f)
  | None => momentDefaultFormat(value)
  }
