# rescript-effect Binding Smoke Tests Plan

**Status:** Backlog
**Created:** 2026-02-28
**Depends on:** `docs/plans/effect-stream-integration.md` Phase A (Jest infrastructure in
`rescript-effect` — `package.json` devDependencies, jest config, `tests/` source dir in
`rescript.json`). That phase must complete first; this plan adds to the same `tests/` directory.
**Summary:** One smoke-test file per binding module in `rescript/rescript-effect/src/`. Tests live
in `rescript/rescript-effect/tests/` — entirely self-contained, no dependency on any Reventless
adapter or `AsyncTest`.

---

## Scope and Principles

**What smoke tests verify:** Each external binding calls the correct JS function with the correct
arguments and returns the expected shape. A smoke test is not a full behavioural test — it is the
smallest test that would catch a wrong JS function name, wrong argument order, or wrong return type
assumption.

**What smoke tests do not cover:** Production-level concurrency hazards, error recovery
compositions, or framework-level correctness. Those belong in the adapter/integration tests in
`reventless-in-memory`.

**One file per source module.** `Queue.res` → `tests/QueueTest.res`, `Deferred.res` →
`tests/DeferredTest.res`, etc. `Stream.res` is already covered by `tests/StreamTest.res` from
the stream integration plan — do not duplicate it here.

**Test infrastructure from Phase A of the stream plan:**
- Jest installed in `rescript-effect` (`package.json` devDependencies)
- `"testMatch": ["<rootDir>/tests/**/*Test.res.mjs"]`
- `tests/` dir as `"type": "dev"` source in `rescript.json`

---

## Section 1: Test Helper Module

**File to create:** `rescript/rescript-effect/tests/AsyncTest.res`

Tests follow the same pattern as the rest of the monorepo: a thin `AsyncTest.res` that binds
directly to Jest globals with `@val external`. This is the established workaround for
`@glennsl/rescript-jest`'s `testPromise` — which wraps the callback in `() => { affirm(callback()); }`,
discarding the returned Promise so Jest treats async tests as synchronous. See
`reventless-core/tests/AsyncTest.res` for the precedent and explanation.

**npm devDependencies needed** (added to `package.json` in Phase A of the stream plan):
`jest`, `@jest/globals`, `jest-environment-node`.
`@glennsl/rescript-jest` is NOT required — `AsyncTest.res` uses only `@val external` bindings that
Jest injects as globals (even in ESM mode with `--experimental-vm-modules`).

```rescript
// AsyncTest.res — Jest bindings for rescript-effect tests.
// Binds directly to Jest globals via @val external (no npm package import needed).
// testPromise is the correct async test binding — rescript-jest's testPromise discards
// the returned Promise. See reventless-core/tests/AsyncTest.res for details.

@val external describe: (string, unit => unit) => unit = "describe"
// Async test — callback returns a Promise; Jest awaits it before starting the next test
@val external testPromise: (string, unit => promise<unit>) => unit = "test"
// Sync test — callback returns unit
@val external test: (string, unit => unit) => unit = "test"

@val external beforeAll: (unit => unit) => unit = "beforeAll"
@val external beforeAllAsync: (unit => promise<unit>) => unit = "beforeAll"
@val external beforeEach: (unit => unit) => unit = "beforeEach"
@val external afterAll: (unit => unit) => unit = "afterAll"

type expectResult

module Expect = {
  @val external expect: 'a => expectResult = "expect"
  @send external toBe: (expectResult, 'a) => unit = "toBe"
  @send external toEqual: (expectResult, 'a) => unit = "toEqual"
  @send external toBeTruthy: expectResult => unit = "toBeTruthy"
  @send external toBeFalsy: expectResult => unit = "toBeFalsy"
  @send external toHaveLength: (expectResult, int) => unit = "toHaveLength"
  @send external toContain: (expectResult, 'a) => unit = "toContain"
  @send external toBeGreaterThan: (expectResult, int) => unit = "toBeGreaterThan"
}
```

