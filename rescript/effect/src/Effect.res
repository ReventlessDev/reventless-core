// ─── Forward-declared abstract types ─────────────────────────────────────
// Defined here to break circular dependencies. Each has a corresponding
// module that re-exports as a transparent type alias:
//   Fiber.res    → type t<'a,'e> = Effect.fiber<'a,'e>
//   Latch.res    → type t       = Effect.latch
//   Schedule.res → type t<'o,'i,'r> = Effect.schedule<'o,'i,'r>

/**
ReScript bindings for `Effect<A, E, R>` — the core type of the Effect library.

The three type parameters represent:
- `'a` — the success value
- `'e` — typed expected errors (recoverable failures)
- `'r` — requirements / dependencies (use `unit` for none)

Effects are **lazy and referentially transparent**: they describe a computation
without executing it. Run with `Effect.runPromise` (async) or `Effect.runSync`
(sync, throws on failure).

**Quick start**
```rescript
Effect.succeed(42)
->Effect.map(n => n * 2)
->Effect.runSync
// 84
```
*/
/** Opaque fiber handle — see `Fiber` module for join, interrupt, and collect operations. */
type fiber<'a, 'e>

/** Opaque latch handle — see `Latch` module. Create via `Effect.makeLatch`. */
type latch

/** Opaque schedule handle — see `Schedule` module for built-in schedules and combinators. */
type schedule<'out, 'in_, 'r>

// ─── Core type ────────────────────────────────────────────────────────────

/** The core Effect type: `t<'a, 'e, 'r>` where `'a` is the success value, `'e` is the typed error, and `'r` is the requirements channel. */
type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

