// ReScript bindings for Effect core
//
// Effect<A, E, R> — the three-channel type:
//   'a = success value
//   'e = typed error channel (expected, recoverable failures)
//   'r = requirements channel (dependencies needed to run — use unit for none)
//
// Effects are lazy and referentially transparent. They describe a computation
// but do not execute until run via runPromise / runSync.
//
// ─── Forward-declared abstract types ─────────────────────────────────────
// Defined here to break circular dependencies. Each has a corresponding
// module that re-exports as a transparent type alias:
//   Fiber.res    → type t<'a,'e> = Effect.fiber<'a,'e>
//   Latch.res    → type t       = Effect.latch
//   Semaphore    → abstract, accessible via Effect.semaphore
//   Schedule.res → type t<'o,'i,'r> = Effect.schedule<'o,'i,'r>

type fiber<'a, 'e>
type latch
type semaphore
type schedule<'out, 'in_, 'r>

// ─── Core type ────────────────────────────────────────────────────────────

type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

// An effect that always succeeds with the given value
@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

// An effect that always fails with the given typed error
@module("effect") @scope("Effect")
external fail: 'e => t<'a, 'e, 'r> = "fail"

// Wrap a synchronous computation. Thrown exceptions become defects (not
// typed errors — they bypass the 'e channel).
@module("effect") @scope("Effect")
external sync: (unit => 'a) => t<'a, 'e, 'r> = "sync"

// Wrap a Promise. Thrown exceptions become defects.
@module("effect") @scope("Effect")
external promise: (unit => promise<'a>) => t<'a, 'e, 'r> = "promise"

// Wrap a Promise, mapping thrown exceptions to typed errors.
@module("effect") @scope("Effect")
external tryPromise: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"

// An effect that never succeeds or fails (blocks forever)
@module("effect") @scope("Effect")
external never: t<'a, 'e, 'r> = "never"

// ─── Transformation ──────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("Effect")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

// Execute a side-effecting effect for its result, return the original value
@module("effect") @scope("Effect")
external tap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// Sequence two effects, discarding the first's result
@module("effect") @scope("Effect")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "zipRight"

// Sequence two effects, discarding the second's result
@module("effect") @scope("Effect")
external zipLeft: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "zipLeft"

// ─── Error handling ──────────────────────────────────────────────────────

// Recover from any typed error
@module("effect") @scope("Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"

// Recover from a specific tagged error by its _tag field value
@module("effect") @scope("Effect")
external catchTag: (t<'a, 'e, 'r>, string, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchTag"

// Wrap in result — effect never fails; errors are Right(error), success is Left(value)
// Note: Effect uses Either<E, A> but result<'a, 'e> is structurally compatible
@module("effect") @scope("Effect")
external either: t<'a, 'e, 'r> => t<result<'a, 'e>, 'e2, 'r> = "either"

// Wrap in option — maps success to Some, failure to None
@module("effect") @scope("Effect")
external option: t<'a, 'e, 'r> => t<option<'a>, 'e2, 'r> = "option"

// ─── Retry / repeat ──────────────────────────────────────────────────────

// Retry on failure using a Schedule. The schedule receives the error value.
@module("effect") @scope("Effect")
external retry: (t<'a, 'e, 'r>, schedule<'out, 'e, 'r>) => t<'a, 'e, 'r> = "retry"

// Repeat on success using a Schedule. The schedule receives the success value.
@module("effect") @scope("Effect")
external repeat: (t<'a, 'e, 'r>, schedule<'out, 'a, 'r>) => t<'out, 'e, 'r> = "repeat"

// ─── Concurrency ─────────────────────────────────────────────────────────

// Fork into a new fiber — runs concurrently with the current fiber
@module("effect") @scope("Effect")
external fork: t<'a, 'e, 'r> => t<fiber<'a, 'e>, 'e2, 'r> = "fork"

// Fork, tying the fiber's lifetime to the current scope
@module("effect") @scope("Effect")
external forkScoped: t<'a, 'e, 'r> => t<fiber<'a, 'e>, 'e2, 'r> = "forkScoped"

// Run all effects concurrently. concurrency: "unbounded" | "inherit" | number-as-string
@module("effect") @scope("Effect")
external all: (array<t<'a, 'e, 'r>>, {. "concurrency": string}) => t<array<'a>, 'e, 'r> = "all"

// Race two effects — first to succeed wins, loser is interrupted
@module("effect") @scope("Effect")
external race: (t<'a, 'e, 'r>, t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "race"

// ─── Resource management ─────────────────────────────────────────────────

// Acquire a resource and guarantee its release even on failure/interruption.
// The release function receives the exit status of the use.
@module("effect") @scope("Effect")
external acquireRelease: (t<'a, 'e, 'r>, ('a, Exit.t<'b, 'e2>) => t<unit, 'e3, 'r>) => t<'a, 'e, 'r> = "acquireRelease"

// Open a new Scope and run the effect within it; finalizers run on scope close
@module("effect") @scope("Effect")
external scoped: t<'a, 'e, 'r> => t<'a, 'e, 'r2> = "scoped"

// ─── Synchronization primitives ──────────────────────────────────────────

// Create a Latch (binary gate). Pass true to start open, false to start closed.
@module("effect") @scope("Effect")
external makeLatch: bool => t<latch, 'e, 'r> = "makeLatch"

// Create a Semaphore with N permits (generalized mutex)
@module("effect") @scope("Effect")
external makeSemaphore: int => t<semaphore, 'e, 'r> = "makeSemaphore"

// Run an effect holding N permits from the semaphore
@module("effect") @scope("Effect")
external withPermits: (semaphore, int, t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "withPermits"

// ─── Timing ──────────────────────────────────────────────────────────────

// Sleep for the given duration (respects TestClock in tests)
@module("effect") @scope("Effect")
external sleep: Duration.t => t<unit, 'e, 'r> = "sleep"

// Abort if the effect does not complete within the given duration
@module("effect") @scope("Effect")
external timeout: (t<'a, 'e, 'r>, Duration.t) => t<option<'a>, 'e, 'r> = "timeout"

// ─── Dependency injection ─────────────────────────────────────────────────

// Provide a Layer to satisfy an Effect's requirements ('r channel).
// After providing a layer that covers all requirements, the returned Effect
// has unit requirements and can be run with runPromise / runSync.
// The 'layer type is polymorphic — pass any TestContext.layer or custom Layer.
@module("effect") @scope("Effect")
external provide: (t<'a, 'e, 'r>, 'layer) => t<'a, 'e, unit> = "provide"

// ─── Fiber control ───────────────────────────────────────────────────────

// Yield control to the Effect scheduler — allows other fibers to run before continuing.
// Useful when testing concurrent effects or when you need to ensure a forked fiber
// has had a chance to start.
@module("effect") @scope("Effect")
external yieldNow: unit => t<unit, 'e, 'r> = "yieldNow"

// ─── Running effects ─────────────────────────────────────────────────────

// Run to Promise. Rejects on typed errors and defects.
@module("effect") @scope("Effect")
external runPromise: t<'a, 'e, 'r> => promise<'a> = "runPromise"

// Run to Promise, always resolving with an Exit (never rejects).
@module("effect") @scope("Effect")
external runPromiseExit: t<'a, 'e, 'r> => promise<Exit.t<'a, 'e>> = "runPromiseExit"

// Run synchronously. Throws if the effect is async.
@module("effect") @scope("Effect")
external runSync: t<'a, 'e, 'r> => 'a = "runSync"

// Run synchronously, returning an Exit instead of throwing.
@module("effect") @scope("Effect")
external runSyncExit: t<'a, 'e, 'r> => Exit.t<'a, 'e> = "runSyncExit"