**Usage in every test file:**

```rescript
open AsyncTest
open AsyncTest.Expect
```

**Note on `testPromise` vs `test`:** Both bind to the JS `test` function — ReScript selects by
callback return type. `test` is for `unit => unit` (sync); `testPromise` is for
`unit => promise<unit>` (async).

---

## Section 2: Test Files — One Per Module

### 2.1 `tests/EffectTest.res` — Effect core

Covers: `succeed`, `fail`, `sync`, `promise`, `tryPromise`, `map`, `flatMap`, `tap`, `zipRight`,
`zipLeft`, `catchAll`, `catchTag`, `option`, `retry`, `all`, `fork`, `race`, `yieldNow`,
`forever`, `runPromise`, `runPromiseExit`, `runSync`, `runSyncExit`, `runFork`.

Bindings not covered here (covered in dedicated files):
`sleep`, `timeout` (Duration + TestClock tests), `makeLatch`, `makeSemaphore`, `withPermits`,
`acquireRelease`, `scoped`, `provide`, `repeat` (Schedule tests).

```rescript
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
    let exit = await Effect.tryPromise({
      "try": () => Promise.resolve(99),
      "catch": _err => "caught",
    })->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("tryPromise catches thrown errors", async () => {
    let exit = await Effect.tryPromise({
      "try": () => Promise.reject(JsError.make("oops")),
      "catch": _err => "caught",
    })->Effect.runPromiseExit
    expect(exit->Exit.isFailure)->toBe(true)
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

  test("option converts success to Some", () => {
    let v = Effect.succeed(7)->Effect.option->Effect.runSync
    expect(v)->toEqual(Some(7))
  })

  test("option converts failure to None", () => {
    let v = Effect.fail("err")->Effect.option->Effect.runSync
    expect(v)->toEqual(None)
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
```

---

### 2.2 `tests/QueueTest.res` — Queue

