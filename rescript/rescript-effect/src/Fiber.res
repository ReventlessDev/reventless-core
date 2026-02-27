// ReScript bindings for Effect Fiber
//
// Fibers are lightweight virtual threads (~1KB each). Every Effect runs on
// a fiber. Fibers support structured concurrency — interruption propagates
// to children and triggers all finalizers.
//
// Transparent alias of Effect.fiber.

type t<'a, 'e> = Effect.fiber<'a, 'e>

// Wait for the fiber to complete, propagating its success or failure
@module("effect") @scope("Fiber")
external join: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "join"

// Interrupt the fiber — triggers its finalizers, resolves with its Exit
@module("effect") @scope("Fiber")
external interrupt: t<'a, 'e> => Effect.t<Exit.t<'a, 'e>, 'e2, 'r> = "interrupt"

// Wait for all fibers in parallel, collecting successes
@module("effect") @scope("Fiber")
external joinAll: array<t<'a, 'e>> => Effect.t<array<'a>, 'e, 'r> = "joinAll"

// Collect Exit from all fibers without failing — never throws
@module("effect") @scope("Fiber")
external collectAll: array<t<'a, 'e>> => Effect.t<array<Exit.t<'a, 'e>>, 'e2, 'r> = "collectAll"
