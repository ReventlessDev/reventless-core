// ReScript bindings for Effect Ref
//
// Ref<A> is a concurrent-safe mutable variable. Reads and writes are
// atomic via compare-and-swap (CAS). For effectful updates that must
// be transactional, use SynchronizedRef instead.

type t<'a>

// Create a new Ref with an initial value
@module("effect") @scope("Ref")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

// Read the current value
@module("effect") @scope("Ref")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

// Replace the value
@module("effect") @scope("Ref")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

// Apply a pure function to update the value
@module("effect") @scope("Ref")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

// Update and return the old value
@module("effect") @scope("Ref")
external getAndUpdate: (t<'a>, 'a => 'a) => Effect.t<'a, 'e, 'r> = "getAndUpdate"

// Update and return the new value
@module("effect") @scope("Ref")
external updateAndGet: (t<'a>, 'a => 'a) => Effect.t<'a, 'e, 'r> = "updateAndGet"

// Compute a result while updating the value in one atomic step
@module("effect") @scope("Ref")
external modify: (t<'a>, 'a => ('b, 'a)) => Effect.t<'b, 'e, 'r> = "modify"