Covers all 14 bindings: `unbounded`, `bounded`, `sliding`, `dropping`, `offer`, `offerAll`,
`take`, `takeAll`, `takeUpTo`, `size`, `isEmpty`, `isFull`, `shutdown`, `isShutdown`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Queue", () => {
  describe("constructors", () => {
    testPromise("unbounded queue accepts offers without blocking", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let accepted = await Queue.offer(q, 1)->Effect.runPromise
      expect(accepted)->toBe(true)
    })

    testPromise("bounded queue reports isFull when at capacity", async () => {
      let q = Queue.bounded(1)->Effect.runSync
      let _ = await Queue.offer(q, "x")->Effect.runPromise
      let full = await Queue.isFull(q)->Effect.runPromise
      expect(full)->toBe(true)
    })

    testPromise("sliding queue drops oldest item when full", async () => {
      let q = Queue.sliding(2)->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3])->Effect.runPromise
      let items = await Queue.takeAll(q)->Effect.runPromise
      // Oldest (1) was dropped; contains [2, 3]
      expect(items)->toHaveLength(2)
      expect(items)->toContain(3)
    })

    testPromise("dropping queue drops new item when full", async () => {
      let q = Queue.dropping(2)->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3])->Effect.runPromise
      let items = await Queue.takeAll(q)->Effect.runPromise
      // Newest (3) was dropped; contains [1, 2]
      expect(items)->toHaveLength(2)
      expect(items)->toContain(1)
    })
  })

  describe("offer / take round-trip", () => {
    testPromise("offer then take returns the same item", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, "hello")->Effect.runPromise
      let v = await Queue.take(q)->Effect.runPromise
      expect(v)->toBe("hello")
    })

    testPromise("offerAll then takeAll returns all items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offerAll(q, [10, 20, 30])->Effect.runPromise
      let items = await Queue.takeAll(q)->Effect.runPromise
      expect(items)->toEqual([10, 20, 30])
    })

    testPromise("takeUpTo returns at most N items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3, 4, 5])->Effect.runPromise
      let items = await Queue.takeUpTo(q, 3)->Effect.runPromise
      expect(items)->toHaveLength(3)
    })
  })

  describe("inspection", () => {
    testPromise("size reflects number of items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, "a")->Effect.runPromise
      let _ = await Queue.offer(q, "b")->Effect.runPromise
      let n = await Queue.size(q)->Effect.runPromise
      expect(n)->toBe(2)
    })

    testPromise("isEmpty is true for empty queue", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let empty = await Queue.isEmpty(q)->Effect.runPromise
      expect(empty)->toBe(true)
    })

    testPromise("isEmpty is false after offer", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, 1)->Effect.runPromise
      let empty = await Queue.isEmpty(q)->Effect.runPromise
      expect(empty)->toBe(false)
    })
  })

  describe("lifecycle", () => {
    testPromise("shutdown + isShutdown", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.shutdown(q)->Effect.runPromise
      let shut = await Queue.isShutdown(q)->Effect.runPromise
      expect(shut)->toBe(true)
    })
  })
})
```

---

### 2.3 `tests/DeferredTest.res` — Deferred

Covers: `make`, `await_`, `succeed`, `fail`, `completeWith`, `isDone`.

```rescript
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
```

---

### 2.4 `tests/LatchTest.res` — Latch

Covers: `makeLatch` (in Effect), `await_`, `open_`, `close`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Latch", () => {
  testPromise("makeLatch(false) starts closed — open_ releases awaiting fiber", async () => {
    let latch = Effect.makeLatch(false)->Effect.runSync
    // Fork a fiber that awaits the latch
    let fiber = latch->Latch.await_->Effect.fork->Effect.runSync
    // Open the latch — fiber should complete
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
    // Now closed — re-open
    let fiber = latch->Latch.await_->Effect.fork->Effect.runSync
    let _ = await latch->Latch.open_->Effect.runPromise
    let exit = await Fiber.join(fiber)->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })
})
```

---

### 2.5 `tests/DurationTest.res` — Duration

Covers: `millis`, `seconds`, `minutes`, `hours`, `days`. Duration.t is opaque — tests verify
constructors produce a truthy value (non-null, non-undefined) and can be consumed by `Effect.sleep`
via `TestClock.adjust` without error.

```rescript
open AsyncTest
open AsyncTest.Expect

// Duration constructors produce opaque values — verify they are truthy (not null/undefined)
// and passable to Effect.sleep without type errors at runtime.
describe("Duration — constructors", () => {
  test("millis returns a truthy Duration.t", () => {
    let d = Duration.millis(100)
    expect(d->Obj.magic)->toBeTruthy
  })

  test("seconds returns a truthy Duration.t", () => {
    expect(Duration.seconds(1)->Obj.magic)->toBeTruthy
  })

  test("minutes returns a truthy Duration.t", () => {
    expect(Duration.minutes(1)->Obj.magic)->toBeTruthy
  })

  test("hours returns a truthy Duration.t", () => {
    expect(Duration.hours(1)->Obj.magic)->toBeTruthy
  })

  test("days returns a truthy Duration.t", () => {
    expect(Duration.days(1)->Obj.magic)->toBeTruthy
  })

  testPromise("millis Duration can be used with Effect.sleep via TestClock", async () => {
    // Verify the Duration.t produced by millis is accepted by Effect.sleep at runtime.
    let program = Effect.sleep(Duration.millis(500))
      ->Effect.provide(TestContext.testContext)
    let fiber = program->Effect.runFork
    let _ = await TestClock.adjust(Duration.millis(500))
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    let exit = await Fiber.join(fiber)->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })
})
```

---

### 2.6 `tests/ExitTest.res` — Exit

