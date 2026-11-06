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
@module("effect/Schedule")
external exponential: Duration.t => t<Duration.t, 'in_, 'r> = "exponential"

/**
A schedule with a fixed interval between *starts* of consecutive runs.

If a run takes longer than the interval, the next run starts immediately.
*/
@module("effect/Schedule")
external fixed: Duration.t => t<int, 'in_, 'r> = "fixed"

/**
A schedule with a fixed delay measured from each *completion*.

Unlike `fixed`, the delay is always the full duration after the previous run finishes.
*/
@module("effect/Schedule")
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
@module("effect/Schedule")
external recurs: int => t<int, 'in_, 'r> = "recurs"

/** A schedule that recurs exactly once (two total attempts when used with `retry`). */
@module("effect/Schedule")
external once: t<unit, 'in_, 'r> = "once"

/** A schedule that repeats indefinitely, producing a monotonically increasing count. */
@module("effect/Schedule")
external forever: t<int, 'in_, 'r> = "forever"

// ─── Composition ─────────────────────────────────────────────────────────

/**
Adds random jitter to the interval durations of the given `Schedule`.

Each interval is multiplied by a random factor between `0.8` and `1.2`, distributing
retries over time and preventing thundering-herd problems after shared failures.

**Example**
```rescript
Schedule.exponential(Duration.seconds(1))->Schedule.jittered
```
*/
@module("effect/Schedule")
external jittered: t<'out, 'in_, 'r> => t<'out, 'in_, 'r> = "jittered"

// What a schedule knows at each step; `while_` decides on it.
type metadata<'out, 'in_> = {input: 'in_, output: 'out, attempt: int}

@module("effect/Schedule")
external while_: (t<'out, 'in_, 'r>, metadata<'out, 'in_> => bool) => t<'out, 'in_, 'r> = "while"

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
let whileInput = (schedule: t<'out, 'in_, 'r>, f: 'in_ => bool): t<'out, 'in_, 'r> =>
  schedule->while_(m => f(m.input))

// A ReScript pair compiles to a two-element JS array, which is what `max` takes.
@module("effect/Schedule")
external maxOfPair: ((t<'out, 'in_, 'r>, t<'out2, 'in_, 'r>)) => t<Duration.t, 'in_, 'r> = "max"

/**
Runs both schedules together: it continues only while *both* continue, and
waits the *longer* of the two delays.

> **Note** Effect 4 calls this `max`, over an array of schedules.
*/
let intersect = (first: t<'out, 'in_, 'r>, second: t<'out2, 'in_, 'r>): t<Duration.t, 'in_, 'r> =>
  maxOfPair((first, second))
