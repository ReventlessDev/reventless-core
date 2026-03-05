# Plan: Effect-Based Runtime Dispatch

**Status:** Backlog
**Created:** 2026-03-05
**Predecessor:** `docs/plans/effect-error-retry-harmonization.md`

---

## Goal

Convert remaining Promise-based handler dispatch patterns in runtime builders to Effect-based
pipelines. These were deferred from the error/retry harmonization plan because they touch
the runtime architecture and handler type system.

---

## Background

Three coexisting dispatch patterns remain after the error/retry harmonization:

1. **Procedural `runEffect` + `Promise.all`** — runtime builders use local `runEffect` helpers
   and `Promise.all` for parallel handler dispatch
2. **`Effect.promise()` bridges** — Effect pipelines wrapping Promise-based handlers
3. **Mutable imperative patterns** — `CommandPublisher` buffer management

---

## Step 1: Consolidate `runEffect` helper

**Files:** `AggregateRuntime_Builder_Common.res`, `EventCollectorRuntime_Builder_Single.res`

Both define identical local helpers:
```rescript
let runEffect = (~correlationId=?, effect) =>
  effect
  ->Effect.provideService(RequestContext.tag, {correlationId: ...})
  ->Effect.runPromise
```

- [ ] Extract to `Runtime.res` alongside existing `runEffectHandler`
- [ ] Update both builders to use the shared version

---

## Step 2: Replace Promise.all fan-outs in runtime builders

**Files:** `AggregateRuntime_Builder_Common.res`, `EventCollectorRuntime_Builder_Single.res`

Current pattern:
```rescript
let _ = await event->RuntimeEnvironment.groupBySource->Dict.toArray
  ->Array.map(async ((urn, event)) => {
    // ... dispatch to commandTopic or eventCollector handlers ...
    handlers->Array.map(handler => runEffect(handler(event, context)))->Promise.all
  })
  ->Promise.all
```

- [ ] Replace outer `Promise.all` with `Effect.all` over grouped sources
- [ ] Replace inner `Promise.all` with `Effect.all` for multi-handler dispatch
- [ ] Keep `runEffectHandler` as the conversion boundary at Lambda entry point

---

## Step 3: Convert `CommandTopic_Builder.filteringHandler`

**File:** `CommandTopic_Builder.res`

Current pattern wraps `Promise.all` inside `Effect.promise`:
```rescript
Effect.promise(async () => {
  let allResults = []
  let _ = await handlers->Array.map(async handlerEntry => {
    let results = await handler(Stream.fromIterable([...]))->Effect.runPromise
    allResults->Array.pushMany(results)
  })->Promise.all
  allResults
})
```

- [ ] Replace with `Effect.all(handlers->Array.map(...), {"concurrency": "unbounded"})`
- [ ] Remove mutable `allResults` accumulation
- [ ] Add proper error handling (currently silent `catch { | _ => () }`)

---

## Step 4: Fix Extension_Operations.res error handling

**File:** `Extension_Operations.res` (~line 169)

Current pattern has a FIXME — `Promise.all` with no error handling:
```rescript
readModelNames->Array.filterMap(readModelName =>
  Ops.publishToReadModels->Dict.get(readModelName)
    ->Option.map(enqueueEvent => enqueueEvent(0, event'.id, eventJson'))
) // FIXME Error handling
->Promise.all
```

- [ ] Replace `Promise.all` with `Effect.all` or `Effect.forEach`
- [ ] Add error logging for individual enqueue failures
- [ ] Decide fail-fast vs continue-on-partial-failure semantics

---

## Step 5: Convert Core_Callback.res extension point dispatch

**File:** `Core_Callback.res`

Currently uses `Effect.promise()` to bridge Promise-based extension point handlers:
```rescript
Effect.all(
  handlers->Array.map(handleEvent =>
    Effect.promise(() => handleEvent(eventJson', pluginDef))
  ),
  {"concurrency": "unbounded"},
)
```

- [ ] Convert extension point handler type from `promise<unit>` to `Effect.t<unit, string, unit>`
- [ ] Remove `Effect.promise` bridges
- [ ] This requires updating `ExtensionPoint` handler registration across the framework

---

## Step 6: CommandPublisher buffer redesign (optional)

**File:** `CommandPublisher.res`

Mutable buffer with `running: ref<option<promise>>` sentinel tracking. The retry logic
(random 3-7s sleep, re-enqueue failed chunk) is coupled with the buffering/chunking logic.

- [ ] Consider replacing with Effect `Queue` + `Stream` consumer
- [ ] Or keep as-is — this is application-level buffering, not internal dispatch

---

## Step 7: S3 pagination

**File:** `TaskBucket_S3_Runtime.res`

- [ ] Replace eager `listObjects` (unbounded memory) with `Stream.paginateEffect` using S3
  continuation token

---

## Step 8: Util_Promise.res cleanup

**File:** `Util_Promise.res`

Remaining functions still in use:
- `toUnit` — used by EventTopic, Extension, PluginConnectExtension
- `mapOk` — used by Extension_Operations
- `make` — deferred Promise pattern
- `onEndHandler` — stream end signaling

- [ ] Replace usages as Effect migration progresses
- [ ] Delete module once all usages are gone

---

## Priority

Steps 1-2 are self-contained refactors with clear benefit (less duplication, uniform error handling).
Steps 3-5 improve correctness (silent error swallowing → proper handling).
Steps 6-8 are cleanup that can happen incrementally.
