/**
ReScript bindings for `Clock` — the current time as an `Effect`, so that
`TestClock` can fix it in a test.

**Example**
```rescript
let program = Clock.currentTimeMillis->Effect.map(now => now +. 60_000.)
```
*/
/** Milliseconds since 1970, UTC, from the `Clock` in context. */
@module("effect/Clock")
external currentTimeMillis: Effect.t<float, 'e, 'r> = "currentTimeMillis"
