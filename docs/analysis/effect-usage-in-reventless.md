# Effect Usage in Reventless — Comprehensive Analysis

**Created:** 2026-03-08

**Related analyses:**
- `effect-requirements-type-analysis.md` — deep dive on the `'r` parameter
- `effect-retry-error-handling-migration.md` — migration of manual retries to Effect
- `effect-services-beyond-logging.md` — candidate Effect services
- `stream-based-runtime-handler-analysis.md` — streaming handler patterns
- `logging-harmonization.md` — unified logging via Effect Logger

---

## Table of Contents

1. [What Is Effect and Why Reventless Uses It](#1-what-is-effect-and-why-reventless-uses-it)
2. [Already Supported: Effect Features in Reventless](#2-already-supported-effect-features-in-reventless)
3. [TypeScript vs ReScript: Key Differences](#3-typescript-vs-rescript-key-differences)
4. [Effect Features That Do Not Make Sense for Reventless](#4-effect-features-that-do-not-make-sense-for-reventless)
5. [New Effect Features Worth Supporting](#5-new-effect-features-worth-supporting)
6. [Untapped Opportunities from Existing Bindings](#6-untapped-opportunities-from-existing-bindings)
7. [Marketing and Explaining Effect in Reventless](#7-marketing-and-explaining-effect-in-reventless)
8. [Effect v4: What Changes](#8-effect-v4-what-changes)
9. [Making the Bindings More ReScript-Idiomatic](#9-making-the-bindings-more-rescript-idiomatic)
10. [Test Coverage Analysis](#10-test-coverage-analysis)

---

## 1. What Is Effect and Why Reventless Uses It

[Effect](https://effect.website/) is a TypeScript library for building robust applications with
typed errors, structured concurrency, dependency injection, streams, and composable retry/scheduling
policies. It is fundamentally a **runtime for structured side effects** — every operation is
described as a lazy, composable `Effect<Success, Error, Requirements>` value that is only executed
when explicitly run.

Reventless uses Effect because event-sourced CQRS systems face exactly the problems Effect solves:

| Problem in Event Sourcing | Effect Solution |
|---------------------------|-----------------|
| Transient storage failures (DynamoDB throttling) | `Effect.retry` + `Schedule` (exponential backoff, jitter) |
| Fan-out to multiple subscribers | `PubSub` + `Stream.fromQueue` + `Fiber` |
| Lazy paginated event replay | `Stream.paginateEffect` |
| Ordered, backpressure-aware processing | `Queue` (bounded/unbounded) + `Stream.runForEach` |
| Deterministic time in tests | `TestClock.adjust` + `TestContext` |
| Resource-safe cleanup | `Effect.scoped` + `acquireRelease` |
| Concurrent handler execution | `Effect.all` with concurrency control |
| Structured logging | `Effect.logInfo` / `Effect.logError` |

The Effect library replaces hand-rolled retry loops, ad-hoc promise combinators, and mutable state
synchronization with composable, type-safe abstractions.

---

## 2. Already Supported: Effect Features in Reventless

### 2.1 ReScript Bindings (`@reventlessdev/rescript-effect`)

The `rescript-effect` package provides bindings for **19 Effect modules** (14 with test coverage):

| Module | Binding File | Purpose | Used In Framework |
|--------|-------------|---------|-------------------|
| **Effect** | `Effect.res` (523 lines) | Core type, construction, transformation, error handling, retry, concurrency, DI, logging, execution | Everywhere |
| **Stream** | `Stream.res` (242 lines) | Lazy sequences, pagination, mapping, folding, draining | EventLog replay, DynamoDB queries, CSV parsing, Bus fan-out, QueryEngine |
| **Schedule** | `Schedule.res` (144 lines) | Retry/repeat policies | DynamoDB, SQS, SNS, Kinesis, EventLog retries |
| **Queue** | `Queue.res` (90 lines) | Concurrent FIFO queues | CSV stream bridging, Bus internals |
| **PubSub** | `PubSub.res` (92 lines) | Broadcast fan-out hubs | InMemory_Bus event distribution |
| **Fiber** | `Fiber.res` (60 lines) | Lightweight virtual threads | Bus drain loops, test orchestration |
| **Deferred** | `Deferred.res` (64 lines) | One-time synchronization | Bus publish completion signaling |
| **Ref** | `Ref.res` (50 lines) | Concurrent-safe mutable references | Bound, not yet used in framework |
| **SynchronizedRef** | `SynchronizedRef.res` (56 lines) | Atomic effectful updates | Bound, not yet used in framework |
| **Stm** | `Stm.res` (116 lines) | Software Transactional Memory | Bound, not yet used in framework |
| **Context** | `Context.res` (42 lines) | Typed service tags | EffectLogger service injection |
| **Layer** | `Layer.res` (67 lines) | Service construction blueprints | Logger provision at dispatch |
| **Latch** | `Latch.res` (44 lines) | Binary synchronization gate | Bound, not yet used in framework |
| **Duration** | `Duration.res` (32 lines) | Time intervals | Schedule definitions, sleep, timeout |
| **Cause** | `Cause.res` (78 lines) | Failure structure algebra | EventLog error extraction after retry |
| **Exit** | `Exit.res` (92 lines) | Fiber completion result | runPromiseExit, Queue shutdown safety |
| **EffectOption** | `EffectOption.res` (8 lines) | Effect Option ↔ ReScript option | Internal conversion layer |
| **TestClock** | `TestClock.res` (48 lines) | Virtual clock for testing | Test suites with time-dependent logic |
| **TestContext** | `TestContext.res` (30 lines) | Test service layer | Providing TestClock in tests |

### 2.2 Usage Patterns Across the Framework

#### Pattern 1: Typed Retry with Exponential Backoff

The most impactful pattern — replaces 15+ hand-rolled retry functions. Each AWS service has a
dedicated error module with a composed schedule:

```rescript
// DynamoDb_Error.res
let retrySchedule =
  Schedule.exponential(Duration.millis(500))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(5))
  ->Schedule.whileInput(isTransient)

// Usage in Util_DynamoDb_Runtime.res
Effect.tryPromise(~catch=DynamoDb_Error.classify, () => table->put(item))
->Effect.retry(DynamoDb_Error.retrySchedule)
->Effect.catchAll(err => Effect.logError(msg)->Effect.map(_ => Error(msg)))
->Effect.runPromise
```

**Where used:** DynamoDB (5 error modules), SQS, SNS, Kinesis, Cognito, EventLog storage.

#### Pattern 2: PubSub + Stream Fan-Out (InMemory Bus)

The entire in-memory event distribution system is built on Effect:

```rescript
// Subscribe: PubSub.subscribe → Stream.fromQueue → Stream.runForEach → Effect.scoped → Effect.runFork
let drainLoop = Effect.scoped(
  PubSub.subscribe(hub)->Effect.flatMap(queue =>
    Stream.fromQueue(queue)->Stream.runForEach(msg =>
      Effect.promise(() => handler(msg.service, msg.meta, msg.json))
      ->Effect.zipRight(msg.done_)
    )
  ))
let _ = Effect.runFork(drainLoop)

// Publish: countdown Deferred for completion signaling across N subscribers
let allDone = Deferred.make()->Effect.runSync
PubSub.publish(hub, msg)->Effect.flatMap(_ => Deferred.await_(allDone))->Effect.runPromise
```

**Key properties:** Bounded queues provide backpressure. Unbounded gives 2-tick delivery.
`PubSub.shutdown` cleanly terminates all drain fibers via `Stream.fromQueue` interruption.

#### Pattern 3: Lazy Paginated Streams

DynamoDB queries return paginated results. `Stream.paginateEffect` makes pagination lazy and
composable:

```rescript
let queryStream = (params): Stream.t<JSON.t, DynamoDb_Error.t, unit> =>
  Stream.paginateEffect(None, cursor =>
    Effect.tryPromise(~catch=DynamoDb_Error.classify, () =>
      QueryCommand.send({...params, exclusiveStartKey: cursor})
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.map(res => (res.items, res.lastEvaluatedKey))
  )
```

**Where used:** DynamoDB event log replay, DCB event log read, QueryDb scan. Each page fetch
retries independently; consumers take only what they need via `Stream.take(limit)`.

#### Pattern 4: Callback-to-Stream Bridging

Node.js callback APIs (CSV parser, readable streams) are bridged to Effect Streams via Queues:

```rescript
// CsvStream.res
Queue.unbounded()->Effect.flatMap(queue => {
  let _ = CSV.parseFile(~path)
    ->CSV.onData(row => Queue.offer(queue, Ok(row))->Effect.runSyncExit->ignore)
    ->CSV.onEnd(_ => Queue.shutdown(queue)->Effect.runSyncExit->ignore)
  Effect.succeed(queue)
})
->Stream.fromEffect->Stream.flatMap(q => Stream.fromQueue(q)->Stream.mapEffect(validate))
```

#### Pattern 5: Concurrent Handler Execution

Multiple event handlers are executed concurrently with `Effect.all`:

```rescript
// Core_Callback.res
Effect.all(
  Spec.outgoingExtensionPointJsonEventsHandlers->Array.map(h =>
    Effect.promise(() => h(eventJson', Spec.pluginDefinition))
  ),
  {"concurrency": "unbounded"},
)->Effect.map(_ => ())
```

#### Pattern 6: Effect Service Injection

The EffectLogger service is provided at dispatch boundaries:

```rescript
// At dispatch
effect
->Effect.provideService(EffectLogger.tag, EffectLogger.consoleLogger)
->Effect.runPromise

// In callback
Effect.serviceWith(EffectLogger.tag, logger => logger.info("handling command"))
```

#### Pattern 7: Deterministic Time Testing

`TestClock` + `TestContext` enable time-dependent tests without real waiting:

```rescript
Effect.sleep(Duration.minutes(5))
->Effect.fork->Effect.flatMap(fiber =>
  TestClock.adjust(Duration.minutes(5))
  ->Effect.zipRight(Fiber.join(fiber))
)
->Effect.provide(TestContext.testContext)
->Effect.runPromise
```

#### Pattern 8: Structured Logging

Effect's built-in logging is used throughout for diagnostics:

```rescript
Effect.logInfo(`CommandPublisher.send: bufferSize: ${bufferSizeStr}, chunk: ${chunkCountStr}`)
->Effect.runSync
```

### 2.3 Packages Using Effect

| Package | Dependency | Usage Level |
|---------|-----------|-------------|
| `reventless-core` | `@reventlessdev/rescript-effect` | Heavy — retry, streams, logging, concurrency |
| `reventless-aws` | `@reventlessdev/rescript-effect` | Heavy — all AWS adapter retry/error handling |
| `reventless-local` | `@reventlessdev/rescript-effect` | Very heavy — entire Bus, streams, fibers |
| `reventless-infra` | `@reventlessdev/rescript-effect` | Type signatures only — Stream/Effect in specs |

---

## 3. TypeScript vs ReScript: Key Differences

### 3.1 Generator Syntax vs Pipe Chains

The most significant ergonomic difference. TypeScript Effect code reads like imperative code:

```typescript
// TypeScript — linear, imperative-looking
const program = Effect.gen(function* () {
  const user = yield* fetchUser(id)
  const posts = yield* fetchPosts(user.id)
  yield* logger.info(`Found ${posts.length} posts`)
  return posts
})
```

ReScript must use explicit pipe chains:

```rescript
// ReScript — functional composition via pipes
let program =
  fetchUser(id)
  ->Effect.flatMap(user => fetchPosts(user.id))
  ->Effect.tap(posts =>
    Effect.logInfo(`Found ${posts->Array.length->Int.toString} posts`)
  )
```

**Impact:** ReScript code is slightly more verbose for sequential operations. However, ReScript's
pipe-first operator (`->`) makes the composition natural and readable. For data transformation
pipelines (map, filter, flatMap), the difference is negligible.

### 3.2 Requirements Type (`'r`) Safety

TypeScript enforces at compile time that all service requirements are satisfied:

```typescript
// TypeScript — won't compile: R = Logger, not never
const program: Effect<string, never, Logger> = ...
Effect.runPromise(program) // ✗ Type error: Logger is not never
```

ReScript uses `unit` for the requirements parameter — `runPromise` accepts any `'r`:

```rescript
// ReScript — compiles fine even with unsatisfied requirements
let program: Effect.t<string, unit, Logger.t> = ...
program->Effect.runPromise // ✓ No type error (unit vs Logger.t not enforced)
```

**Impact:** The type-level safety guarantee is opt-in, not enforced. This is a pragmatic tradeoff —
ReScript's type system lacks intersection types needed for `R` parameter composition.

### 3.3 Tag Declaration

TypeScript uses class syntax for creating service tags:

```typescript
class Logger extends Context.Tag("MyApp/Logger")<
  Logger, { readonly log: (msg: string) => Effect<void> }
>() {}
```

ReScript uses `Context.genericTag` with a string key:

```rescript
let tag: Context.tag<t> = Context.genericTag("MyApp/Logger")
```

**Impact:** Both work at runtime. The TypeScript syntax is more ergonomic for pattern matching on
tags but more verbose to declare.

### 3.4 Pattern Matching on Errors

TypeScript uses tagged unions with `_tag` fields:

```typescript
class NotFound extends Data.TaggedError("NotFound")<{ id: string }> {}
class Unauthorized extends Data.TaggedError("Unauthorized")<{}> {}

effect.pipe(Effect.catchTag("NotFound", (e) => ...))
```

ReScript uses native pattern matching on variants:

```rescript
type error = NotFound({id: string}) | Unauthorized

effect->Effect.catchAll(err => switch err {
  | NotFound({id}) => ...
  | Unauthorized => ...
})
```

**Impact:** ReScript's native pattern matching is more natural and exhaustive. `Effect.catchTag`
works in ReScript bindings but is less idiomatic than a full `switch`.

### 3.5 Layer Composition

TypeScript has `Layer.merge` for combining layers side-by-side:

```typescript
const AppLayer = Layer.merge(LoggerLive, DatabaseLive)
```

ReScript bindings note `Layer.merge` as "not bound" because ReScript lacks intersection types.
The workaround is calling `Effect.provideService` multiple times:

```rescript
effect
->Effect.provideService(Logger.tag, loggerImpl)
->Effect.provideService(Database.tag, dbImpl)
->Effect.runPromise
```

**Impact:** Works, but slightly more verbose. For Reventless's use case (providing 3-5 services
at the dispatch boundary), this is acceptable.

### 3.6 Schema Integration

TypeScript Effect includes `Schema` for validation and encoding:

```typescript
import { Schema } from "effect"
const User = Schema.Struct({ name: Schema.String, age: Schema.Number })
```

Reventless uses `sury-ppx` (the `@schema` attribute) for the same purpose — schema generation
from ReScript types. There is no need to bind Effect Schema because sury-ppx is more idiomatic
and already deeply integrated.

---

## 4. Effect Features That Do Not Make Sense for Reventless

### 4.1 Effect Schema

**Why not:** Reventless already uses `sury-ppx` for schema generation, which is deeply integrated
into the ReScript type system via the `@schema` attribute. Binding Effect Schema would create
a parallel, competing serialization system with no benefit.

### 4.2 Effect Platform (HttpClient, FileSystem, KeyValueStore, Worker, Terminal)

**Why not:** These are platform-abstraction modules designed for TypeScript applications that need
to run on Node.js, Bun, and the browser. Reventless runs exclusively on AWS Lambda (Node.js). The
framework has its own platform abstraction layer (`reventless-aws`, `reventless-local`) that
maps to the actual deployment targets. Effect Platform would be an abstraction layer on top of
another abstraction layer.

### 4.3 Effect RPC

**Why not:** Reventless's inter-component communication is already defined by its own protocol —
commands published via SQS/SNS, events distributed via EventTopic, queries via QueryDb. These are
domain-specific message types with sury-ppx schemas. Effect RPC would impose a different wire
format and routing convention with no clear benefit.

### 4.4 Effect SQL / Effect Postgres / Effect MySQL

**Why not:** Reventless uses DynamoDB as its primary storage, not relational databases. The
framework's storage adapters (EventLog, QueryDb) already abstract the DynamoDB API. Adding SQL
bindings would serve a niche that Reventless doesn't target.

### 4.5 Effect CLI

**Why not:** Reventless is a serverless framework — it has no CLI user interface. The
`reventless-gen` code generator is a build tool, not an interactive CLI application.

### 4.6 Effect Cluster (Sharding, Singleton)

**Why not:** Reventless runs on AWS Lambda, which is inherently stateless. Cluster primitives like
sharding and singleton processes are for long-running server applications.

### 4.7 Effect AI

**Why not:** Reventless is an event-sourcing framework, not an AI application framework. AI
integration would be a downstream application concern, not a framework feature.

### 4.8 Effect Match (Pattern Matching)

**Why not:** ReScript has native pattern matching with `switch` expressions, which is more
powerful and ergonomic than Effect's runtime pattern matching. This is one area where ReScript
has a clear advantage over TypeScript.

---

## 5. New Effect Features Worth Supporting

### 5.1 Metrics / Telemetry Service (High Value)

Effect has built-in metrics support (Counter, Gauge, Histogram, Timer) with OpenTelemetry export.
Reventless currently has **no structured metrics collection** — observability is limited to log
scraping.

**What it could provide:**
- Count commands processed per aggregate
- Measure EventLog replay duration
- Track DynamoDB throttling rates
- Histogram of handler execution times
- All silenceable in tests, swappable between providers

**Binding effort:** Medium — define `Metric.Counter`, `Metric.Histogram`, `Metric.Timer` types
and their `increment`/`observe`/`record` operations.

**Framework integration:** Provide via `Effect.provideService` at the dispatch boundary, alongside
Logger and RequestContext.

### 5.2 Config Service (Medium Value)

Effect's `Config` module reads typed configuration from environment variables with validation,
defaults, and nesting — replacing ad-hoc `Env.get("VAR")` calls.

**What it could provide:**
- Typed configuration with validation at startup
- Default values and required/optional semantics
- Nested configuration for complex setups
- Test overrides without environment variable manipulation

**Binding effort:** Low-medium — `Config.string`, `Config.number`, `Config.boolean`,
`Config.withDefault`, `Config.nested`.

**Caveat:** Most Reventless configuration is resolved at deploy time via Pulumi. Runtime config
is limited to environment variables set by Pulumi. The value is primarily in **validation and
type safety** of those environment variables at Lambda cold start.

### 5.3 Durable Workflows (`@effect/workflow`) (Future, High Value)

Effect v4 introduces alpha-stage durable workflow support — long-running, resumable business
processes that survive process restarts.

**What it could provide for Reventless:**
- Saga orchestration across aggregates
- Multi-step business processes with compensation
- Timeout-based escalation workflows
- Human-in-the-loop approval flows

**Binding effort:** High — alpha API, may change substantially.

**Relevance:** Reventless already has the `Scheduler` and `Task` components for deferred work.
Durable workflows could replace or complement these with a more composable programming model.
Worth monitoring but not binding until the API stabilizes.

### 5.4 Cron Scheduling (Low-Medium Value)

Effect has `Cron` for calendar-based scheduling expressions.

**What it could provide:**
- Typed cron expressions for the Scheduler component
- Timezone-aware schedule definitions
- Integration with `Schedule` for hybrid fixed-interval + calendar scheduling

**Binding effort:** Low — small API surface.

### 5.5 Effect.gen via Async/Await Emulation (Ergonomic)

While ReScript lacks generators, the async/await syntax combined with Effect could provide
a middle ground. Some community efforts explore using ReScript's `async/await` to sequence
Effects more ergonomically.

**Current limitation:** ReScript's `async/await` works with `promise<'a>`, not `Effect.t<'a, 'e, 'r>`.
Bridging requires wrapping each step in `Effect.runPromise`, which loses the lazy composition
benefit.

**Alternative:** A `do` notation PPX for Effect (similar to what exists in OCaml for monads)
could provide the ergonomic improvement without losing composability. This is not available today
but is a potential future direction for the ReScript Effect integration.

---

## 6. Untapped Opportunities from Existing Bindings

Several bound modules are not yet used in the framework. These represent opportunities to improve
existing code without adding new bindings.

### 6.1 Ref / SynchronizedRef — Replace Mutable `ref<'a>` State

**Current state:** The InMemory Bus and other modules use plain ReScript `ref<dict<...>>` for
mutable state, which is not fiber-safe.

**Opportunity:** Replace with `Ref.t<dict<...>>` for concurrent-safe reads/writes, or
`SynchronizedRef.t` when updates depend on async operations.

**Example:**
```rescript
// Current (not fiber-safe)
let subscriberCounts: ref<dict<int>> = ref(Dict.make())
subscriberCounts.contents->Dict.set(topicName, n + 1)

// With Ref (fiber-safe)
let subscriberCounts: Ref.t<dict<int>> = Ref.make(Dict.make())->Effect.runSync
subscriberCounts->Ref.update(d => { d->Dict.set(topicName, n + 1); d })
```

**Value:** Low in practice — the InMemory Bus runs single-threaded (Node.js event loop), so
fiber safety isn't strictly required. However, it would make the code more robust and serve as
documentation of intent.

### 6.2 STM — Atomic Multi-Variable Transactions

**Current state:** Not used anywhere. Bound with full TRef CRUD operations.

**Opportunity:** STM is most valuable when multiple variables must be updated atomically without
explicit locks. Potential use cases:
- Atomic subscriber count increment + hub creation in InMemory Bus
- Consistent snapshot reads across multiple QueryDb entries
- Multi-aggregate command validation

**Value:** Low-medium for the current single-threaded runtime. Would become high-value if
Reventless ever supports multi-threaded execution (e.g., via Node.js worker threads).

### 6.3 Latch — Synchronization Gates

**Current state:** Not used in the framework. Bound with await/open/close operations.

**Opportunity:** Replace manual `Deferred.make()` + `Deferred.succeed()` patterns where the
intent is "wait until setup is complete, then proceed":
- Wait for all component builders to complete before starting the platform
- Gate test execution until all subscriptions are registered

**Value:** Low — Deferred already serves this purpose. Latch adds re-closability which is rarely
needed.

### 6.4 Effect.timeout — Protect Against Slow Operations

**Current state:** No timeout protection on any AWS operations. If DynamoDB or SQS hangs, the
Lambda invocation runs until the Lambda timeout (default 15 minutes), wasting billing time.

**Opportunity:** Wrap critical operations with `Effect.timeout`:

```rescript
Effect.tryPromise(~catch=classify, () => ddb->put(item))
->Effect.timeout(Duration.seconds(10))
->Effect.flatMap(opt => switch opt {
  | Some(result) => Effect.succeed(result)
  | None => Effect.fail(TimeoutError("DynamoDB put timed out"))
})
```

**Value:** High for production robustness. Prevents silent hang-forever failure modes.

### 6.5 Effect.race — First-to-Succeed Patterns

**Current state:** Not used. Bound in Effect.res.

**Opportunity:** For operations with fallback strategies:
- Race a primary DynamoDB query against a cache lookup
- Race multiple read replicas and use the first response

**Value:** Low — Reventless's single-region DynamoDB architecture doesn't typically need racing.

### 6.6 Effect.ensuring — Guaranteed Cleanup

**Current state:** Bound but not used in application code (only internally in Stream).

**Opportunity:** Resource cleanup that must run regardless of success/failure:
- Release temporary S3 objects after processing
- Clean up DynamoDB TTL markers
- Close SSH connections in the SSH2 adapter

**Value:** Medium — currently handled by try/finally or not at all.

### 6.7 Stream.grouped — Batch Processing

**Current state:** Bound but not used.

**Opportunity:** Process events in fixed-size batches for efficiency:

```rescript
eventStream
->Stream.grouped(25) // DynamoDB BatchWriteItem limit
->Stream.mapEffect(batch => batchWrite(batch))
```

**Value:** Medium — useful for bulk import/migration scenarios.

---

## 7. Marketing and Explaining Effect in Reventless

### 7.1 The Elevator Pitch

> Reventless uses Effect as its **operational runtime** — the layer that makes your event-sourced
> system resilient, observable, and testable. Effect handles the hard parts of distributed
> infrastructure (retries, timeouts, backpressure, concurrency) so your domain code stays clean.

### 7.2 Key Messages for Different Audiences

**For developers evaluating Reventless:**

> "You write business logic. Effect handles the infrastructure plumbing."
>
> When your aggregate command handler saves events to DynamoDB and DynamoDB throttles —
> Reventless automatically retries with exponential backoff and jitter. When your read model
> needs to process a million events — Reventless streams them lazily, one page at a time,
> without loading them all into memory. When your test needs to simulate time passing —
> Reventless gives you a virtual clock that advances instantly.
>
> All of this is powered by Effect, the same library used in production by companies building
> TypeScript applications at scale.

**For TypeScript/Effect developers:**

> "If you already know Effect, Reventless is a natural fit."
>
> Reventless's ReScript codebase uses the same Effect primitives you know: `Effect.tryPromise`,
> `Schedule.exponential`, `Stream.paginateEffect`, `PubSub`, `Fiber`, `Deferred`. The ReScript
> bindings map 1:1 to the TypeScript API. Your mental model transfers directly.
>
> Where Reventless adds value is at the **framework level** — it composes these Effect primitives
> into a complete event-sourced CQRS system with aggregates, read models, plugins, and
> deploy-time infrastructure via Pulumi.

**For event sourcing practitioners:**

> "Built-in resilience for event-sourced infrastructure."
>
> Event-sourced systems have specific operational challenges: event log append failures, event
> topic fan-out delivery, read model projection backpressure, and event replay pagination.
> Reventless solves each with a dedicated Effect pattern:
>
> - **Append failures** → `Effect.retry` with typed error classification
> - **Fan-out delivery** → `PubSub` + `Stream` with completion signaling
> - **Backpressure** → Bounded queues with fiber-level suspension
> - **Replay** → `Stream.paginateEffect` with per-page retry

### 7.3 Concrete Examples for Documentation

**Example 1: "How Reventless retries DynamoDB operations"**

```
Your command → Aggregate → EventLog.append
                               ↓
                     DynamoDB PutItem fails (throttled)
                               ↓
                     Effect retries: 500ms → 1s → 2s → 4s → 8s (with jitter)
                               ↓
                     Success on retry 3 → events published
```

No user code needed. The retry policy is configured once in the error module and applies
automatically to every DynamoDB operation.

**Example 2: "How Reventless distributes events to read models"**

```
Aggregate publishes events
       ↓
  PubSub hub (unbounded or bounded)
       ↓                    ↓
  ReadModel A fiber    ReadModel B fiber
  (Stream.fromQueue)   (Stream.fromQueue)
       ↓                    ↓
  handler(event)       handler(event)
       ↓                    ↓
  done_ signal         done_ signal
       ↓
  Deferred.await_ resolves → publish returns
```

All subscribers process concurrently. The publisher waits until ALL subscribers complete
before returning — guaranteeing delivery.

**Example 3: "How Reventless tests time-dependent behavior"**

```rescript
// The system under test uses Effect.sleep for a 5-minute heartbeat
let heartbeat = Effect.sleep(Duration.minutes(5))->Effect.zipRight(sendPing())

// The test advances virtual time instantly
let test =
  heartbeat->Effect.fork->Effect.flatMap(fiber =>
    TestClock.adjust(Duration.minutes(5))  // instant, no real waiting
    ->Effect.zipRight(Fiber.join(fiber))
  )
  ->Effect.provide(TestContext.testContext)
  ->Effect.runPromise
```

### 7.4 Positioning vs Alternatives

| Comparison | Reventless + Effect | Alternative Approach |
|------------|--------------------|--------------------|
| Retry logic | Composable schedules: exponential, jittered, conditional | Hand-rolled recursive loops with hardcoded delays |
| Fan-out | PubSub + Stream with backpressure | `Promise.all` with no concurrency control |
| Pagination | Lazy `Stream.paginateEffect` with per-page retry | Eager `while` loop loading all pages into memory |
| Testing time | `TestClock.adjust` (instant, deterministic) | `setTimeout` with real delays (slow, flaky) |
| Error handling | Typed error channel with `catchAll`/`catchTag` | `try/catch` with string error messages |
| Resource cleanup | `acquireRelease` + `scoped` (guaranteed) | `try/finally` (easy to forget) |

---

## 8. Effect v4: What Changes

### 8.1 Overview

Effect v4 is currently in **beta** (as of March 2026). It is planned as a **long-term stable
(LTS)** release with infrequent major versions. For production systems, v3 remains the
recommended choice until v4 stabilizes.

### 8.2 Key Changes

| Change | Impact on Reventless |
|--------|---------------------|
| **Runtime rewrite** — lower memory overhead, faster execution | Positive — automatic performance improvement when upgrading |
| **Bundle size reduction** — ~70 kB (v3) → ~20 kB (v4) | Positive — smaller Lambda cold start times |
| **Unified versioning** — all ecosystem packages share one version number | Simplifies dependency management in `rescript-effect` |
| **Consolidated core** — `@effect/platform`, `@effect/rpc`, `@effect/cluster` merged into `effect` | Neutral — Reventless only imports from `effect` already |
| **Unstable modules** — 17 modules under `effect/unstable/*` | Potential new features (workflows, AI, SQL) accessible via future bindings |
| **API changes** — some renames, error class changes, Schema class changes | **Requires binding updates** — each `@module("effect")` binding must be verified |

### 8.3 Migration Impact on rescript-effect

The rescript-effect bindings use `@module("effect") @scope("ModuleName")` externals throughout.
Migration to v4 requires:

1. **Audit all 19 binding files** for renamed or removed functions
2. **Update `@scope` annotations** if module paths change (e.g., merged packages)
3. **Test all 14 test files** against the v4 runtime
4. **Update the `effect` dependency** from `^3.17.0` to `^4.0.0`

**Estimated effort:** Medium. The core programming model (Effect, Layer, Stream, Schedule) is
unchanged. Changes are organizational and in specific API details.

### 8.4 New v4 Features to Consider Binding

| Feature | v4 Status | Relevance to Reventless |
|---------|-----------|------------------------|
| Durable Workflows (`@effect/workflow`) | Alpha, unstable | High — saga orchestration, compensation |
| Improved Schema integration | Stable | None — Reventless uses sury-ppx |
| Unified HTTP client | Stable | Low — Reventless uses AWS SDK directly |
| Cron module improvements | Stable | Medium — Scheduler component |
| Runtime performance | Transparent | High — automatic benefit |
| Bundle size reduction | Transparent | High — Lambda cold starts |

### 8.5 Recommended Upgrade Strategy

1. **Wait for v4 stable release** — do not migrate to beta in production
2. **Create a v4 branch** of `rescript-effect` when v4 RC ships
3. **Run all 14 test files** against v4 to identify breaking changes
4. **Fix binding adjustments** (expected to be mechanical renames)
5. **Test framework integration** with `reventless-core`, `reventless-aws`, `reventless-local`
6. **Ship after v4 reaches LTS** status

The upgrade should be low-risk because:
- Reventless uses Effect's **stable core API** (Effect, Stream, Schedule, PubSub, Queue, Fiber)
- No usage of unstable or experimental modules
- The binding pattern (`@module("effect") @scope(...)`) is resilient to internal reorganization
  as long as the public API surface is maintained

---

## 9. Summary

### What Effect provides to Reventless today

- **Resilient infrastructure** — every AWS operation retries with typed error classification
- **Structured concurrency** — PubSub fan-out with backpressure and completion signaling
- **Lazy streaming** — paginated event replay without memory pressure
- **Testable time** — virtual clock for deterministic time-dependent tests
- **Service injection** — Logger and future services provided at dispatch boundaries
- **Composable logging** — structured log output through Effect's log functions

### What to add next

1. **Metrics service** — production observability (highest unfilled gap)
2. **Effect.timeout** — protect against hanging AWS operations
3. **Complete retry migration** — replace remaining hand-rolled retries in AWS adapters
4. **Config service** — typed environment variable access with validation
5. **Monitor Effect v4** — prepare bindings migration when v4 reaches LTS

### What to avoid

- Effect Schema (sury-ppx is the right choice for ReScript)
- Effect Platform / HttpClient (Reventless has its own adapter layer)
- Effect RPC / SQL / Cluster (wrong deployment model for serverless)
- Effect AI / CLI / Match (unrelated to framework concerns)

---

## 9. Making the Bindings More ReScript-Idiomatic

The current bindings are faithful 1:1 mappings of the Effect TypeScript API. This is a good
foundation, but several opportunities exist to make them feel more natural to ReScript developers.

### 9.1 Pipe-First Consistency

**Current state:** All bindings already use pipe-first (`->`) order, which is correct. The main
Effect module functions take `t<'a, 'e, 'r>` as the first parameter:

```rescript
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"
// Used as: effect->Effect.map(x => x + 1) ✓
```

**Assessment:** This is already idiomatic. No changes needed for pipe-first ordering.

### 9.2 Labeled Arguments for Multi-Parameter Functions

**Current state:** Functions with multiple non-obvious parameters use positional arguments:

```rescript
external acquireRelease: (
  t<'a, 'e, 'r>,
  ('a, Exit.t<'b, 'e2>) => t<unit, 'e3, 'r>,
) => t<'a, 'e, 'r> = "acquireRelease"
```

**Opportunity:** ReScript's labeled arguments (`~label`) make intent clearer at call sites. While
`@module` externals cannot use labeled arguments directly (they map positionally to JS), wrapper
functions can:

```rescript
// Idiomatic wrapper
let acquireRelease = (~acquire: t<'a, 'e, 'r>, ~release: ('a, Exit.t<'b, 'e2>) => t<unit, 'e3, 'r>) =>
  _acquireReleaseRaw(acquire, release)

// Call site becomes:
Effect.acquireRelease(
  ~acquire=openConnection(),
  ~release=(conn, _exit) => closeConnection(conn),
)
```

**Candidates for labeled argument wrappers:**

| Function | Current | Proposed |
|----------|---------|----------|
| `tryPromise` | Already uses `~catch` label | Already idiomatic ✓ |
| `trySync` | Already uses `~catch` label | Already idiomatic ✓ |
| `acquireRelease` | `(acquire, release)` | `(~acquire, ~release)` |
| `withPermits` | `(semaphore, int, effect)` | `(~semaphore, ~permits, effect)` |
| `provideService` | `(effect, tag, impl)` | Already pipe-friendly ✓ |
| `Exit.match` | Already uses `~onFailure, ~onSuccess` | Already idiomatic ✓ |

**Value:** Medium. The framework uses `acquireRelease` in 2-3 places. The improvement is mainly
for documentation and new code. `tryPromise` and `trySync` already demonstrate the labeled
argument pattern well.

### 9.3 `option<'a>` Return Types Instead of Effect Internal Types

**Current state:** Several bindings already convert between Effect's internal `Option` type
(a tagged object `{_tag: "Some"/"None", value?}`) and ReScript's native `option<'a>`:

```rescript
// Effect.res — already converts
let option = effect => effect->_option->map(EffectOption.toOption)

// Stream.res — already converts runHead
let runHead = stream => stream->runHeadRaw->Effect.map(effectOptionGetOrUndefined)

// Exit.res — already converts causeOption
let causeOption = exit => exit->_causeOption->EffectOption.toOption

// Fiber.res — already converts poll
let poll = fiber => fiber->_poll->Effect.map(EffectOption.toOption)
```

**Assessment:** This is already well-handled. The `EffectOption.res` module with its `toOption`
bridge is the right pattern. All public APIs return native `option<'a>`.

**One remaining issue:** `EffectOption.toOption` uses `%raw` JavaScript:

```rescript
let toOption: t<'a> => option<'a> = %raw(`
  function(opt) { return opt._tag === "Some" ? opt.value : undefined; }
`)
```

This works but is fragile — it assumes the internal `_tag` field name. The binding already also
uses `@module("effect") @scope("Option") external getOrUndefined` in Stream.res. **Recommendation:**
Standardize on `Option.getOrUndefined` (from Effect's JS module) everywhere and remove the `%raw`
implementation in `EffectOption.res`. This makes the bridge rely on Effect's public API rather
than internal structure.

### 9.4 `result<'a, 'e>` Integration with `Effect.either`

**Current state:** `Effect.either` is bound but maps to Effect's `Either<E, A>` which is
structurally compatible with ReScript's `result<'a, 'e>`:

```rescript
external either: t<'a, 'e, 'r> => t<result<'a, 'e>, 'e2, 'r> = "either"
```

**Assessment:** The type annotation claims `result<'a, 'e>` but Effect's `Either` has a different
runtime shape (`{_tag: "Right", right: value}` vs `{TAG: 0, _0: value}` for ReScript's `Ok`).

**Risk:** If anyone pattern-matches on the return value of `Effect.either`:

```rescript
let r = await effect->Effect.either->Effect.runPromise
switch r {
| Ok(v) => ...   // This may NOT work — runtime shape mismatch
| Error(e) => ...
}
```

**Recommendation:** Either:
1. Add a wrapper that converts Effect's `Either` to ReScript's `result`:
   ```rescript
   let either = effect =>
     _eitherRaw(effect)->map(either =>
       either._tag == "Right" ? Ok(either.right) : Error(either.left)
     )
   ```
2. Or document that `Effect.either` returns Effect's Either (not ReScript's result) and provide
   a separate `toResult` helper.

**Value:** High — this is a correctness issue, not just ergonomics. The current type annotation
is misleading and may cause runtime errors.

### 9.5 Module Organization: Submodules vs Flat Namespace

**Current state:** All modules are top-level files: `Effect.res`, `Stream.res`, `Queue.res`, etc.
They are imported individually: `Effect.succeed`, `Stream.fromIterable`, `Queue.take`.

**Alternative:** A single umbrella module `Effect` with submodules:

```rescript
// Hypothetical: Effect.Stream.fromIterable, Effect.Queue.take
module Effect = {
  include Effect_Core  // succeed, fail, map, flatMap...
  module Stream = Stream
  module Queue = Queue
  module Schedule = Schedule
  // ...
}
```

**Assessment:** The current flat namespace is actually more idiomatic for ReScript. ReScript
projects typically use separate modules (each file is a module). A single umbrella would require
a manual wrapper file and would break the current import pattern used across the framework.

**Recommendation:** Keep the flat namespace. It matches ReScript conventions and works well with
the `@module("effect") @scope("ModuleName")` binding pattern.

### 9.6 `ignore` Helper for Fire-and-Forget Effects

**Current state:** Fire-and-forget patterns require `->ignore` or `let _ =`:

```rescript
let _ = Effect.runFork(drainLoop)
// or
Queue.offer(queue, item)->Effect.runSyncExit->ignore
```

**Opportunity:** A dedicated `Effect.runForkIgnore` or `Effect.runSyncIgnore`:

```rescript
let runForkIgnore: t<'a, 'e, 'r> => unit = effect => { let _ = runFork(effect) }
let runSyncIgnore: t<'a, 'e, 'r> => unit = effect => { let _ = runSync(effect) }
```

**Value:** Low — `let _ =` and `->ignore` are standard ReScript patterns. Adding helpers
would diverge from the upstream API without meaningful benefit.

### 9.7 ReScript-Native Error Types via Variants

**Current state:** Error classification in the framework uses variant types:

```rescript
type ddbError = Transient(string) | Permanent(string) | StaleState(string)
```

These work with `Effect.catchAll` via switch, but not with `Effect.catchTag` (which expects
a `_tag` field on the error object).

**Opportunity:** Provide a helper that bridges ReScript variants to Effect's tagged error protocol:

```rescript
// Helper: convert a variant classifier to a tagged-error-compatible function
let tagError = (classify: unknown => 'e, tagOf: 'e => string): unknown => {"_tag": string, ...'e} =>
  err => {
    let classified = classify(err)
    {"_tag": tagOf(classified), ...classified}
  }
```

**Assessment:** This is overengineering. ReScript's `switch` with `Effect.catchAll` is more
natural and provides exhaustiveness checking. `Effect.catchTag` exists for TypeScript where
`switch` over error types is less ergonomic. In ReScript, `catchAll` + `switch` is the
idiomatic pattern and should be documented as such.

**Recommendation:** Document that `Effect.catchAll` + `switch` is the preferred ReScript pattern
for error handling, rather than trying to make `catchTag` work with ReScript variants.

### 9.8 `Effect.gen`-Like Sequential Composition

**Current state:** Sequential effectful operations require nested `flatMap`:

```rescript
Effect.succeed(1)
->Effect.flatMap(a =>
  Effect.succeed(2)->Effect.flatMap(b =>
    Effect.succeed(a + b)
  )
)
```

**Opportunity:** A `let*` syntax via PPX would be the ideal solution:

```rescript
// Hypothetical PPX
let%effect result = {
  let* a = Effect.succeed(1)
  let* b = Effect.succeed(2)
  Effect.succeed(a + b)
}
```

No such PPX exists for Effect today. The closest alternative is a `do_` helper using callbacks:

```rescript
// Sequential builder pattern
let do2 = (e1, e2, f) => e1->Effect.flatMap(a => e2->Effect.flatMap(b => f(a, b)))
let do3 = (e1, e2, e3, f) => e1->Effect.flatMap(a => e2->Effect.flatMap(b => e3->Effect.flatMap(c => f(a, b, c))))
```

**Assessment:** The pipe chain with `flatMap` is already readable for 2-3 steps. For deeper
nesting, the `do2`/`do3` helpers help but are limited. A PPX is the real solution but requires
significant investment.

**Recommendation:** For now, keep using `flatMap` chains. If the codebase develops patterns with
4+ sequential bindings, consider adding `do2`/`do3`/`do4` convenience functions. A PPX is a
longer-term community project, not something to build in-house.

### 9.9 `Stream.t` Interop with ReScript `array<'a>`

**Current state:** `Stream.fromIterable` accepts `array<'a>`, and `Stream.runCollect` returns
`array<'a>` (after the `arrayFrom` conversion wrapper). This already provides good interop.

**Opportunity:** Add a `Stream.toArray` alias for `runCollect` that is more discoverable:

```rescript
let toArray = runCollect  // alias
```

**Value:** Very low — `runCollect` is the Effect convention and changing it would confuse
developers who know the TypeScript API.

### 9.10 Summary of Idiomatic Improvements

| Improvement | Value | Effort | Recommendation |
|-------------|-------|--------|----------------|
| Replace `EffectOption.toOption` `%raw` with `Option.getOrUndefined` | Medium | Low | Do it |
| Fix `Effect.either` type safety (Either vs result) | **High** | Low | Do it — correctness bug |
| Labeled args for `acquireRelease` | Medium | Low | Do it |
| Document `catchAll` + `switch` as idiomatic error pattern | Medium | Very low | Do it |
| `do2`/`do3` sequential helpers | Low | Low | Defer until needed |
| `Stream.toArray` alias | Very low | Very low | Skip |
| `runForkIgnore`/`runSyncIgnore` | Very low | Very low | Skip |
| `Effect.gen` PPX | High | Very high | Future community project |
| Umbrella module restructuring | None | Medium | Skip — current flat structure is correct |

---

## 10. Test Coverage Analysis

### 10.1 Existing Test Files

The `rescript-effect` package has **16 test files** (15 module test files + 1 test utility):

| Test File | Module Tested | Tests | Coverage Assessment |
|-----------|--------------|-------|---------------------|
| `EffectTest.res` | Effect | 25 | Good — construction, transformation, error handling, resource management, running, concurrency |
| `StreamTest.res` | Stream | 19 | Good — construction, transformation, terminal runners |
| `ScheduleTest.res` | Schedule | 7 | Moderate — recurs, once, whileInput, intersect, union, fixed+TestClock, exponential+TestClock |
| `QueueTest.res` | Queue | 11 | Good — constructors, offer/take, inspection, lifecycle |
| `PubSubTest.res` | PubSub | 5 | Moderate — subscribe+publish, size, publishAll, bounded, shutdown |
| `FiberTest.res` | Fiber | 4 | Moderate — join, interrupt, joinAll, collectAll |
| `DeferredTest.res` | Deferred | 6 | Good — make+succeed+await, isDone, idempotent succeed, fail, completeWith |
| `RefTest.res` | Ref | 6 | Good — make+get, set, update, getAndUpdate, updateAndGet, modify |
| `SynchronizedRefTest.res` | SynchronizedRef | 5 | Good — make+get, set, update, updateEffect, modifyEffect |
| `StmTest.res` | Stm + TRef | 10 | Good — TRef CRUD, STM succeed/map/flatMap/zipRight/fail |
| `LatchTest.res` | Latch | 3 | Good — closed→open, starts open, close→open cycle |
| `CauseTest.res` | Cause | 8 | Good — constructors+predicates, extraction (failures, defects, pretty), composition |
| `ExitTest.res` | Exit | 9 | Good — constructors+predicates, extraction (getOrElse, causeOption), match, transformation |
| `DurationTest.res` | Duration | 6 | Good — all 5 constructors + sleep integration |
| `TestClockTest.res` | TestClock + TestContext | 5 | Good — currentTimeMillis, adjust, sleep+adjust, partial advance, accumulation |
| `AsyncTest.res` | (test utility) | — | Test infrastructure: describe, test, testPromise, expect bindings |

**Total: 129 individual tests across 15 module test files.**

### 10.2 Modules WITHOUT Dedicated Test Files

| Module | Test File | Status |
|--------|-----------|--------|
| **Context** | None | **No tests** — `Context.genericTag` is untested directly |
| **Layer** | None | **No tests** — `Layer.succeed_`, `Layer.effect_`, `Layer.provide` are untested |
| **EffectOption** | None | **No tests** — but exercised indirectly via `Effect.option`, `Stream.runHead`, `Exit.causeOption`, `Fiber.poll` |

### 10.3 Per-Function Coverage Gap Analysis

#### Effect.res — Functions Not Tested

| Function | Bound | Tested | Used in Framework | Priority |
|----------|-------|--------|-------------------|----------|
| `succeed` | ✓ | ✓ | ✓ | — |
| `fail` | ✓ | ✓ | ✓ | — |
| `sync` | ✓ | ✓ | ✓ | — |
| `promise` | ✓ | ✓ | ✓ | — |
| `tryPromise` | ✓ | ✓ | ✓ | — |
| `trySync` | ✓ | ✓ | ✗ | — |
| `never` | ✓ | ✓ (in FiberTest) | ✗ | — |
| `map` | ✓ | ✓ | ✓ | — |
| `flatMap` | ✓ | ✓ | ✓ | — |
| `tap` | ✓ | ✓ | ✓ | — |
| `zipRight` | ✓ | ✓ | ✓ | — |
| `zipLeft` | ✓ | ✓ | ✗ | — |
| `catchAll` | ✓ | ✓ | ✓ | — |
| **`catchTag`** | ✓ | **✗** | ✗ | Low — not idiomatic in ReScript |
| `either` | ✓ | **✗** | ✗ | **High — has type safety issue** |
| `option` | ✓ | ✓ | ✗ | — |
| `retry` | ✓ | ✓ (in ScheduleTest) | ✓ | — |
| `repeat` | ✓ | ✓ (in ScheduleTest) | ✗ | — |
| `fork` | ✓ | ✓ | ✓ | — |
| **`forkScoped`** | ✓ | **✗** | ✗ | Medium — important for resource safety |
| `all` | ✓ | ✓ (5 tests) | ✓ | — |
| **`race`** | ✓ | **✗** | ✗ | Low |
| `ensuring` | ✓ | ✓ (3 tests) | ✗ | — |
| `acquireRelease` | ✓ | **✗** | ✓ (InMemory_Bus) | **High — used in framework, untested in bindings** |
| `scoped` | ✓ | **✗** (only via PubSubTest) | ✓ (InMemory_Bus) | **Medium — exercised indirectly** |
| `makeLatch` | ✓ | ✓ (in LatchTest) | ✗ | — |
| `makeSemaphore` | ✓ | **✗** | ✗ | Medium |
| **`withPermits`** | ✓ | **✗** | ✗ | Medium |
| `sleep` | ✓ | ✓ (in TestClockTest) | ✓ | — |
| **`timeout`** | ✓ | **✗** | ✗ | **High — identified as key untapped opportunity** |
| `forever` | ✓ | **✗** | ✗ | Medium — used pattern in Bus drain loops |
| `provide` | ✓ | ✓ (in TestClockTest) | ✓ | — |
| **`serviceWith`** | ✓ | **✗** | ✓ (EffectLogger) | **High — core DI mechanism, untested** |
| **`serviceWithEffect`** | ✓ | **✗** | ✗ | Medium |
| **`provideService`** | ✓ | **✗** | ✓ (EffectLogger) | **High — core DI mechanism, untested** |
| `yieldNow` | ✓ | ✓ | ✗ | — |
| `logInfo` | ✓ | **✗** | ✓ | Low — fire-and-forget logging |
| `logDebug` | ✓ | **✗** | ✗ | Low |
| `logWarning` | ✓ | **✗** | ✗ | Low |
| `logError` | ✓ | **✗** | ✓ | Low |
| `runPromise` | ✓ | ✓ | ✓ | — |
| `runPromiseExit` | ✓ | ✓ | ✓ | — |
| `runSync` | ✓ | ✓ | ✓ | — |
| `runSyncExit` | ✓ | ✓ | ✓ | — |
| `runFork` | ✓ | ✓ | ✓ | — |

#### Stream.res — Functions Not Tested

| Function | Tested | Priority |
|----------|--------|----------|
| `fromEffect` | ✓ | — |
| `fromIterable` | ✓ | — |
| `fromQueue` | ✓ | — |
| `empty` | ✓ | — |
| `paginateEffect` | ✓ | — |
| `map` | ✓ | — |
| `mapEffect` | ✓ (2 tests) | — |
| **`flatMap`** | **✗** | Medium |
| `filter` | ✓ | — |
| `grouped` | ✓ (3 tests) | — |
| `take` | ✓ | — |
| **`tap`** | **✗** | Low |
| `runCollect` | ✓ | — |
| `runFold` | ✓ (2 tests) | — |
| `runForEach` | ✓ | — |
| **`runDrain`** | **✗** | Medium — used in framework |
| `runHead` | ✓ (2 tests) | — |
| **`catchAll`** | **✗** | Medium |
| **`fromReadableStream`** | **✗** | Low — Node.js interop, hard to test |

#### Schedule.res — Functions Not Tested

| Function | Tested | Priority |
|----------|--------|----------|
| `exponential` | ✓ | — |
| `fixed` | ✓ | — |
| **`spaced`** | **✗** | Low |
| `recurs` | ✓ | — |
| `once` | ✓ | — |
| `forever` | **✗** | Low |
| **`elapsed`** | **✗** | Low |
| `jittered` | **✗** (used in framework but not directly tested) | Medium — key production pattern |
| `whileInput` | ✓ | — |
| **`whileOutput`** | **✗** | Low |
| **`compose`** | **✗** | Low |
| `union` | ✓ | — |
| `intersect` | ✓ | — |

#### Context.res — NO Tests

| Function | Tested | Priority |
|----------|--------|----------|
| **`genericTag`** | **✗** | **High — foundational for DI, used by EffectLogger** |

#### Layer.res — NO Tests

| Function | Tested | Priority |
|----------|--------|----------|
| **`succeed_`** | **✗** | **High — used for service provision** |
| **`effect_`** | **✗** | Medium |
| **`provide`** | **✗** | Medium |

#### PubSub.res — Partially Tested

| Function | Tested | Priority |
|----------|--------|----------|
| `unbounded` | ✓ | — |
| `bounded` | ✓ | — |
| **`sliding`** | **✗** | Low |
| **`dropping`** | **✗** | Low |
| `publish` | ✓ | — |
| `publishAll` | ✓ | — |
| `subscribe` | ✓ | — |
| `size` | ✓ | — |
| `shutdown` | ✓ | — |
| `isShutdown` | ✓ | — |

### 10.4 Missing Tests — Prioritized List

#### Priority 1 — High (Correctness & Core Functionality)

These are either used in the framework without dedicated binding-level tests, or have known
correctness concerns:

| Test | Why High Priority |
|------|-------------------|
| **`Effect.either` round-trip** | Type annotation claims `result<'a, 'e>` but runtime shape may differ — verify or fix |
| **`Context.genericTag` + `Effect.serviceWith` + `Effect.provideService`** | Core DI mechanism used by EffectLogger, completely untested at the binding level |
| **`Layer.succeed_` + `Effect.provide(layer)`** | Service provision pattern, untested |
| **`Effect.acquireRelease` + `Effect.scoped`** | Used in InMemory_Bus for subscription lifecycle, untested at binding level |
| **`Effect.timeout`** | Identified as key production improvement, needs test before adoption |

**Suggested test file: `ContextLayerTest.res`** (new)

```rescript
describe("Context + Layer + Service injection", () => {
  // Test 1: genericTag creates a tag that can be used with serviceWith
  // Test 2: provideService satisfies a serviceWith requirement
  // Test 3: serviceWithEffect chains effectful service access
  // Test 4: Layer.succeed_ creates a layer, Effect.provide(layer) satisfies requirements
  // Test 5: Layer.effect_ creates a layer from an effectful construction
  // Test 6: Layer.provide chains layers
  // Test 7: Multiple provideService calls satisfy multiple services
})
```

**Suggested additions to `EffectTest.res`:**

```rescript
describe("Effect — either", () => {
  // Test 1: either on success returns Ok(value) — verify pattern match works
  // Test 2: either on failure returns Error(error) — verify pattern match works
  // Test 3: either always succeeds (no error propagation)
})

describe("Effect — acquireRelease + scoped", () => {
  // Test 1: acquire runs, release runs on success
  // Test 2: release runs on failure
  // Test 3: forkScoped fiber is interrupted when scope closes
})

describe("Effect — timeout", () => {
  // Test 1: timeout with TestClock — effect completes before timeout → Some(value)
  // Test 2: timeout with TestClock — effect exceeds timeout → None
})

describe("Effect — semaphore", () => {
  // Test 1: makeSemaphore + withPermits limits concurrency
})

describe("Effect — race", () => {
  // Test 1: race returns the first to succeed
  // Test 2: losing effect is interrupted
})
```

#### Priority 2 — Medium (Framework Patterns & Completeness)

| Test | Why Medium Priority |
|------|---------------------|
| `Stream.flatMap` | Used pattern, just not directly tested |
| `Stream.runDrain` | Used in framework (Core_Callback) |
| `Stream.catchAll` | Error recovery pattern for streams |
| `Stream.tap` | Side-effect pattern |
| `Schedule.jittered` | Key production pattern (verifying it doesn't error is sufficient) |
| `Effect.forever` | Used in Bus drain loops (test with Queue.take + shutdown) |
| `Effect.forkScoped` | Important for resource safety patterns |
| `PubSub.sliding` | Completeness |
| `PubSub.dropping` | Completeness |

#### Priority 3 — Low (Completeness, Rarely Used)

| Test | Why Low Priority |
|------|------------------|
| `Effect.catchTag` | Not idiomatic in ReScript (prefer `catchAll` + `switch`) |
| `Effect.logInfo/logDebug/logWarning/logError` | Fire-and-forget, hard to assert on output |
| `Schedule.spaced` | Similar to `fixed`, low risk |
| `Schedule.elapsed` | Rarely used |
| `Schedule.whileOutput` | Mirror of `whileInput` |
| `Schedule.compose` | Rarely used |
| `Schedule.forever` | Simple schedule |
| `Stream.fromReadableStream` | Node.js interop, requires file fixtures |

### 10.5 Test Infrastructure Quality

**Strengths:**
- `AsyncTest.res` provides correct async test bindings (avoids the broken `testPromise` from
  `@glennsl/rescript-jest` — see MEMORY.md)
- Consistent `open AsyncTest` + `open AsyncTest.Expect` pattern across all test files
- `arrayFrom` helper for Effect Chunk → array conversion
- TestClock + TestContext pattern is well-documented in test comments
- Tests are pure binding-level verification — no framework dependencies

**Weaknesses:**
- No negative/edge-case tests for many modules (e.g., "what happens when you take from a shut
  down queue?")
- No concurrency stress tests (e.g., "100 fibers writing to the same Ref")
- `Expect` module is minimal — missing `toThrow`, `toBeNull`, `toMatch` matchers

### 10.6 Coverage Summary

| Category | Modules | Tests | Assessment |
|----------|---------|-------|------------|
| **Fully tested** (all bound functions) | Effect (core), Ref, SynchronizedRef, Stm, Deferred, Exit, Cause, Latch, Duration, TestClock | 88 | Strong |
| **Well tested** (>70% functions) | Stream, Queue, PubSub, Schedule, Fiber | 46 | Good, some gaps |
| **Exercised indirectly only** | EffectOption | 0 (but covered via other modules) | Acceptable |
| **Untested** | Context, Layer | 0 | **Gap — needs ContextLayerTest.res** |
| **Partially untested** | Effect (DI functions, timeout, race, acquireRelease) | 0 | **Gap — needs additions to EffectTest.res** |

**Overall:** ~75% of bound functions have dedicated tests. The main gaps are in dependency
injection (Context, Layer, serviceWith, provideService) and resource management (acquireRelease,
scoped, timeout). These are also the areas most likely to be used more heavily as the framework
adopts Effect services for logging, metrics, and other cross-cutting concerns.
