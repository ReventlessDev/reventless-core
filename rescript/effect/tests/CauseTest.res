open JestGlobals

let failures = cause =>
  cause
  ->Cause.reasons
  ->Array.filterMap(reason =>
    switch reason {
    | Cause.Fail({error}) => Some(error)
    | Die(_) | Interrupt(_) => None
    }
  )

describe("Cause", () => {
  describe("constructors + predicates", () => {
    testSync(
      "fail has a typed failure and no defect",
      () => {
        let c = Cause.fail("err")
        expect(c->Cause.hasFails)->toBe(true)
        expect(c->Cause.hasDies)->toBe(false)
      },
    )

    testSync(
      "die has a defect and no typed failure",
      () => {
        let c = Cause.die(JsError.make("defect"))
        expect(c->Cause.hasDies)->toBe(true)
        expect(c->Cause.hasFails)->toBe(false)
      },
    )

    testSync(
      "a typed failure is not an interruption",
      () => {
        let c = Cause.fail("err")
        expect(c->Cause.hasInterrupts)->toBe(false)
      },
    )
  })

  describe("reasons", () => {
    testSync(
      "a fail cause holds its typed error",
      () => {
        expect(Cause.fail("my-error")->failures)->toEqual(["my-error"])
      },
    )

    testSync(
      "a die cause holds one defect and nothing else",
      () => {
        let isDie = reason =>
          switch reason {
          | Cause.Die(_) => true
          | Fail(_) | Interrupt(_) => false
          }
        let reasons = Cause.die("surprise")->Cause.reasons
        expect((reasons->Array.length, reasons->Array.every(isDie)))->toEqual((1, true))
      },
    )

    testSync(
      "combine keeps the reasons of both, in order",
      () => {
        let c = Cause.combine(Cause.fail("a"), Cause.fail("b"))
        expect(c->failures)->toEqual(["a", "b"])
      },
    )

    testSync(
      "pretty returns a non-empty string",
      () => {
        let s = Cause.fail("err")->Cause.pretty
        expect(s->String.length)->toBeGreaterThan(0)
      },
    )
  })
})
