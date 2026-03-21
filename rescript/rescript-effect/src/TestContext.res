/**
ReScript bindings for `TestContext` — a `Layer` that provides test versions of core services.

Providing `TestContext.testContext` replaces the following real services with test doubles:
- `TestClock` — virtual clock for deterministic time control
- `TestRandom` — deterministic random number generation
- `TestConsole` — captures console output

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

/**
The `TestContext` layer — provides `TestClock` and other test services.

Provide this to an `Effect` before running it in tests to enable
`TestClock.adjust`, `TestClock.currentTimeMillis`, etc.
*/
@module("effect/TestContext")
external testContext: layer = "TestContext"
