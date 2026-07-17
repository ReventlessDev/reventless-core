/**
ReScript bindings for `Deferred<A, E>` — a one-time, single-value synchronization primitive.

One fiber sets the value; any number of fibers can await it. Awaiting fibers
suspend semantically (no thread is blocked) and resume when the value is set.

**Why use `Deferred` instead of `ref<option<handler>>`?**
A `ref` forces consumers to poll or risk a race where they see `None` before
the producer sets the value. `Deferred` makes the wait explicit and safe.

**Example**
```rescript
let d = Deferred.make()->Effect.runSync

// Producer fiber
Deferred.succeed(d, handler)->Effect.runPromise

// Consumer fiber (may run before the producer)
Deferred.await_(d)->Effect.runPromise // suspends until succeeded
```
*/
type t<'a, 'e>

/** Creates a new, empty `Deferred`. */
@module("effect/Deferred")
external make: unit => Effect.t<t<'a, 'e>, 'e2, 'r> = "make"

/**
Suspends the current fiber until the `Deferred` is completed.

> **Note** `await` is a reserved keyword in ReScript — use `await_` here.
*/
@module("effect/Deferred")
external await_: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "await"

/**
Completes the `Deferred` with a success value.

Returns `true` if this was the first completion; `false` if already completed.
Only the first call has any effect — subsequent calls are no-ops.
*/
@module("effect/Deferred")
external succeed: (t<'a, 'e>, 'a) => Effect.t<bool, 'e2, 'r> = "succeed"

/**
Completes the `Deferred` with a failure.

Returns `true` if this was the first completion.
*/
@module("effect/Deferred")
external fail: (t<'a, 'e>, 'e) => Effect.t<bool, 'e2, 'r> = "fail"

/**
Completes the `Deferred` with the result of running an `Effect`.

Returns `true` if this was the first completion.
*/
@module("effect/Deferred")
external completeWith: (t<'a, 'e>, Effect.t<'a, 'e, 'r>) => Effect.t<bool, 'e2, 'r> = "completeWith"

/** Returns `true` if the `Deferred` has been completed (non-suspending). */
@module("effect/Deferred")
external isDone: t<'a, 'e> => Effect.t<bool, 'e2, 'r> = "isDone"
