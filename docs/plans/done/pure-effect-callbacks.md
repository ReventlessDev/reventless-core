# Pure Effect Callbacks (Phase C)

**Status:** Done

**Created:** 2026-03-05

**Depends on:** `docs/plans/done/effect-logger-and-request-context.md` (complete)

**Summary:** Restructure callbacks to stay entirely in the Effect pipeline, eliminating
`Effect.promise(async () => ...)` blocks in favor of Effect combinators.

**Follow-up:** AWS runtime `Console.*` migration → `docs/plans/Backlog/pure-effect-aws-runtime.md`

---

## Goal

After the logger migration (Phase A+B), logging inside async closures uses
`Effect.logInfo(...)->Effect.runSync` -- it works but is awkward. Pure Effect callbacks would:

- Make logging natural: `->Effect.tap(_ => Effect.logInfo("msg"))` with no `runSync`
- Enable testability: silence logs with `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`
- Enable composability: callbacks become pure Effect values -- combinable, retriable, timeable
- Align with the Effect programming model

---

## Scope

### Core callbacks

Each needs restructuring:
- `Effect.promise(async () => { ... })` -> Effect combinators (`flatMap`, `tap`, `forEach`, `all`)
- `await somePromise` -> `Effect.tryPromise(() => somePromise)`
- `Array.map(async ...)` -> `Effect.forEach` or `Effect.all`
- Mutable accumulators -> `Effect.reduce` or `Ref`

### AWS adapter runtime files

Extracted to separate backlog plan: `docs/plans/Backlog/pure-effect-aws-runtime.md`

---

## Approach

This is a significant refactor -- each callback can be migrated independently.

### Work items (core callbacks)

Order: simplest first.

1. [x] `ReadModel_Callback.res` — replace `Effect.sync` + `runSync` logging with pure pipeline
2. [x] `Core_Callback.res` — replace `Effect.promise(async)` with `Effect.logInfo` + `Effect.all`
3. [x] `Plugin_Callback.res` — replace `Effect.promise(async)` + `detectUnhandledEvent` sync logging
4. [x] `SideEffectHandler_Callback.res` — replace `Effect.promise(async)` + try/catch error handling
5. [x] `CommandGenerator_Callback.res` — replace `Effect.promise(async)` with pure Effect pipeline
6. [x] `StateChangeSlice_Callback.res` — replace `Effect.promise(async)` + recursive retry; lift `handleSingleCommand` into Effect
7. [x] `ExtensionPoint_Callback.res` — replace `Effect.promise(async)` + lift `applyCommandAction` into Effect
8. [x] `Counter_Callback.res` — lift async `counterHandler` into Effect
9. [x] `EventMapper_Callback.res` — lift `commonEventsHandler` async + both handler modules into Effect
10. [x] `Aggregate_Callback.res` — lift `processCommand` + nested async loops into Effect

### Notes on completed migration

**Patterns applied:**
- `Effect.promise(async () => { ... })` → `Effect.flatMap` chains with `Effect.promise(() => singleCall)`
- `Effect.logInfo(...)->Effect.runSync` → `Effect.tap(_ => Effect.logInfo(...))` or `Effect.zipRight`
- `Array.map(async ...)->Promise.all` → `Effect.all(array->Array.map(item => ...), {"concurrency": "unbounded"})`
- `await somePromise` → `Effect.promise(() => somePromise)` chained with `flatMap`
- `try { ... } catch { ... }` → `Effect.trySync(~catch=..., ...)` or `Effect.tryPromise(~catch=..., ...)`
- `JsExn.fromException` on `unknown` errors → `Util.Error.messageFromUnknown` (takes `unknown` directly)

**Remaining `Effect.logInfo->Effect.runSync` in synchronous contexts:**
- `Aggregate_Callback.res`: `errorHandler` (sync callback passed to `Behavior.execute`), command logging inside `Array.forEach`
- `Counter_Callback.res`: inside `Array.filterMap` (sync predicate)
- `EventMapper_Callback.res`: `findMapping` and `commonEventsHandler` (sync array processing with `Array.mapWithIndex`)
- `SideEffectHandler_Callback.res`: `findSideEffect` (sync lookup with try/catch)

These remain because they're inside synchronous array callbacks or sync helper functions that can't return Effect.
Lifting them would require restructuring the data flow (e.g., separate mapping from logging).

**AWS runtime files:** Extracted to `docs/plans/Backlog/pure-effect-aws-runtime.md`.
