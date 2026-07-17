open MomentRe
open MomentRe_Helpers
open JestGlobals

let isJsDateValid: Date.t => bool = %raw(`
  function(date) {
    return (date instanceof Date && !isNaN(date.valueOf())) ? true : false;
  }
`)

/* note that this is an interops test, not tests for moment.js itself, i.e. test comprehensiveness is not the goal */
describe("moment", () => {
  testSync("#clone", () => expect(moment("2017-01-01")->Moment.clone->Moment.isValid)->toBe(true))
  testSync("#mutableSubtract", () =>
    expect(
      Moment.isSame(
        moment("2016-01-01"),
        {
          let original = moment("2017-01-01")
          Moment.mutableSubtract(original, duration(1., #years))
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#subtract", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01"),
        moment("2017-01-04")
        ->Moment.subtract(~duration=duration(1., #days))
        ->Moment.subtract(~duration=duration(2., #days)),
      ),
    )->toBe(true)
  )
  testSync("#sameDay with granularity by day", () =>
    expect(Moment.isSameWithGranularity(moment("2017-01-01"), moment("2017-01-04"), #day))->toBe(
      false,
    )
  )
  testSync("#sameDay with granularity by month", () =>
    expect(Moment.isSameWithGranularity(moment("2017-01-01"), moment("2017-01-04"), #month))->toBe(
      true,
    )
  )
  testSync("#sameDay with granularity by year", () =>
    expect(Moment.isSameWithGranularity(moment("2017-01-01"), moment("2017-01-04"), #year))->toBe(
      true,
    )
  )
  testSync("#mutableAdd", () =>
    expect(
      Moment.isSame(
        moment("2017-01-04"),
        {
          let original = moment("2017-01-01")
          Moment.mutableAdd(original, duration(3., #days))
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#add", () =>
    expect(
      Moment.isSame(
        moment("2017-01-04"),
        moment("2017-01-01")
        ->Moment.add(~duration=duration(1., #days))
        ->Moment.add(~duration=duration(2., #days)),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetMillisecond", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:05.100"),
        {
          let original = moment("2017-01-01 02:25:05.000")
          Moment.mutableSetMillisecond(original, 100)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setMillisecond", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:05.100"),
        moment("2017-01-01 02:25:05.000")
        ->Moment.setMillisecond(200)
        ->Moment.setMillisecond(100),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetSecond", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:30.100"),
        {
          let original = moment("2017-01-01 02:25:05.100")
          Moment.mutableSetSecond(original, 30)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setSecond", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:30.100"),
        moment("2017-01-01 02:25:05.100")->Moment.setSecond(20)->Moment.setSecond(30),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetMinute", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:30.100"),
        {
          let original = moment("2017-01-01 02:20:30.100")
          Moment.mutableSetMinute(original, 25)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setMinute", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 02:25:30.100"),
        moment("2017-01-01 02:20:30.100")->Moment.setMinute(30)->Moment.setMinute(25),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetHour", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 00:25:05.000"),
        {
          let original = moment("2017-01-01 02:25:05.000")
          Moment.mutableSetHour(original, 0)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setHour", () =>
    expect(
      Moment.isSame(
        moment("2017-01-01 00:25:05.000"),
        moment("2017-01-01 06:25:05.000")->Moment.setHour(2)->Moment.setHour(0),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetDate", () =>
    expect(
      Moment.isSame(
        moment("2017-01-04"),
        {
          let original = moment("2017-01-01")
          Moment.mutableSetDate(original, 4)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setDate", () =>
    expect(
      Moment.isSame(
        moment("2017-01-04"),
        moment("2017-01-01")->Moment.setDate(2)->Moment.setDate(4),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetDay", () =>
    expect(
      Moment.isSame(
        moment("2018-05-01"),
        {
          let original = moment("2018-05-05")
          Moment.mutableSetDay(original, 2)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setDay", () =>
    expect(
      Moment.isSame(moment("2018-05-01"), moment("2018-05-05")->Moment.setDay(3)->Moment.setDay(2)),
    )->toBe(true)
  )
  testSync("#mutableSetWeekday", () =>
    expect(
      Moment.isSame(
        moment("2018-05-01"),
        {
          let original = moment("2018-05-05")
          Moment.mutableSetWeekday(original, 2)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setWeekday", () =>
    expect(
      Moment.isSame(
        moment("2018-05-01"),
        moment("2018-05-05")->Moment.setWeekday(3)->Moment.setWeekday(2),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetIsoWeekday", () =>
    expect(
      Moment.isSame(
        moment("2018-05-01"),
        {
          let original = moment("2018-05-05")
          Moment.mutableSetIsoWeekday(original, 2)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setIsoWeekday", () =>
    expect(
      Moment.isSame(
        moment("2018-05-01"),
        moment("2018-05-05")->Moment.setIsoWeekday(3)->Moment.setIsoWeekday(2),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetDayOfYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-01"),
        {
          let original = moment("2018-01-05")
          Moment.mutableSetDayOfYear(original, 1)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setDayOfYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-01"),
        moment("2018-01-05")->Moment.setDayOfYear(3)->Moment.setDayOfYear(1),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetWeek", () =>
    expect(
      Moment.isSame(
        moment("2018-01-17"),
        {
          let original = moment("2018-01-03")
          Moment.mutableSetWeek(original, 3)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setWeek", () =>
    expect(
      Moment.isSame(
        moment("2018-01-17"),
        moment("2018-01-03")->Moment.setWeek(5)->Moment.setWeek(3),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetIsoWeek", () =>
    expect(
      Moment.isSame(
        moment("2018-01-17"),
        {
          let original = moment("2018-01-03")
          Moment.mutableSetIsoWeek(original, 3)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setIsoWeek", () =>
    expect(
      Moment.isSame(
        moment("2018-01-17"),
        moment("2018-01-03")->Moment.setIsoWeek(5)->Moment.setIsoWeek(3),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetMonth", () =>
    expect(
      Moment.isSame(
        moment("2017-04-01"),
        {
          let original = moment("2017-01-01")
          Moment.mutableSetMonth(original, 3)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setMonth", () =>
    expect(
      Moment.isSame(
        moment("2017-04-01"),
        moment("2017-01-01")->Moment.setMonth(2)->Moment.setMonth(3),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetQuarter", () =>
    expect(
      Moment.isSame(
        moment("2013-04-01T00:00:00.000"),
        {
          let original = moment("2013-01-01T00:00:00.000")
          Moment.mutableSetQuarter(original, 2)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setQuarter", () =>
    expect(
      Moment.isSame(
        moment("2013-04-01T00:00:00.000"),
        moment("2013-01-01T00:00:00.000")->Moment.setQuarter(4)->Moment.setQuarter(2),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetYear", () =>
    expect(
      Moment.isSame(
        moment("2019-01-01"),
        {
          let original = moment("2017-01-01")
          Moment.mutableSetYear(original, 2019)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setYear", () =>
    expect(
      Moment.isSame(
        moment("2019-01-01"),
        moment("2017-01-01")->Moment.setYear(2018)->Moment.setYear(2019),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetWeekYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-05"),
        {
          let original = moment("2019-01-04")
          Moment.mutableSetWeekYear(original, 2018)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setWeekYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-05"),
        moment("2019-01-04")->Moment.setWeekYear(2020)->Moment.setWeekYear(2018),
      ),
    )->toBe(true)
  )
  testSync("#mutableSetIsoWeekYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-05"),
        {
          let original = moment("2019-01-04")
          Moment.mutableSetIsoWeekYear(original, 2018)
          original
        },
      ),
    )->toBe(true)
  )
  testSync("#setIsoWeekYear", () =>
    expect(
      Moment.isSame(
        moment("2018-01-05"),
        moment("2019-01-04")->Moment.setIsoWeekYear(2020)->Moment.setIsoWeekYear(2018),
      ),
    )->toBe(true)
  )
  testSync("#isValid", () => expect(moment("2017-01-01")->Moment.isValid)->toBe(true))
  testSync("not #isValid", () => expect(moment("")->Moment.isValid)->toBe(false))
  testSync("#isDST", () => expect(moment("2016-01-01T00:00:00")->Moment.isDST)->toBe(false))
  testSync("leap year", () => expect(moment("2016-01-01")->Moment.isLeapYear)->toBe(true))
  testSync("not leap year", () => expect(moment("1900-01-01")->Moment.isLeapYear)->toBe(false))
  testSync("instantiation", () =>
    expect(Moment.isSame(moment("2017-04-01"), moment("2017-04-01")))->toBe(true)
  )
  testSync("instantiation with format", () =>
    expect(Moment.isSame(moment("2017-04-01"), moment("2017-04-01")))->toBe(true)
  )
  testSync("instantiation with date", () =>
    expect(
      Moment.isSame(
        momentWithDate(Date.fromString("6 Mar 2017 21:22:23 GMT")),
        moment("6 Mar 2017 21:22:23 GMT"),
      ),
    )->toBe(true)
  )
  testSync("instantiation momentWithTimestampMS (float)", () =>
    expect(
      Moment.isSame(moment("2017-06-12T18:30:00+02:00"), momentWithTimestampMS(1497285000000.0)),
    )->toBe(true)
  )
  testSync("instantiation momentWithUnix (int)", () =>
    expect(Moment.isSame(moment("6 Mar 2017 21:22:23 GMT"), momentWithUnix(1488835343)))->toBe(true)
  )
  testSync(".now", () => expect(momentNow()->Moment.isValid)->toBe(true))
  testSync("#isSame", () =>
    expect(Moment.isSame(moment("2016-01-01"), moment("2016-01-01")))->toBe(true)
  )
  testSync("#isBefore", () =>
    expect(Moment.isBefore(moment("2016-01-01"), moment("2016-01-02")))->toBe(true)
  )
  testSync("#isSameOrBefore", () =>
    expect(Moment.isSameOrBefore(moment("2016-01-01"), moment("2016-01-02")))->toBe(true)
  )

  testSync("#isSameOrBeforeWithGranularity", () => {
    expect(
      Moment.isSameOrBeforeWithGranularity(moment("2016-01-01"), moment("2016-01-02"), #day),
    )->toBe(true)

    expect(
      Moment.isSameOrBeforeWithGranularity(moment("2016-01-01"), moment("2016-01-01"), #day),
    )->toBe(true)
  })
  testSync("#isAfter", () =>
    expect(Moment.isAfter(moment("2016-01-02"), moment("2016-01-01")))->toBe(true)
  )
  testSync("#isAfterWithGranularity", () => {
    expect(Moment.isAfterWithGranularity(moment("2016-01-02"), moment("2016-01-01"), #day))
    ->toBe(true)
    ->ignore
    expect(Moment.isAfterWithGranularity(moment("2016-01-02"), moment("2016-01-01"), #month))
    ->toBe(false)
    ->ignore
    expect(Moment.isAfterWithGranularity(moment("2016-01-02"), moment("2016-01-01"), #year))
    ->toBe(false)
    ->ignore
    expect(Moment.isAfterWithGranularity(moment("2017-01-02"), moment("2016-01-01"), #year))->toBe(
      true,
    )
  })
  testSync("#isSameOrAfter", () =>
    expect(Moment.isSameOrAfter(moment("2016-01-02"), moment("2016-01-01")))->toBe(true)
  )
  testSync("#isBetween", () =>
    expect(
      Moment.isBetween(moment("2016-01-02"), moment("2016-01-01"), moment("2016-01-03")),
    )->toBe(true)
  )
  testSync("#format", () =>
    expect(moment("2016-01-01")->Moment.format("YYYY-MM-DD"))->toBe("2016-01-01")
  )
  testSync(
    /* TODO: test this time-zone independently */
    "#defaultFormat",
    () => expect(moment("2016-01-01")->Moment.defaultFormat)->toContain("2016-01-01"),
  )
  testSync("#utc", () =>
    expect(momentUtc("2018-01-22")->Moment.isValid)->toBe(true)
  )
  testSync("#defaultUtc", () =>
    expect(momentUtc("2018-01-22")->Moment.isValid)->toBe(true)
  )
  testSync("#locale", () =>
    expect(
      moment("2018-01-01 00:00:00Z")->Moment.locale("da_DK")->Moment.format("MMMM Do YYYY"),
    )->toBe("januar 1. 2018")
  )
  testSync("#valueOf" /* TODO: float? */, () =>
    expect(moment("2016-01-01 00:00:00Z")->Moment.valueOf)->toBeCloseTo(1451606400000.)
  )
  describe("#toJSON", () => {
    testSync(
      "valid",
      () => expect(moment("2016-01-01")->Moment.toJSON->Option.getOrThrow)->toContain("000Z"),
    )
    testSync("invalid", () => expect(moment("9999-99-99")->Moment.toJSON)->toBe(None))
  })
  testSync("#toDate", () => expect(isJsDateValid(moment("2016-01-01")->Moment.toDate))->toBe(true))
  testSync("#toUnix", () => expect(moment("6 Mar 2017 21:22:23 GMT")->Moment.toUnix)->toBe(1488835343))
  describe("#toISOString", () => {
    testSync(
      "default",
      () =>
        expect(moment("6 Mar 2017 21:22:23 GMT")->Moment.toISOString)->toBe(
          "2017-03-06T21:22:23.000Z",
        ),
    )
    testSync(
      "keepOffset",
      () =>
        moment("6 Mar 2017 21:22:23 GMT")
        ->Moment.toISOString(~keepOffset=true)
        ->String.includes("000Z")
        ->expect
        ->toBe(false),
    )
  })
  testSync("#get", () => expect(moment("2017-01-02 03:04:05.678")->Moment.get(#day))->toBe(1))
  testSync("#second", () => expect(moment("2017-01-02 03:04:05.678")->Moment.second)->toBe(5))
  testSync("#minute", () => expect(moment("2017-01-02 03:04:05.678")->Moment.minute)->toBe(4))
  testSync("#hour", () => expect(moment("2017-01-02 03:04:05.678")->Moment.hour)->toBe(3))
  testSync("#day", () => expect(moment("2017-01-02 03:04:05.678")->Moment.day)->toBe(1))
  testSync("#date", () => expect(moment("2017-01-02 03:04:05.678")->Moment.date)->toBe(2))
  testSync("#week", () => expect(moment("2017-01-02 03:04:05.678")->Moment.week)->toBe(1))
  testSync("#month", () => expect(moment("2017-01-02 03:04:05.678")->Moment.month)->toBe(0))
  testSync("#year", () => expect(moment("2017-01-02 03:04:05.678")->Moment.year)->toBe(2017))
  testSync("#weekday", () => expect(moment("2017-01-02 03:04:05.678")->Moment.weekday)->toBe(1))
  testSync("#startOf week", () => {
    let inputDate = moment("2017-01-10 03:04:05.678")
    let expected = moment("2017-01-08T00:00:00.000")

    expect(Moment.isSame(expected, Moment.startOf(inputDate, #week)))->toBe(true)
  })
  testSync("#startOf isoWeek", () => {
    let inputDate = moment("2017-01-10 03:04:05.678")
    let expected = moment("2017-01-09T00:00:00.000")

    expect(Moment.isSame(expected, Moment.startOf(inputDate, #isoWeek)))->toBe(true)
  })
  testSync("#endOf week", () => {
    let inputDate = moment("2017-01-10 03:04:05.678")
    let expected = moment("2017-01-14T23:59:59.999")

    expect(Moment.isSame(expected, Moment.endOf(inputDate, #week)))->toBe(true)
  })
  testSync("#endOf isoWeek", () => {
    let inputDate = moment("2017-01-10 03:04:05.678")
    let expected = moment("2017-01-15T23:59:59.999")

    expect(Moment.isSame(expected, Moment.endOf(inputDate, #isoWeek)))->toBe(true)
  })

  testSync("#moment (format defined)", () => {
    let format = "DD-MM-YYYY HH : ss"
    let dateStr = "10-01-2017 03 : 04"

    expect(moment(~format=[format], dateStr)->Moment.format(format))->toBe(dateStr)
  })

  testSync("#momentUtc Z (default format)", () => {
    let dateStr = "2017-01-10T03:04"

    expect(momentUtc(dateStr ++ "Z")->Moment.format("YYYY-MM-DDTHH:mm"))->toBe(dateStr)
  })

  testSync("#momentUtc no Z (default format)", () => {
    let dateStr = "2017-01-10T03:04"

    expect(momentUtc(dateStr)->Moment.format("YYYY-MM-DDTHH:mm"))->toBe(dateStr)
  })

  testSync("#momentUtc Z (format defined)", () => {
    let format = "DD-MM-YYYY HH : ss"
    let dateStr = "10-01-2017 03 : 04"

    expect(momentUtc(~format=[format], dateStr ++ "Z")->Moment.format(format))->toBe(dateStr)
  })

  testSync("#momentUtc no Z (format defined)", () => {
    let format = "DD-MM-YYYY HH : ss"
    let dateStr = "10-01-2017 03 : 04"

    expect(momentUtc(~format=[format], dateStr)->Moment.format(format))->toBe(dateStr)
  })
})

describe("moment duration", () => {
  testSync("get duration", () => expect(duration(2., #days))->toBeTruthy)
  testSync("get duration millis", () => expect(durationMillis(2.0))->toBeTruthy)
  testSync("get duration format", () => expect(durationFormat("P2D")->Duration.toJSON)->toBe("P2D"))
  testSync("#milliseconds", () => expect(duration(2., #milliseconds)->Duration.milliseconds)->toBe(2))
  testSync("#seconds", () => expect(duration(2., #seconds)->Duration.seconds)->toBe(2))
  testSync("#asSeconds", () => expect(duration(2., #seconds)->Duration.asSeconds)->toBe(2.))
  testSync("#minutes", () => expect(duration(2., #minutes)->Duration.minutes)->toBe(2))
  testSync("#asMinutes", () => expect(duration(2., #minutes)->Duration.asMinutes)->toBe(2.))
  testSync("#hours", () => expect(duration(2., #hours)->Duration.hours)->toBe(2))
  testSync("#asHours", () => expect(duration(2., #hours)->Duration.asHours)->toBe(2.))
  testSync("#days", () => expect(duration(2., #days)->Duration.days)->toBe(2))
  testSync("#asDays", () => expect(duration(2., #days)->Duration.asDays)->toBe(2.))
  testSync("#weeks", () => expect(duration(2., #weeks)->Duration.weeks)->toBe(2))
  testSync("#asWeeks", () => expect(duration(2., #weeks)->Duration.asWeeks)->toBe(2.))
  testSync("#months", () => expect(duration(2., #months)->Duration.months)->toBe(2))
  testSync("#asMonths", () => expect(duration(2., #months)->Duration.asMonths)->toBe(2.))
  testSync("#years", () => expect(duration(2., #years)->Duration.years)->toBe(2))
  testSync("#asYears", () => expect(duration(2., #years)->Duration.asYears)->toBe(2.))
  testSync("#as", () => expect(duration(2., #days)->Duration.asUnitOfTime(#days))->toBe(2.))
  testSync("#toJSON", () => expect(duration(2., #days)->Duration.toJSON)->toBe("P2D"))
  testSync("#toISOString", () => expect(duration(2., #days)->Duration.toJSON)->toBe("P2D"))
  testSync("#humanize", () => expect(duration(2., #days)->Duration.humanize)->toBe("2 days"))
})

describe("moment diff", () => {
  testSync("should return correct difference of moments in days", () =>
    expect(diff(moment("2017-01-02"), moment("2017-01-01"), #days))->toBe(1.)
  )
  testSync("should return correct difference of moments in hours", () =>
    expect(
      diff(moment("2017-01-01 02:00:00.000"), moment("2017-01-01 00:00:00.000"), #hours),
    )->toBe(2.)
  )
  testSync("should be able to handle negative difference of moments", () =>
    expect(
      diff(moment("2017-01-01 00:00:00.000"), moment("2017-01-01 02:00:00.000"), #hours),
    )->toBe(-2.)
  )
  testSync("should return correct difference of moments in hours", () =>
    expect(
      diff(moment("2017-01-01 00:25:05.000"), moment("2017-01-01 00:00:00.000"), #minutes),
    )->toBe(25.)
  )
})
