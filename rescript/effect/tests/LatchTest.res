open JestGlobals

describe("Latch", () => {
  testPromise("makeLatch(false) starts closed — open_ releases awaiting fiber", async () => {
    let latch = Effect.makeLatch(false)->Effect.runSync
    // Use runFork for a daemon fiber — fork->runSync would interrupt the fiber
    // when the runSync scope closes (before open_ is called).
    let fiber = latch->Latch.await_->Effect.runFork
    let _ = await latch->Latch.open_->Effect.runPromise
    let exit = await Fiber.join(fiber)->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("makeLatch(true) starts open — await_ passes through immediately", async () => {
    let latch = Effect.makeLatch(true)->Effect.runSync
    let _ = await latch->Latch.await_->Effect.runPromise
    expect(true)->toBe(true)  // reached without blocking
  })

  testPromise("close then open — latch can be cycled", async () => {
    let latch = Effect.makeLatch(true)->Effect.runSync
    let _ = await latch->Latch.close->Effect.runPromise
    // Now closed — re-open using a daemon fiber
    let fiber = latch->Latch.await_->Effect.runFork
    let _ = await latch->Latch.open_->Effect.runPromise
    let exit = await Fiber.join(fiber)->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })
})
