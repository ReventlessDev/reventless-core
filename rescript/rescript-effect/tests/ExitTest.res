open AsyncTest
open AsyncTest.Expect

describe("Exit", () => {
  describe("constructors + predicates", () => {
    test("succeed isSuccess = true, isFailure = false", () => {
      let e = Exit.succeed(1)
      expect(e->Exit.isSuccess)->toBe(true)
      expect(e->Exit.isFailure)->toBe(false)
    })

    test("fail isSuccess = false, isFailure = true", () => {
      let e = Exit.fail("err")
      expect(e->Exit.isSuccess)->toBe(false)
      expect(e->Exit.isFailure)->toBe(true)
    })

    test("die (defect) isFailure = true", () => {
      let e = Exit.die(JsError.make("defect"))
      expect(e->Exit.isFailure)->toBe(true)
    })
  })

  describe("extraction", () => {
    // Note: Exit.toOption does not exist in Effect v3. Use getOrElse instead.
    test("getOrElse on success returns the value", () => {
      let e = Exit.succeed(42)
      expect(e->Exit.getOrElse(_ => -1))->toBe(42)
    })

    test("getOrElse on failure returns the default", () => {
      let e = Exit.fail("err")
      expect(e->Exit.getOrElse(_ => -1))->toBe(-1)
    })

    // Note: causeOption returns Effect's Option type {_id:"Option", _tag:"Some"|"None"}
    // NOT ReScript's option (null | value). Compare via the _tag field.
    test("causeOption on failure returns a Some-tagged Effect Option", () => {
      let e = Exit.fail("err")
      let causeOpt = e->Exit.causeOption
      let tag: string = (causeOpt->Obj.magic)["_tag"]
      expect(tag)->toBe("Some")
    })

    test("causeOption on success returns a None-tagged Effect Option", () => {
      let e = Exit.succeed(1)
      let causeOpt = e->Exit.causeOption
      let tag: string = (causeOpt->Obj.magic)["_tag"]
      expect(tag)->toBe("None")
    })
  })

  describe("transformation", () => {
    test("map on success transforms value", () => {
      let e = Exit.succeed(3)->Exit.map(n => n * 2)
      expect(e->Exit.getOrElse(_ => -1))->toBe(6)
    })

    test("map on failure is a no-op", () => {
      let e = Exit.fail("err")->Exit.map(n => n * 2)
      expect(e->Exit.isFailure)->toBe(true)
    })

    test("flatMap on success chains exits", () => {
      let e = Exit.succeed(5)->Exit.flatMap(n => Exit.succeed(n + 1))
      expect(e->Exit.getOrElse(_ => -1))->toBe(6)
    })
  })
})