/** Creates an `Effect` that always succeeds with `value`. Lifts a pure value into the Effect world. */
@module("effect/Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

/** Creates an `Effect` that always fails with the given typed error in the `'e` channel. */
@module("effect/Effect")
external fail: 'e => t<'a, 'e, 'r> = "fail"

/**
Wraps a synchronous computation in an `Effect`.

Exceptions thrown by `f` become *defects* — they bypass the typed `'e` channel and
are not catchable with `catchAll`. Use `tryPromise` (with a synchronous promise) if
you need to catch synchronous exceptions as typed errors.
*/
@module("effect/Effect")
external sync: (unit => 'a) => t<'a, 'e, 'r> = "sync"

/**
Wraps a `Promise`-returning thunk in an `Effect`.

Rejected promises become *defects* — they bypass the typed `'e` channel.
Use `tryPromise` if you want to map exceptions to typed errors.
*/
@module("effect/Effect")
external promise: (unit => promise<'a>) => t<'a, 'e, 'r> = "promise"

@module("effect/Effect")
external _tryPromiseRaw: {"try": unit => promise<'a>, "catch": unknown => 'e} => t<'a, 'e, 'r> =
  "tryPromise"

/**
Wraps a `Promise`-returning thunk, mapping thrown exceptions to typed errors.

- `~catch`: maps the caught `unknown` exception to a value of type `'e`.
- `f`: the thunk that produces the `Promise`.

**Example**
```rescript
Effect.tryPromise(
  ~catch=exn => NetworkError(exn->JsExn.fromException->Option.flatMap(JsExn.message)),
  () => fetch("/api/data")->Promise.then(r => r->Response.json),
)
```

> **Note** Exceptions thrown inside the `~catch` mapper itself become defects.
*/
let tryPromise = (~catch as onError: unknown => 'e, f: unit => promise<'a>): t<'a, 'e, 'r> =>
  _tryPromiseRaw({"try": f, "catch": onError})

@module("effect/Effect")
external _trySyncRaw: {"try": unit => 'a, "catch": unknown => 'e} => t<'a, 'e, 'r> = "try"

/**
Wraps a synchronous computation that may throw into a typed `Effect`.

- `~catch`: maps the caught exception (typed as `unknown`) to a typed error.
- `f`: the synchronous computation.

**Example**
```rescript
Effect.trySync(~catch=_exn => "parse error", () => JSON.parseOrThrow(input))
```
*/
let trySync = (~catch as onError: unknown => 'e, f: unit => 'a): t<'a, 'e, 'r> =>
  _trySyncRaw({"try": f, "catch": onError})

/** An `Effect` that never succeeds or fails — it suspends the current fiber forever. */
@module("effect/Effect")
external never: t<'a, 'e, 'r> = "never"

// ─── Transformation ──────────────────────────────────────────────────────

/** Transforms the success value with a pure function, leaving errors unchanged. */
@module("effect/Effect")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

/**
Chains `Effect`s — runs the first and passes its success value to `f`,
which returns the next `Effect` to run.

**Example**
```rescript
fetchUser(id)->Effect.flatMap(user => saveUser(user))
```
*/
@module("effect/Effect")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

/**
Runs `f` for its side effect on each success value, then passes the original value
through unchanged. Useful for logging or metrics without altering the pipeline.
*/
@module("effect/Effect")
external tap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

/**
Sequences two `Effect`s and returns the result of the second, discarding the first's value.

> **Note** Effect 4 calls this `andThen` (given an `Effect`, not a function).
*/
@module("effect/Effect")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "andThen"

// ─── Error handling ──────────────────────────────────────────────────────

/**
Recovers from any typed error by running `f` to produce a new `Effect`.

Only catches errors in the `'e` channel; defects (unexpected exceptions) are
not caught and propagate as unrecoverable failures.

> **Note** Effect 4 calls this `catch`, a reserved word in ReScript.
*/
@module("effect/Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catch"

/**
Recovers from a specific tagged error variant identified by its `_tag` field.

Leaves all other error variants in the `'e` channel unhandled.

**Example**
```rescript
effect->Effect.catchTag("StaleState", ({id}) => retryWithFreshState(id))
```
*/
@module("effect/Effect")
external catchTag: (t<'a, 'e, 'r>, string, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchTag"

/**
Converts the `Effect` to always succeed with `option<'a>`:
`Some(value)` on success, `None` on typed error.

Defects still propagate as failures.
*/
@module("effect/Effect")
external _option: t<'a, 'e, 'r> => t<EffectOption.t<'a>, 'e2, 'r> = "option"
let option = effect => effect->_option->map(EffectOption.toOption)

// ─── Retry / repeat ──────────────────────────────────────────────────────

/**
Retries a failing `Effect` according to the given `Schedule`.

The `Schedule` receives each failure value and decides whether — and after
how long — to retry. When the `Schedule` stops, the most recent failure is returned.

**Example**
```rescript
// Up to 5 retries with exponential backoff and jitter
Effect.tryPromise(~catch=classifyError, fetchData)
->Effect.retry(
  Schedule.exponential(Duration.millis(200))
  ->Schedule.jittered
  ->Schedule.recurs(5),
)
```

> **Note** `Schedule.recurs(n)` adds n retries — total attempts = n + 1.
*/
@module("effect/Effect")
external retry: (t<'a, 'e, 'r>, schedule<'out, 'e, 'r>) => t<'a, 'e, 'r> = "retry"

/**
Repeats a successful `Effect` according to the given `Schedule`.

The `Schedule` receives each success value and decides whether — and after
how long — to run again. The final output of the `Schedule` is returned.
*/
@module("effect/Effect")
external repeat: (t<'a, 'e, 'r>, schedule<'out, 'a, 'r>) => t<'out, 'e, 'r> = "repeat"

// ─── Concurrency ─────────────────────────────────────────────────────────

/**
Forks the `Effect` into a child fiber that runs concurrently with the calling fiber.

The child is interrupted when its parent fiber ends. Use `forkScoped` to tie its
lifetime to the current scope instead.

> **Note** Effect 4 calls this `forkChild`.
*/
@module("effect/Effect")
external fork: t<'a, 'e, 'r> => t<fiber<'a, 'e>, 'e2, 'r> = "forkChild"

/**
Forks the `Effect` into a new fiber, tying its lifetime to the current scope.

When the enclosing scope closes (e.g. when `Effect.scoped` finishes), the fiber
is automatically interrupted and its finalizers are run.
*/
@module("effect/Effect")
external forkScoped: t<'a, 'e, 'r> => t<fiber<'a, 'e>, 'e2, 'r> = "forkScoped"

/**
Runs all effects concurrently and collects their results into an array.

The `concurrency` option controls the maximum number of simultaneously running fibers:
- `"unbounded"` — all effects start immediately
- `"inherit"` — respects the ambient concurrency limit
- an `int` — maximum number of concurrent fibers (e.g. `{"concurrency": 3}`)

**Example**
```rescript
Effect.all(handlers->Array.map(h => h(event)), {"concurrency": "unbounded"})
Effect.all(effects, {"concurrency": 3})  // at most 3 concurrent
```
*/
@module("effect/Effect")
external all: (array<t<'a, 'e, 'r>>, {"concurrency": 'concurrency}) => t<array<'a>, 'e, 'r> = "all"

/**
Races two effects — the first to succeed wins and its value is returned.
The losing effect is interrupted immediately.
*/
@module("effect/Effect")
external race: (t<'a, 'e, 'r>, t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "race"

// ─── Resource management ─────────────────────────────────────────────────

/**
Registers a finalizer that always runs after `effect` completes — whether by
success, failure, or interruption.

Unlike `acquireRelease`, the finalizer receives no outcome value. Use when you
need unconditional cleanup without inspecting the exit status.

**Example**
```rescript
Stream.runForEach(stream, item => Queue.offer(queue, item)->Effect.map(_ => ()))
->Effect.ensuring(Queue.offer(queue, None)->Effect.map(_ => ()))
```
*/
@module("effect/Effect")
external ensuring: (t<'a, 'e, 'r>, t<unit, 'e2, 'r>) => t<'a, 'e, 'r> = "ensuring"

/**
Acquires a resource and guarantees its release even on failure or interruption.

The `release` function receives the `Exit` status of the use, so it can
distinguish clean completion from failure when releasing.

**Example**
```rescript
Effect.acquireRelease(
  openConnection(),
  (conn, _exit) => closeConnection(conn),
)
```
*/
@module("effect/Effect")
external acquireRelease: (
  t<'a, 'e, 'r>,
  ('a, Exit.t<'b, 'e2>) => t<unit, 'e3, 'r>,
) => t<'a, 'e, 'r> = "acquireRelease"

/**
Opens a new `Scope` and runs the `Effect` within it.

All finalizers registered via `acquireRelease` or `forkScoped` inside the
scope are run when `scoped` completes (success, failure, or interruption).
*/
@module("effect/Effect")
external scoped: t<'a, 'e, 'r> => t<'a, 'e, 'r2> = "scoped"

// ─── Synchronization primitives ──────────────────────────────────────────

/**
Creates a `Latch` — a binary synchronization gate.

Pass `true` to start open (fibers pass through immediately),
`false` to start closed (fibers block until `latch.open_` is called).

See the `Latch` module for `await_`, `open_`, and `close` operations.
*/
@module("effect/Latch")
external makeLatch: bool => t<latch, 'e, 'r> = "make"

/**
Runs `effect` as one transaction over `TxRef`s: its writes become visible only
if it succeeds, and a failure discards them all.
*/
@module("effect/Effect")
external tx: t<'a, 'e, 'r> => t<'a, 'e, 'r> = "tx"

// ─── Timing ──────────────────────────────────────────────────────────────

/**
Suspends the current fiber for the given `Duration`.

In tests, use `TestClock.adjust` to advance virtual time instead of waiting
for real time to pass.
*/
@module("effect/Effect")
external sleep: Duration.t => t<unit, 'e, 'r> = "sleep"

/**
Aborts the `Effect` if it does not complete within `duration`.

Returns `Some(value)` if the effect completes in time, `None` if it times out.
The timed-out effect is interrupted.
*/
@module("effect/Effect")
external _timeoutOption: (t<'a, 'e, 'r>, Duration.t) => t<EffectOption.t<'a>, 'e, 'r> =
  "timeoutOption"
let timeout = (effect, duration) => effect->_timeoutOption(duration)->map(EffectOption.toOption)

// ─── Repetition ──────────────────────────────────────────────────────────

/**
Repeats the `Effect` forever — runs, then immediately runs again, indefinitely.

Useful for drain loops: combine with `Queue.take` to process items as they arrive.
When the underlying resource (e.g. a `Queue`) is shut down, the interruption
propagates out and ends the loop cleanly.

**Example**
```rescript
Queue.take(q)
->Effect.flatMap(processItem)
->Effect.forever
->Effect.fork
```
*/
@module("effect/Effect")
external forever: t<'a, 'e, 'r> => t<'b, 'e, 'r> = "forever"

// ─── Dependency injection ─────────────────────────────────────────────────

/**
Provides a `Layer` to satisfy an `Effect`'s requirements (`'r` channel).

After providing a layer that covers all requirements, the returned `Effect`
has `unit` requirements and can be run with `runPromise` or `runSync`.
The `'layer` type is polymorphic — pass any `TestContext.layer` or custom `Layer`.
*/
@module("effect/Effect")
external provide: (t<'a, 'e, 'r>, 'layer) => t<'a, 'e, unit> = "provide"

/**
Reads a service from the context and maps it to a pure value.

The `'r` channel of the returned effect is set to `'service` (the tag's phantom type),
requiring that service to be provided before the effect can run.

**Example**
```rescript
let logInfo = (msg: string) =>
  Effect.serviceWith(Logger.tag, logger => logger.info(msg))
```
*/
@module("effect/Effect")
external service: Context.tag<'service> => t<'service, 'e, 'service> = "service"

let serviceWith = (tag: Context.tag<'service>, f: 'service => 'b): t<'b, 'e, 'service> =>
  tag->service->map(f)

/**
Like `serviceWith`, but the mapping function returns an `Effect`.

Avoids an extra `flatMap` at the call site when the service method is itself effectful.

**Example**
```rescript
let logInfo = (msg: string) =>
  Effect.serviceWithEffect(Logger.tag, logger => logger.info(msg))
```
*/
let serviceWithEffect = (tag: Context.tag<'service>, f: 'service => t<'a, 'e, 'service>): t<
  'a,
  'e,
  'service,
> => tag->service->flatMap(f)

/**
Satisfies a single service requirement by supplying a concrete implementation.

Reduces `'r` to `unit` — all requirements are treated as satisfied.
Place at the outermost handler boundary, after all service uses are composed.

**Example**
```rescript
myEffect
->Effect.provideService(Config.tag, Config.default)
->Effect.runPromise
```
*/
@module("effect/Effect")
external provideService: (t<'a, 'e, 'r>, Context.tag<'service>, 'service) => t<'a, 'e, unit> =
  "provideService"

// ─── Fiber control ───────────────────────────────────────────────────────

/**
Yields control to the Effect scheduler, allowing other fibers to run before continuing.

Useful in tests to ensure a forked fiber has had a chance to start, or when
implementing cooperative multitasking in a tight computation loop.
*/
@module("effect/Effect")
external yieldNowEffect: t<unit, 'e, 'r> = "yieldNow"

// Effect 4 makes `yieldNow` a value; the function keeps the call sites as they were.
let yieldNow = (): t<unit, 'e, 'r> => yieldNowEffect

// ─── Logging ──────────────────────────────────────────────────────────────

/**
Effect's built-in log functions — no service requirements.
They use the fiber's logger, configured at the layer level.
In tests, silence with `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`.
*/
@module("effect/Effect")
external logInfo: string => t<unit, 'e, 'r> = "logInfo"

@module("effect/Effect")
external logDebug: string => t<unit, 'e, 'r> = "logDebug"

@module("effect/Effect")
external logWarning: string => t<unit, 'e, 'r> = "logWarning"

@module("effect/Effect")
external logError: string => t<unit, 'e, 'r> = "logError"

/**
Attaches a structured key/value annotation to every log record produced while
the given effect runs. The annotation surfaces on `loggerOptions.annotations`
in a custom logger (see `effect/Logger`), letting a log sink promote it to a
top-level field (e.g. `correlationId`, `requestId`) instead of baking it into
the message string.
*/
@module("effect/Effect")
external annotateLogs: (t<'a, 'e, 'r>, string, string) => t<'a, 'e, 'r> = "annotateLogs"

/** A log level, by Effect's own names. */
type logLevel = [#All | #Fatal | #Error | #Warn | #Info | #Debug | #Trace | #None]

@module("effect/References")
external minimumLogLevel: Context.tag<logLevel> = "MinimumLogLevel"

@module("effect/Effect")
external _provideReference: (t<'a, 'e, 'r>, Context.tag<'v>, 'v) => t<'a, 'e, 'r> = "provideService"

/**
Runs `effect` with `level` as the minimum: a log line below it is dropped before
it reaches any logger.
*/
let withMinimumLogLevel = (effect: t<'a, 'e, 'r>, level: logLevel): t<'a, 'e, 'r> =>
  effect->_provideReference(minimumLogLevel, level)

@module("effect/References")
external currentLogAnnotations: Context.tag<dict<string>> = "CurrentLogAnnotations"

/**
The log annotations currently in scope — the counterpart of `annotateLogs`,
useful for asserting what a dispatch boundary attached without installing a
logger and capturing its output.
*/
let logAnnotations = (): t<dict<string>, 'e, dict<string>> => currentLogAnnotations->service

// ─── Running effects ─────────────────────────────────────────────────────

/**
Runs the `Effect` to completion, always resolving the `Promise` with an `Exit`.

Unlike `runPromise`, never rejects — failures are encoded in the `Exit` value.
Useful when you need to inspect whether the effect succeeded or failed.
*/
@module("effect/Effect")
external runPromiseExit: t<'a, 'e, 'r> => promise<Exit.t<'a, 'e>> = "runPromiseExit"

/**
Runs the `Effect` to completion, returning a `Promise`.

The `Promise` resolves with the success value, or rejects on typed errors and defects.
This is the main entry point for running effects at the application boundary.

> **Note** It always rejects with an `Error` (see `Cause.toError`). Effect 4's own
`runPromise` rejects with the failure value as it is, so a failure of a string
would reach a `catch` with no message.
*/
let runPromise = async (effect: t<'a, 'e, 'r>): 'a => {
  let exit = await effect->runPromiseExit
  exit->Exit.match(~onFailure=cause => cause->Cause.toError->JsError.throw, ~onSuccess=a => a)
}

/**
Runs the `Effect` synchronously, returning an `Exit` instead of throwing.

Throws if the effect performs any asynchronous operations.
*/
@module("effect/Effect")
external runSyncExit: t<'a, 'e, 'r> => Exit.t<'a, 'e> = "runSyncExit"

/**
Runs the `Effect` synchronously and returns the success value.

Throws if the effect performs any asynchronous operations (e.g. `Promise`, `sleep`).
Use for purely synchronous effects where async is not needed.

> **Note** It always throws an `Error` (see `Cause.toError`), as `runPromise` rejects with one.
*/
let runSync = (effect: t<'a, 'e, 'r>): 'a =>
  effect
  ->runSyncExit
  ->Exit.match(~onFailure=cause => cause->Cause.toError->JsError.throw, ~onSuccess=a => a)

/**
Starts the `Effect` in a new background fiber using the default runtime.

Returns the `RuntimeFiber` immediately — the effect runs concurrently.
The fiber is a *daemon* (not tied to any scope); it runs until completion,
failure, or interruption (e.g. when `Queue.shutdown` is called).
*/
@module("effect/Effect")
external runFork: t<'a, 'e, 'r> => fiber<'a, 'e> = "runFork"
