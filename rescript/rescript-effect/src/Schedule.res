/**
ReScript bindings for `Schedule<Out, In, R>` — a composable recurrence policy.

The three type parameters:
- `'out` — value produced on each recurrence (e.g. `Duration.t` for `exponential`)
- `'in_` — input consumed (error value for `retry`, success value for `repeat`)
- `'r`   — requirements

`Schedule.t` is a transparent alias of `Effect.schedule` — values pass cleanly
to `Effect.retry` and `Effect.repeat` without casting.
*/
type t<'out, 'in_, 'r> = Effect.schedule<'out, 'in_, 'r>

// ─── Built-in schedules ──────────────────────────────────────────────────

/**
Exponential backoff: `base`, `2×base`, `4×base`, …

Pair with `Schedule.jittered` and `Schedule.recurs` to build a production
retry policy with random variance and a retry cap.

**Example**
```rescript
Schedule.exponential(Duration.millis(100))
->Schedule.jittered
->Schedule.recurs(5)
```
*/
@module("effect") @scope("Schedule")
external exponential: Duration.t => t<Duration.t, 'in_, 'r> = "exponential"

/**
A schedule with a fixed interval between *starts* of consecutive runs.

If a run takes longer than the interval, the next run starts immediately.
*/
@module("effect") @scope("Schedule")
external fixed: Duration.t => t<int, 'in_, 'r> = "fixed"

/**
A schedule with a fixed delay measured from each *completion*.

Unlike `fixed`, the delay is always the full duration after the previous run finishes.
*/
@module("effect") @scope("Schedule")
external spaced: Duration.t => t<int, 'in_, 'r> = "spaced"

/**
Limits the schedule to exactly `n` additional recurrences.

> **Note** `recurs(n)` adds **n recurrences** after the first attempt —
total attempts = n + 1.

**Example**
```rescript
Schedule.exponential(Duration.millis(200))->Schedule.recurs(4)
// up to 5 total attempts
```
*/
@module("effect") @scope("Schedule")
external recurs: int => t<int, 'in_, 'r> = "recurs"

/** A schedule that recurs exactly once (two total attempts when used with `retry`). */
@module("effect") @scope("Schedule")
external once: t<int, 'in_, 'r> = "once"

/** A schedule that repeats indefinitely, producing a monotonically increasing count. */
@module("effect") @scope("Schedule")
external forever: t<int, 'in_, 'r> = "forever"

/** A schedule that tracks the total elapsed time as its output value. */
@module("effect") @scope("Schedule")
external elapsed: t<Duration.t, 'in_, 'r> = "elapsed"

// ─── Composition ─────────────────────────────────────────────────────────

/**
Adds random jitter to the interval durations of the given `Schedule`.

Each interval is multiplied by a random factor in `[0.0, 1.0)`, distributing
retries over time and preventing thundering-herd problems after shared failures.

**Example**
```rescript
Schedule.exponential(Duration.seconds(1))->Schedule.jittered
```
*/
@module("effect") @scope("Schedule")
external jittered: t<'out, 'in_, 'r> => t<'out, 'in_, 'r> = "jittered"

/**
Continues the schedule only while the input predicate returns `true`.

Use with `Effect.retry` to skip retrying on non-transient errors:

**Example**
```rescript
Schedule.exponential(Duration.millis(500))
->Schedule.recurs(5)
->Schedule.whileInput(err => err != StaleState)
```
*/
@module("effect") @scope("Schedule")
external whileInput: (t<'out, 'in_, 'r>, 'in_ => bool) => t<'out, 'in_, 'r> = "whileInput"

/**
Continues the schedule only while the output predicate returns `true`.

Useful for capping by total elapsed time rather than a fixed count:

**Example**
```rescript
// Retry for up to 30 seconds of total elapsed time
Schedule.exponential(Duration.millis(100))
->Schedule.whileOutput(elapsed => elapsed < Duration.seconds(30))
```
*/
@module("effect") @scope("Schedule")
external whileOutput: (t<'out, 'in_, 'r>, 'out => bool) => t<'out, 'in_, 'r> = "whileOutput"

/**
Feeds the output of `first` as input to `second` — pipelines two schedules.

Useful for building multi-stage recurrence strategies.
*/
@module("effect") @scope("Schedule")
external compose: (t<'out, 'in_, 'r>, t<'out2, 'out, 'r>) => t<'out2, 'in_, 'r> = "compose"

/**
Runs both schedules in parallel, using the *longer* delay of the two.

The combined schedule continues as long as *both* constituent schedules continue.
*/
@module("effect") @scope("Schedule")
external union: (t<'out, 'in_, 'r>, t<'out2, 'in_, 'r>) => t<('out, 'out2), 'in_, 'r> = "union"

/**
Runs both schedules in parallel, using the *shorter* delay of the two.

The combined schedule stops as soon as *either* constituent schedule stops.
*/
@module("effect") @scope("Schedule")
external intersect: (t<'out, 'in_, 'r>, t<'out2, 'in_, 'r>) => t<('out, 'out2), 'in_, 'r> = "intersect"
