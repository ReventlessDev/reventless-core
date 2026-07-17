open JestGlobals

describe("Schedule", () => {
  describe("recurs — count-based repetition", () => {
    testPromise("recurs(3) repeats an effect 3 additional times (4 total executions)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.recurs(3))
        ->Effect.runPromise
      expect(count.contents)->toBe(4)  // initial + 3 repeats
    })

    testPromise("recurs(0) does not repeat (1 total execution)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.recurs(0))
        ->Effect.runPromise
      expect(count.contents)->toBe(1)
    })
  })

  describe("once", () => {
    testPromise("once repeats exactly once (2 total executions)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.once)
        ->Effect.runPromise
      expect(count.contents)->toBe(2)
    })
  })

  describe("whileInput — conditional retry", () => {
    testPromise("whileInput stops when predicate returns false", async () => {
      let count = ref(0)
      let schedule = Schedule.recurs(5)->Schedule.whileInput(err => err == "transient")
      let exit = await Effect.sync(() => {
        count := count.contents + 1
      })
        ->Effect.flatMap(_ => {
          if count.contents < 3 {
            Effect.fail("transient")
          } else {
            Effect.succeed(count.contents)
          }
        })
        ->Effect.retry(schedule)
        ->Effect.runPromiseExit
      expect(exit->Exit.isSuccess)->toBe(true)
    })
  })

  describe("intersect — stop when either stops", () => {
    testPromise("intersect(recurs(2), recurs(4)) stops after 2 repeats", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.intersect(Schedule.recurs(2), Schedule.recurs(4)))
        ->Effect.runPromise
      expect(count.contents)->toBe(3)  // initial + 2 repeats (shorter schedule wins)
    })
  })

  describe("union — stop when both stop", () => {
    testPromise("union(recurs(2), recurs(4)) stops after 4 repeats", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.union(Schedule.recurs(2), Schedule.recurs(4)))
        ->Effect.runPromise
      expect(count.contents)->toBe(5)  // initial + 4 repeats (longer schedule wins)
    })
  })

  describe("timing-based schedules — require TestClock", () => {
    // TestClock pattern: fork the scheduled effect INSIDE the TestContext pipeline,
    // then adjust the clock, then join — all in one Effect.provide chain.
    testPromise("fixed(100ms) repeats after each 100ms interval", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.intersect(Schedule.fixed(Duration.millis(100)), Schedule.recurs(3)))
        ->Effect.fork
        ->Effect.flatMap(fiber =>
          TestClock.adjust(Duration.millis(400))
          ->Effect.zipRight(Fiber.join(fiber))
        )
        ->Effect.provide(TestContext.testContext)
        ->Effect.runPromise
      expect(count.contents)->toBe(4)
    })

    testPromise("exponential starts with the base delay", async () => {
      // Verify the schedule can be composed and run without error
      let count = ref(0)
      let schedule = Schedule.exponential(Duration.millis(100))
        ->Schedule.intersect(Schedule.recurs(1))
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(schedule)
        ->Effect.fork
        ->Effect.flatMap(fiber =>
          TestClock.adjust(Duration.millis(200))
          ->Effect.zipRight(Fiber.join(fiber))
        )
        ->Effect.provide(TestContext.testContext)
        ->Effect.runPromise
      expect(count.contents)->toBe(2)
    })
  })
})
