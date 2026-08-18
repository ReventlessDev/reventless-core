open JestGlobals

// `DateRange` is the first semantic type whose invariant the boundary does not
// enforce: the `start <= end` rule is record-level, sury 11-alpha miscompiles a
// refinement wrapping a record, so the rule lives in `validate` and decode lets
// a reversed range through. The load-bearing cases below are therefore the two
// that hold that seam in place — that `validate` refuses a reversed range and
// that decode does *not* — plus end-exclusivity, which nothing but `contains`
// and `overlaps` may re-decide.
describe("DateRange:", () => {
  let dr = (start, end_): DateRange.t => {start, end_}

  // 09:00, 11:00, 13:00 on one day. 09–11 and 11–13 are adjacent.
  let nine = "2026-03-02T09:00:00Z"
  let eleven = "2026-03-02T11:00:00Z"
  let thirteen = "2026-03-02T13:00:00Z"

  describe("duration is the length in whole seconds:", () => {
    testSync("two hours is 7200 seconds", () =>
      expect(DateRange.duration(dr(nine, eleven))->Duration.toInt)->toBe(7200)
    )

    // A zero-length range is legal — an instant timeout, an empty window — and
    // its length is zero, not an error.
    testSync("a zero-length range is zero seconds", () =>
      expect(DateRange.duration(dr(nine, nine))->Duration.toInt)->toBe(0)
    )
  })

  describe("contains is [start, end) — end exclusive:", () => {
    testSync("the start instant is contained", () =>
      expect(DateRange.contains(dr(nine, thirteen), nine))->toBe(true)
    )
    testSync("an instant inside is contained", () =>
      expect(DateRange.contains(dr(nine, thirteen), eleven))->toBe(true)
    )
    // The whole reason end-exclusivity is a decision and not a default: the
    // instant that ends this range is the one that opens the next.
    testSync("the end instant is NOT contained", () =>
      expect(DateRange.contains(dr(nine, thirteen), thirteen))->toBe(false)
    )
    testSync("a zero-length range contains nothing, not even its own instant", () =>
      expect(DateRange.contains(dr(nine, nine), nine))->toBe(false)
    )
  })

  describe("overlaps is end-exclusive too:", () => {
    // Adjacent ranges do not overlap — this is the property a day grid relies on
    // to lay out back-to-back windows without an invented millisecond gap.
    testSync("adjacent ranges do not overlap", () =>
      expect(DateRange.overlaps(dr(nine, eleven), dr(eleven, thirteen)))->toBe(false)
    )
    testSync("ranges that share an interior instant overlap", () =>
      expect(DateRange.overlaps(dr(nine, thirteen), dr(eleven, thirteen)))->toBe(true)
    )
    testSync("overlap is symmetric", () =>
      expect(DateRange.overlaps(dr(eleven, thirteen), dr(nine, thirteen)))->toBe(true)
    )
  })

  describe("validate is the single statement of the ordering rule:", () => {
    testSync("an ordered range is accepted", () =>
      expect(DateRange.validate(dr(nine, eleven))->Result.isOk)->toBe(true)
    )
    testSync("a zero-length range is ordered", () =>
      expect(DateRange.validate(dr(nine, nine))->Result.isOk)->toBe(true)
    )
    testSync("a reversed range is refused", () =>
      expect(DateRange.validate(dr(eleven, nine))->Result.isOk)->toBe(false)
    )
    testSync("the refusal shows both instants", () =>
      expect(
        switch DateRange.validate(dr(eleven, nine)) {
        | Error(why) => why->String.includes(eleven) && why->String.includes(nine)
        | Ok(_) => false
        },
      )->toBe(true)
    )
    testSync("make runs the same check", () =>
      expect(DateRange.make(~start=eleven, ~end_=nine)->Result.isOk)->toBe(false)
    )
  })

  describe("format is the two instants, locale-independent:", () =>
    testSync("an en dash between start and end", () =>
      expect(DateRange.format(dr(nine, eleven)))->toBe(`${nine} – ${eleven}`)
    )
  )

  describe("the schema:", () => {
    let range = (start, end_) =>
      JSON.Encode.object(
        Dict.fromArray([("start", JSON.Encode.string(start)), ("end", JSON.Encode.string(end_))]),
      )

    let parses = (raw: JSON.t) =>
      switch raw->S.parseOrThrow(~to=DateRange.schema) {
      | _ => true
      | exception _ => false
      }

    testSync("carries the dateRange id", () =>
      expect(DateRange.schema->S.castToUnknown->Semantic.has(~id="dateRange"))->toBe(true)
    )

    // The vocabulary id is a string contract with a consumer in another repo
    // that nothing type-checks across the boundary — compared to a literal on
    // purpose, exactly as `money` is.
    testSync("and the id is the wire string", () =>
      expect(Semantic.Id.dateRange)->toBe("dateRange")
    )

    testSync("accepts an ordered range", () => expect(parses(range(nine, eleven)))->toBe(true))

    // The seam this type turns on, stated as an expectation so it fails loudly
    // the day sury's record refinement is fixed and the rule can move into the
    // schema: decode accepts a range `validate` refuses.
    testSync("decode does NOT enforce ordering — a reversed range still parses", () =>
      expect(parses(range(eleven, nine)))->toBe(true)
    )
    testSync("but validate refuses the same reversed range", () =>
      expect(DateRange.validate(dr(eleven, nine))->Result.isOk)->toBe(false)
    )

    // `end` on the wire, `end_` in the source — fixed by `@as("end")`, and the
    // wire form is the permanent part.
    testSync("serializes end under the wire key \"end\"", () =>
      expect(dr(nine, eleven)->Util_Sury.toJson(DateRange.schema))
      ->toEqual(range(nine, eleven))
    )
  })
})
