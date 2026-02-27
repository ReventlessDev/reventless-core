// ReScript bindings for Effect Schedule
//
// Schedule<Out, In, R> — a composable policy that controls recurrence timing.
//   'out  = value produced on each recurrence (e.g. Duration.t for exponential)
//   'in_  = input consumed (error value for retry, success value for repeat)
//   'r    = requirements
//
// Transparent alias of Effect.schedule — passes cleanly to Effect.retry / Effect.repeat.

type t<'out, 'in_, 'r> = Effect.schedule<'out, 'in_, 'r>

// ─── Built-in schedules ──────────────────────────────────────────────────

// Exponential backoff: base, base*2, base*4, ...
@module("effect") @scope("Schedule")
external exponential: Duration.t => t<Duration.t, 'in_, 'r> = "exponential"

// Fixed interval between completions
@module("effect") @scope("Schedule")
external fixed: Duration.t => t<int, 'in_, 'r> = "fixed"

// Fixed delay between completions (measured from completion time)
@module("effect") @scope("Schedule")
external spaced: Duration.t => t<int, 'in_, 'r> = "spaced"

// Exactly N recurrences then stop
@module("effect") @scope("Schedule")
external recurs: int => t<int, 'in_, 'r> = "recurs"

// Recur exactly once
@module("effect") @scope("Schedule")
external once: t<int, 'in_, 'r> = "once"

// Repeat forever, producing a count
@module("effect") @scope("Schedule")
external forever: t<int, 'in_, 'r> = "forever"

// Track elapsed time as the output value
@module("effect") @scope("Schedule")
external elapsed: t<Duration.t, 'in_, 'r> = "elapsed"

// ─── Composition ─────────────────────────────────────────────────────────

// Add random jitter to interval durations (prevents thundering herd)
@module("effect") @scope("Schedule")
external jittered: t<'out, 'in_, 'r> => t<'out, 'in_, 'r> = "jittered"

// Only continue while the input predicate holds (e.g. error is transient)
@module("effect") @scope("Schedule")
external whileInput: (t<'out, 'in_, 'r>, 'in_ => bool) => t<'out, 'in_, 'r> = "whileInput"

// Only continue while the output predicate holds (e.g. total elapsed < 1 minute)
@module("effect") @scope("Schedule")
external whileOutput: (t<'out, 'in_, 'r>, 'out => bool) => t<'out, 'in_, 'r> = "whileOutput"

// Feed the output of one schedule as input to another
@module("effect") @scope("Schedule")
external compose: (t<'out, 'in_, 'r>, t<'out2, 'out, 'r>) => t<'out2, 'in_, 'r> = "compose"

// Run both schedules, use the longer delay of the two
@module("effect") @scope("Schedule")
external union: (t<'out, 'in_, 'r>, t<'out2, 'in_, 'r>) => t<('out, 'out2), 'in_, 'r> = "union"

// Run both schedules, stop when either stops
@module("effect") @scope("Schedule")
external intersect: (t<'out, 'in_, 'r>, t<'out2, 'in_, 'r>) => t<('out, 'out2), 'in_, 'r> = "intersect"
