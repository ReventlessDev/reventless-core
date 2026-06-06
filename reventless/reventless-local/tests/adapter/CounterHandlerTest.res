// Unit tests for LocalCounterHandler.
// CounterHandler uses module-level refs — call reset() in beforeEach for isolation.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

// No Pulumi mock needed (LocalCounterHandler uses no Output)

let _ = beforeEach(() => {
  LocalCounterHandler.reset()
})

// Create a handler instance; all parameters are ignored by the in-memory implementation
let makeHandler = () =>
  LocalCounterHandler.make(
    ~name="counter",
    ~referencesName="refs",
    ~referencesDb=Obj.magic(()),
    ~countsName="counts",
    ~countsDb=Obj.magic(()),
    ~counterHandler=Obj.magic(()),
    ~specModulePath="",
    ~mappingsModulePath="",
    ~publishChannelId=Pulumi.Output.make(""),
    ~opts={},
  )

describe("LocalCounterHandler", () => {
  describe("addToCounterTarget", () => {
    testPromise("increments counter by target amount", async () => {
      let handler = makeHandler()
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "likes",
        target: 3,
        targetRef: "ref-1",
      })
      expect(LocalCounterHandler.getCount("likes"))->toBe(3)
    })

    testPromise("same (counterId, targetRef) pair is counted only once", async () => {
      let handler = makeHandler()
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "likes",
        target: 5,
        targetRef: "ref-dup",
      })
      // Duplicate — should be ignored
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "likes",
        target: 5,
        targetRef: "ref-dup",
      })
      expect(LocalCounterHandler.getCount("likes"))->toBe(5)
    })

    testPromise("different targetRef values for same counterId accumulate", async () => {
      let handler = makeHandler()
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "views",
        target: 2,
        targetRef: "ref-a",
      })
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "views",
        target: 3,
        targetRef: "ref-b",
      })
      expect(LocalCounterHandler.getCount("views"))->toBe(5)
    })

    testPromise("multiple counters are tracked independently", async () => {
      let handler = makeHandler()
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "alpha",
        target: 10,
        targetRef: "r1",
      })
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "beta",
        target: 7,
        targetRef: "r1",
      })
      expect(LocalCounterHandler.getCount("alpha"))->toBe(10)
      expect(LocalCounterHandler.getCount("beta"))->toBe(7)
    })
  })

  describe("getCount", () => {
    testPromise("returns 0 for unknown counterId", async () => {
      expect(LocalCounterHandler.getCount("no-such-counter"))->toBe(0)
    })
  })

  describe("reset", () => {
    testPromise("clears all counter values and deduplication state", async () => {
      let handler = makeHandler()
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "x",
        target: 99,
        targetRef: "ref-x",
      })
      expect(LocalCounterHandler.getCount("x"))->toBe(99)
      LocalCounterHandler.reset()
      expect(LocalCounterHandler.getCount("x"))->toBe(0)
      // After reset, the same (counterId, targetRef) pair should count again
      await handler.addToCounterTarget({
        ReventlessInfra.Counter.counterId: "x",
        target: 99,
        targetRef: "ref-x",
      })
      expect(LocalCounterHandler.getCount("x"))->toBe(99)
    })
  })
})
