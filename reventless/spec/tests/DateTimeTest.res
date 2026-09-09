open JestGlobals

// `DateTime` was the oldest semantic and the only one that was never a type: a
// bare marker on `S.string` that checked nothing. Every rejection below is a
// value that used to reach an event log through a field declared as one.
//
// The offset cases are the decisions rather than the accidents, so they are
// pinned as decisions — see the module doc's UTC rule.
describe("DateTime:", () => {
  let accepts = raw => DateTime.fromString(raw)->Result.isOk

  testSync("accepts a UTC instant", () => expect(accepts("2026-03-02T09:00:00Z"))->toBe(true))
  testSync("accepts sub-second precision", () =>
    expect(accepts("2026-03-02T09:00:00.123456Z"))->toBe(true)
  )

  // Not a tolerance the type declined to add — a rule it keeps. A feed carrying
  // a supplier's local offset converts at the boundary; the alternative is a
  // stored instant whose zone every consumer has to re-decide.
  testSync("rejects an offset — instants are stored in UTC", () =>
    expect(accepts("2026-03-02T09:00:00+01:00"))->toBe(false)
  )
  testSync("rejects a zoneless local time", () =>
    expect(accepts("2026-03-02T09:00:00"))->toBe(false)
  )
  testSync("rejects a calendar date — that is CalendarDate", () =>
    expect(accepts("2026-03-02"))->toBe(false)
  )
  testSync("rejects a bare word", () => expect(accepts("not-a-date"))->toBe(false))

  // The value the example used as "has not happened yet" on two views, which is
  // what `option` says now.
  testSync("rejects the empty string", () => expect(accepts(""))->toBe(false))

  testSync("says what it wanted and shows the value", () =>
    expect(
      switch DateTime.fromString("tomorrow") {
      | Error(why) =>
        why->String.includes("UTC ISO-8601 instant") && why->String.includes("tomorrow")
      | Ok(_) => false
      },
    )->toBe(true)
  )

  testSync("marks itself with the dateTime id", () =>
    expect(DateTime.schema->S.castToUnknown->Semantic.has(~id="dateTime"))->toBe(true)
  )

  // The schema and the constructor are one grammar by construction, and this is
  // what keeps it that way.
  testSync("the schema agrees with the constructor", () => {
    let parses = raw =>
      switch raw->S.parseOrThrow(~to=DateTime.schema) {
      | _ => true
      | exception _ => false
      }
    expect((parses("2026-03-02T09:00:00Z"), parses("")))->toEqual((true, false))
  })

  describe("ordering:", () => {
    let earlier = "2026-03-02T09:00:00Z"
    let later = "2026-03-02T11:00:00Z"

    testSync(
      "isBefore is strict",
      () =>
        expect((
          DateTime.isBefore(earlier, later),
          DateTime.isBefore(later, earlier),
          DateTime.isBefore(earlier, earlier),
        ))->toEqual((true, false, false)),
    )

    testSync(
      "compare orders oldest first",
      () =>
        expect(
          ["2026-03-02T11:00:00Z", "2026-03-02T09:00:00Z"]->Array.toSorted(DateTime.compare),
        )->toEqual([earlier, later]),
    )
  })

  describe("format:", () => {
    testSync(
      "reads to the minute, in UTC",
      () => expect(DateTime.format("2026-03-02T09:04:31.512Z"))->toBe("2026-03-02 09:04"),
    )

    // Transparent `t` means a value the grammar never saw can reach this. It
    // reads back unchanged rather than being sliced into something that looks
    // like a date and is not one.
    testSync(
      "hands back a value that is not an instant",
      () => expect(DateTime.format("time"))->toBe("time"),
    )
  })
})
