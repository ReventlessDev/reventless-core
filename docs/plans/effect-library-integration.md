# Effect Library Integration Analysis

**Status:** Backlog
**Created:** 2026-02-27
**Summary:** Analysis of the [Effect TypeScript library](https://effect.website/) features and how they could improve the Reventless architecture. Covers typed errors, retry/scheduling, resource management, concurrency, streaming, schema versioning, and future distributed systems patterns.

---

## Background

Reventless is an event-sourced CQRS framework written in ReScript. Effect is a TypeScript functional effect system (successor to ZIO/fp-ts) providing typed errors, structured concurrency, composable retry/scheduling, and resource lifecycle management. This document maps Effect features to concrete Reventless pain points.

Effect is a TypeScript library — using it from ReScript requires writing `@module("effect")` bindings. ReScript's pipe operator (`->`) maps naturally to Effect's `pipe()` composition; `Effect.flatMap` / `Effect.map` align with ReScript's functional style.

---

## Current Pain Points in Reventless

### 1. Inconsistent Error Handling
The framework mixes three incompatible error strategies:
- `result<unit, string>` return types (the stated contract)
- `throw` / `JsExn` exceptions (what actually happens)
- `Console.log` + empty-array returns (silent failures in `QueryDb_Operations.res` decode)

There is a documented `FIXME` in `reventless/reventless/src/components/EventLog/EventLog_Operations.res`:
```rescript
// FIXME: append is supposed to return result<unit, string>,
//        but at the same moment, we throw errors
//        We should use result everywhere instead of throwing errors
```

### 2. No Retry / Resilience Strategy
- If DynamoDB throttles an `EventLog.append`, the command fails permanently
- SQS dead-letters after 5 attempts with no backoff between retries
- No distinction between transient (503) and permanent (400/validation) errors

### 3. Handler Registration Race Conditions
- `handlerRef: ref<option<handler>>` in `RuntimeEnvironment_InMemory` can be `None` when first messages arrive
- `EventCollectorChannel_InMemory` subscribes inside `Output.apply` (2 async microtask ticks) — messages published before subscription is registered are silently lost
- Heartbeat timers require explicit `reset()` calls; no automatic lifecycle cleanup

### 4. EventLog Atomicity Gap
`EventLog.append` has a crash window between:
1. Writing events to DynamoDB ✓
2. Publishing to EventTopic ← crash here = events stored but never broadcast

### 5. Concurrent Command Error Loss
When processing commands for multiple aggregate IDs concurrently, if two fail, only the first exception propagates. The second error is silently discarded.

### 6. No Schema Versioning
`sury-ppx` has no mechanism for event schema migration. Renamed fields break `EventLog.replay` for historical events with no recovery path.

### 7. Broken Test Infrastructure
- `testPromise` from `@glennsl/rescript-jest` does not properly await async tests (documented in `MEMORY.md`)
- `Jest.useFakeTimers()` + `HeartbeatRunner.reset()` pattern is fragile
- No deterministic time control for Schedule/retry testing

---

## Effect Feature Mapping

### Tier 1 — High Impact, Feasible Near-Term

#### 1. `Effect<A, E, R>` Typed Errors → Fix inconsistent error handling

**Effect feature:** The three-parameter type `Effect<Success, Error, Requirements>` encodes errors in the type. Errors must be handled or propagated — the compiler rejects unhandled cases. `catchTag` handles specific error types exhaustively.

**Reventless application:**
- `StorageError` (transient DynamoDB throttle) vs `ValidationError` (permanent) become distinct types
- `DecodeError` vs `NotFound` vs `BusinessRuleViolation` are all compiler-visible
- The FIXME in `EventLog_Operations.res` becomes a type error rather than a runtime surprise
- Silent `Console.log` + empty-array returns in `QueryDb_Operations.res` become impossible

**Algebraic error mapping for command handling:**
```
Effect<A,                E,               R>
       ↕                 ↕                ↕
  emitted events    domain errors    event store +
  / acknowledgment  (AggNotFound,    command bus
                    BusinessRule)    services
```

The `R` channel means the compiler refuses to execute a command handler if any infrastructure service hasn't been provided — eliminating runtime "no handler registered" warnings.

**Files affected:**
- `reventless/reventless/src/components/EventLog/EventLog_Operations.res`
- `reventless/reventless/src/components/QueryDb/QueryDb_Operations.res`
- `reventless/reventless-in-memory/src/components/CommandTopicChannel_InMemory.res`

---

#### 2. `Schedule` + `Effect.retry` → Fill the resilience gap

**Effect feature:** `Schedule` is a composable data value controlling recurrence timing. Built-in schedules compose via pipe:

```typescript
Schedule.exponential(Duration.millis(100)).pipe(
  Schedule.jittered,             // add randomness (thundering herd prevention)
  Schedule.recurs(5),            // max 5 retries
  Schedule.whileInput(isTransient) // only retry transient errors
)
```

`Schedule.fromCron` for cron-style heartbeat expressions. `Schedule.fromCron` + `Effect.repeat` replaces the manual `setInterval` in `HeartbeatRunner_InMemory`.

**Reventless application:**
- `EventLog.append` retries on DynamoDB throttle with exponential backoff + jitter
- Retry policy is a data value — composable, testable, and configurable per operation
- Replaces the 5-strike-dead-letter SQS retry with something declarative

**Files affected:**
- `reventless/reventless/src/components/EventLog/EventLog_Operations.res`
- `reventless/reventless-in-memory/src/HeartbeatRunner_InMemory.res`

---

#### 3. `Latch` + `SynchronizedRef` → Fix handler registration races

**Effect feature:**
- `Effect.makeLatch(false)` — a binary gate that blocks consumers until `latch.open` is called
- `SynchronizedRef<A>` — atomic mutable variable with `updateEffect` (effectful atomic updates)
- `Deferred<A, E>` — single-value one-shot rendezvous; one fiber sets it, any number await it

**Reventless application:**
- Replace `handlerRef: ref<option<handler>>` with a `Deferred` — readers block until the handler is registered rather than seeing `None` and logging a warning
- Replace the `Output.apply` subscription timing race in `EventCollectorChannel_InMemory` with a `Latch` that blocks publishers until subscription is confirmed registered
- `SynchronizedRef` provides transactional handler slot updates

**Files affected:**
- `reventless/reventless-in-memory/src/RuntimeEnvironment_InMemory.res`
- `reventless/reventless-in-memory/src/EventCollectorChannel_InMemory.res`

---

#### 4. `Cause<E>` — Parallel error preservation

**Effect feature:** `Cause<E>` is an algebraic data type with `Cause.Parallel(a, b)` that preserves **both** errors from concurrent operations (not just the first).

**Reventless application:** When `Aggregate_Callback.handleCommands` processes multiple aggregate IDs concurrently and two fail, currently only the first exception propagates. With `Cause`, all failures are preserved and surfaced.

**Files affected:**
- `reventless/reventless/src/components/Aggregate/Aggregate_Callback.res`

---

#### 5. `@effect/vitest` + `TestClock` → Fix broken test infrastructure

**Effect feature:**
- `it.effect(name, () => Effect.gen(...))` — properly awaits async Effect fibers (replaces broken `testPromise`)
- `TestClock.adjust(duration)` — synchronously advances virtual time, triggering any `sleep`s or `Schedule`s
- `describe.layer(ServiceLayer)` — eliminates manual `beforeAll`/`afterAll` service lifecycle
- `it.scoped` — provides a scope that closes after the test (automatic timer/resource cleanup)

**Reventless application:**
- Replaces broken `testPromise` concurrency pattern (documented in MEMORY.md)
- Replaces `Jest.useFakeTimers()` + `HeartbeatRunner.reset()` fragile pattern
- Makes all retry/timeout tests deterministic and instantaneous

---

### Tier 2 — Medium Impact, Meaningful Architecture Improvement

#### 6. STM → Fix EventLog append/publish atomicity

**Effect feature:** Software Transactional Memory enables atomic multi-variable operations. Transactions retry automatically if any read value changed before commit — no deadlocks, no explicit locking:

```typescript
const appendAndPublish = STM.gen(function* () {
  yield* TRef.update(eventStore, appendEvents)
  yield* TRef.update(subscriptions, notifySubscribers)
})
yield* STM.commit(appendAndPublish)
```

**Reventless application:**
- For the in-memory adapter: `STM` commit over `TRef(eventStore)` + `TRef(subscriptions)` makes append-and-publish truly atomic
- For AWS: maps to the transactional outbox pattern (events written to a DynamoDB outbox table atomically with the event record, then a separate Lambda publishes from outbox to SNS)

**Files affected:**
- `reventless/reventless-in-memory/src/EventLogStorage_InMemory.res`
- `reventless/reventless-in-memory/src/InMemory_Bus.res`

---

#### 7. `Queue` / `PubSub` → Improve InMemory_Bus

**Effect feature:**
- `Queue.bounded(capacity)` — backpressure when producers outrun consumers
- `PubSub.bounded(capacity)` — broadcast with per-subscriber queues
- Overflow strategies: `Queue.sliding`, `Queue.dropping`

**Reventless application:**
- `InMemory_Bus` is currently an unbounded array of callbacks with no backpressure
- Replace with `PubSub` to make the in-memory adapter production-realistic
- Tests would catch backpressure-related bugs that currently only manifest in AWS under load

**Files affected:**
- `reventless/reventless-in-memory/src/InMemory_Bus.res`

---

#### 8. `Stream` → Replace event processing pipeline

**Effect feature:** `Stream<A, E, R>` is a lazy, effectful, backpressure-aware sequence. Key for CQRS:

```typescript
EventLog.replay(id).pipe(
  Stream.map(decodeEvent),
  Stream.runFoldEffect(initialState, applyEvent)
)
```

**Reventless application:**
- `EventLog.replay` currently loads all events into a `array<event>` — dangerous for large aggregates
- `Stream` enables chunked replay without loading full history into RAM
- `Stream.fromPubSub` replaces manual EventCollector subscription array
- `Stream.retry` handles transient read failures automatically
- `Stream.grouped(100)` enables batch projection updates

**Files affected:**
- `reventless/reventless/src/components/EventLog/EventLog_Operations.res`
- `reventless/reventless/src/components/EventCollector/EventCollectorChannel_InMemory.res`

---

#### 9. `ManagedRuntime` → Lambda cold-start optimization

**Effect feature:** `ManagedRuntime.make(AppLayer)` builds the dependency graph once and reuses it across Lambda invocations (warm container reuse). `dispose()` runs all finalizers on shutdown.

**Reventless application:**
- Currently DynamoDB connections and schema compilation happen per-invocation
- With `ManagedRuntime`, Layer construction is a one-time cost per Lambda container lifetime
- `Layer.scoped` ties DynamoDB connection pool lifecycle to the runtime, not the request

---

#### 10. `Effect.Schema` → Replace sury-ppx (long-term)

**Effect feature:** A single schema definition drives parsing, encoding, validation, pretty-printing, and test data generation. `Schema.transform` / `Schema.transformOrFail` provide bidirectional versioning:

```typescript
const EventV2 = Schema.transform(
  EventV1Schema,
  EventV2Schema,
  { decode: (v1) => migrate(v1), encode: (v2) => downgrade(v2) }
)
```

Standard Schema v1 interop — allows sharing schemas with Zod, Valibot, etc.

**Reventless application:**
- Replaces `sury-ppx` limitations:
  - Payload-less variants serialize as strings (breaks `splitMessage`/`combineMessage`)
  - `@s.matches` placement is silent on wrong position
  - `type t` generates `schema` not `tSchema` (confusing)
- `Schema.transformOrFail` enables event migration: `EventLog.replay` applies migrations on read
- **Caveat:** Requires writing full ReScript bindings for Effect Schema + migrating all `@schema`-annotated types. Very high effort.

---

### Tier 3 — Future Architectural Evolution

#### 11. `@effect/workflow` → Durable Aggregates / Sagas

**Effect feature:** `@effect/workflow` (alpha 2025) provides durable workflow execution:
- `Activity` — executes exactly once (idempotent without explicit retry)
- `DurableDeferred` — pause workflow until an external signal (e.g. payment confirmed)
- Durable `sleep` — consumes no resources while paused
- Compensation finalizers — rollback on failure (Saga pattern)

**Reventless application:**
- Currently: multi-step processes (e.g. order fulfillment saga) must be modeled as aggregate state transitions with no native "wait for external event" semantics
- With `@effect/workflow`: aggregates become long-lived workflows that survive Lambda cold starts — state is checkpointed automatically
- Enables true Saga pattern with compensation as a first-class concept

---

#### 12. `@effect/cluster` → Stateful Aggregate Actors

**Effect feature:** Distributed actor system with entity sharding (production-ready 2025):
- Consistent hashing: `entityId → shardId → runner`
- Each entity is a stateful actor holding reconstructed state in memory
- Only replays on cold start (first activation), not on every command
- Singletons: exactly-once effects across the cluster with automatic failover
- Inspired by Akka Cluster Sharding

**Reventless application:**
- Currently: every command triggers a full `EventLog.replay` to reconstruct aggregate state
- With `@effect/cluster`: aggregate actor holds state warm, dramatically reducing DynamoDB read costs for hot aggregates
- **Caveat:** Exits the serverless-stateless model. Requires ECS/EC2/Kubernetes instead of Lambda. Major architectural shift.

---

## Priority Matrix

| Effect Feature | Reventless Problem | Impact | Effort |
|---|---|---|---|
| `Effect<A,E,R>` typed errors | FIXME + silent decode failures | **Critical** | Medium |
| `Schedule` + `retry` | No backoff, DLQ-only resilience | High | Low |
| `Latch` + `SynchronizedRef` | HandlerRef race, timer leaks | High | Low |
| `Cause.Parallel` | Concurrent command errors lost | High | Low |
| `@effect/vitest` + `TestClock` | Broken testPromise, fake timers | High | Low |
| STM | EventLog append/publish atomicity | High | Medium |
| `Queue` / `PubSub` | Unbounded Bus, no backpressure | Medium | Medium |
| `ManagedRuntime` | Lambda cold-start Layer cost | Medium | Medium |
| `Stream` | In-memory replay, manual fan-out | Medium | High |
| `Effect.Schema` | No schema versioning, sury-ppx limits | Medium | Very High |
| `@effect/workflow` | No Saga / durable processes | Future | Very High |
| `@effect/cluster` | Hot aggregate replay cost | Future | Very High |

---

## `rescript-effect` Package

All ReScript bindings for the Effect library live in a dedicated package following the same conventions as `rescript-uuid`, `rescript-graphql-yoga`, etc.

### Location and naming

```
rescript/rescript-effect/          ← follows rescript/ folder convention
├── package.json                   ← @reventlessdev/rescript-effect
├── rescript.json
└── src/
    ├── Effect.res
    ├── Duration.res
    ├── Schedule.res
    ├── Fiber.res
    ├── Exit.res
    ├── Cause.res
    ├── Deferred.res
    ├── Ref.res
    ├── SynchronizedRef.res
    ├── Latch.res
    ├── Queue.res
    ├── PubSub.res
    └── Stm.res
```

All Effect modules export from the single `"effect"` npm package, so every binding file uses `@module("effect")` with a different `@scope`.

### `package.json`

```json
{
  "name": "@reventlessdev/rescript-effect",
  "version": "0.1.0-alpha.0",
  "description": "ReScript bindings for the Effect TypeScript library",
  "license": "MIT",
  "scripts": {
    "build": "rescript build",
    "start": "rescript build -w",
    "clean": "rescript clean",
    "rebuild": "npm run clean && npm run build -- -with-deps",
    "test": "echo \"No tests for rescript-effect bindings.\""
  },
  "dependencies": {
    "effect": "^3.17.0"
  },
  "devDependencies": {
    "rescript": "^12.1.0"
  },
  "peerDependencies": {
    "rescript": "^12.1.0"
  },
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### `rescript.json`

```json
{
  "name": "@reventlessdev/rescript-effect",
  "namespace": false,
  "warnings": {
    "error": "-44+101"
  },
  "sources": [
    {
      "dir": "src",
      "subdirs": true
    }
  ],
  "dependencies": []
}
```

`namespace: false` keeps module names flat (`Effect`, `Schedule`, etc.) matching the Effect library's own naming, so usage in Reventless reads naturally.

### Monorepo registration

Add to root `rescript.json` dependencies array:
```json
"@reventlessdev/rescript-effect"
```

Add to consuming packages' `rescript.json` dependencies (`reventless-in-memory`, `reventless`):
```json
"dependencies": ["@reventlessdev/rescript-effect"]
```

The package is automatically included in Lerna workspaces via the `rescript/*` glob in `lerna.json` and `package.json` workspaces — no changes needed there.

---

### Design Decisions

#### The `R` (requirements) channel

Effect's full type is `Effect<A, E, R>` where `R` is the dependency injection channel. In TypeScript, `R = never` means "no requirements". ReScript has no `never` equivalent, so bindings use a polymorphic `'r` throughout. This is intentionally permissive for Phase 1 — all in-memory adapter usage will naturally resolve `'r` to `unit`. The Layer/Context DI system is not bound in Phase 1 (not needed for the in-memory adapter or retry improvements).

#### No `Effect.gen` — use `flatMap` pipelines

Effect's generator syntax (`Effect.gen(function* () { ... })`) relies on JavaScript generator functions, which ReScript does not support. All Effect chains use `flatMap`/`map`/`zipRight` pipelines instead. This is idiomatic in ReScript and equivalent in behavior:

```rescript
// TypeScript (gen syntax):
// const program = Effect.gen(function* () {
//   const d = yield* Deferred.make<string, never>()
//   yield* Deferred.succeed(d, "hello")
//   return yield* Deferred.await(d)
// })

// ReScript equivalent (flatMap pipeline):
let program =
  Deferred.make()
  ->Effect.flatMap(d =>
    Deferred.succeed(d, "hello")
    ->Effect.zipRight(Deferred.await(d))
  )
```

#### Naming conflicts

`open` is a reserved word in ReScript. The `Latch.open` method must be bound as `open_` with `= "open"`:
```rescript
@send external open_: (t, unit) => Effect.t<unit, 'e, 'r> = "open"
```

---

### Source Files

#### `Effect.res` — Core type and operations

```rescript
// Effect<A, E, R> — the three-channel type.
// 'a = success value, 'e = typed error, 'r = requirements (use unit for no deps)
type t<'a, 'e, 'r>

// ─── Construction ──────────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

@module("effect") @scope("Effect")
external fail: 'e => t<'a, 'e, 'r> = "fail"

@module("effect") @scope("Effect")
external sync: (unit => 'a) => t<'a, 'e, 'r> = "sync"

// Wrap a Promise — thrown exceptions become defects (not typed errors)
@module("effect") @scope("Effect")
external promise: (unit => promise<'a>) => t<'a, 'e, 'r> = "promise"

// Wrap a Promise — map thrown exceptions to typed errors
@module("effect") @scope("Effect")
external tryPromise: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"

// ─── Transformation ────────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("Effect")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

// Execute for side effect, return original value
@module("effect") @scope("Effect")
external tap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// Sequence two effects, return the second's result
@module("effect") @scope("Effect")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "zipRight"

// ─── Error handling ────────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"

// Handle a specific tagged error variant by name
@module("effect") @scope("Effect")
external catchTag: (t<'a, 'e, 'r>, string, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchTag"

// Wrap result in Either — effect never fails
@module("effect") @scope("Effect")
external either: t<'a, 'e, 'r> => t<result<'a, 'e>, 'e2, 'r> = "either"

// ─── Retry / repeat ───────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external retry: (t<'a, 'e, 'r>, Schedule.t<'out, 'e, 'r>) => t<'a, 'e, 'r> = "retry"

@module("effect") @scope("Effect")
external repeat: (t<'a, 'e, 'r>, Schedule.t<'out, 'a, 'r>) => t<'out, 'e, 'r> = "repeat"

// ─── Concurrency ──────────────────────────────────────────────────────────

@module("effect") @scope("Effect")
external fork: t<'a, 'e, 'r> => t<Fiber.t<'a, 'e>, 'e2, 'r> = "fork"

// Run array of effects concurrently
@module("effect") @scope("Effect")
external all: (array<t<'a, 'e, 'r>>, {. "concurrency": @string [@as("unbounded") | @as("inherit") | Bounded(int)]}) => t<array<'a>, 'e, 'r> = "all"

// ─── Resource management ──────────────────────────────────────────────────

@module("effect") @scope("Effect")
external acquireRelease: (t<'a, 'e, 'r>, ('a, Exit.t<'b, 'e>) => t<unit, 'e2, 'r>) => t<'a, 'e, 'r> = "acquireRelease"

@module("effect") @scope("Effect")
external scoped: t<'a, 'e, 'r> => t<'a, 'e, 'r2> = "scoped"

// ─── Synchronization primitives ────────────────────────────────────────────

@module("effect") @scope("Effect")
external makeLatch: bool => t<Latch.t, 'e, 'r> = "makeLatch"

@module("effect") @scope("Effect")
external makeSemaphore: int => t<Semaphore.t, 'e, 'r> = "makeSemaphore"

// ─── Running effects ──────────────────────────────────────────────────────

// Run to promise — throws on typed error (use runPromiseExit for safe handling)
@module("effect") @scope("Effect")
external runPromise: t<'a, 'e, 'r> => promise<'a> = "runPromise"

// Run to promise — always resolves with Exit (never throws)
@module("effect") @scope("Effect")
external runPromiseExit: t<'a, 'e, 'r> => promise<Exit.t<'a, 'e>> = "runPromiseExit"

// Run synchronously — throws if effect is async
@module("effect") @scope("Effect")
external runSync: t<'a, 'e, 'r> => 'a = "runSync"
```

---

#### `Duration.res` — Time values

```rescript
type t

@module("effect") @scope("Duration")
external millis: int => t = "millis"

@module("effect") @scope("Duration")
external seconds: int => t = "seconds"

@module("effect") @scope("Duration")
external minutes: int => t = "minutes"

@module("effect") @scope("Duration")
external hours: int => t = "hours"
```

---

#### `Schedule.res` — Composable retry/repeat policies

```rescript
// Schedule<Out, In, R>
// 'out = value produced each recurrence (e.g. Duration.t for exponential)
// 'in_ = input consumed (error value for retry, success value for repeat)
// 'r   = requirements
type t<'out, 'in_, 'r>

// ─── Built-in schedules ────────────────────────────────────────────────────

// 100ms, 200ms, 400ms, 800ms... (doubles each time)
@module("effect") @scope("Schedule")
external exponential: Duration.t => t<Duration.t, 'in_, 'r> = "exponential"

// Fixed interval between completions
@module("effect") @scope("Schedule")
external fixed: Duration.t => t<int, 'in_, 'r> = "fixed"

// Fixed delay between completions
@module("effect") @scope("Schedule")
external spaced: Duration.t => t<int, 'in_, 'r> = "spaced"

// Exactly N repetitions
@module("effect") @scope("Schedule")
external recurs: int => t<int, 'in_, 'r> = "recurs"

// Run once (no recurrence)
@module("effect") @scope("Schedule")
external once: t<int, 'in_, 'r> = "once"

// Repeat forever
@module("effect") @scope("Schedule")
external forever: t<int, 'in_, 'r> = "forever"

// ─── Composition ──────────────────────────────────────────────────────────

// Add random jitter to prevent thundering herd
@module("effect") @scope("Schedule")
external jittered: t<'out, 'in_, 'r> => t<'out, 'in_, 'r> = "jittered"

// Only continue while the input predicate holds (e.g. error is transient)
@module("effect") @scope("Schedule")
external whileInput: (t<'out, 'in_, 'r>, 'in_ => bool) => t<'out, 'in_, 'r> = "whileInput"

// Only continue while the output predicate holds (e.g. total elapsed < 1 minute)
@module("effect") @scope("Schedule")
external whileOutput: (t<'out, 'in_, 'r>, 'out => bool) => t<'out, 'in_, 'r> = "whileOutput"

// Feed output of one schedule as input to another
@module("effect") @scope("Schedule")
external compose: (t<'out, 'in_, 'r>, t<'out2, 'out, 'r>) => t<'out2, 'in_, 'r> = "compose"

// Track elapsed time as the output
@module("effect") @scope("Schedule")
external elapsed: t<Duration.t, 'in_, 'r> = "elapsed"
```

---

#### `Deferred.res` — Single-value one-shot synchronization

```rescript
// Deferred<A, E> — set exactly once; consumers block until set
type t<'a, 'e>

@module("effect") @scope("Deferred")
external make: unit => Effect.t<t<'a, 'e>, 'e2, 'r> = "make"

// Block the current fiber until the deferred is completed
@module("effect") @scope("Deferred")
external await: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "await"

// Complete with a success value — returns true if first to complete
@module("effect") @scope("Deferred")
external succeed: (t<'a, 'e>, 'a) => Effect.t<bool, 'e2, 'r> = "succeed"

// Complete with a failure — returns true if first to complete
@module("effect") @scope("Deferred")
external fail: (t<'a, 'e>, 'e) => Effect.t<bool, 'e2, 'r> = "fail"

// Complete with an effect's result
@module("effect") @scope("Deferred")
external completeWith: (t<'a, 'e>, Effect.t<'a, 'e, 'r>) => Effect.t<bool, 'e2, 'r> = "completeWith"
```

---

#### `Ref.res` — Mutable reference (concurrent-safe)

```rescript
type t<'a>

@module("effect") @scope("Ref")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

@module("effect") @scope("Ref")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

@module("effect") @scope("Ref")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

@module("effect") @scope("Ref")
external update: (t<'a>, 'a => 'a) => Effect.t<unit, 'e, 'r> = "update"

@module("effect") @scope("Ref")
external getAndUpdate: (t<'a>, 'a => 'a) => Effect.t<'a, 'e, 'r> = "getAndUpdate"

@module("effect") @scope("Ref")
external modify: (t<'a>, 'a => ('b, 'a)) => Effect.t<'b, 'e, 'r> = "modify"
```

---

#### `SynchronizedRef.res` — Atomic effectful reference updates

```rescript
// Like Ref but updateEffect is transactional — the effect is run atomically
type t<'a>

@module("effect") @scope("SynchronizedRef")
external make: 'a => Effect.t<t<'a>, 'e, 'r> = "make"

@module("effect") @scope("SynchronizedRef")
external get: t<'a> => Effect.t<'a, 'e, 'r> = "get"

@module("effect") @scope("SynchronizedRef")
external set: (t<'a>, 'a) => Effect.t<unit, 'e, 'r> = "set"

// Run an effectful function atomically — no other fiber can modify between read and write
@module("effect") @scope("SynchronizedRef")
external updateEffect: (t<'a>, 'a => Effect.t<'a, 'e, 'r>) => Effect.t<unit, 'e, 'r> = "updateEffect"

@module("effect") @scope("SynchronizedRef")
external modifyEffect: (t<'a>, 'a => Effect.t<('b, 'a), 'e, 'r>) => Effect.t<'b, 'e, 'r> = "modifyEffect"
```

---

#### `Latch.res` — Binary gate synchronization

```rescript
// Latch — closed by default; fibers calling await block until open is called
type t

// Block until the latch is opened
@send
external await: (t, unit) => Effect.t<unit, 'e, 'r> = "await"

// Open the latch — releases all waiting fibers immediately
// Note: `open` is reserved in ReScript; bind as open_
@send
external open_: (t, unit) => Effect.t<unit, 'e, 'r> = "open"

// Close the latch — future await calls will block again
@send
external close: (t, unit) => Effect.t<unit, 'e, 'r> = "close"
```

---

#### `Cause.res` — Lossless algebraic error structure

```rescript
// Cause<E> captures the full failure structure including parallel failures
type t<'e>

@module("effect") @scope("Cause")
external fail: 'e => t<'e> = "fail"

@module("effect") @scope("Cause")
external die: 'defect => t<'e> = "die"

// Combine two causes from concurrent operations — BOTH are preserved
@module("effect") @scope("Cause")
external parallel: (t<'e>, t<'e>) => t<'e> = "parallel"

@module("effect") @scope("Cause")
external sequential: (t<'e>, t<'e>) => t<'e> = "sequential"

@module("effect") @scope("Cause")
external isFail: t<'e> => bool = "isFail"

@module("effect") @scope("Cause")
external isDie: t<'e> => bool = "isDie"

@module("effect") @scope("Cause")
external isEmpty: t<'e> => bool = "isEmpty"

// Extract all typed failures from a cause tree
@module("effect") @scope("Cause")
external failures: t<'e> => array<'e> = "failures"

// Extract all defects (unexpected exceptions)
@module("effect") @scope("Cause")
external defects: t<'e> => array<unknown> = "defects"

@module("effect") @scope("Cause")
external pretty: t<'e> => string = "pretty"
```

---

#### `Exit.res` — Effect execution result

```rescript
// Exit<A, E> — the result of running a fiber to completion
type t<'a, 'e> =
  | Success('a)
  | Failure(Cause.t<'e>)

@module("effect") @scope("Exit")
external succeed: 'a => t<'a, 'e> = "succeed"

@module("effect") @scope("Exit")
external fail: 'e => t<'a, 'e> = "fail"

@module("effect") @scope("Exit")
external isSuccess: t<'a, 'e> => bool = "isSuccess"

@module("effect") @scope("Exit")
external isFailure: t<'a, 'e> => bool = "isFailure"

@module("effect") @scope("Exit")
external map: (t<'a, 'e>, 'a => 'b) => t<'b, 'e> = "map"

@module("effect") @scope("Exit")
external flatMap: (t<'a, 'e>, 'a => t<'b, 'e>) => t<'b, 'e> = "flatMap"
```

---

#### `Fiber.res` — Lightweight concurrent thread

```rescript
type t<'a, 'e>

// Wait for a fiber to complete — propagates its errors
@module("effect") @scope("Fiber")
external join: t<'a, 'e> => Effect.t<'a, 'e, 'r> = "join"

// Interrupt a fiber — triggers its finalizers
@module("effect") @scope("Fiber")
external interrupt: t<'a, 'e> => Effect.t<Exit.t<'a, 'e>, 'e2, 'r> = "interrupt"

// Wait for all fibers in parallel
@module("effect") @scope("Fiber")
external joinAll: array<t<'a, 'e>> => Effect.t<array<'a>, 'e, 'r> = "joinAll"

// Collect exits from all fibers — never fails
@module("effect") @scope("Fiber")
external collectAll: array<t<'a, 'e>> => Effect.t<array<Exit.t<'a, 'e>>, 'e2, 'r> = "collectAll"
```

---

#### `Queue.res` — Bounded concurrent queue (Phase 2)

```rescript
type t<'a>

@module("effect") @scope("Queue")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

@module("effect") @scope("Queue")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

// Offer — blocks if queue is full (backpressure)
@module("effect") @scope("Queue")
external offer: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "offer"

// Take — blocks if queue is empty
@module("effect") @scope("Queue")
external take: t<'a> => Effect.t<'a, 'e, 'r> = "take"

@module("effect") @scope("Queue")
external takeAll: t<'a> => Effect.t<array<'a>, 'e, 'r> = "takeAll"

@module("effect") @scope("Queue")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

@module("effect") @scope("Queue")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"
```

---

#### `PubSub.res` — Broadcast hub (Phase 2)

```rescript
// PubSub<A> — each subscriber gets its own view (backed by per-subscriber Queue)
type t<'a>

@module("effect") @scope("PubSub")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

@module("effect") @scope("PubSub")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

// Publish — blocks if all subscribers' queues are full
@module("effect") @scope("PubSub")
external publish: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "publish"

// Subscribe — returns a scoped Queue; auto-unsubscribes when scope closes
@module("effect") @scope("PubSub")
external subscribe: t<'a> => Effect.t<Queue.t<'a>, 'e, 'r> = "subscribe"

@module("effect") @scope("PubSub")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"

@module("effect") @scope("PubSub")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"
```

---

#### `Stm.res` — Software Transactional Memory (Phase 2)

```rescript
// STM<A, E, R> — a transactional computation over TRef values
type t<'a, 'e, 'r>

// TRef<A> — a transactional mutable variable
module TRef: {
  type t<'a>

  @module("effect") @scope("TRef")
  external make: 'a => Stm.t<t<'a>, 'e, 'r> = "make"

  @module("effect") @scope("TRef")
  external get: t<'a> => Stm.t<'a, 'e, 'r> = "get"

  @module("effect") @scope("TRef")
  external set: (t<'a>, 'a) => Stm.t<unit, 'e, 'r> = "set"

  @module("effect") @scope("TRef")
  external update: (t<'a>, 'a => 'a) => Stm.t<unit, 'e, 'r> = "update"
}

@module("effect") @scope("STM")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

@module("effect") @scope("STM")
external fail: 'e => t<'a, 'e, 'r> = "fail"

@module("effect") @scope("STM")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("STM")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

// Execute the transaction atomically — retries if any TRef changed
@module("effect") @scope("STM")
external commit: t<'a, 'e, 'r> => Effect.t<'a, 'e, 'r> = "commit"
```

---

### Binding Verification Process

Before each binding file is considered complete:

1. **Check exact JS name** against the Effect source or npm package exports — `@scope("Effect")` with `external succeed` must match `Effect.succeed` in the published package
2. **Verify argument order** — Effect functions are data-last (`Effect.map(self, f)`), which aligns with ReScript's `->` pipe
3. **Build with zero warnings** — run `npm run build 2>&1 | grep -E "Warning|error"` after each file
4. **Smoke test** — write a minimal `.res` file in `src/examples/` that exercises each binding to confirm the JS output is correct

---

## Recommended Implementation Approach

The clearest near-term path is writing thin ReScript bindings for Effect core primitives and applying them to the in-memory adapter and EventLog operations first — measurable improvements with contained scope before considering the deeper Stream or Schema migration.

**Phase 0 — Create `rescript-effect` package: ✅ COMPLETE**
- [x] Scaffold `rescript/rescript-effect/` with `package.json`, `rescript.json`, `.gitignore`
- [x] Implement `Duration.res`, `Effect.res`, `Exit.res`, `Cause.res` (foundational)
- [x] Implement `Schedule.res`, `Fiber.res` (retry and concurrency)
- [x] Implement `Deferred.res`, `Ref.res`, `SynchronizedRef.res`, `Latch.res` (synchronization)
- [x] Implement `Queue.res`, `PubSub.res`, `Stm.res` (Phase 2 primitives, included upfront)
- [x] Add to root `rescript.json` and run `npm install`
- [x] Full clean build: 13 modules, zero warnings
- **Implementation notes:**
  - `await` is a reserved keyword in ReScript — bound as `await_` in `Deferred.res` and `Latch.res`
  - Circular deps broken via abstract forward-declared types in `Effect.res`: `fiber<'a,'e>`, `latch`, `semaphore`, `schedule<'out,'in_,'r>`; dependent modules use transparent type aliases (e.g. `type t<'a,'e> = Effect.fiber<'a,'e>`)
  - `Latch` properties (`await`, `open`, `close`) use `@get` (not `@send`) — they are getter properties in Effect, not callable methods
  - `Stm.TRef` nested module uses local `type stm<'a,'e,'r> = t<'a,'e,'r>` alias to avoid self-referencing `Stm` by name inside the same file
  - `rebuild` script uses `-with-deps` which is invalid in ReScript v12; use `npx rescript clean && npx rescript build` instead

**Phase 1 — In-memory adapter improvements: ✅ COMPLETE**
- [x] Replace `handlerRef: ref<option<handler>>` with `Deferred` in `RuntimeEnvironment_InMemory`
- [x] Fix `EventCollectorChannel_InMemory` subscription race with `Latch` (subscriptionLatch opens after subscription registers; `Latch.await_` replaces `await resource.name->TestRunner.resolve` in single-topic tests)
- [x] `HeartbeatRunner_InMemory` and `CommandTopicChannel_InMemory` updated to use `Deferred.await_` (no more `None` check / warning log)
- **Implementation notes:**
  - `parts` type: `{handlerDeferred: Deferred.t<handler, unit>, subscriptionLatch: Latch.t}`
  - Creation (`Deferred.make`, `Effect.makeLatch`) via `Effect.runSync` (purely synchronous)
  - Completion (`Deferred.succeed`, `Latch.open_`) via `Effect.runPromise` (fiber wake-ups are async-safe)
  - setInterval replacement with Schedule deferred to Phase 3 (requires TestClock infrastructure)
  - 353 modules compiled, zero warnings; 129/129 tests pass

**Phase 2 — Core framework: ✅ COMPLETE**
- [x] Fix `EventLog_Operations` — remove FIXME and all throw/re-throw patterns; `publishToEventTopic` now returns `result<unit, string>`; `append` switches on storage result and returns `Error` on failure — never throws
- [x] Fix `QueryDb_Operations` — `decode` returns `result<state, storageError>` (was `[state]` / `[]`); `load` sequences decode results via `Result.flatMap` accumulator; `save`/`saveBatch` propagate encode errors instead of `Console.log` + silent skip
- [x] Apply STM to `EventLogStorage_InMemory` — `ref<dict<...>>` replaced with `Stm.TRef`; `append` uses `Stm.TRef.modify->Stm.commit->Effect.runPromise`; `replay` uses `Stm.TRef.get->Stm.commit->Effect.runPromise`
- **Deferred:** Replace `InMemory_Bus` with `PubSub` / Effect Queue — requires refactoring all consumers from callback model to Queue.take model. Deferred to Phase 3: with the callback model, `publishEvent` awaits all subscribers synchronously; switching to Queue makes delivery asynchronous, which breaks existing tests that rely on immediate propagation. Requires `@effect/vitest` + `TestClock` to manage timing deterministically.
- **Build:** 353 modules, zero warnings; 129/129 tests pass

**Phase 2.5 — Namespace fix + retry: ✅ COMPLETE**
- [x] Rename `reventless-core/src/util/Schedule.res` → `ScheduleOps.res` — frees the bare `Schedule` name for rescript-effect
- [x] Update 4 callers inside reventless-core: `ExtensionPoint_Operations.res`, `ExtensionPoint_Callback.res`, `SideEffectHandler_Builder.res`, `PluginExtensionPoint_Plugin.res` (`Schedule.*` → `ScheduleOps.*`)
- [x] Add `@reventlessdev/rescript-effect` to `reventless-core` `rescript.json` + `package.json`
- [x] Add `Effect.retry` to `EventLog_Operations.res`:
  - `isTransient` predicate (ThrottlingException, ProvisionedThroughputExceededException, ServiceUnavailable, RequestLimitExceeded, InternalServerError)
  - `storageRetrySchedule`: `exponential(100ms) -> jittered -> intersect(recurs(5)) -> whileInput(isTransient)`
  - `append` wraps storage call in `Effect.tryPromise -> flatMap (Ok→succeed / Error→fail) -> retry(schedule)`, runs with `Effect.runPromiseExit`, branches on `Exit.isSuccess`
  - `exitCausePayload<'e>` type at module scope for safe cause extraction via `Obj.magic`
- **Implementation notes:**
  - `Schedule.recurs(5)` creates a standalone schedule (not a modifier) — compose via `Schedule.intersect(expBackoff, recurs(5))`, not pipe
  - Top-level schedule value needs explicit type annotation `Schedule.t<(Duration.t, int), string, unit>` to resolve value restriction weak type variable
  - `Exit.toOption` returns Effect's tagged Option (not ReScript option) — use `Exit.isSuccess` + `Obj.magic` cast to `exitCausePayload` for safe branching and cause extraction
  - `Effect.either` also returns Effect's Either, not ReScript result — do not use for bridging
  - **Build:** 615 modules, zero warnings; 172/172 reventless-core + 129/129 reventless-in-memory tests pass

**Phase 3 — Test infrastructure: ✅ COMPLETE**
- [x] Add `TestClock.res` bindings: `adjust(duration)`, `currentTimeMillis` (both at `@module("effect") @scope("TestClock")`)
- [x] Add `TestContext.res` bindings: abstract `layer` type, `testContext` Layer value (`@scope("TestContext") external testContext = "TestContext"`)
- [x] Add `Effect.provide` and `Effect.yieldNow` to `Effect.res`
- [x] Add `AsyncTest.testPromiseWithTimeout` for tests requiring custom Jest timeouts
- [x] Extend `EventLogFixtures` with counter-based mocks: `failNextAppendsWithTransient: ref<int>`, `appendCallCount: ref<int>`
- [x] Write `EventLogRetryTest.res` — 13 tests verifying retry behavior:
  - `isTransient` predicate (7 tests): ThrottlingException, ProvisionedThroughputExceededException, ServiceUnavailable, RequestLimitExceeded, InternalServerError are transient; ValidationException and generic failures are not
  - Permanent failure (2 tests): returns Error immediately, no publish, exactly 1 storage call
  - Transient failure retry (3 tests): 1 failure → 2 calls → Ok; events stored+published; 2 failures → 3 calls → Ok
  - Retry exhaustion (1 test): 6 transient failures exhaust 5 retries → Error, no publish, exactly 6 storage calls (12s timeout)
- **Deferred:** Replace `InMemory_Bus` event delivery with Effect Queue — `Ops.append` runs Effect internally via `Effect.runPromiseExit` (creates its own runtime), so `Effect.provide(TestContext)` from outside cannot inject TestClock into those retry sleeps. Queue replacement requires refactoring `append` to expose an Effect (rather than a promise) or using a different concurrency approach. Deferred to Phase 4.
- **Build:** 196 modules, zero warnings; 185/185 tests pass (13 new retry tests)
- **Implementation notes:**
  - `TC.adjust` is a function, `TC.currentTimeMillis` is a value (Effect object) — bind accordingly
  - `TestContext.TestContext` (capital T) is the Layer; `testContext` is the binding name in ReScript
  - `Effect.provide` is typed as `('layer) => t<'a, 'e, unit>` — polymorphic layer type, unit requirements after providing
  - `Effect.yieldNow` is a function `(unit) => Effect.t<unit,'e,'r>` in Effect v3 (takes options? object — bind as unit)
  - Retry exhaustion test takes ~3100ms (real time, no TestClock) — 12s timeout gives 2× headroom above jitter ceiling
  - Using TestClock for retry delays requires `append` to return `Effect.t` instead of `promise` — architectural change deferred

**Phase 4 — Streaming and future (evaluate when Phases 1–3 are complete):**
- [ ] Evaluate `Stream`-based `EventLog.replay` for large aggregate support
- [ ] Evaluate `Effect.Schema` migration (assess scope vs. benefit)
- [ ] Track `@effect/workflow` and `@effect/cluster` maturity for future architectural decisions

---

## References

- [Effect Documentation](https://effect.website/docs/getting-started/introduction/)
- [Effect GitHub](https://github.com/Effect-TS/effect)
- [@effect/cluster](https://effect-ts.github.io/effect/docs/cluster)
- [@effect/workflow on npm](https://www.npmjs.com/package/@effect/workflow)
- [@effect/ai Introduction](https://effect.website/docs/ai/introduction/)
- [Effect 3.0 Release](https://effect.website/blog/releases/effect/30/)
