# Plan: move the Effect bindings to Effect 4

**Status.** Planned 2026-10-12. Effect 4.0.0 went GA on 2026-10-01, and 4.0.3 was
the latest release when this was written. We are on `effect@3.22.2`, the newest
3.x release, which is still being patched. **Rechecked 2026-11-06** against
`4.1.2`, which the package calls a long-term support release.
[The Effect 4 analysis](../analysis/effect-v4-migration.md) has the recount, the
two hazards added to [§2](#2-behavior-changes-that-do-not-show-up-as-compile-errors),
and what v4 opens up afterwards.

**Progress (2026-11-07).** Steps 1 to 3, 5 and 7 are done on `effect@4.1.2`; see
[§5](#5-what-the-port-found). The build has zero warnings and all 539 suites pass
in 22 projects. Step 4 turned out not to be needed, and the deployed check of
step 7 passed after two fixes (see [§3](#3-steps)). Step 6 is open.

**In plain words.** Effect is the library behind every queue, stream, retry
schedule and background fiber in the framework. Version 4 rewrites its runtime
and renames part of its API. Our ReScript bindings
([rescript/effect/](../../rescript/effect/)) are the only code that talks to it
directly, so most of the renames stay inside that package. The risky part is
**behavior**, not names: the runtime is new, and errors, layers and background
fibers now act differently.

**Goal.** `rescript-effect` binds `effect@4.x`, the whole suite passes on the
in-memory, SQLite and AWS backends, and a deployed stack runs commands and
projections as it did before.

**Non-goals.** Adopting new v4 features (Schema v4, `effect/unstable/*`, the
merged platform modules). Changing the public shape of the bindings where a v4
name maps onto the same meaning.

**When to start.** Once 4.0 has settled. 4.0.1 to 4.0.3 shipped within ten days
of the GA. A few weeks with no 4.0.x patch touching `Effect`, `Stream`, `Queue`,
`Schedule` or `Cause` is a good signal.

---

## 1. What we bind and what is gone

Every `@module("effect/…")` external in `rescript/effect/src/` was loaded
against `effect@4.0.3`. **50 of the 174 bindings no longer resolve.** Most are
unused outside the bindings package, so they can simply be deleted. The ones the
framework calls are below. "Uses" counts call sites outside `rescript/effect/`.

| v3 binding | Uses | v4 replacement (to confirm against the `.d.ts`) |
|---|---|---|
| `Effect.catchAll` | 82 in 35 files | `Effect.catch` |
| `Effect.zipRight` | 11 in 6 files | `Effect.andThen` |
| `Effect.makeLatch` | 9 in 5 files | `Latch.make` (its own module now) |
| `Schedule.intersect` | 9 in 8 files | `Schedule.max` ("recur while all recur") |
| `Schedule.whileInput` | 8 in 7 files | `Schedule.while` (takes a step-metadata predicate) |
| `Stm.*` / `TRef.*` | 13 in 1 file | `TxRef` + `Effect.tx`. There is no `STM` module any more. |
| `Stream.paginateChunkEffect` | via `Stream.paginateEffect`, 4 files | `Stream.paginate` |
| `Option.fromNullable` (inside `Stream.res`) | internal | `Option.fromNullishOr` |
| `Stream.catchAll` | 2 in 2 files | `Stream.catch` |
| `Context.GenericTag` | 1 (`RequestContext`) | `Context.Service` |
| `Effect.fork` | 1 (`DcbEventLogStorage_DynamoDb_Runtime`) | `Effect.forkChild` |
| `Effect.logAnnotations` | 1 (a test) | no direct equivalent. Read the annotations another way or drop the assertion. |
| `Cron.unsafeParse` | `ScheduleTime` (automations on a time) | `Cron.parseUnsafe` |
| `DateTime.unsafeMakeZoned` | `DateTime.makeZonedFromMillis` | `DateTime.makeZonedUnsafe` |

Unused bindings with no v4 export, to delete rather than port: `Cause.parallel`,
`sequential`, `isEmpty`, `isFailType`, `isDie`, `isInterrupted`, `failures`,
`defects`; `Effect.zipLeft`, `either`, `makeSemaphore`, `withPermits`;
`Exit.getOrElse`, `causeOption`, `flatMap`; `Fiber.poll`; `Queue.takeUpTo`,
`isEmpty`, `isShutdown`; `Schedule.elapsed`, `whileOutput`, `compose`, `union`;
`TestClock.*`, which moved to `effect/testing/TestClock`; and `TestContext`.

Names that still resolve may still have changed shape. A binding that compiles
against a changed signature fails only at run time, so **each of the 124
surviving bindings gets its v4 signature checked by hand.** `Queue.take` /
`takeAll` (v4 queues have an end-of-stream error channel), `Stream.runDrain`, and
`Effect.runPromise` / `runSync` come first, because they carry the most traffic
(97 and 49 files call the last two).

## 2. Behavior changes that do not show up as compile errors

These are the reason this is a plan and not a version bump. Each one needs a
test that fails on the old behavior before we trust the port.

- **Cause is flattened.** It is now a list of reasons instead of a tree. Anything
  that renders or classifies failures goes through it, including the AWS error
  modules in `reventless/aws/src/errors/` and the error handling in the command
  handlers. Check that a rejected command still reports the same `errorCode` and
  cause.
- **Fibers keep the process alive.** v4 keeps Node running while a fiber is
  live. `LocalBus` and `LocalEventCollectorChannel` start long-lived drain fibers
  with `Effect.runFork`. Expect Jest to report open handles or hang on exit, and
  the local platform to need an explicit shutdown. In Lambda the process is
  frozen rather than exited, but check that a handler still returns while a fiber
  is pending. *Checked: only half true.* A fiber waiting on a subscription or on
  `Effect.never` does not keep Node alive; one in `Effect.sleep` does, through its
  timer, as in v3. Jest's `--detectOpenHandles` does list each suspended fiber
  (`effect/Fiber`), because v4 records its async context, but the process exits.
- **Layer caching across `Effect.provide` changed.** 5 files call
  `Effect.provide`. Check that services built once per cold start are still built
  once.
- **`catch` vs `catchAll`.** Check whether the v4 `catch` also catches defects or
  only typed failures. If it differs, the 82 call sites need sorting rather than a
  rename.
- **`Queue.shutdown` drops what is buffered.** In v4 it discards the queued
  items; `Queue.end` is "no more, let the reader drain". `CsvStream` ends its
  input with `shutdown`, so a reader that is behind loses the last rows without
  an error. Port it to `Queue.endUnsafe`
  ([EVO2](../analysis/effect-v4-migration.md#42-evo2-queues-that-end-instead-of-being-shut-down)).
- **The new runtime.** Scheduling order between fibers can shift. The tests most
  likely to notice are the ones that depend on ordering: `LocalBus` drain,
  `HeartbeatTest`, and the channel tests in `reventless/local/tests/adapter/`.
  It did shift; [§5](#5-what-the-port-found) says how.

## 3. Steps

1. **Bindings branch.** Bump `effect` in
   [rescript/effect/package.json](../../rescript/effect/package.json). Delete the
   unused bindings from [§1](#1-what-we-bind-and-what-is-gone). Port the used ones,
   keeping the ReScript names where the meaning is unchanged, so `catchAll` can
   stay `catchAll` in ReScript while binding v4 `catch`. That keeps the 35 calling
   files untouched for this step.
2. **Re-check every surviving signature** against `effect/dist/*.d.ts`, as
   described in [§1](#1-what-we-bind-and-what-is-gone). Extend the package's own
   tests in `rescript/effect/tests/` for each binding whose shape moved.
3. **Port `EventLogStorage_InMemory`** from `Stm`/`TRef` to `TxRef` + `Effect.tx`.
   It is the only STM user.
4. **Handle the process-lifetime change** in the local platform. Give the drain
   fibers a scope or an explicit interrupt on shutdown: a `FiberSet` per platform
   instance, cleared by `reset`
   ([EVO3](../analysis/effect-v4-migration.md#43-evo3-background-fibers-that-have-an-owner)).
   Then run the suite with `--detectOpenHandles`. *Not needed.* The suite (924
   local-platform tests) exits by itself; the 22 `effect/Fiber` entries
   `--detectOpenHandles` lists are drain fibers waiting on a subscription, which
   hold no timer, and `reset` already ends them by shutting their hubs down.
5. **Full build with zero warnings, then `pnpm test`** across all projects.
6. **Cause and error behavior.** Write a test per error path from
   [§2](#2-behavior-changes-that-do-not-show-up-as-compile-errors): a rejected
   command, a forbidden command, an AWS SDK failure mapped through
   `reventless/aws/src/errors/`.
7. **Deployed check.** Deploy the hybrid example. Run a command through each
   handler, both sync and async, and confirm projections update. Compare cold-start
   time and Lambda bundle size with the v3 build. *Done 2026-11-07,* after the two
   fixes [§5](#5-what-the-port-found) ends with. The seed's `next` set ran through
   both plugins' command handlers and the queue-fed ones (the Plugin aggregate, the
   extension points), and its view read-back saw the new rows. The example has no
   `@@reventless.async` component, so no async command handler is deployed to
   check. Cold start fell by about 40% (Ordering's DCB handler 3.0 s → 1.7 s, the
   platform's aggregates 2.2 s → 1.3 s; one to three samples each, so a
   direction). The Lambda layer grew 17.8 MB → 20.6 MB zipped.
8. **Commit** as `feat(deps)!: upgrade effect to v4`. It changes the public
   bindings of a published package. Close this plan in the same commit.

## 4. Open questions

- Should the bindings keep v3 names (smaller diff, but the names drift from
  Effect's own docs) or take the v4 names (bigger diff, but they match upstream)?
  Recommendation: keep the ReScript names for this migration and rename in a
  separate commit if wanted.
- Does anything outside this repo bind `effect` directly at a v3 version? A
  consumer that pins `effect@3` alongside our v4 bindings gets two copies of the
  runtime, and their fibers and services do not mix.

## 5. What the port found

Done so far: the bump, the bindings, the `TxRef` port and a full run. The
binding tests in `rescript/effect/tests/` now run with the rest: they were in no
Jest project before, so CI had never run them. The package is a step of the root
`build` (before `rescript/jest`, whose tests it would otherwise orphan) and a
project in `jest.config.js`.

The renames went as [§1](#1-what-we-bind-and-what-is-gone) said; the ReScript
names are kept. What a renamed-names check does not catch, and the full run did:

- **`runPromise` rejects with the failure as it is.** A failure of a string
  reaches a `catch` as that string, with no `message`. The binding now runs the
  effect to an `Exit` and throws `Cause.toError`, an `Error` that renders the
  failure, keeps a thrown error's `name` (the caller-fault mark rides on it) and
  matches v3's rejection. `runSync` the same.
- **The logger is a different shape.** `Logger.withMinimumLogLevel` is gone (a
  `MinimumLogLevel` reference now), levels are strings (`Warning` is `Warn`), and
  a line's annotations are read off its fiber, not its options. `EffectLogger`
  is ported; 208 of the first run's 294 failures were this one call.
- **`DateTime` parts are singular.** `hour`, `minute`, `second`, `millisecond`,
  in and out. `makeZoned` ignored our `hours` and answered midnight. The record
  fields keep their ReScript names and map with `@as`.
- **`Stream.map` passes `(element, index)`** and `runFold` takes its seed as a
  function. The wrappers pass the element alone and wrap the seed. `runCollect`
  and `grouped` give plain arrays, so the `Chunk` helpers are gone, also from
  the hand-written `DcbCommandTopicEntryPoint.mjs`.
- **`PubSub.subscribe` gives a `Subscription`**, not a queue: `LocalBus` reads it
  with `Stream.fromSubscription` and leaves closing it to the scope.
- **A woken fiber can run inside the call that woke it.** A `LocalBus`
  subscriber ran inside `publishEvent`. Its drain loop now starts the handler a
  microtask later, which keeps the bus's "never delivered synchronously" rule.
- **Scheduled fiber work runs on `setImmediate`.** Two tests that waited a
  fixed number of microtasks, or advanced fully faked timers synchronously, now
  wait a macrotask or use `advanceTimersByTimeAsync`.
- Smaller: `yieldNow` is a value, `Fiber.interrupt` yields nothing,
  `Latch.open_`/`close` yield whether they changed it, `Queue.offerAll` returns
  what it did not add, `Schedule.intersect` is `max([a, b])` with a `Duration`
  output (seven retry schedules' type annotations), `TestContext` is
  `TestClock.layer()`.
- `CsvStream` ends its queue with `Queue.endUnsafe`
  ([EVO2](../analysis/effect-v4-migration.md#42-evo2-queues-that-end-instead-of-being-shut-down)).

The first deploy ([step 7](#3-steps)) found two more, neither of which any test
reached:

- **A fork inside a concurrent `Effect.all` dies with its worker.** v4 runs each
  element on a fiber of its own, and a child fiber is interrupted when that fiber
  ends; v3 grafted it onto the caller. The DynamoDB DCB reader's k-way merge
  forked one producer per sub-query that way, so every multi-query decision read
  on AWS waited on queues nobody filled. Nothing else kept Node alive, and Lambda
  ended the process (`Runtime.ExitError`). The producers are now forked one at a
  time, on the consuming fiber.
- **That merge's end marker sat in a finalizer.** An interrupted producer blocked
  offering it to a full queue, so a reader that stopped early never finished.
  The marker now follows the stream instead. Both are pinned by
  `Runtime.mergeSortedEvents` tests in `DcbEventLogStorage_DynamoDb_RuntimeTest`.

The deploy also ran new function code on the previous Lambda layer, which still
held Effect 3: a recovery publish (`publish-only`) collected no tags, so no layer
was built. Its tag list now comes from what it published.

