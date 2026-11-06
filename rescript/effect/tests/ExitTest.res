open JestGlobals

describe("Exit", () => {
  describe("constructors + predicates", () => {
    testSync(
      "succeed isSuccess = true, isFailure = false",
      () => {
        let e = Exit.succeed(1)
        expect(e->Exit.isSuccess)->toBe(true)
        expect(e->Exit.isFailure)->toBe(false)
      },
    )

    testSync(
      "fail isSuccess = false, isFailure = true",
      () => {
        let e = Exit.fail("err")
        expect(e->Exit.isSuccess)->toBe(false)
        expect(e->Exit.isFailure)->toBe(true)
      },
    )

    testSync(
      "die (defect) isFailure = true",
      () => {
        let e = Exit.die(JsError.make("defect"))
        expect(e->Exit.isFailure)->toBe(true)
      },
    )
  })

  describe("extraction", () => {
    testSync(
      "causeOption on failure returns Some(cause)",
      () => {
        let e = Exit.fail("err")
        let causeOpt = e->Exit.causeOption
        expect(causeOpt->Option.isSome)->toBe(true)
      },
    )

    testSync(
      "causeOption on success returns None",
      () => {
        let e = Exit.succeed(1)
        let causeOpt = e->Exit.causeOption
        expect(causeOpt->Option.isNone)->toBe(true)
      },
    )
  })

  describe("match", () => {
    testSync(
      "match on failure invokes onFailure",
      () => {
        let e = Exit.fail("err")
        let result = e->Exit.match(~onFailure=_cause => "failed", ~onSuccess=_ => "succeeded")
        expect(result)->toBe("failed")
      },
    )

    testSync(
      "match on success invokes onSuccess",
      () => {
        let e = Exit.succeed(42)
        let result = e->Exit.match(~onFailure=_cause => -1, ~onSuccess=n => n * 2)
        expect(result)->toBe(84)
      },
    )
  })

  describe("transformation", () => {
    testSync(
      "map on success transforms value",
      () => {
        let e = Exit.succeed(3)->Exit.map(n => n * 2)
        expect(e->Exit.match(~onFailure=_ => -1, ~onSuccess=n => n))->toBe(6)
      },
    )

    testSync(
      "map on failure is a no-op",
      () => {
        let e = Exit.fail("err")->Exit.map(n => n * 2)
        expect(e->Exit.isFailure)->toBe(true)
      },
    )
  })
})
