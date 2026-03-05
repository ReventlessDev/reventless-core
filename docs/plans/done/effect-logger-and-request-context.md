# Effect Logger Migration & RequestContext Provision

**Status:** Complete (Phase A + Phase B + Phase B2 done; Phase C is `docs/plans/Backlog/pure-effect-callbacks.md`)

**Created:** 2026-03-05

**Depends on:** `docs/plans/done/effect-based-handlers.md` (complete)

**Summary:** Migrate per-callback logging to Effect's built-in logger (`Effect.logInfo`, `Effect.logError`,
etc.), provide `RequestContext` at the dispatch point, remove legacy logging infrastructure
(`Logger.res`, `EffectLogger.res`, `runtimeLogger`), and move formatting helpers to `LogFormat.res`.

---

## Background

The effect-based-handlers plan moved `Effect.runPromise` to the runtime builder dispatch and added
`Effect.provideService(EffectLogger.tag, EffectLogger.consoleLogger)` at that point. Callbacks now
run inside an Effect pipeline — but none of them use Effect logging yet.

Additionally, `RequestContext.res` already defines the service tag and type but is never provided.
The dispatch point can extract `correlationId` from the incoming event and provide it.

### Key Insight: Use Effect's Built-in Logger

Effect provides built-in log functions: `Effect.logInfo`, `Effect.logDebug`, `Effect.logWarning`,
`Effect.logError`. These have **no service requirements** — they return `Effect<void, never, never>`
and use the fiber's logger (configured at the layer level). This means:

- **No type constraint problem**: `effectHandler` can keep `unit` requirements
- **No `serviceWithEffect` or capture pattern needed**
- **No custom EffectLogger service needed** — remove it entirely
- **No `provideService(EffectLogger.tag, ...)` at dispatch** — just remove those calls
- **Test silencing**: use `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`

---

## Phase A — Groundwork (complete)

Removed the old `Logger.*` / `runtimeLogger` infrastructure. Replaced with `Console.*` as an
intermediate step. This clears the path for Effect's built-in logger.

What was done:
- Removed `Logger.log`, `Logger.info`, `Logger.warn`, `Logger.error`, `Logger.debug`, `Logger.Level`,
  `Logger.createTag`, `Logger.logCmdJson`, `Logger.logCmdJsons`, `Logger.logJsonEvent`
- Kept formatting helpers: `commandJsonToLogMessage`, `commandJsonsToLogMessages`, `event'JsonToLogMessage`
- Removed `type runtimeLogger`, `defaultLogger`, `silentLogger` from `Runtime.res`
- Removed `logger` from `module type Environment`
- Added `extractCorrelationId` to `module type Environment` (Lambda + InMemory implementations)
- Provided `RequestContext` at dispatch with extracted `correlationId`
- Replaced all `Logger.*` calls with `Console.*` in callbacks, operations, and builders
- Added `S.enableJson()` to callback files that lost it due to changed import chains
- Simplified `OutputLogger.res` to direct `Console.log2`

---

## Phase B — Effect Built-in Logger in Callbacks (complete)

### Work Item 5 — Add Effect.logInfo/logError/etc. bindings to rescript-effect (complete)

Add ReScript bindings for Effect's built-in log functions in `rescript/rescript-effect/src/Effect.res`:

```rescript
// Effect's built-in log functions — no service requirements.
// They use the fiber's logger, configured at the layer level.
// Returns Effect.t<unit, unit, unit> (no requirements).

@module("effect") @scope("Effect")
external logInfo: string => t<unit, unit, unit> = "logInfo"

@module("effect") @scope("Effect")
external logDebug: string => t<unit, unit, unit> = "logDebug"

@module("effect") @scope("Effect")
external logWarning: string => t<unit, unit, unit> = "logWarning"

@module("effect") @scope("Effect")
external logError: string => t<unit, unit, unit> = "logError"
```

Note: Effect TS `logInfo` is variadic (`...message: Array<any>`), but binding as single-string
is sufficient — format multi-arg messages into a string using formatting helpers or interpolation.

**Implementation note:** Bindings use polymorphic error/requirements (`t<unit, 'e, 'r>`) instead of
`t<unit, unit, unit>` because TS `never` is the bottom type (unifies with anything). Using `unit`
would cause type errors when used inside `Effect.tap` in pipelines with `string` error channels.

### Work Item 6 — Create LogFormat.res and delete Logger.res (complete)

**Step 1:** Create `reventless/reventless-core/src/util/LogFormat.res` with the formatting helpers
moved from `Logger.res`:

```rescript
// Log formatting utilities for domain objects.

let commandJsonToLogMessage: Message.commandJson => string = ({id, meta, commandJson}) => {
  let commandName = commandJson->Message.variantNameOfJson
  let commandStr = commandJson->JSON.stringify
  let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
  `${commandName}(${id}): {"command":${commandStr},"meta":${metaStr},"id":${id}}`
}

let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmds => {
  let count = cmds->Array.length->Int.toString
  cmds->Array.mapWithIndex((cmd, idx) => {
    let idx = (idx + 1)->Int.toString
    `${idx}/${count}: ${cmd->commandJsonToLogMessage}`
  })
}

let event'JsonToLogMessage = eventJson' => {
  let eventName = eventJson'->Message.eventNameOfEvent'Json
  let (id, metaStr, eventStr) = eventJson'->Message.idMetaEventOfEvent'Json
  let event'Str = `{"event":${eventStr},"meta":${metaStr},"id":"${id}"}`
  `${eventName}(${id}): ${event'Str}`
}
```

**Step 2:** Update all references from `Logger.commandJsonToLogMessage` etc. to `LogFormat.*`.

**Step 3:** Delete `Logger.res`.

**Step 4:** Update `LoggerTest.res` → rename to `LogFormatTest.res`, update imports.

### Work Item 7 — Delete EffectLogger (complete)

Remove the custom Logger service — Effect's built-in logger replaces it entirely.

**Step 1:** Remove `provideService(EffectLogger.tag, EffectLogger.consoleLogger)` from dispatch points:
- `Runtime.res` — `runEffectHandler`
- `AggregateRuntime_Builder_Common.res` — `runEffect`
- `EventCollectorRuntime_Builder_Single.res` — `runEffect`

**Step 2:** Delete `rescript/rescript-effect/src/Logger.res` (the custom Logger service).

**Step 3:** Delete `rescript/rescript-effect/src/EffectLogger.res` (the alias).

**Step 4 (added):** Update `InMemory_Bus.res` — replaced `Logger.t` config with `silent: bool`.
`MakeWithLogger` → `MakeSilent`. `Platform.MakeWithConfig` takes `{let silent: bool}` instead of
`{let logger: Logger.t}`. The Bus's single diagnostic warning uses `Console.warn` directly when
`silent=false`.

### Work Item 8 — Replace Console.* with Effect.logInfo/logError in callbacks (complete)

Replace `Console.*` calls in all runtime callbacks and operations with Effect's built-in log functions.

**Pattern for pure Effect code** (inside `Effect.flatMap`, `Stream.mapEffect`, etc.):

```rescript
// Before:
->Effect.map(result => {
  Console.log("processed")
  result
})

// After:
->Effect.tap(_ => Effect.logInfo("processed"))
```

**Pattern for async closures** (`Effect.promise(async () => ...)`):

Inside `Effect.promise`, we're in Promise-land. Use `Effect.runSync` on the log effect
(log effects are synchronous — they just write to the fiber logger):

```rescript
Effect.promise(async () => {
  // Before:
  Console.log("starting")
  // After:
  Effect.logInfo("starting")->Effect.runSync
  ...
})
```

**Pattern for code that can be lifted out of the async closure:**

Where a log call is at the boundary between Effect-land and Promise-land, prefer
`Effect.tap` before `Effect.promise` rather than `runSync` inside it:

```rescript
// Before:
->Effect.flatMap(_ =>
  Effect.promise(async () => {
    Console.log("starting")
    ...
  })
)

