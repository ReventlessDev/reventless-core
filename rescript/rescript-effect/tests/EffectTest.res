open AsyncTest
open AsyncTest.Expect

describe("Effect — construction", () => {
  test("succeed runSync returns value", () => {
    let v = Effect.succeed(42)->Effect.runSync
    expect(v)->toBe(42)
  })

  test("fail runSyncExit isFailure", () => {
    let exit = Effect.fail("boom")->Effect.runSyncExit
    expect(exit->Exit.isFailure)->toBe(true)
  })

  test("sync wraps a computation", () => {
    let v = Effect.sync(() => 1 + 1)->Effect.runSync
    expect(v)->toBe(2)
  })

  testPromise("promise wraps a Promise", async () => {
    let v = await Effect.promise(() => Promise.resolve("hello"))->Effect.runPromise
    expect(v)->toBe("hello")
  })

  testPromise("tryPromise succeeds when no throw", async () => {
    let exit = await Effect.tryPromise(~catch=_err => "caught", () => Promise.resolve(99))
      ->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("tryPromise catches thrown errors", async () => {
    let exit =
      await Effect.tryPromise(
        ~catch=_err => "caught",
        () => Promise.reject(JsError.make("oops")->Obj.magic),
      )->Effect.runPromiseExit
    expect(exit->Exit.isFailure)->toBe(true)
  })

  test("trySync succeeds when no throw", () => {
    let exit = Effect.trySync(~catch=_exn => "caught", () => 42)->Effect.runSyncExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  test("trySync returns computed value", () => {
    let v = Effect.trySync(~catch=_exn => "caught", () => 1 + 1)->Effect.runSync
    expect(v)->toBe(2)
  })

  test("trySync catches thrown exceptions", () => {
    let exit =
      Effect.trySync(~catch=_exn => "caught", () => JSON.parseOrThrow("not json"))
      ->Effect.runSyncExit
    expect(exit->Exit.isFailure)->toBe(true)
  })

  test("trySync maps caught exception to typed error catchable via catchAll", () => {
    let caught = ref("")
    Effect.trySync(~catch=_exn => "parse failed", () => JSON.parseOrThrow("not json"))
    ->Effect.catchAll(msg => {
      caught := msg
      Effect.succeed(JSON.Encode.null)
    })
    ->Effect.runSync
    ->ignore
    expect(caught.contents)->toBe("parse failed")
  })
})

describe("Effect — transformation", () => {
  test("map transforms the success value", () => {
    let v = Effect.succeed(3)->Effect.map(n => n * 2)->Effect.runSync
    expect(v)->toBe(6)
  })

  test("flatMap chains effects", () => {
    let v = Effect.succeed(5)
      ->Effect.flatMap(n => Effect.succeed(n + 1))
      ->Effect.runSync
    expect(v)->toBe(6)
  })

  test("tap runs side effect and passes value through", () => {
    let sideEffect = ref(0)
    let v = Effect.succeed(10)
      ->Effect.tap(n => Effect.sync(() => { sideEffect := n }))
      ->Effect.runSync
    expect(v)->toBe(10)
    expect(sideEffect.contents)->toBe(10)
  })

  test("zipRight returns the second value", () => {
    let v = Effect.succeed("a")->Effect.zipRight(Effect.succeed("b"))->Effect.runSync
    expect(v)->toBe("b")
  })

  test("zipLeft returns the first value", () => {
    let v = Effect.succeed("a")->Effect.zipLeft(Effect.succeed("b"))->Effect.runSync
    expect(v)->toBe("a")
  })
})

describe("Effect — error handling", () => {
  test("catchAll recovers from failure", () => {
    let v = Effect.fail("err")
      ->Effect.catchAll(_e => Effect.succeed("recovered"))
      ->Effect.runSync
    expect(v)->toBe("recovered")
  })

  // Note: Effect.option returns Effect's Option type {_id:"Option", _tag:"Some"|"None"},
  // NOT ReScript's option (null | value). Compare via the _tag field.
  test("option converts success to Some-tagged Effect Option", () => {
    let v = Effect.succeed(7)->Effect.option->Effect.runSync
    let tag: string = (v->Obj.magic)["_tag"]
    expect(tag)->toBe("Some")
  })

  test("option converts failure to None-tagged Effect Option", () => {
    let v = Effect.fail("err")->Effect.option->Effect.runSync
    let tag: string = (v->Obj.magic)["_tag"]
    expect(tag)->toBe("None")
  })
})

describe("Effect — running", () => {
  test("runSyncExit success exit isSuccess", () => {
    let exit = Effect.succeed("ok")->Effect.runSyncExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("runPromiseExit success exit isSuccess", async () => {
    let exit = await Effect.succeed("ok")->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("runPromiseExit failure exit isFailure", async () => {
    let exit = await Effect.fail("err")->Effect.runPromiseExit
    expect(exit->Exit.isFailure)->toBe(true)
  })
})

describe("Effect — concurrency", () => {
  testPromise("all runs effects concurrently and collects results", async () => {
    let results = await Effect.all(
      [Effect.succeed(1), Effect.succeed(2), Effect.succeed(3)],
      {"concurrency": "unbounded"},
    )->Effect.runPromise
    expect(results)->toEqual([1, 2, 3])
  })

  testPromise("fork + Fiber.join completes the forked effect", async () => {
    let result = await Effect.succeed(99)
      ->Effect.fork
      ->Effect.flatMap(fiber => Fiber.join(fiber))
      ->Effect.runPromise
    expect(result)->toBe(99)
  })

  testPromise("runFork starts a background fiber", async () => {
    let fiber = Effect.succeed(42)->Effect.runFork
    let result = await Fiber.join(fiber)->Effect.runPromise
    expect(result)->toBe(42)
  })

  testPromise("yieldNow resolves without error", async () => {
    let _ = await Effect.yieldNow()->Effect.runPromise
    expect(true)->toBe(true)
  })
})
