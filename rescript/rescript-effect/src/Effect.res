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

// ─── Forward-declared abstract types ─────────────────────────────────────
// Defined here to break circular dependencies. Each has a corresponding
// module that re-exports as a transparent type alias:
//   Fiber.res    → type t<'a,'e> = Effect.fiber<'a,'e>
//   Latch.res    → type t       = Effect.latch
//   Semaphore    → abstract, accessible via Effect.semaphore
//   Schedule.res → type t<'o,'i,'r> = Effect.schedule<'o,'i,'r>

/** Opaque fiber handle — see `Fiber` module for join, interrupt, and collect operations. */
type fiber<'a, 'e>

/** Opaque latch handle — see `Latch` module. Create via `Effect.makeLatch`. */
type latch

/** Opaque semaphore handle — use via `Effect.withPermits`. Create via `Effect.makeSemaphore`. */
type semaphore

/** Opaque schedule handle — see `Schedule` module for built-in schedules and combinators. */
type schedule<'out, 'in_, 'r>

// ─── Core type ────────────────────────────────────────────────────────────

/** The core Effect type: `t<'a, 'e, 'r>` where `'a` is the success value, `'e` is the typed error, and `'r` is the requirements channel. */
type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

/** Creates an `Effect` that always succeeds with `value`. Lifts a pure value into the Effect world. */
@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

/** Creates an `Effect` that always fails with the given typed error in the `'e` channel. */
@module("effect") @scope("Effect")
external fail: 'e => t<'a, 'e, 'r> = "fail"

