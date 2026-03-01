open AsyncTest
open AsyncTest.Expect

describe("Deferred", () => {
  testPromise("make + succeed + await_ delivers the value", async () => {
    let d = Deferred.make()->Effect.runSync
    let _ = await Deferred.succeed(d, 42)->Effect.runPromise
    let v = await Deferred.await_(d)->Effect.runPromise
    expect(v)->toBe(42)
  })

  testPromise("isDone is false before completion", async () => {
    let d = Deferred.make()->Effect.runSync
    let done_ = await Deferred.isDone(d)->Effect.runPromise
    expect(done_)->toBe(false)
  })

  testPromise("isDone is true after succeed", async () => {
    let d = Deferred.make()->Effect.runSync
    let _ = await Deferred.succeed(d, "x")->Effect.runPromise
    let done_ = await Deferred.isDone(d)->Effect.runPromise
    expect(done_)->toBe(true)
  })

  testPromise("succeed is idempotent — second call returns false", async () => {
    let d = Deferred.make()->Effect.runSync
    let first = await Deferred.succeed(d, 1)->Effect.runPromise
    let second = await Deferred.succeed(d, 2)->Effect.runPromise
    expect(first)->toBe(true)
    expect(second)->toBe(false)
  })

  testPromise("fail completes with error — await_ fails", async () => {
    let d: Deferred.t<int, string> = Deferred.make()->Effect.runSync
    let _ = await Deferred.fail(d, "oops")->Effect.runPromise
    let exit = await Deferred.await_(d)->Effect.runPromiseExit
    expect(exit->Exit.isFailure)->toBe(true)
  })

  testPromise("completeWith completes with the result of an effect", async () => {
    let d = Deferred.make()->Effect.runSync
    let _ = await Deferred.completeWith(d, Effect.succeed(99))->Effect.runPromise
    let v = await Deferred.await_(d)->Effect.runPromise
    expect(v)->toBe(99)
  })
})
