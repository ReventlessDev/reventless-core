/**
ReScript bindings for `SynchronizedRef<A>` — a `Ref` with atomic effectful updates.

Like `Ref`, `SynchronizedRef` is a concurrent-safe mutable variable. Unlike `Ref`,
`updateEffect` and `modifyEffect` serialise effectful update functions: no other
fiber can observe the ref in the intermediate state between the read and the write.

**When to use `SynchronizedRef` over `Ref`:**
Use `SynchronizedRef` when the new value depends on an async computation
(e.g. fetching from a database or calling an external service).
*/
type t<'a>

/** Creates a new `SynchronizedRef` initialised with `value`. */
@module("effect/SynchronizedRef")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

/** Reads and returns the current value. */
@module("effect/SynchronizedRef")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

/** Replaces the current value with `newValue`. */
@module("effect/SynchronizedRef")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

/** Atomically applies a pure function to update the value. */
@module("effect/SynchronizedRef")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

/**
Atomically applies an effectful function to update the value.

No other fiber can read or write the ref between the read and write steps.
The effect is run while the ref is "locked" — all other `updateEffect` calls
for this ref will wait until the current one completes.

**Example**
```rescript
// Load current state from DB and update — atomically
ref->SynchronizedRef.updateEffect(current =>
  loadFromDb(current.id)->Effect.map(fresh => {...fresh, count: fresh.count + 1})
)
```
*/
@module("effect/SynchronizedRef")
external updateEffect: (t<'a>, 'a => Effect.t<'a, 'e, 'r>) => Effect.t<unit, 'e, 'r> = "updateEffect"

/**
Atomically applies an effectful function that produces both a result and a new value.

Combines the atomicity guarantee of `updateEffect` with the result-returning
semantics of `Ref.modify`.
*/
@module("effect/SynchronizedRef")
external modifyEffect: (t<'a>, 'a => Effect.t<('b, 'a), 'e, 'r>) => Effect.t<'b, 'e, 'r> = "modifyEffect"