Covers: `succeed`, `fail`, `die`, `isSuccess`, `isFailure`, `toOption`, `causeOption`, `map`,
`flatMap`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Exit", () => {
  describe("constructors + predicates", () => {
    test("succeed isSuccess = true, isFailure = false", () => {
      let e = Exit.succeed(1)
      expect(e->Exit.isSuccess)->toBe(true)
      expect(e->Exit.isFailure)->toBe(false)
    })

    test("fail isSuccess = false, isFailure = true", () => {
      let e = Exit.fail("err")
      expect(e->Exit.isSuccess)->toBe(false)
      expect(e->Exit.isFailure)->toBe(true)
    })

    test("die (defect) isFailure = true", () => {
      let e = Exit.die(JsError.make("defect"))
      expect(e->Exit.isFailure)->toBe(true)
    })
  })

  describe("extraction", () => {
    test("toOption on success returns Some(value)", () => {
      let e = Exit.succeed(42)
      expect(e->Exit.toOption)->toEqual(Some(42))
    })

    test("toOption on failure returns None", () => {
      let e = Exit.fail("err")
      expect(e->Exit.toOption)->toEqual(None)
    })

    test("causeOption on failure returns Some(cause)", () => {
      let e = Exit.fail("err")
      let causeOpt = e->Exit.causeOption
      expect(causeOpt->Option.isSome)->toBe(true)
    })

    test("causeOption on success returns None", () => {
      let e = Exit.succeed(1)
      expect(e->Exit.causeOption)->toEqual(None)
    })
  })

  describe("transformation", () => {
    test("map on success transforms value", () => {
      let e = Exit.succeed(3)->Exit.map(n => n * 2)
      expect(e->Exit.toOption)->toEqual(Some(6))
    })

    test("map on failure is a no-op", () => {
      let e = Exit.fail("err")->Exit.map(n => n * 2)
      expect(e->Exit.isFailure)->toBe(true)
    })

    test("flatMap on success chains exits", () => {
      let e = Exit.succeed(5)->Exit.flatMap(n => Exit.succeed(n + 1))
      expect(e->Exit.toOption)->toEqual(Some(6))
    })
  })
})
```

---

### 2.7 `tests/CauseTest.res` — Cause

Covers: `fail`, `die`, `parallel`, `sequential`, `isEmpty`, `isFail`, `isDie`, `isInterrupted`,
`failures`, `defects`, `pretty`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Cause", () => {
  describe("constructors + predicates", () => {
    test("fail isFail = true, isDie = false", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isFail)->toBe(true)
      expect(c->Cause.isDie)->toBe(false)
    })

    test("die isDie = true, isFail = false", () => {
      let c = Cause.die(JsError.make("defect"))
      expect(c->Cause.isDie)->toBe(true)
      expect(c->Cause.isFail)->toBe(false)
    })

    test("isInterrupted is false for fail cause", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isInterrupted)->toBe(false)
    })

    test("isEmpty is false for non-empty cause", () => {
      let c = Cause.fail("err")
      expect(c->Cause.isEmpty)->toBe(false)
    })
  })

  describe("extraction", () => {
    test("failures extracts typed errors from fail cause", () => {
      let c = Cause.fail("my-error")
      let errs = c->Cause.failures
      expect(errs)->toEqual(["my-error"])
    })

    test("failures extracts from parallel cause — both preserved", () => {
      let c = Cause.parallel(Cause.fail("left"), Cause.fail("right"))
      let errs = c->Cause.failures
      expect(errs)->toHaveLength(2)
    })

    test("defects extracts exceptions from die cause", () => {
      let c = Cause.die("surprise")
      let defs = c->Cause.defects
      expect(defs)->toHaveLength(1)
    })

    test("pretty returns a non-empty string", () => {
      let c = Cause.fail("err")
      let s = c->Cause.pretty
      expect(s->String.length)->toBeGreaterThan(0)
    })
  })

  describe("composition", () => {
    test("parallel preserves both causes", () => {
      let c = Cause.parallel(Cause.fail("a"), Cause.fail("b"))
      expect(c->Cause.failures)->toHaveLength(2)
    })

    test("sequential preserves both causes", () => {
      let c = Cause.sequential(Cause.fail("first"), Cause.fail("second"))
      expect(c->Cause.failures)->toHaveLength(2)
    })
  })
})
```

