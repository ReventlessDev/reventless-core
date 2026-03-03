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
*/
@module("effect") @scope("Exit")
external _causeOption: t<'a, 'e> => EffectOption.t<Cause.t<'e>> = "causeOption"
let causeOption = exit => exit->_causeOption->EffectOption.toOption

// ─── Transformation ────────────────────────────────────────────────────────

/** Transforms the success value with a pure function, leaving failures unchanged. */
@module("effect") @scope("Exit")
external map: (t<'a, 'e>, 'a => 'b) => t<'b, 'e> = "map"

/** Chains `Exit`s — applies `f` to the success value, which returns the next `Exit`. */
@module("effect") @scope("Exit")
external flatMap: (t<'a, 'e>, 'a => t<'b, 'e>) => t<'b, 'e> = "flatMap"

// ─── Pattern matching ───────────────────────────────────────────────────────

@module("effect") @scope("Exit")
external _matchRaw: (t<'a, 'e>, {"onFailure": Cause.t<'e> => 'b, "onSuccess": 'a => 'b}) => 'b =
  "match"

/**
Pattern-matches an `Exit`, running `onFailure` for a failed exit or `onSuccess` for a
successful one.

**Example**
```rescript
exit->Exit.match(
  ~onFailure=cause => "failed: " ++ cause->Cause.pretty,
  ~onSuccess=value => "succeeded: " ++ value->Int.toString,
)
```
*/
let match = (exit, ~onFailure, ~onSuccess) =>
  _matchRaw(exit, {"onFailure": onFailure, "onSuccess": onSuccess})