/**
Wraps a synchronous computation in an `Effect`.

Exceptions thrown by `f` become *defects* — they bypass the typed `'e` channel and
are not catchable with `catchAll`. Use `tryPromise` (with a synchronous promise) if
you need to catch synchronous exceptions as typed errors.
*/
@module("effect") @scope("Effect")
external sync: (unit => 'a) => t<'a, 'e, 'r> = "sync"

/**
Wraps a `Promise`-returning thunk in an `Effect`.

Rejected promises become *defects* — they bypass the typed `'e` channel.
Use `tryPromise` if you want to map exceptions to typed errors.
*/
@module("effect") @scope("Effect")
external promise: (unit => promise<'a>) => t<'a, 'e, 'r> = "promise"

@module("effect") @scope("Effect")
external _tryPromiseRaw: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"

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

@module("effect") @scope("Effect")
external _trySyncRaw: {
  "try": unit => 'a,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "try"

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
@module("effect") @scope("Effect")
external never: t<'a, 'e, 'r> = "never"

// ─── Transformation ──────────────────────────────────────────────────────

/** Transforms the success value with a pure function, leaving errors unchanged. */
@module("effect") @scope("Effect")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

/**
Chains `Effect`s — runs the first and passes its success value to `f`,
which returns the next `Effect` to run.

**Example**
```rescript
fetchUser(id)->Effect.flatMap(user => saveUser(user))
```
*/
@module("effect") @scope("Effect")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

/**
Runs `f` for its side effect on each success value, then passes the original value
through unchanged. Useful for logging or metrics without altering the pipeline.
*/
@module("effect") @scope("Effect")
external tap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

/** Sequences two `Effect`s and returns the result of the second, discarding the first's value. */
@module("effect") @scope("Effect")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "zipRight"

/** Sequences two `Effect`s and returns the result of the first, discarding the second's value. */
@module("effect") @scope("Effect")
external zipLeft: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "zipLeft"

// ─── Error handling ──────────────────────────────────────────────────────

/**
Recovers from any typed error by running `f` to produce a new `Effect`.

Only catches errors in the `'e` channel; defects (unexpected exceptions) are
not caught and propagate as unrecoverable failures.
*/
@module("effect") @scope("Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"

/**
Recovers from a specific tagged error variant identified by its `_tag` field.

Leaves all other error variants in the `'e` channel unhandled.

**Example**
```rescript
effect->Effect.catchTag("StaleState", ({id}) => retryWithFreshState(id))
```
*/
@module("effect") @scope("Effect")
external catchTag: (t<'a, 'e, 'r>, string, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchTag"

/**
Converts success to `Ok` and typed errors to `Error` — the resulting `Effect`
always succeeds with a `result<'a, 'e>`.

> **Note** Effect uses `Either<E, A>` internally, but `result<'a, 'e>` is
structurally compatible with `{_tag: "Left"/"Right"}`.
*/
@module("effect") @scope("Effect")
external either: t<'a, 'e, 'r> => t<result<'a, 'e>, 'e2, 'r> = "either"

/**
Converts the `Effect` to always succeed with `option<'a>`:
`Some(value)` on success, `None` on typed error.

Defects still propagate as failures.
*/
@module("effect") @scope("Effect")
external option: t<'a, 'e, 'r> => t<option<'a>, 'e2, 'r> = "option"

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
@module("effect") @scope("Effect")
external retry: (t<'a, 'e, 'r>, schedule<'out, 'e, 'r>) => t<'a, 'e, 'r> = "retry"

/**
Repeats a successful `Effect` according to the given `Schedule`.

The `Schedule` receives each success value and decides whether — and after
how long — to run again. The final output of the `Schedule` is returned.
*/
@module("effect") @scope("Effect")
external repeat: (t<'a, 'e, 'r>, schedule<'out, 'a, 'r>) => t<'out, 'e, 'r> = "repeat"

// ─── Concurrency ─────────────────────────────────────────────────────────

/**
Forks the `Effect` into a new fiber that runs concurrently with the calling fiber.

The forked fiber is a *daemon* — it is not automatically interrupted when the
parent scope ends. Use `forkScoped` to tie the fiber's lifetime to the current scope.
*/
@module("effect") @scope("Effect")
external fork: t<'a, 'e, 'r> => t<fiber<'a, 'e>, 'e2, 'r> = "fork"

/**
Forks the `Effect` into a new fiber, tying its lifetime to the current scope.

When the enclosing scope closes (e.g. when `Effect.scoped` finishes), the fiber
is automatically interrupted and its finalizers are run.
*/
@module("effect") @scope("Effect")
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
@module("effect") @scope("Effect")
external all: (array<t<'a, 'e, 'r>>, {. "concurrency": 'concurrency}) => t<array<'a>, 'e, 'r> = "all"

/**
Races two effects — the first to succeed wins and its value is returned.
The losing effect is interrupted immediately.
*/
@module("effect") @scope("Effect")
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
@module("effect") @scope("Effect")
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
@module("effect") @scope("Effect")
external acquireRelease: (t<'a, 'e, 'r>, ('a, Exit.t<'b, 'e2>) => t<unit, 'e3, 'r>) => t<'a, 'e, 'r> = "acquireRelease"

/**
Opens a new `Scope` and runs the `Effect` within it.

All finalizers registered via `acquireRelease` or `forkScoped` inside the
scope are run when `scoped` completes (success, failure, or interruption).
*/
@module("effect") @scope("Effect")
external scoped: t<'a, 'e, 'r> => t<'a, 'e, 'r2> = "scoped"

// ─── Synchronization primitives ──────────────────────────────────────────

/**
Creates a `Latch` — a binary synchronization gate.

Pass `true` to start open (fibers pass through immediately),
`false` to start closed (fibers block until `latch.open_` is called).

See the `Latch` module for `await_`, `open_`, and `close` operations.
*/
@module("effect") @scope("Effect")
external makeLatch: bool => t<latch, 'e, 'r> = "makeLatch"

/**
Creates a `Semaphore` with `n` permits — a generalized mutex.

Use `Effect.withPermits(sem, n, effect)` to run `effect` while holding `n` permits.
Fibers that request more permits than available will block until permits are released.
*/
@module("effect") @scope("Effect")
external makeSemaphore: int => t<semaphore, 'e, 'r> = "makeSemaphore"

/** Runs `effect` while holding `n` permits from `semaphore`. Blocks if insufficient permits are available. */
@module("effect") @scope("Effect")
external withPermits: (semaphore, int, t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "withPermits"

// ─── Timing ──────────────────────────────────────────────────────────────

/**
Suspends the current fiber for the given `Duration`.

In tests, use `TestClock.adjust` to advance virtual time instead of waiting
for real time to pass.
*/
@module("effect") @scope("Effect")
external sleep: Duration.t => t<unit, 'e, 'r> = "sleep"

/**
Aborts the `Effect` if it does not complete within `duration`.

Returns `Some(value)` if the effect completes in time, `None` if it times out.
The timed-out effect is interrupted.
*/
@module("effect") @scope("Effect")
external timeout: (t<'a, 'e, 'r>, Duration.t) => t<option<'a>, 'e, 'r> = "timeout"

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
@module("effect") @scope("Effect")
external forever: t<'a, 'e, 'r> => t<'b, 'e, 'r> = "forever"

// ─── Dependency injection ─────────────────────────────────────────────────

/**
Provides a `Layer` to satisfy an `Effect`'s requirements (`'r` channel).

After providing a layer that covers all requirements, the returned `Effect`
has `unit` requirements and can be run with `runPromise` or `runSync`.
The `'layer` type is polymorphic — pass any `TestContext.layer` or custom `Layer`.
*/
@module("effect") @scope("Effect")
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
@module("effect") @scope("Effect")
external serviceWith: (Context.tag<'service>, 'service => 'b) => t<'b, 'e, 'service> =
  "serviceWith"

/**
Like `serviceWith`, but the mapping function returns an `Effect`.

Avoids an extra `flatMap` at the call site when the service method is itself effectful.

**Example**
```rescript
let logInfo = (msg: string) =>
  Effect.serviceWithEffect(Logger.tag, logger => logger.info(msg))
```
*/
@module("effect") @scope("Effect")
external serviceWithEffect: (
  Context.tag<'service>,
  'service => t<'a, 'e, 'service>,
) => t<'a, 'e, 'service> = "serviceWithEffect"

/**
Satisfies a single service requirement by supplying a concrete implementation.

Reduces `'r` to `unit` — all requirements are treated as satisfied.
Place at the outermost handler boundary, after all service uses are composed.

**Example**
```rescript
myEffect
->Effect.provideService(Logger.tag, Logger.consoleLogger)
->Effect.runPromise
```
*/
@module("effect") @scope("Effect")
external provideService: (t<'a, 'e, 'r>, Context.tag<'service>, 'service) => t<'a, 'e, unit> =
  "provideService"

// ─── Fiber control ───────────────────────────────────────────────────────

/**
Yields control to the Effect scheduler, allowing other fibers to run before continuing.

Useful in tests to ensure a forked fiber has had a chance to start, or when
implementing cooperative multitasking in a tight computation loop.
*/
@module("effect") @scope("Effect")
external yieldNow: unit => t<unit, 'e, 'r> = "yieldNow"

// ─── Running effects ─────────────────────────────────────────────────────

/**
Runs the `Effect` to completion, returning a `Promise`.

The `Promise` resolves with the success value, or rejects on typed errors and defects.
This is the main entry point for running effects at the application boundary.
*/
@module("effect") @scope("Effect")
external runPromise: t<'a, 'e, 'r> => promise<'a> = "runPromise"

/**
Runs the `Effect` to completion, always resolving the `Promise` with an `Exit`.

Unlike `runPromise`, never rejects — failures are encoded in the `Exit` value.
Useful when you need to inspect whether the effect succeeded or failed.
*/
@module("effect") @scope("Effect")
external runPromiseExit: t<'a, 'e, 'r> => promise<Exit.t<'a, 'e>> = "runPromiseExit"

/**
Runs the `Effect` synchronously and returns the success value.

Throws if the effect performs any asynchronous operations (e.g. `Promise`, `sleep`).
Use for purely synchronous effects where async is not needed.
*/
@module("effect") @scope("Effect")
external runSync: t<'a, 'e, 'r> => 'a = "runSync"

/**
Runs the `Effect` synchronously, returning an `Exit` instead of throwing.

Throws if the effect performs any asynchronous operations.
*/
@module("effect") @scope("Effect")
external runSyncExit: t<'a, 'e, 'r> => Exit.t<'a, 'e> = "runSyncExit"

/**
Starts the `Effect` in a new background fiber using the default runtime.

Returns the `RuntimeFiber` immediately — the effect runs concurrently.
The fiber is a *daemon* (not tied to any scope); it runs until completion,
failure, or interruption (e.g. when `Queue.shutdown` is called).
*/
@module("effect") @scope("Effect")
external runFork: t<'a, 'e, 'r> => fiber<'a, 'e> = "runFork"