// After:
->Effect.tap(_ => Effect.logInfo("starting"))
->Effect.flatMap(_ =>
  Effect.promise(async () => {
    ...
  })
)
```

**Formatting helpers:** Use `LogFormat.*` to format domain objects into strings:

```rescript
Effect.logInfo("Handling command: " ++ LogFormat.commandJsonToLogMessage(cmdJson))
```

### Callbacks to migrate

**Light logging (1-3 calls):**

1. `InboundTranslationSlice_Callback.res` — 1x `Console.error`
2. `AutomationSlice_Callback.res` — 3x `Console.error`
3. `OutboundTranslationSlice_Callback.res` — 3x `Console.error`
4. `Plugin_Callback.res` — 2x `Console.log`

**Medium logging (4-6 calls):**

5. `StateChangeSlice_Callback.res` — 6x `Console.log`/`Console.error`/`Console.log2`
6. `CommandTopic_Callback.res` — `Console.error`, `Effect.tap`+`Effect.sync` with Console

**Heavy logging (7+ calls):**

7. `Aggregate_Callback.res` — 8+ calls
8. `SideEffectHandler_Callback.res` — `Console.log` with formatting
9. `EventMapper_Callback.res` — `Console.log` with formatting

**Non-callback files (Operations):**

10. `CommandTopic_Operations.res` — 2x with formatting
11. `EventTopic_Operations.res` — 2x with formatting
12. `Extension_Operations.res` — `Console.error`, `Console.log2`
13. `ExtensionPoint_Operations.res` — `Console.error`, `Console.log2`
14. `CommandPublisher.res` — `Console.error2`, `Console.log`
15. `Core_Callback.res` — `Console.log` with formatting

**Runtime builder handlers** (migrated — these run per Lambda invocation, not at deploy time):

- `AggregateRuntime_Builder_Common.res` — `aggregateHandler` dispatch logging
- `EventCollectorRuntime_Builder_Single.res` — `eventCollectorHandler` dispatch logging

**Deploy-time logging (keep as Console.log — runs during Pulumi wiring, no Effect pipeline):**

- `AggregateRuntime_Builder_Common.res` — `Output.apply` handler registration messages (`*****`)
- `EventCollectorRuntime_Builder_Single.res` — `Output.apply` + `validateParent` + `finish` messages
- `OutputLogger.res` — deploy-time output logging
- `GraphQL_Stitcher.res` — deploy-time schema stitching
- `Projection.res` — deploy-time projection setup
- Builder files (`StateChangeSlice_Builder.res`, `AutomationSlice_Builder.res`,
  `OutboundTranslationSlice_Builder.res`)

**Stubs/placeholders (skip):**

- `Heartbeat_Callback.res`, `StateViewSlice_Callback.res`, `ExtensionPoint_Callback.res`

### Work Item 9 — Migrate remaining core runtime files (complete)

Additional core runtime files that were missed in WI 8. Same patterns apply — `Effect.logInfo`/
`Effect.logError`/`Effect.logWarning` with `->Effect.runSync` for non-Effect contexts.

**Callbacks/Operations (13 files, ~30 call sites):**

- `Counter_Callback.res` — 4x `Console.log`/`log2` → `Effect.logInfo`
- `Counter_Operations.res` — 4x `Console.log` → `Effect.logInfo`/`Effect.logError`
- `CommandGenerator_Callback.res` — 1x `Console.log2` → `Effect.logInfo`
- `ReadModel_Callback.res` — 1x `Console.log2` → `Effect.logInfo`
- `DcbEventLog_Operations.res` — 1x `Console.log2` → `Effect.logError`
- `PluginExtensionPoint_Plugin.res` — 5x `Console.log2`/`log3`/`warn3` → `Effect.logInfo`/`logWarning`/`logError`
- `ScheduleOps.res` — 4x `Console.log2`/`log3` → `Effect.logInfo`/`Effect.logError`
- `MapperNto1.res` — 1x `Console.log2` → `Effect.logError`
- `Util_AdapterRuntime.res` — 2x `Console.log` → `Effect.logError`
- `Util_QueryDbRuntime.res` — 1x `Console.log2` → `Effect.logError`
- `FTPHandler.res` — 6x `Console.log`/`log2`/`error2` → `Effect.logInfo`/`Effect.logError`
- `Util_Promise.res` — 1x `Console.log2` → `Effect.logError`
- `Validation.res` — 1x `Console.log` → `Effect.logError`

**Multi-arg Console calls:** Converted `Console.log2`/`log3` to string interpolation or
`JSON.stringifyAny` for non-string values (e.g., `err->JSON.stringifyAny->Option.getOr("unknown")`).

**Remaining Console.* in production after WI 9:**
- Deploy-time code (Pulumi `Output.apply`, builders, stitchers, projection)
- AWS adapter runtime files (tracked in Phase C backlog plan)
- `reventless-spec` package (`Message.res`, `Handler.res`, `SideEffect.res` — no Effect dependency)
- In-memory dev tooling (`MCP_Server.res`, `GraphQL_Server.res`)
- Test files

---

## Phase C — Pure Effect Callbacks (future, separate plan)

### Goal

Restructure callbacks to stay entirely in the Effect pipeline, eliminating
`Effect.promise(async () => ...)` blocks in favor of Effect combinators.

### Why

After Phase B, logging inside async closures uses `Effect.logInfo(...)->Effect.runSync` — it works
but is awkward. Pure Effect callbacks would:

- Make logging natural: `->Effect.tap(_ => Effect.logInfo("msg"))` with no `runSync`
- Enable testability: silence logs with `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`
- Enable composability: callbacks become pure Effect values — combinable, retriable, timeable
- Align with the Effect programming model

### Scope

**Core callbacks** — each needs restructuring:
- `Effect.promise(async () => { ... })` → Effect combinators (`flatMap`, `tap`, `forEach`, `all`)
- `await somePromise` → `Effect.tryPromise(() => somePromise)`
- `Array.map(async ...)` → `Effect.forEach` or `Effect.all`
- Mutable accumulators → `Effect.reduce` or `Ref`

**AWS adapter runtime files** — migrate `Console.*` to `Effect.logInfo`/`Effect.logError` once the
functions they're called from are lifted into pure Effect pipelines. These were out of scope for
Phase B because they sit below the callback layer as infrastructure adapters, and using
`Effect.logInfo->Effect.runSync` in plain async functions provides no benefit over `Console.*`.

AWS runtime files to migrate (all in `reventless/reventless-aws/src/`):

- `adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res` — SQS command handling + publishing
- `adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res` — SQS/DynamoDB stream event handling
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res` — DynamoDB stream events
- `adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` — event log storage errors/warnings
- `adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` — QueryDb CRUD with retry logging
- `adapter/QueryEngine/QueryEngine_DynamoDb.res` — query/scan logging
- `adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res` — counter stream handling
- `adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res` — scheduled publish errors
- `adapter/Cloner/ClonerRunner_Fargate_Runtime.res` — cloner diagnostics
- `util/Util_SQS_Runtime.res` — SQS send/delete with retry logging
- `util/Util_DynamoDb_Runtime.res` — DynamoDB put/delete with retry logging
- `util/Util_TopicSubscription_Runtime.res` — SNS subscribe/unsubscribe errors
- `util/Util_PluginMessage_Runtime.res` — plugin message errors
- `util/Util_Cognito_Runtime.res` — Cognito user creation logging
- `util/Util_SNS_FIFO.res` — SNS FIFO error logging
- `util/Util_DeadLetterQueue.res` — dead letter logging

