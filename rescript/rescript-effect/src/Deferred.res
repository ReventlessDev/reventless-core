// ReScript bindings for Effect Deferred
//
// Deferred<A, E> is a single-value, one-time synchronization primitive.
// One fiber sets it; any number of fibers can await it. Awaiting fibers
// suspend semantically (no thread blocked) until the value is set.
//
// Use Deferred instead of ref<option<handler>> to eliminate the race
// condition where consumers see None before the producer has set the value.

type t<'a, 'e>

// Create a new, empty Deferred
@module("effect") @scope("Deferred")
external make: unit => Effect.t<t<'a, 'e>, 'e2, 'r> = "make"

// Block the current fiber until the Deferred is completed
// Note: `await` is a reserved keyword in ReScript — use await_
@module("effect") @scope("Deferred")
external await_: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "await"

// Complete with a success value — returns true if this was the first completion
@module("effect") @scope("Deferred")
external succeed: (t<'a, 'e>, 'a) => Effect.t<bool, 'e2, 'r> = "succeed"

// Complete with a failure — returns true if this was the first completion
@module("effect") @scope("Deferred")
external fail: (t<'a, 'e>, 'e) => Effect.t<bool, 'e2, 'r> = "fail"

// Complete with the result of running an effect
@module("effect") @scope("Deferred")
external completeWith: (t<'a, 'e>, Effect.t<'a, 'e, 'r>) => Effect.t<bool, 'e2, 'r> = "completeWith"

// Check if the Deferred has been completed (non-blocking)
@module("effect") @scope("Deferred")
external isDone: t<'a, 'e> => Effect.t<bool, 'e2, 'r> = "isDone"
