open JestGlobals
open ChunkHelpers

describe("Cause", () => {
  describe("constructors + predicates", () => {
    testSync("fail isFail = true, isDie = false", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isFail)->toBe(true)
      expect(c->Cause.isDie)->toBe(false)
    })

    testSync("die isDie = true, isFail = false", () => {
      let c = Cause.die(JsError.make("defect"))
      expect(c->Cause.isDie)->toBe(true)
      expect(c->Cause.isFail)->toBe(false)
    })

    testSync("isInterrupted is false for fail cause", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isInterrupted)->toBe(false)
    })

    testSync("isEmpty is false for non-empty cause", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isEmpty)->toBe(false)
    })
  })

  describe("extraction", () => {
    testSync("failures extracts typed errors from fail cause", () => {
      let c = Cause.fail("my-error")
      // Cause.failures returns an Effect Chunk — convert to array for toEqual
      let errs = c->Cause.failures->arrayFrom
      expect(errs)->toEqual(["my-error"])
    })

    testSync("failures extracts from parallel cause — both preserved", () => {
      let c = Cause.parallel(Cause.fail("left"), Cause.fail("right"))
      let errs = c->Cause.failures
      expect(errs)->toHaveLength(2)
    })

    testSync("defects extracts exceptions from die cause", () => {
      let c = Cause.die("surprise")
      let defs = c->Cause.defects
      expect(defs)->toHaveLength(1)
    })

    testSync("pretty returns a non-empty string", () => {
      let c = Cause.fail("err")
      let s = c->Cause.pretty
      expect(s->String.length)->toBeGreaterThan(0)
    })
  })

  describe("composition", () => {
    testSync("parallel preserves both causes", () => {
      let c = Cause.parallel(Cause.fail("a"), Cause.fail("b"))
      expect(c->Cause.failures)->toHaveLength(2)
    })

    testSync("sequential preserves both causes", () => {
      let c = Cause.sequential(Cause.fail("first"), Cause.fail("second"))
      expect(c->Cause.failures)->toHaveLength(2)
    })
  })
})