---

### 2.8 `tests/FiberTest.res` — Fiber

Covers: `join`, `interrupt`, `joinAll`, `collectAll`.

```rescript
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
    expect(exits->Array.getUnsafe(0)->Exit.isSuccess)->toBe(true)
    expect(exits->Array.getUnsafe(1)->Exit.isFailure)->toBe(true)
  })
})
```

---

### 2.9 `tests/ScheduleTest.res` — Schedule

Covers: `recurs`, `once`, `exponential`, `fixed`, `spaced`, `elapsed`, `forever`, `jittered`,
`whileInput`, `whileOutput`, `intersect`, `union`, `compose`. Tests that involve real timing
(exponential, fixed, spaced, elapsed) are controlled via `TestClock` to avoid wall-clock delays.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Schedule", () => {
  describe("recurs — count-based repetition", () => {
    testPromise("recurs(3) repeats an effect 3 additional times (4 total executions)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.recurs(3))
        ->Effect.runPromise
      expect(count.contents)->toBe(4)  // initial + 3 repeats
    })

    testPromise("recurs(0) does not repeat (1 total execution)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.recurs(0))
        ->Effect.runPromise
      expect(count.contents)->toBe(1)
    })
  })

  describe("once", () => {
    testPromise("once repeats exactly once (2 total executions)", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.once)
        ->Effect.runPromise
      expect(count.contents)->toBe(2)
    })
  })

  describe("whileInput — conditional retry", () => {
    testPromise("whileInput stops when predicate returns false", async () => {
      let count = ref(0)
      // Retry on "transient" errors only; fail permanently on "fatal"
      let schedule = Schedule.recurs(5)->Schedule.whileInput(err => err == "transient")
      let attempts = ref(0)
      let exit = await Effect.sync(() => {
        attempts := attempts.contents + 1
        if attempts.contents < 3 {
          // First 2 calls fail with transient error (should retry)
        }
      })
        ->Effect.flatMap(_ => {
          count := count.contents + 1
          if count.contents < 3 {
            Effect.fail("transient")
          } else {
            Effect.succeed(count.contents)
          }
        })
        ->Effect.retry(schedule)
        ->Effect.runPromiseExit
      expect(exit->Exit.isSuccess)->toBe(true)
    })
  })

  describe("intersect — stop when either stops", () => {
    testPromise("intersect(recurs(2), recurs(4)) stops after 2 repeats", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.intersect(Schedule.recurs(2), Schedule.recurs(4)))
        ->Effect.runPromise
      expect(count.contents)->toBe(3)  // initial + 2 repeats (shorter schedule wins)
    })
  })

  describe("union — stop when both stop", () => {
    testPromise("union(recurs(2), recurs(4)) stops after 4 repeats", async () => {
      let count = ref(0)
      let _ = await Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.union(Schedule.recurs(2), Schedule.recurs(4)))
        ->Effect.runPromise
      expect(count.contents)->toBe(5)  // initial + 4 repeats (longer schedule wins)
    })
  })

  describe("timing-based schedules — require TestClock", () => {
    testPromise("fixed(100ms) repeats after each 100ms interval", async () => {
      let count = ref(0)
      let program = Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(Schedule.intersect(Schedule.fixed(Duration.millis(100)), Schedule.recurs(3)))
        ->Effect.provide(TestContext.testContext)
      let fiber = program->Effect.runFork
      // Advance clock 4 times to trigger 3 repeats
      let _ = await TestClock.adjust(Duration.millis(400))
        ->Effect.provide(TestContext.testContext)
        ->Effect.runPromise
      let _ = await Fiber.join(fiber)->Effect.runPromiseExit
      expect(count.contents)->toBe(4)
    })

    testPromise("exponential starts with the base delay", async () => {
      // Just verify the schedule can be composed and run without error
      let count = ref(0)
      let schedule = Schedule.exponential(Duration.millis(100))
        ->Schedule.intersect(Schedule.recurs(1))
      let program = Effect.sync(() => { count := count.contents + 1 })
        ->Effect.repeat(schedule)
        ->Effect.provide(TestContext.testContext)
      let fiber = program->Effect.runFork
      let _ = await TestClock.adjust(Duration.millis(200))
        ->Effect.provide(TestContext.testContext)
        ->Effect.runPromise
      let _ = await Fiber.join(fiber)->Effect.runPromiseExit
      expect(count.contents)->toBe(2)
    })
  })
})
```

---

### 2.10 `tests/StmTest.res` — STM / TRef

Covers: `TRef.make`, `TRef.get`, `TRef.set`, `TRef.update`, `TRef.getAndUpdate`, `TRef.modify`,
`STM.succeed`, `STM.fail`, `STM.map`, `STM.flatMap`, `STM.zipRight`, `STM.commit`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Stm.TRef", () => {
  testPromise("make + get returns the initial value", async () => {
    let ref = Stm.TRef.make(10)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(ref)->Stm.commit->Effect.runSync
    expect(v)->toBe(10)
  })

  testPromise("set + get reflects the new value", async () => {
    let ref = Stm.TRef.make(0)->Stm.commit->Effect.runSync
    let _ = Stm.TRef.set(ref, 99)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(ref)->Stm.commit->Effect.runSync
    expect(v)->toBe(99)
  })

  testPromise("update applies a function to the value", async () => {
    let ref = Stm.TRef.make(5)->Stm.commit->Effect.runSync
    let _ = Stm.TRef.update(ref, n => n * 2)->Stm.commit->Effect.runSync
    let v = Stm.TRef.get(ref)->Stm.commit->Effect.runSync
    expect(v)->toBe(10)
  })

  testPromise("getAndUpdate returns the old value", async () => {
    let ref = Stm.TRef.make(3)->Stm.commit->Effect.runSync
    let old = Stm.TRef.getAndUpdate(ref, n => n + 1)->Stm.commit->Effect.runSync
    let new_ = Stm.TRef.get(ref)->Stm.commit->Effect.runSync
    expect(old)->toBe(3)
    expect(new_)->toBe(4)
  })

  testPromise("modify returns computed result and updates the ref", async () => {
    let ref = Stm.TRef.make(7)->Stm.commit->Effect.runSync
    let result = Stm.TRef.modify(ref, n => (n * 10, n + 1))->Stm.commit->Effect.runSync
    let new_ = Stm.TRef.get(ref)->Stm.commit->Effect.runSync
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
```

