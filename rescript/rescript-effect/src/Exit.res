/**
ReScript bindings for `Exit<A, E>` — the result of running a fiber to completion.

An `Exit` is either:
- `Success(value: A)` — the fiber completed successfully
- `Failure(cause: Cause<E>)` — the fiber failed, was interrupted, or threw a defect

You encounter `Exit` when using `Effect.runPromiseExit`, `Effect.runSyncExit`,
`Fiber.collectAll`, or `Effect.acquireRelease`.
*/
type t<'a, 'e>

// ─── Constructors ──────────────────────────────────────────────────────────

/** Creates a successful `Exit` carrying `value`. */
@module("effect") @scope("Exit")
external succeed: 'a => t<'a, 'e> = "succeed"

/** Creates a failed `Exit` from a typed error (wraps it in a `Cause.fail`). */
@module("effect") @scope("Exit")
external fail: 'e => t<'a, 'e> = "fail"

/** Creates a failed `Exit` from a defect (unexpected exception). */
@module("effect") @scope("Exit")
external die: 'defect => t<'a, 'e> = "die"

// ─── Predicates ────────────────────────────────────────────────────────────

/** Returns `true` if the `Exit` is a success. */
@module("effect") @scope("Exit")
external isSuccess: t<'a, 'e> => bool = "isSuccess"

/** Returns `true` if the `Exit` is a failure (typed error, defect, or interruption). */
@module("effect") @scope("Exit")
external isFailure: t<'a, 'e> => bool = "isFailure"

// ─── Extraction ────────────────────────────────────────────────────────────

/**
Extracts the success value, or computes a fallback from the `Cause` if the `Exit` failed.

> **Note** `Exit.toOption` does not exist in Effect v3. Use `getOrElse` instead.

**Example**
```rescript
exit->Exit.getOrElse(cause => {
  Console.error(cause->Cause.pretty)
  defaultValue
})
```
*/
@module("effect") @scope("Exit")
external getOrElse: (t<'a, 'e>, Cause.t<'e> => 'a) => 'a = "getOrElse"

/**
Returns `Some(cause)` if the `Exit` is a failure, or `None` if it succeeded.

Useful for inspecting the cause without pattern matching the full `Exit` structure.
*/
@module("effect") @scope("Exit")
external causeOption: t<'a, 'e> => option<Cause.t<'e>> = "causeOption"

// ─── Transformation ────────────────────────────────────────────────────────

/** Transforms the success value with a pure function, leaving failures unchanged. */
@module("effect") @scope("Exit")
external map: (t<'a, 'e>, 'a => 'b) => t<'b, 'e> = "map"

/** Chains `Exit`s — applies `f` to the success value, which returns the next `Exit`. */
@module("effect") @scope("Exit")
external flatMap: (t<'a, 'e>, 'a => t<'b, 'e>) => t<'b, 'e> = "flatMap"
