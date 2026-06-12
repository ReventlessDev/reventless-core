open JestGlobals

// Duration constructors produce opaque values — verify they are truthy (not null/undefined)
// and passable to Effect.sleep without type errors at runtime.
describe("Duration — constructors", () => {
  testSync("millis returns a truthy Duration.t", () => {
    let d = Duration.millis(100)
    expect(d->Obj.magic)->toBeTruthy
  })

  testSync("seconds returns a truthy Duration.t", () => {
    expect(Duration.seconds(1)->Obj.magic)->toBeTruthy
  })

  testSync("minutes returns a truthy Duration.t", () => {
    expect(Duration.minutes(1)->Obj.magic)->toBeTruthy
  })

  testSync("hours returns a truthy Duration.t", () => {
    expect(Duration.hours(1)->Obj.magic)->toBeTruthy
  })

  testSync("days returns a truthy Duration.t", () => {
    expect(Duration.days(1)->Obj.magic)->toBeTruthy
  })

  testPromise("millis Duration can be used with Effect.sleep via TestClock", async () => {
    // Verify that Duration.millis is accepted by Effect.sleep at runtime.
    // All operations (fork, adjust, join) must be inside one pipeline with a single
    // Effect.provide(TestContext.testContext) so they share the same virtual clock.
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
})
