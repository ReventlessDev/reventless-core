// ReScript bindings for Effect Exit
//
// Exit<A, E> is the result of running a fiber to completion.
// It is either a success carrying the value A, or a failure carrying
// a Cause<E> (which may include parallel failures, defects, and interruptions).

type t<'a, 'e>

// ─── Constructors ──────────────────────────────────────────────────────────

@module("effect") @scope("Exit")
external succeed: 'a => t<'a, 'e> = "succeed"

@module("effect") @scope("Exit")
external fail: 'e => t<'a, 'e> = "fail"

@module("effect") @scope("Exit")
external die: 'defect => t<'a, 'e> = "die"

// ─── Predicates ────────────────────────────────────────────────────────────

@module("effect") @scope("Exit")
external isSuccess: t<'a, 'e> => bool = "isSuccess"

@module("effect") @scope("Exit")
external isFailure: t<'a, 'e> => bool = "isFailure"

// ─── Extraction ────────────────────────────────────────────────────────────

// Extract the success value — returns None if failure
@module("effect") @scope("Exit")
external toOption: t<'a, 'e> => option<'a> = "toOption"

// Extract the Cause from a failure exit (undefined if success)
@module("effect") @scope("Exit")
external causeOption: t<'a, 'e> => option<Cause.t<'e>> = "causeOption"

// ─── Transformation ────────────────────────────────────────────────────────

@module("effect") @scope("Exit")
external map: (t<'a, 'e>, 'a => 'b) => t<'b, 'e> = "map"

@module("effect") @scope("Exit")
external flatMap: (t<'a, 'e>, 'a => t<'b, 'e>) => t<'b, 'e> = "flatMap"
