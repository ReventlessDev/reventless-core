open JestGlobals

describe("Ref", () => {
  testPromise("make + get returns the initial value", async () => {
    let r = Ref.make(0)->Effect.runSync
    let v = await Ref.get(r)->Effect.runPromise
    expect(v)->toBe(0)
  })

  testPromise("set + get reflects the new value", async () => {
    let r = Ref.make(0)->Effect.runSync
    let _ = await Ref.set(r, 42)->Effect.runPromise
    let v = await Ref.get(r)->Effect.runPromise
    expect(v)->toBe(42)
  })

  testPromise("update applies a pure function", async () => {
    let r = Ref.make(10)->Effect.runSync
    let _ = await Ref.update(r, n => n + 5)->Effect.runPromise
    let v = await Ref.get(r)->Effect.runPromise
    expect(v)->toBe(15)
  })

  testPromise("getAndUpdate returns the old value", async () => {
    let r = Ref.make(3)->Effect.runSync
    let old = await Ref.getAndUpdate(r, n => n * 2)->Effect.runPromise
    let new_ = await Ref.get(r)->Effect.runPromise
    expect(old)->toBe(3)
    expect(new_)->toBe(6)
  })

  testPromise("updateAndGet returns the new value", async () => {
    let r = Ref.make(5)->Effect.runSync
    let new_ = await Ref.updateAndGet(r, n => n - 1)->Effect.runPromise
    expect(new_)->toBe(4)
  })

  testPromise("modify returns computed result and updates the ref", async () => {
    let r = Ref.make(7)->Effect.runSync
    let result = await Ref.modify(r, n => (n * 10, n + 1))->Effect.runPromise
    let new_ = await Ref.get(r)->Effect.runPromise
    expect(result)->toBe(70)
    expect(new_)->toBe(8)
  })
})