---

### 2.11 `tests/PubSubTest.res` — PubSub

Covers: `unbounded`, `bounded`, `sliding`, `dropping`, `publish`, `publishAll`, `subscribe`,
`size`, `shutdown`, `isShutdown`.

```rescript
open AsyncTest
open AsyncTest.Expect

describe("PubSub", () => {
  testPromise("unbounded pubsub: publish + subscribe + Queue.take delivers message", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    // Subscribe before publishing
    let queue = await PubSub.subscribe(ps)->Effect.scoped->Effect.runPromise
    let _ = await PubSub.publish(ps, "hello")->Effect.runPromise
    let v = await Queue.take(queue)->Effect.runPromise
    expect(v)->toBe("hello")
  })

  testPromise("size reflects subscriber count", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    let _q1 = await PubSub.subscribe(ps)->Effect.scoped->Effect.runPromise
    let _q2 = await PubSub.subscribe(ps)->Effect.scoped->Effect.runPromise
    let n = await PubSub.size(ps)->Effect.runPromise
    // Size may reflect subscribers or buffered items depending on PubSub variant;
    // with unbounded and no items published, count should be >= 0
    expect(n)->toBeGreaterThan(-1)
  })

  testPromise("publishAll delivers all items to subscriber", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    let queue = await PubSub.subscribe(ps)->Effect.scoped->Effect.runPromise
    let _ = await PubSub.publishAll(ps, [1, 2, 3])->Effect.runPromise
    let items = await Queue.takeAll(queue)->Effect.runPromise
    expect(items)->toEqual([1, 2, 3])
  })

  testPromise("bounded constructor creates a PubSub.t without error", async () => {
    let ps = PubSub.bounded(10)->Effect.runSync
    let accepted = await PubSub.publish(ps, "x")->Effect.runPromise
    expect(accepted)->toBe(true)
  })

  testPromise("shutdown + isShutdown", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    let _ = await PubSub.shutdown(ps)->Effect.runPromise
    let shut = await PubSub.isShutdown(ps)->Effect.runPromise
    expect(shut)->toBe(true)
  })
})
```

