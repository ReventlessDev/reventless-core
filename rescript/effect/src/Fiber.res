/**
ReScript bindings for `Fiber<A, E>` — a lightweight virtual thread.

Every `Effect` runs on a fiber. Fibers are cheap (~1 KB each), support
structured concurrency, and propagate interruption to children (all finalizers run).

`Fiber.t` is a transparent alias of `Effect.fiber`, so values flow between
the two modules without casting.

**Typical usage**
```rescript
// Fork a background task and join later
let fiber = myEffect->Effect.fork->Effect.runSync
let result = fiber->Fiber.join->Effect.runPromise
```
*/
type t<'a, 'e> = Effect.fiber<'a, 'e>

/**
Waits for the fiber to complete and returns its success value.

If the fiber failed, the failure is propagated into the current fiber's error channel.
*/
@module("effect/Fiber")
external join: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "join"

/**
Interrupts the fiber, triggering its finalizers.

Returns the fiber's `Exit` once interruption completes. Interruption is
propagated to all child fibers of the interrupted fiber.
*/
@module("effect/Fiber")
external interrupt: t<'a, 'e> => Effect.t<Exit.t<'a, 'e>, 'e2, 'r> = "interrupt"

/**
Waits for all fibers in parallel and collects their success values into an array.

If any fiber fails, the failure is propagated and remaining fibers are interrupted.
*/
@module("effect/Fiber")
external joinAll: array<t<'a, 'e>> => Effect.t<array<'a>, 'e, 'r> = "joinAll"

/**
Waits for all fibers and collects each fiber's `Exit` — never fails itself.

Use this when you want to inspect the outcome of each fiber regardless of success or failure.

> **Note** Effect v3 exports this as `awaitAll` (not `collectAll`). This binding maps to the correct JS name.
*/
@module("effect/Fiber")
external collectAll: array<t<'a, 'e>> => Effect.t<array<Exit.t<'a, 'e>>, 'e2, 'r> = "awaitAll"

/**
Non-blocking poll — returns the fiber's `Exit` if it has already completed, or `None` if still running.
*/
@module("effect/Fiber")
external _poll: t<'a, 'e> => Effect.t<EffectOption.t<Exit.t<'a, 'e>>, 'e2, 'r> = "poll"
let poll = fiber => fiber->_poll->Effect.map(EffectOption.toOption)
