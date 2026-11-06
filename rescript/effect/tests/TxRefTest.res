open JestGlobals

describe("TxRef", () => {
  testSync("make + get returns the initial value", () => {
    let ref = TxRef.make(10)->Effect.runSync
    expect(TxRef.get(ref)->Effect.runSync)->toBe(10)
  })

  testSync("makeUnsafe needs no Effect", () => {
    let ref = TxRef.makeUnsafe("a")
    expect(TxRef.get(ref)->Effect.runSync)->toBe("a")
  })

  testSync("set + get reflects the new value", () => {
    let ref = TxRef.makeUnsafe(0)
    TxRef.set(ref, 99)->Effect.runSync
    expect(TxRef.get(ref)->Effect.runSync)->toBe(99)
  })

  testSync("update applies a function to the value", () => {
    let ref = TxRef.makeUnsafe(5)
    TxRef.update(ref, n => n * 2)->Effect.runSync
    expect(TxRef.get(ref)->Effect.runSync)->toBe(10)
  })

  testSync("modify returns the computed result and updates the ref", () => {
    let ref = TxRef.makeUnsafe(7)
    let result = TxRef.modify(ref, n => (n * 10, n + 1))->Effect.runSync
    expect(result)->toBe(70)
    expect(TxRef.get(ref)->Effect.runSync)->toBe(8)
  })
})

describe("Effect.tx", () => {
  testSync("commits every write when the transaction succeeds", () => {
    let a = TxRef.makeUnsafe(1)
    let b = TxRef.makeUnsafe(1)
    TxRef.update(a, n => n + 1)
    ->Effect.zipRight(TxRef.update(b, n => n + 1))
    ->Effect.tx
    ->Effect.runSync
    expect((TxRef.get(a)->Effect.runSync, TxRef.get(b)->Effect.runSync))->toEqual((2, 2))
  })

  testSync("discards every write when the transaction fails", () => {
    let a = TxRef.makeUnsafe(1)
    let exit =
      TxRef.set(a, 2)
      ->Effect.zipRight(Effect.fail("rolled back"))
      ->Effect.tx
      ->Effect.runSyncExit
    expect(exit->Exit.isFailure)->toBe(true)
    expect(TxRef.get(a)->Effect.runSync)->toBe(1)
  })
})
