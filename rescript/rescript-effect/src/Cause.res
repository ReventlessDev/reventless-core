/**
ReScript bindings for `Cause<E>` — the algebraic data type that captures
the full failure structure of an `Effect`.

Unlike a plain error value, a `Cause` preserves:
- *Typed failures* (`Fail`) — expected errors in the `'e` channel
- *Defects* (`Die`) — unexpected thrown exceptions
- *Parallel failures* (`Parallel`) — both sides of a concurrent failure
- *Sequential failures* (`Sequential`) — a chain of failures
- *Interruptions* — fiber cancellation

You encounter `Cause` when inspecting `Exit.t` or using `Effect.runPromiseExit`.
*/
type t<'e>

// ─── Constructors ──────────────────────────────────────────────────────────

/** Creates a `Cause` representing a typed, expected failure in the `'e` channel. */
@module("effect") @scope("Cause")
external fail: 'e => t<'e> = "fail"

/** Creates a `Cause` representing an unexpected exception or defect (not a typed error). */
@module("effect") @scope("Cause")
external die: 'defect => t<'e> = "die"

/**
Creates a `Cause` representing two concurrent failures — **both** causes are preserved.

This is what distinguishes Effect's `Cause` from a plain exception: neither failure
is silently discarded when two fibers fail simultaneously.
*/
@module("effect") @scope("Cause")
external parallel: (t<'e>, t<'e>) => t<'e> = "parallel"

/** Creates a `Cause` representing two sequential failures — a failure followed by a finalizer failure. */
@module("effect") @scope("Cause")
external sequential: (t<'e>, t<'e>) => t<'e> = "sequential"

// ─── Predicates ────────────────────────────────────────────────────────────

/** Returns `true` if the cause is empty (no failure, no defect, no interruption). */
@module("effect") @scope("Cause")
external isEmpty: t<'e> => bool = "isEmpty"

/**
Returns `true` if the cause is exactly a typed `Fail` node.

> **Note** Effect v3 exports this as `isFailType` — not `isFail`. This binding maps to the correct JS name.
*/
@module("effect") @scope("Cause")
external isFail: t<'e> => bool = "isFailType"

/** Returns `true` if the cause contains a `Die` (unexpected exception / defect). */
@module("effect") @scope("Cause")
external isDie: t<'e> => bool = "isDie"

/** Returns `true` if the cause contains an interruption. */
@module("effect") @scope("Cause")
external isInterrupted: t<'e> => bool = "isInterrupted"

// ─── Extraction ────────────────────────────────────────────────────────────

/**
Extracts all typed failure values from the cause tree, including those in parallel branches.

Returns an empty array if the cause contains no typed failures.
*/
@module("effect") @scope("Cause")
external failures: t<'e> => array<'e> = "failures"

/** Extracts all defects (unexpected exceptions) from the cause tree. */
@module("effect") @scope("Cause")
external defects: t<'e> => array<unknown> = "defects"

/** Returns a human-readable string representation of the full cause tree, useful for logging. */
@module("effect") @scope("Cause")
external pretty: t<'e> => string = "pretty"
