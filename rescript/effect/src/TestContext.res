/**
ReScript bindings for `TestContext` — a `Layer` that provides test versions of core services.

Providing `TestContext.testContext` replaces the clock with `TestClock`, a virtual
clock for deterministic time control.

**Example**
```rescript
myEffect
->Effect.provide(TestContext.testContext)
->Effect.runPromise
```

After providing, use `TestClock.adjust` to advance virtual time.
*/
/** Opaque type for Effect `Layer`s — use via `Effect.provide`. */
type layer

@module("effect/testing/TestClock")
external makeLayer: unit => layer = "layer"

/**
The test layer — provides `TestClock`.

Provide this to an `Effect` before running it in tests to enable
`TestClock.adjust`, `TestClock.currentTimeMillis`, etc.
*/
let testContext = makeLayer()
