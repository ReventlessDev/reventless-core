open AsyncTest
open AsyncTest.Expect

describe("Stm.TRef", () => {
  testPromise("make + get returns the initial value", async () => {
    let tref = Stm.TRef.make(10)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(tref)->Stm.commit->Effect.runSync
    expect(v)->toBe(10)
  })

  testPromise("set + get reflects the new value", async () => {
    let tref = Stm.TRef.make(0)->Stm.commit->Effect.runSync
    let _ = Stm.TRef.set(tref, 99)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(tref)->Stm.commit->Effect.runSync
    expect(v)->toBe(99)
  })

  testPromise("update applies a function to the value", async () => {
    let tref = Stm.TRef.make(5)->Stm.commit->Effect.runSync
    let _ = Stm.TRef.update(tref, n => n * 2)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(tref)->Stm.commit->Effect.runSync
    expect(v)->toBe(10)
  })

  testPromise("getAndUpdate returns the old value", async () => {
    let tref = Stm.TRef.make(3)->Stm.commit->Effect.runSync
    let old = Stm.TRef.getAndUpdate(tref, n => n + 1)->Stm.commit->Effect.runSync
    let new_ = Stm.TRef.get(tref)->Stm.commit->Effect.runSync
    expect(old)->toBe(3)
    expect(new_)->toBe(4)
  })

  testPromise("modify returns computed result and updates the ref", async () => {
    let tref = Stm.TRef.make(7)->Stm.commit->Effect.runSync
    let result = Stm.TRef.modify(tref, n => (n * 10, n + 1))->Stm.commit->Effect.runSync
    let new_ = Stm.TRef.get(tref)->Stm.commit->Effect.runSync
    expect(result)->toBe(70)  // computed: 7 * 10
    expect(new_)->toBe(8)     // updated: 7 + 1
  })
})

describe("Stm — STM operations", () => {
  test("succeed + commit produces the value", () => {
    let v = Stm.succeed(42)->Stm.commit->Effect.runSync
    expect(v)->toBe(42)
  })

  test("map transforms the value", () => {
    let v = Stm.succeed(3)->Stm.map(n => n * 2)->Stm.commit->Effect.runSync
    expect(v)->toBe(6)
  })

  test("flatMap chains transactions", () => {
    let v = Stm.succeed(4)
      ->Stm.flatMap(n => Stm.succeed(n + 1))
      ->Stm.commit
      ->Effect.runSync
    expect(v)->toBe(5)
  })

  test("zipRight returns the second value", () => {
    let v = Stm.succeed("a")
      ->Stm.zipRight(Stm.succeed("b"))
      ->Stm.commit
      ->Effect.runSync
    expect(v)->toBe("b")
  })

  test("fail + commit + runSyncExit is a failure", () => {
    let exit = Stm.fail("oops")->Stm.commit->Effect.runSyncExit
    expect(exit->Exit.isFailure)->toBe(true)
  })
})
