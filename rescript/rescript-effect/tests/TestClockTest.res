open AsyncTest
open AsyncTest.Expect

// Key pattern: TestClock tests must run the sleeping fiber AND the clock adjustment
// in the SAME Effect pipeline, provided with a SINGLE TestContext layer via
// Effect.provide at the end. Using Effect.runFork + separate Effect.runPromise gives
// two separate runtimes with independent virtual clocks — adjust has no effect.

describe("TestClock + TestContext", () => {
  testPromise("currentTimeMillis starts at 0", async () => {
    let t = await TestClock.currentTimeMillis
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    expect(t)->toBe(0)
  })

  testPromise("adjust advances the virtual clock", async () => {
    let program = TestClock.adjust(Duration.millis(1000))
      ->Effect.zipRight(TestClock.currentTimeMillis)
      ->Effect.provide(TestContext.testContext)
    let t = await program->Effect.runPromise
    expect(t)->toBe(1000)
  })

  testPromise("Effect.sleep resolves after TestClock.adjust by the matching duration", async () => {
    // Fork inside the TestContext scope so the fiber shares the virtual clock.
    // Then adjust the same clock and join the fiber — all in one pipeline.
    let _ = await Effect.sleep(Duration.millis(500))
      ->Effect.fork
      ->Effect.flatMap(fiber =>
        TestClock.adjust(Duration.millis(500))
        ->Effect.zipRight(Fiber.join(fiber))
      )
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    expect(true)->toBe(true)  // Reached without error = sleep resolved
  })

  testPromise("Effect.sleep does not resolve before clock is advanced", async () => {
    // Use Fiber.poll (non-blocking check) to verify the fiber hasn't completed
    // after only a partial clock advance.
    let fiberPoll = await Effect.sleep(Duration.millis(1000))
      ->Effect.fork
      ->Effect.flatMap(fiber =>
        TestClock.adjust(Duration.millis(999))
        ->Effect.zipRight(Effect.yieldNow())
        ->Effect.zipRight(Fiber.poll(fiber))
      )
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    // Fiber.poll returns None if the fiber hasn't completed yet
    expect(fiberPoll->Option.isNone)->toBe(true)
  })

  testPromise("multiple adjusts accumulate", async () => {
    let program = TestClock.adjust(Duration.millis(300))
      ->Effect.zipRight(TestClock.adjust(Duration.millis(200)))
      ->Effect.zipRight(TestClock.currentTimeMillis)
      ->Effect.provide(TestContext.testContext)
    let t = await program->Effect.runPromise
    expect(t)->toBe(500)
  })
})
