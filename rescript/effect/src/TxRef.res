/**
ReScript bindings for `TxRef<A>` — a transactional reference.

Each operation is atomic on its own. To make several reads and writes, on one or
more refs, commit or fail together, run them inside `Effect.tx`: a write becomes
visible only when the outermost transaction succeeds.

**Example**
```rescript
let counter = TxRef.makeUnsafe(0)
counter->TxRef.update(n => n + 1)->Effect.runSync
```
*/
type t<'a>

/** Creates a `TxRef` holding `initial`. */
@module("effect/TxRef")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

/** Creates a `TxRef` outside an `Effect`, for state built once at startup. */
@module("effect/TxRef")
external makeUnsafe: 'a => t<'a> = "makeUnsafe"

/** Reads the current value. */
@module("effect/TxRef")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

/** Replaces the value. */
@module("effect/TxRef")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

/** Replaces the value with `f` of the current one. */
@module("effect/TxRef")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

/**
Applies `f` to the current value, which returns a result and the new value, in one step.

```rescript
ref->TxRef.modify(list => switch list {
  | [] => (None, [])
  | [head, ...tail] => (Some(head), tail)
})
```
*/
@module("effect/TxRef")
external modify: (t<'a>, 'a => ('b, 'a)) => Effect.t<'b, 'e, 'r> = "modify"