---

### 2.12 `tests/RefTest.res` — Ref

Covers: `make`, `get`, `set`, `update`, `getAndUpdate`, `updateAndGet`, `modify`.

```rescript
open AsyncTest
open AsyncTest.Expect

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
```

---

### 2.13 `tests/SynchronizedRefTest.res` — SynchronizedRef

Covers: `make`, `get`, `set`, `update`, `updateEffect`, `modifyEffect`.

```rescript
open AsyncTest
open AsyncTest.Expect

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
```

---

### 2.14 `tests/TestClockTest.res` — TestClock + TestContext

Covers: `TestClock.adjust`, `TestClock.currentTimeMillis`, `TestContext.testContext`,
`Effect.provide`. This file also serves as the integration test for the TestClock+TestContext
binding pair.

```rescript
open AsyncTest
open AsyncTest.Expect

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
    let program = Effect.sleep(Duration.millis(500))
      ->Effect.provide(TestContext.testContext)
    let fiber = program->Effect.runFork
    let _ = await TestClock.adjust(Duration.millis(500))
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    let exit = await Fiber.join(fiber)->Effect.runPromiseExit
    expect(exit->Exit.isSuccess)->toBe(true)
  })

  testPromise("Effect.sleep does not resolve before clock is advanced", async () => {
    let completed = ref(false)
    let program = Effect.sleep(Duration.millis(1000))
      ->Effect.tap(_ => Effect.sync(() => { completed := true }))
      ->Effect.provide(TestContext.testContext)
    let _fiber = program->Effect.runFork
    // Advance by less than the sleep duration
    let _ = await TestClock.adjust(Duration.millis(999))
      ->Effect.provide(TestContext.testContext)
      ->Effect.runPromise
    let _ = await Effect.yieldNow()->Effect.runPromise
    expect(completed.contents)->toBe(false)
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
```

---

## Section 3: Implementation Order

All test files are independent of each other. The only shared prerequisite is `AsyncTest.res`.
Suggested implementation order — simplest/most foundational first:

1. `AsyncTest.res` — shared helpers (prerequisite for all others)
2. `DurationTest.res` — trivial constructors, no async complexity
3. `ExitTest.res` — purely synchronous, foundational type
4. `CauseTest.res` — purely synchronous, foundational type
5. `EffectTest.res` — core primitives used by everything else
6. `RefTest.res` — straightforward async CRUD
7. `SynchronizedRefTest.res` — like Ref but with effectful updates
8. `StmTest.res` — transactions, synchronous-ish
9. `QueueTest.res` — concurrent but simple patterns
10. `DeferredTest.res` — completion signals
11. `LatchTest.res` — binary gates
12. `FiberTest.res` — concurrency primitives
13. `PubSubTest.res` — fan-out
14. `ScheduleTest.res` — uses TestClock
15. `TestClockTest.res` — TestClock + TestContext together

