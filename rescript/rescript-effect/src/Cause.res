// ReScript bindings for Effect Cause
//
// Cause<E> is an algebraic data type that captures the full failure structure
// of an effect, including parallel failures (both errors preserved, not just
// the first) and unexpected defects (thrown exceptions).

type t<'e>

// ─── Constructors ──────────────────────────────────────────────────────────

// A typed, expected failure
@module("effect") @scope("Cause")
external fail: 'e => t<'e> = "fail"

// An unexpected exception/defect (not a typed failure)
@module("effect") @scope("Cause")
external die: 'defect => t<'e> = "die"

// Two causes from concurrent operations — BOTH are preserved
@module("effect") @scope("Cause")
external parallel: (t<'e>, t<'e>) => t<'e> = "parallel"

// Two causes from sequential operations
@module("effect") @scope("Cause")
external sequential: (t<'e>, t<'e>) => t<'e> = "sequential"

// ─── Predicates ────────────────────────────────────────────────────────────

@module("effect") @scope("Cause")
external isEmpty: t<'e> => bool = "isEmpty"

// Note: Effect v3 exports this as `isFailType` (exact Fail tag check)
@module("effect") @scope("Cause")
external isFail: t<'e> => bool = "isFailType"

@module("effect") @scope("Cause")
external isDie: t<'e> => bool = "isDie"

@module("effect") @scope("Cause")
external isInterrupted: t<'e> => bool = "isInterrupted"

// ─── Extraction ────────────────────────────────────────────────────────────

// All typed failures in the cause tree (including parallel branches)
@module("effect") @scope("Cause")
external failures: t<'e> => array<'e> = "failures"

// All defects (unexpected exceptions) in the cause tree
@module("effect") @scope("Cause")
external defects: t<'e> => array<unknown> = "defects"

// Human-readable representation of the full cause tree
@module("effect") @scope("Cause")
external pretty: t<'e> => string = "pretty"
