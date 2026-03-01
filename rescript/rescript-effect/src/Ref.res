/**
ReScript bindings for `Ref<A>` — a concurrent-safe mutable variable.

All read/write operations are atomic via compare-and-swap (CAS), making `Ref`
safe to use from multiple concurrent fibers without additional locking.

For updates that depend on an async computation (e.g. loading from a database),
use `SynchronizedRef` instead — it serialises effectful updates atomically.
*/
type t<'a>

/** Creates a new `Ref` initialised with `value`. */
@module("effect") @scope("Ref")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

/** Reads and returns the current value. */
@module("effect") @scope("Ref")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

/** Replaces the current value with `newValue`. */
@module("effect") @scope("Ref")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

/** Atomically applies a pure function to the current value and stores the result. */
@module("effect") @scope("Ref")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

/** Atomically applies `f` to the current value, stores the new value, and returns the **old** value. */
@module("effect") @scope("Ref")
external getAndUpdate: (t<'a>, 'a => 'a) => Effect.t<'a, 'e, 'r> = "getAndUpdate"

/** Atomically applies `f` to the current value, stores the new value, and returns the **new** value. */
@module("effect") @scope("Ref")
external updateAndGet: (t<'a>, 'a => 'a) => Effect.t<'a, 'e, 'r> = "updateAndGet"

/**
Atomically applies `f` to the current value, producing a result `'b` and a new value `'a` in one step.

**Example**
```rescript
// Atomically dequeue the head element
ref->Ref.modify(list => switch list {
  | [] => (None, [])
  | [head, ...tail] => (Some(head), tail)
})
```
*/
@module("effect") @scope("Ref")
external modify: (t<'a>, 'a => ('b, 'a)) => Effect.t<'b, 'e, 'r> = "modify"
