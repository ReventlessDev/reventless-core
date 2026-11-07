# Effect 4: what moving costs and what it opens up

> **Status:** Analysis · no implementation. First written 2026-02-28 against `4.0.0-beta.19`.
> **Rewritten 2026-11-06** against `effect@4.1.2` (the npm `latest`), read against the code on
> `alpha` the same day. The steps of the move are
> [the Effect 4 migration plan](../plans/done/effect-v4-migration.md) (2026-10-12); this analysis is
> the *why* and the *what next* beside it.
>
> **Questions and short answers:**
>
> 1. *Should we update the effect library to version 4?* **Yes, through
>    [the plan](../plans/done/effect-v4-migration.md#3-steps), and it can start now.** The reason to
>    wait was API churn. 4.x is now a long-term support release with a second minor out. What is
>    left is behavior risk in our own code, and waiting does not shrink it
>    ([§2](#2-where-things-stand-in-november-2026), [EVQ1](#6-open-questions)).
> 2. *Isn't there already an analysis for that migration?* **Yes, this one.** It was written
>    against a beta and its trigger ("wait for the RC") has passed. The October plan already
>    replaced its steps. This rewrite keeps the analysis role: what changed, what the plan
>    misses, what v4 gives us ([§2](#2-where-things-stand-in-november-2026),
>    [§3](#3-what-the-plan-does-not-list-yet)).
> 3. *What opportunities does the new version open?* **Six worth taking, three of them inside the
>    migration itself.** A runtime about half the size that loads in under half the time
>    ([EVO1](#41-evo1-a-smaller-runtime-that-loads-faster)), queues that end instead of being
>    shut down ([EVO2](#42-evo2-queues-that-end-instead-of-being-shut-down)), background fibers
>    that have an owner ([EVO3](#43-evo3-background-fibers-that-have-an-owner)), a flat failure
>    model ([EVO4](#44-evo4-a-flat-failure-model)), a request context with a default
>    ([EVO5](#45-evo5-a-request-context-with-a-default)), and tracing and metrics without the
>    OpenTelemetry SDK, still unstable
>    ([EVO6](#46-evo6-tracing-and-metrics-without-the-opentelemetry-sdk)). Most of the large new
>    modules (SQL, workflows, event log, GraphQL) are not for us yet ([§5](#5-what-to-leave-alone)).
>
> **Relates to:** [the Effect 4 migration plan](../plans/done/effect-v4-migration.md) (the steps);
> [the Effect usage analysis](effect-usage-in-reventless.md) (what we use Effect for; its
> [§8](effect-usage-in-reventless.md#8-effect-v4-what-changes) is the March view of v4 that
> this one updates).
>
> **Ids:** EVO1 to EVO6 are the opportunities (**E**ffect **v**4 **o**pportunity), EVQ1 to EVQ3
> the open questions.

---

## 1. In plain words

Effect is the library behind every retry, queue, stream and background task in the framework:
the DynamoDB retry with backoff, the local event bus that hands each event to every subscriber,
the paged read of an event log. We never call it directly. All calls go through our ReScript
bindings in [rescript/effect/](../../rescript/effect/), and the rest of the framework calls those.

Version 4 is a rewrite of Effect's insides. Some functions have new names (`catchAll` is now
`catch`), a few modules are gone (`STM`), and some things behave differently while keeping their
name. The last kind is the dangerous one. A renamed function fails the build or the first test.
A function that keeps its name but behaves differently can lose data without an error. Example:
a CSV import that drops its last rows because "close the queue" now means "throw away what is
still in it" ([§3](#3-what-the-plan-does-not-list-yet)).

In return, v4 is smaller and faster, which matters on Lambda, where every cold start loads it. It
also brings a few tools that fix things we work around today.

## 2. Where things stand in November 2026

| | |
|---|---|
| We run | `effect@3.22.2` ([package.json](../../rescript/effect/package.json)); 3.x is still patched (3.22.4 on 2026-10-22) |
| Latest | `4.1.2` (2026-11-02). 4.0.0 went GA on 2026-10-01 |
| Support | The package README calls 4.x "a long-term support (LTS) release, with at least three years of bug and security fixes" |
| Runtime | Node 22.19 or newer. Met: the repo and CI run 24.22.2 ([.node-version](../../.node-version)) and Lambda runs `nodejs24.x`, since [the Node 24 plan](../plans/done/node-24.md) ([EVQ2](#6-open-questions)) |
| Packaging | One package. What used to be `@effect/platform`, `@effect/sql`, `@effect/workflow` and the others is now subpaths of `effect` (`effect/sql`, `effect/workflow`, …). Each module carries a `@stability` tag: `stable`, `unstable` or `experimental` |

**Bindings.** Each `@module("effect/…")` external in
[rescript/effect/src/](../../rescript/effect/src/) was checked against the 4.1.2 type
declarations, counting names that are exported through an alias (`catch_ as catch`).
**133 of 184 still resolve, and 51 do not.** The plan counted 50 of 174 against 4.0.3. The
difference is bindings added since then. Two of them are in use and missing from
[the plan's table](../plans/done/effect-v4-migration.md#1-what-we-bind-and-what-is-gone):

| v3 binding | Used by | v4 name |
|---|---|---|
| `Cron.unsafeParse` | [ScheduleTime.res](../../reventless/core/src/util/ScheduleTime.res) (automations that run on a time) | `Cron.parseUnsafe` |
| `DateTime.unsafeMakeZoned` | `DateTime.makeZonedFromMillis` in [DateTime.res](../../rescript/effect/src/DateTime.res) | `DateTime.makeZonedUnsafe` |

The rest of the plan's table still holds, and the call counts are close: `Effect.catchAll` 84
uses in 36 files, `Effect.runPromise` 324 in 106. The February analysis was right about the big
items (Cause flattened, `Latch` and `Semaphore` in modules of their own, `fork` → `forkChild`).
Its open question about STM is now settled: STM is gone, and `TxRef` + `Effect.tx` replace it.

## 3. What the plan does not list yet

Two findings belong in [the plan's §2](../plans/done/effect-v4-migration.md#2-behavior-changes-that-do-not-show-up-as-compile-errors),
the behavior changes that do not show up as compile errors:

- **`Queue.shutdown` now throws away what is still buffered.** The 4.1.2 docs say: "Shuts down
  the queue immediately, discarding buffered messages." The call that means "no more items, let
  the reader drain what is there" is the new `Queue.end` (`endUnsafe` outside an Effect), and
  `Stream.fromQueue` ends cleanly when it sees it. [CsvStream.res](../../reventless/core/src/util/CsvStream.res#L23)
  ends the input with `Queue.shutdown` from the parser's `onEnd` callback. If the reader is
  behind when the file ends, the last rows are lost and no error is raised. The fix is
  [EVO2](#42-evo2-queues-that-end-instead-of-being-shut-down). The `Queue.shutdown` in
  [LocalBus.res](../../reventless/local/src/adapter/LocalBus.res#L358) runs when a subscriber is
  torn down, where throwing away the rest is what we want.
- **Node 22.19.** The repo pin, CI and the Lambda runtime all have to be at or above it
  ([EVQ2](#6-open-questions)). A quick check loaded the 4.1.2 bundle on 22.17.1 without error,
  so this is a support statement rather than a known crash. Running below a library's stated
  floor still means a bug report it will not take. Met since the move to Node 24.

## 4. Opportunities

Each opportunity says whether it comes with the migration or after it, and the stability of the
v4 module it rests on.

### 4.1 EVO1 a smaller runtime that loads faster

**With the migration · automatic.** The 130 bindings that exist in both versions (18 modules)
were bundled with esbuild (minified, ESM, Node), once against 3.22.2 and once against 4.1.2.
Each bundle was then imported 15 times in a fresh Node 22.17.1 process:

| | v3 | v4 |
|---|---|---|
| Minified | 234 KB | 114 KB |
| Gzipped | 72 KB | 37 KB |
| Import time, median | 14.2 ms | 6.4 ms |

That is about half the size and under half the load time, paid on every cold start of every
Lambda that touches Effect, which is nearly all of them. A few milliseconds is small next to a
whole cold start, but it costs nothing beyond the migration. These are bundles of the bindings
alone, not of a real handler, so the deployed difference will be diluted by everything else the
handler loads. [Plan step 7](../plans/done/effect-v4-migration.md#3-steps) already compares cold-start time
and bundle size on a deployed stack. These numbers are what to expect.

### 4.2 EVO2 queues that end instead of being shut down

**With the migration · `Queue` stable.** v4 separates two acts that v3 joined: *ending* a queue
(no more items, let the reader finish: `Queue.end`) and *shutting it down* (stop now, drop the
rest: `Queue.shutdown`). A v4 queue also carries an error channel, so a producer can end it with
a failure the reader sees (`Queue.fail`). For
[CsvStream.res](../../reventless/core/src/util/CsvStream.res) that means:

- `onEnd` → `Queue.endUnsafe(queue)`: every parsed row reaches the reader, however far behind it is.
- `onError` → the current `Error(msg)` row followed by `Queue.endUnsafe`, so the error row is
  read before the stream ends. (`Queue.fail` would end the stream with the error as a failure
  instead. It has no synchronous form, so the callback would keep its `runSyncExit`.)
- The `Effect.runSyncExit->ignore` around `onEnd` goes away, since `endUnsafe` is a plain
  synchronous call.

The bindings get `Queue.end`, `endUnsafe` and `fail`. The
[`Stream.fromQueue` doc comment](../../rescript/effect/src/Stream.res#L43), which says the stream
"terminates cleanly when `Queue.shutdown` is called", changes to say `Queue.end`.

### 4.3 EVO3 background fibers that have an owner

**After the migration, optional · `FiberSet`, `FiberHandle` stable.** The local platform starts long-lived
drain fibers and drops the handle: `let _ = Effect.runFork(drainLoop)` in
[LocalBus.res](../../reventless/local/src/adapter/LocalBus.res#L334) and in
[LocalEventCollectorChannel.res](../../reventless/local/src/adapter/EventCollector/LocalEventCollectorChannel.res#L86).
Today they end only because `reset` shuts the hubs down. The plan expected trouble here, with
v4 keeping Node alive while a fiber runs
([plan §2](../plans/done/effect-v4-migration.md#2-behavior-changes-that-do-not-show-up-as-compile-errors)).
The port showed it does not, for these fibers: one waiting on a subscription holds no timer, and
the process exits.

A `FiberSet` per platform instance would still give those fibers an owner: each drain fiber
started with `FiberSet.run`, and `reset` or a platform shutdown clearing the set, interrupting
every fiber in it. What it buys is clarity, "which background work does this platform own" as
something the code can answer, not a fix. It needs an open `Scope` for the set's lifetime, which
the bus does not hold today, so it is a refactor of its own and no longer part of the migration.
`FiberHandle` is the one-fiber form, for a single loop such as a heartbeat.

### 4.4 EVO4 a flat failure model

**With the migration · `Cause` stable.** A v3 `Cause` is a tree: failures combined in sequence
or in parallel, each to be walked. A v4 `Cause` is a flat list of reasons (`cause.reasons`) with
`hasFails`, `hasDies`, `hasInterrupts`, `squash` and `prettyErrors`. We port `Cause.res` anyway,
since 8 of its bindings are gone. Today the only framework user is
[ScheduleOps.res](../../reventless/core/src/util/ScheduleOps.res), which calls `Cause.pretty`,
and that still exists.

The opportunity is in *what we bind*: bind the flat model as it is (`reasons` plus the three
predicates) rather than rebuilding v3's tree helpers on top of it. A failure classifier, such as
"was this a typed error or a defect, and which", becomes one `switch` over an array.

### 4.5 EVO5 a request context with a default

**After the migration · `Context` stable.** [RequestContext.res](../../reventless/core/src/RequestContext.res#L44)
is a `GenericTag` service. Every Effect that reads it needs it provided, so tests provide
`RequestContext.test()` by hand (6 places) and each runtime entry point provides the real one.
v4's `Context.Reference` is a key with a lazily built default: read it unprovided and you get the
default, and provide it to override. With an anonymous, uncorrelated default, a test or tool
that does not care about the caller stops having to say so. Entry points that know the caller
still provide it, as now.

This changes a published type, so it does not belong in the migration commit. It is a small
follow-up once the bindings carry `Context.Reference`.

### 4.6 EVO6 tracing and metrics without the OpenTelemetry SDK

**After the migration · `Tracer`, `Metric` stable; `effect/observability` unstable.** Today a
metric is a JSON log line that a CloudWatch metric filter turns into a count
([Metrics.res](../../reventless/core/src/util/Metrics.res), through its `Sink`). There is no
tracing; a request is followed by grepping its `correlationId` across logs.

v4 has spans (`Effect.withSpan`) and metrics (`Metric.counter`, `histogram`, `timer`) in the
stable core. It also ships OTLP exporters (`effect/observability`: `OtlpTracer`,
`OtlpMetrics`, `OtlpLogger`) that send them to any OpenTelemetry collector without the
OpenTelemetry SDK, which is otherwise a heavy cold-start dependency. A command's path through
the plugin (publish, decide, append, project) could then be one trace instead of four log
searches.

The exporters are `unstable`, so this is a prototype, not an adoption
([EVQ3](#6-open-questions)). The low-risk first step uses only stable parts: a `Metrics.Sink` that
records into an Effect `Metric`, and `withSpan` around the command handler, exported by a local
collector in development. One caveat for ReScript: v4's `Effect.fn`, the convenient way to make
a traced function, takes a generator function, which ReScript cannot write. `Effect.withSpan` on
the returned Effect is the route we can use.

## 5. What to leave alone

The single package now holds much more than the core. It is worth saying where the obvious ideas
do not pay off, so they are not reopened every time someone browses the module list:

| Module | Stability | Why not, or not yet |
|---|---|---|
| `effect/Schema` | stable | sury, through `@schema`, is the serialization layer; a second one buys nothing ([the usage analysis §4](effect-usage-in-reventless.md#4-effect-features-that-do-not-make-sense-for-reventless)) |
| `effect/sql` | unstable | The SQLite and Postgres backends talk to `node:sqlite` and `pg` directly, and v4's drivers are separate packages. Revisit only if a third SQL backend arrives |
| `effect/workflow` | unstable | Durable workflows overlap with our automations and tasks, which already persist their state as events. Reading material for the automation design, not a dependency |
| `effect/eventlog` | unstable | A local-first, replicated event journal with its own event and identity model. Different in kind from our event log; nothing to adopt |
| `effect/graphql` | experimental | We serve GraphQL with graphql-yoga and generate the SDL; a second server model buys nothing |
| `effect/cli` | unstable | Our bins share `CliArgs` over `util.parseArgs`; switching would be churn |
| `persistence/CircuitBreaker`, `ErrorReporter` | experimental, unstable | Both interesting for the AWS adapters (stop calling a failing service; forward failures to an error tracker). Look again when they reach stable |
| `cluster`, `ai`, `rpc`, `http`, `workers` | unstable | Long-running servers or application concerns, not a serverless framework's |

`Effect.timeout` on AWS calls ([the usage analysis §6.4](effect-usage-in-reventless.md#64-effecttimeout--protect-against-slow-operations))
is still unused. It is not new in v4, so it does not belong on this list. It remains worth doing.

## 6. Open questions

**EVQ1. Start the migration now, or wait longer?** The plan's trigger was "a few weeks with no
4.0.x patch touching `Effect`, `Stream`, `Queue`, `Schedule` or `Cause`". Since then 4.1 has
shipped, and the README declares 4.x LTS.

**Recommendation:** start now with plan steps 1 to 3 (bindings, signatures, the STM port). They
are confined to [rescript/effect/](../../rescript/effect/) and one storage file, and they can be
thrown away if 4.1 moves under them. Fold [EVO2](#42-evo2-queues-that-end-instead-of-being-shut-down)
into the port, because it is how the queue hazard gets fixed.
[EVO3](#43-evo3-background-fibers-that-have-an-owner) turned out not to be needed for it. Revisit if a 4.1.x release changes `Queue`, `Stream` or `Cause`
while the bindings are being ported.

**EVQ2. Is the Node 22.19 floor met everywhere?** The repo pins 22.17.1. Lambda `nodejs22.x`
follows AWS's patch cadence, and we have not read its version.

**Recommendation:** in the migration commit, move [.node-version](../../.node-version) to the
latest 22.x, and read `process.version` from a deployed function before step 7. Revisit if
Lambda reports a version below 22.19; then the deploy waits for the runtime, not the other way
round.

**Answered 2026-11-07.** We moved past the floor rather than to it: [the Node 24
plan](../plans/done/node-24.md) put the repo and CI on 24.22.2 and the Lambdas on `nodejs24.x`,
whose functions report `nodejs:24.mainline.v115` at start.

**EVQ3. Adopt the OTLP exporters while they are unstable?**

**Recommendation:** no. Build [EVO6](#46-evo6-tracing-and-metrics-without-the-opentelemetry-sdk)'s
stable half (an Effect `Metric` sink, spans around the command handler) and export locally only.
The log-line metric stays the production path. Revisit when `effect/observability` is tagged
`stable`, or when a deployment needs traces badly enough to accept a pinned unstable module.