AWS deploy-time files (keep as `Console.*` — no Effect pipeline):
- `util/Util_DynamoDb.res`, `util/Util_DynamoDbStream.res`, `util/Util_SNS.res`
- `adapter/EventCollector/EventCollectorChannel_Helpers.res`
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res`
- `components/DataCleaner.res`

This is a significant refactor — each callback can be migrated independently.
Should be its own plan with per-callback work items.

---

## Completed Work Items (Phase A)

### Work Item 1 — Remove old Logger output functions (complete)

Removed `Logger.log/info/warn/error/debug`, `Logger.Level`, `Logger.createTag`, `logCmdJson`,
`logCmdJsons`, `logJsonEvent`. Kept formatting helpers temporarily in `Logger.res`.

### Work Item 2 — RequestContext provision at dispatch (complete)

Added `extractCorrelationId` to `module type Environment` (Lambda + InMemory). `runEffect` in
both runtime builders provides `RequestContext` with extracted correlationId.
`runEffectHandler` in `Runtime.res` provides `RequestContext.test()`.

### Work Item 3 — Remove runtimeLogger (complete)

Removed `type runtimeLogger`, `defaultLogger`, `silentLogger` from `Runtime.res`.
Deploy-time builder logging uses `Console.log`/`Console.warn` directly.

### Work Item 4 — Remove Logger output functions from Logger.res (complete)

Logger.res now contains only formatting helpers. These move to `LogFormat.res` in Work Item 6.

---

## Verification

After each work item:

1. `npm run build` from root — zero warnings, zero errors
2. `cd reventless/reventless-core && npm test` — all tests pass
3. `cd reventless/reventless-in-memory && npm test` — all tests pass
4. `cd examples/online-shop-aggregates && npm run build` — compiles
5. `cd examples/online-shop-dcb && npm run build` — compiles

---

## Ordering

```
Phase A (complete: WI 1-4)
  │
  ├─> Work Item 5 (add Effect.logInfo bindings)
  ├─> Work Item 6 (LogFormat.res + delete Logger.res)
  │        │
  │        v
  ├─> Work Item 7 (delete EffectLogger)
  │        │
  │        v
  └─> Work Item 8 (replace Console.* with Effect.logInfo in callbacks)
              │
              v
       Work Item 9 (migrate remaining core runtime files)
              │
              v
       Phase C (pure Effect callbacks — docs/plans/Backlog/pure-effect-callbacks.md)
```

Work Items 5, 6 can be done in parallel.
Work Item 7 depends on 5 (need Effect.logInfo before removing EffectLogger).
Work Item 8 depends on 5, 6, 7.
Work Item 9 depends on 8 (same patterns, additional files).
