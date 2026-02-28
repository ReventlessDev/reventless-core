/**
ReScript bindings for `TestClock` — a virtual clock for deterministic time testing.

Instead of waiting for real time, `TestClock.adjust` advances the virtual clock
and immediately runs all effects scheduled for that time or earlier (in order).

**Typical test pattern:**
1. Fork the effect under test (it will suspend at `Effect.sleep` or a `Schedule`)
2. Call `TestClock.adjust` to advance virtual time
3. Join the fiber to inspect the result

`TestClock` is activated by providing `TestContext.testContext` via `Effect.provide`.

**Example**
```rescript
let program =
  Effect.sleep(Duration.minutes(5))
  ->Effect.zipRight(Effect.succeed("done"))

let test =
  program
  ->Effect.fork
  ->Effect.flatMap(fiber =>
    TestClock.adjust(Duration.minutes(5))
    ->Effect.zipRight(fiber->Fiber.join)
  )
  ->Effect.provide(TestContext.testContext)
  ->Effect.runPromise
```
*/

/**
Advances the virtual clock by `duration`, running all scheduled effects on or before the new time.

Effects are run in chronological order. If advancing triggers a `Schedule`, all
recurrences that fall within the new time are fired.
*/
@module("effect") @scope("TestClock")
external adjust: Duration.t => Effect.t<unit, 'e, 'r> = "adjust"

/**
Returns the current virtual clock time in milliseconds as an `Effect`.

> **Note** `currentTimeMillis` is an Effect value (not a function call) — no `()` needed.
*/
@module("effect") @scope("TestClock")
external currentTimeMillis: Effect.t<int, 'e, 'r> = "currentTimeMillis"
