open JestGlobals

describe("SynchronizedRef", () => {
  testPromise("make + get returns the initial value", async () => {
    let r = SynchronizedRef.make(0)->Effect.runSync
    let v = await SynchronizedRef.get(r)->Effect.runPromise
    expect(v)->toBe(0)
  })

  testPromise("set + get reflects the new value", async () => {
    let r = SynchronizedRef.make(0)->Effect.runSync
    let _ = await SynchronizedRef.set(r, 99)->Effect.runPromise
    let v = await SynchronizedRef.get(r)->Effect.runPromise
    expect(v)->toBe(99)
  })

  testPromise("update applies a pure function atomically", async () => {
    let r = SynchronizedRef.make(10)->Effect.runSync
    let _ = await SynchronizedRef.update(r, n => n * 3)->Effect.runPromise
    let v = await SynchronizedRef.get(r)->Effect.runPromise
    expect(v)->toBe(30)
  })

  testPromise("updateEffect updates with an async computation", async () => {
    let r = SynchronizedRef.make(5)->Effect.runSync
    let _ = await SynchronizedRef.updateEffect(r, n =>
      Effect.promise(() => Promise.resolve(n + 10))
    )->Effect.runPromise
    let v = await SynchronizedRef.get(r)->Effect.runPromise
    expect(v)->toBe(15)
  })

  testPromise("modifyEffect returns result and updates atomically", async () => {
    let r = SynchronizedRef.make(4)->Effect.runSync
    let result = await SynchronizedRef.modifyEffect(r, n =>
      Effect.promise(() => Promise.resolve((n * 100, n + 1)))
    )->Effect.runPromise
    let new_ = await SynchronizedRef.get(r)->Effect.runPromise
    expect(result)->toBe(400)
    expect(new_)->toBe(5)
  })
})
