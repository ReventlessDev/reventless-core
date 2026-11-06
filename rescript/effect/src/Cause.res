/**
ReScript bindings for `Cause<E>` — everything that made an `Effect` fail.

A `Cause` is a flat list of reasons, each one of:
- *Typed failures* (`Fail`) — expected errors in the `'e` channel
- *Defects* (`Die`) — unexpected thrown exceptions
- *Interruptions* (`Interrupt`) — fiber cancellation

Two fibers failing at once leave two reasons; neither is discarded.

You encounter `Cause` when inspecting `Exit.t` or using `Effect.runPromiseExit`.
*/
type t<'e>

/** One reason in a `Cause`. */
@tag("_tag")
type reason<'e> =
  | Fail({error: 'e})
  | Die({defect: unknown})
  | Interrupt({fiberId?: int})

// ─── Constructors ──────────────────────────────────────────────────────────

/** Creates a `Cause` representing a typed, expected failure in the `'e` channel. */
@module("effect/Cause")
external fail: 'e => t<'e> = "fail"

/** Creates a `Cause` representing an unexpected exception or defect (not a typed error). */
@module("effect/Cause")
external die: 'defect => t<'e> = "die"

/** Combines two causes into one holding the reasons of both. */
@module("effect/Cause")
external combine: (t<'e>, t<'e>) => t<'e> = "combine"

// ─── Reading ───────────────────────────────────────────────────────────────

/** The reasons, in the order they occurred. */
@get
external reasons: t<'e> => array<reason<'e>> = "reasons"

/** Returns `true` if the cause holds at least one typed failure. */
@module("effect/Cause")
external hasFails: t<'e> => bool = "hasFails"

/** Returns `true` if the cause holds at least one defect. */
@module("effect/Cause")
external hasDies: t<'e> => bool = "hasDies"

/** Returns `true` if the cause holds at least one interruption. */
@module("effect/Cause")
external hasInterrupts: t<'e> => bool = "hasInterrupts"

/** Returns a human-readable rendering of every reason, useful for logging. */
@module("effect/Cause")
external pretty: t<'e> => string = "pretty"

/** One `Error` per reason, each with the reason's message and an error's own `name`. */
@module("effect/Cause")
external prettyErrors: t<'e> => array<JsError.t> = "prettyErrors"

/**
The cause as one `Error` to throw: a typed failure becomes an `Error` whose message
renders it, and a thrown error keeps its message and `name`.
*/
let toError = (cause: t<'e>): JsError.t =>
  switch cause->prettyErrors->Array.get(0) {
  | Some(first) => first
  | None => JsError.make(cause->pretty)
  }