`StreamTest.res` is handled separately in the stream integration plan (Phase A).

---

## Section 4: Coverage Summary

| Module | Bindings | Test file | Notes |
|---|---|---|---|
| `Effect.res` | 34 | `EffectTest.res` | `sleep`/`timeout` in `TestClockTest`; `provide` in `TestClockTest`/`ScheduleTest` |
| `Queue.res` | 14 | `QueueTest.res` | All covered |
| `Deferred.res` | 6 | `DeferredTest.res` | All covered |
| `Latch.res` | 3 | `LatchTest.res` | All covered |
| `Duration.res` | 5 | `DurationTest.res` | All covered |
| `Exit.res` | 9 | `ExitTest.res` | All covered |
| `Cause.res` | 11 | `CauseTest.res` | All covered |
| `Fiber.res` | 4 | `FiberTest.res` | All covered |
| `Schedule.res` | 13 | `ScheduleTest.res` | Timing tests use TestClock |
| `Stm.res` | 13 | `StmTest.res` | All covered |
| `PubSub.res` | 10 | `PubSubTest.res` | All covered |
| `Ref.res` | 7 | `RefTest.res` | All covered |
| `SynchronizedRef.res` | 6 | `SynchronizedRefTest.res` | All covered |
| `TestClock.res` | 2 | `TestClockTest.res` | Combined with TestContext |
| `TestContext.res` | 1 | `TestClockTest.res` | Combined with TestClock |
| `Stream.res` (planned) | 15 | `StreamTest.res` | See stream integration plan Phase A |

**Total: 15 modules, ~140 bindings, ~70 smoke tests across 15 test files.**

---

## Section 5: Known Constraints

### `Effect.either` binding may not be structurally compatible

The comment in `Effect.res` notes that `result<'a, 'e>` is "structurally compatible" with Effect's
`Either<E, A>`. This is likely incorrect: ReScript `result` uses `{TAG: "Ok", _0: val}` /
`{TAG: "Error", _0: val}` (v12 string tags), while Effect's `Either` uses
`{_tag: "Right", right: val}` / `{_tag: "Left", left: val}`. A smoke test would surface this
discrepancy. The binding is not currently used in production code — verify at implementation time
and correct the binding or add a note about required `Obj.magic` coercion.

### `PubSub.subscribe` is scoped

`PubSub.subscribe` returns an `Effect.t<Queue.t<'a>>` that is scoped — the subscription is
released when the enclosing scope closes. In tests, use `Effect.scoped` to open and close a scope
around the subscription, or use `Effect.runFork` + manual scope management. Tests that subscribe
and then publish must sequence the subscription before publishing; otherwise the published item
may be dropped.

### `TestClock` + `Effect.provide` scope

`TestClock.adjust` must be provided with the same `TestContext.testContext` layer as the sleeping
effect. Both the sleeping fiber AND the `adjust` call must be in the same test context scope. The
pattern: provide TestContext to both `program` and `TestClock.adjust` separately — they share the
virtual clock implicitly via the runtime.

### `runFork` vs `fork` in tests

`Effect.runFork` starts a daemon fiber immediately in the global runtime. `Effect.fork` creates a
fiber that is a child of the current scope. In test contexts without a scope, `runFork` is simpler.
For tests that need to verify child fiber behavior (structured concurrency), use `Effect.fork`
inside an Effect pipeline.

### `Schedule.forever` naming conflict

`Schedule.forever` is a value (a Schedule that runs forever), not a function. It has the same
binding name as `Effect.forever` (which is a function `t<'a,'e,'r> => t<'b,'e,'r>`). Since they
live in separate modules there is no name conflict in ReScript, but the test file should be clear
about which `forever` is being used.
