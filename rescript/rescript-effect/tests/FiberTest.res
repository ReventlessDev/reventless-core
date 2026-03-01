open AsyncTest
open AsyncTest.Expect

describe("Fiber", () => {
  testPromise("join waits for fiber and returns its result", async () => {
    let fiber = Effect.succeed(123)->Effect.runFork
    let v = await Fiber.join(fiber)->Effect.runPromise
    expect(v)->toBe(123)
  })

  testPromise("interrupt terminates fiber and returns Exit", async () => {
    // Fork a never-completing effect and interrupt it
    let fiber = Effect.never->Effect.runFork
    let exit = await Fiber.interrupt(fiber)->Effect.runPromise
    expect(exit->Exit.isFailure)->toBe(true)  // interrupted = failure
  })

  testPromise("joinAll collects results from multiple fibers", async () => {
    let fiber1 = Effect.succeed(1)->Effect.runFork
    let fiber2 = Effect.succeed(2)->Effect.runFork
    let fiber3 = Effect.succeed(3)->Effect.runFork
    let results = await Fiber.joinAll([fiber1, fiber2, fiber3])->Effect.runPromise
    expect(results)->toEqual([1, 2, 3])
  })

  testPromise("collectAll returns Exit for each fiber without failing", async () => {
    let fiber1 = Effect.succeed(1)->Effect.runFork
    let fiber2 = Effect.fail("err")->Effect.runFork
    let exits = await Fiber.collectAll([fiber1, fiber2])->Effect.runPromise
    expect(exits)->toHaveLength(2)
    let e0 = exits->Array.getUnsafe(0)
    let e1 = exits->Array.getUnsafe(1)
    expect(e0->Exit.isSuccess)->toBe(true)
    expect(e1->Exit.isFailure)->toBe(true)
  })
})
