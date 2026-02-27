// ReScript bindings for Effect SynchronizedRef
//
// SynchronizedRef<A> is like Ref, but provides updateEffect — an atomic,
// effectful update. No other fiber can read or write the ref between the
// read and write steps of the update. Use this instead of Ref when the
// new value depends on an async computation (e.g. loading from storage).

type t<'a>

// Create a new SynchronizedRef with an initial value
@module("effect") @scope("SynchronizedRef")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

// Read the current value
@module("effect") @scope("SynchronizedRef")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

// Replace the value
@module("effect") @scope("SynchronizedRef")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

// Apply a pure function atomically
@module("effect") @scope("SynchronizedRef")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

// Run an effectful function atomically — no other fiber can observe
// the ref in the intermediate state between read and write.
@module("effect") @scope("SynchronizedRef")
external updateEffect: (t<'a>, 'a => Effect.t<'a, 'e, 'r>) => Effect.t<unit, 'e, 'r> = "updateEffect"

// Effectful update that also produces a result value
@module("effect") @scope("SynchronizedRef")
external modifyEffect: (t<'a>, 'a => Effect.t<('b, 'a), 'e, 'r>) => Effect.t<'b, 'e, 'r> = "modifyEffect"
