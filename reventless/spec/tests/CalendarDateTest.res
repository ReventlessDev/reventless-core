open JestGlobals

// The type exists to stop a day being stored as an instant, so the two
// rejections that matter are in opposite directions: an instant is not a day,
// and a day is not an instant.
describe("CalendarDate:", () => {
  let accepts = raw => CalendarDate.fromString(raw)->Result.isOk

  testSync("accepts a calendar day", () => expect(accepts("2026-03-02"))->toBe(true))
  testSync("rejects an impossible month", () => expect(accepts("2026-13-02"))->toBe(false))
  testSync("rejects a time of day", () => expect(accepts("09:00:00"))->toBe(false))
  testSync("rejects an instant — that is DateTime", () =>
    expect(accepts("2026-03-02T09:00:00Z"))->toBe(false)
  )
  testSync("rejects the empty string", () => expect(accepts(""))->toBe(false))

  testSync("says the shape it wanted and shows the value", () =>
    expect(
      switch CalendarDate.fromString("March 2nd") {
      | Error(why) => why->String.includes("YYYY-MM-DD") && why->String.includes("March 2nd")
      | Ok(_) => false
      },
    )->toBe(true)
  )

  // Literal on purpose: the id is a string contract with a consumer in another
  // repo that nothing type-checks across the boundary.
  testSync("its vocabulary id is the short one", () => expect(Semantic.Id.date)->toBe("date"))

  testSync("marks itself with it", () =>
    expect(CalendarDate.schema->S.castToUnknown->Semantic.has(~id="date"))->toBe(true)
  )

  // A day is not an instant to the marker readers either — a field that answered
  // to both would put a calendar day on a timeline axis.
  testSync("does not answer to the date-time marker", () =>
    expect(CalendarDate.schema->S.castToUnknown->DateTime.isDateTime)->toBe(false)
  )

  testSync("the schema agrees with the constructor", () => {
    let parses = raw =>
      switch raw->S.parseOrThrow(~to=CalendarDate.schema) {
      | _ => true
      | exception _ => false
      }
    expect((parses("2026-03-02"), parses("2026-03-02T09:00:00Z")))->toEqual((true, false))
  })
})
