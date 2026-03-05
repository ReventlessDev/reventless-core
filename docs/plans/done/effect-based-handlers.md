# Effect-Based Handlers

**Status:** In Progress

**Created:** 2026-03-05

**Depends on:** `docs/plans/done/effect-context-layer-integration.md` (complete)

**Summary:** Convert the inner handler dispatch from `promise`-based `eventHandler` to `Effect.t`-based
`effectHandler`, moving `Effect.runPromise` from channel adapters to the runtime builder dispatch
point. This creates a natural injection point for Effect services (Logger, RequestContext) via
`Effect.provideService`.

---

## Background

The framework's handler infrastructure uses `eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>` — plain async functions. The callback handlers (CommandTopic_Callback, ReadModel_Callback, etc.) already return `Effect.t` internally, but the channel adapters call `Effect.runPromise` and wrap the result back into a promise. This means the dispatch point (`aggregateHandler`, `eventCollectorHandler`) has no opportunity to provide Effect services before execution.

By moving `Effect.runPromise` from channel adapters to the runtime builder dispatch, we gain a natural injection point for Effect services. The outer handler (`aggregateHandler`) remains promise-based because Lambda expects a promise return — only the inner dispatch changes.

### Key Insight: Callbacks Already Return Effect

The `jsonCommandsHandler` type is `Stream → Effect.t<array<result<string, string>>, string, unit>`.
The `jsonEventsHandler` type is `Stream → Effect.t<unit, string, unit>`.
Channel adapters currently call `Effect.runPromise` on these and wrap into `eventHandler`. We simply
stop doing that — return the Effect directly and let the dispatcher run it.

### Namespace Shadowing Issue

`ReventlessCore.Logger` (in `src/util/Logger.res`) shadows the Effect `Logger` module from
`rescript-effect`. To reference the Effect Logger's tag/implementations from within `reventless-core`,
we add `EffectLogger.res` in `rescript-effect` as an alias.

---

## Scope

- **In scope:** Handler type infrastructure, channel adapter changes, runtime builder dispatch,
  CommandGenerator conversion, Logger service provision at dispatch
- **Out of scope:** Converting callback internals to use `serviceWith(Logger.tag, ...)` (follow-on
  per-callback), RequestContext provision (needs per-event-format extraction), removing `eventHandler`
  type (still used by `RuntimeEnvironment.make` for the outer Lambda handler)

---

## Phase A — `effectHandler` type and `Environment` module type

**File:** `reventless/reventless-core/src/adapter/Runtime/Runtime.res`

### What to add/change

```rescript
// Effect-based handler for inner dispatch.
// The outer Lambda/Deferred handler remains promise-based (eventHandler);
// only the per-component handlers stored in runtime builder dicts use this type.
type effectHandler<'event, 'context, 'result> = ('event, 'context) => Effect.t<'result, unit, unit>
```

In `module type Environment`:
- Rename `asEventHandler` → `asEffectHandler` with signature `'a => effectHandler<event, context, 'result>`
- Keep `eventHandler`, `environmentMaker`, `make` unchanged (outer handler stays promise-based)

### Notes

- Error type is `unit` in the type definition; actual error types vary across handlers but are coerced
  via `%identity` (same as the existing `asEventHandler` pattern). This is safe because
  `Effect.runPromise` handles any error type.
- The `'r` channel is `unit` because ReScript cannot express union requirements. Services are still
  provided at runtime via `provideService` — the type just doesn't enforce it.

---

## Phase B — Module type updates

**File:** `reventless/reventless-core/src/adapter/Runtime/AggregateRuntime_Builder.res`

```rescript
// Change forCommandTopic and forEventCollector handler types:
let forCommandTopic: Runtime.forComponent<
  Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit>,  // was eventHandler
  runtimeParts,
  CommandTopic.component<'op>,
>
let forEventCollector: Runtime.forEventCollector<
  Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit>,  // was eventHandler
  EventCollector.component,
>
let forCommandGenerator: Runtime.forComponent<
  CommandGenerator.effectEventHandler<context>,  // new type
  runtimeParts,
  CommandGenerator.component,
>
```

**File:** `reventless/reventless-core/src/adapter/Runtime/EventCollectorRuntime_Builder.res`

```rescript
let forEventCollector: Runtime.forEventCollector<
  Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit>,  // was eventHandler
  EventCollector.component,
>
```

---

## Phase C — Adapter type contracts

**File:** `reventless/reventless-core/src/components/CommandTopic/CommandTopic_Adapter.res`

Change `handleChannelEvent` in the `channel` record type:

```rescript
handleChannelEvent: CommandTopic.jsonCommandsHandler => Pulumi.Output.t<
  Runtime.effectHandler<'callbackEvent, 'context, unit>,  // was Runtime.eventHandler
>,
```

**File:** `reventless/reventless-core/src/components/EventCollector/EventCollector_Adapter.res`

Same change to `handleChannelEvent`:

```rescript
handleChannelEvent: EventCollector.jsonEventsHandler => Pulumi.Output.t<
  Runtime.effectHandler<'callbackEvent, 'context, unit>,  // was Runtime.eventHandler
>,
```

---

## Phase D — `EffectLogger.res` alias

**File:** `rescript/rescript-effect/src/EffectLogger.res` (new)

```rescript
// Alias for Logger that can be referenced from namespaced packages
// where "Logger" is shadowed (e.g., ReventlessCore has its own Logger.res).
// Effect's Context.GenericTag caches by key, so EffectLogger.tag and Logger.tag
// are the same runtime object.
include Logger
```

---

## Phase E — CommandGenerator types

**File:** `reventless/reventless-core/src/components/CommandGenerator/CommandGenerator.res`

```rescript
// Change:
type commandGenerator = payload => promise<string>
// To:
type commandGenerator = payload => Effect.t<string, unit, unit>

// Add:
type effectEventHandler<'context> = Runtime.effectHandler<payload, 'context, string>
```

---

## Phase F — In-memory channel adapters

**File:** `reventless/reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`

Change `handleChannelEvent` to return Effect instead of promise:

```rescript
// Before:
let handleChannelEvent = (handleCmds: ReventlessCore.CommandTopic.jsonCommandsHandler) =>
  (
    (fullBody: JSON.t, _ctx) => {
      let reference = decodeId(fullBody)
      let item = {command: fullBody, reference}
      handleCmds(Stream.fromIterable([item]))
      ->Effect.runPromise
      ->Promise.thenResolve(_ => ())
    }
  )->Pulumi.Output.make

// After:
let handleChannelEvent = (handleCmds: ReventlessCore.CommandTopic.jsonCommandsHandler) =>
  (
    (fullBody: JSON.t, _ctx) => {
      let reference = decodeId(fullBody)
      let item = {command: fullBody, reference}
      handleCmds(Stream.fromIterable([item]))
      ->Effect.map(_ => ())
    }
  )->Pulumi.Output.make
```

**File:** `reventless/reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res`

```rescript
// Before:
handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
  ((json: JSON.t, _ctx) =>
    handleEvents(Stream.fromIterable([json]))->Effect.runPromise
  )->Pulumi.Output.make,

// After:
handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
  ((json: JSON.t, _ctx) =>
    handleEvents(Stream.fromIterable([json]))
  )->Pulumi.Output.make,
```

---

## Phase G — AWS channel adapters

**File:** `reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res`

Change `handleQueueEvent` to return Effect instead of async:

```rescript
// Before: async (event, _) => { ... await ...->handleJsonCommands->Effect.runPromise ... }
// After:
let handleQueueEvent = (queue, handleJsonCommands: ReventlessCore.CommandTopic.jsonCommandsHandler) =>
  (event: PulumiAws.SQS.Queue.event, _) => {
    let records = event.records
    let jsons = records->Array.filterMap(record => ...)
    let topicItems = ...

    Stream.fromIterable(topicItems)
    ->handleJsonCommands
    ->Effect.flatMap(results =>
      Effect.promise(async () => {
        // SQS delete batch logic (same as before, just inside Effect.promise)
        ...
      })
    )
    ->Effect.map(_ => ())
  }
```

**File:** `reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res`

Change `handleDynamoDbEvent` and `handleDynamoDbOrSqsEvent`:

```rescript
// Before: async (event, _) => { ... await (Stream...->handleEvents->Effect.runPromise) }
// After:
let handleDynamoDbEvent = handleEvents =>
  (event: PulumiAws.Lambda.CallbackFunction.event, _) => {
    let jsons = event.records->Array.filterMap(...)
    Stream.fromIterable(jsons)->handleEvents
  }
```

**File:** `reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res`

Same pattern — return Effect instead of async.

**Files that just follow the type changes:**
- `reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS.res`
- `reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res`

---

## Phase H — Runtime builder dispatch

**File:** `reventless/reventless-core/src/adapter/Runtime/AggregateRuntime_Builder_Common.res`

```rescript
// Change dict types:
type effectHandler = Runtime.effectHandler<RuntimeEnvironment.event, context, unit>
let commandTopicHandlers: dict<effectHandler> = Dict.make()
let eventCollectorHandlers: dict<array<effectHandler>> = Dict.make()
let commandGeneratorHandlers: dict<CommandGenerator.effectEventHandler<context>> = Dict.make()

// In aggregateHandler dispatch:
// Before:
await handler(event, context)
// After:
await handler(event, context)
  ->Effect.provideService(EffectLogger.tag, EffectLogger.consoleLogger)
  ->Effect.runPromise

// In forCommandTopic/forEventCollector:
// Use RuntimeEnvironment.asEffectHandler instead of asEventHandler
```

**File:** `reventless/reventless-core/src/adapter/Runtime/EventCollectorRuntime_Builder_Single.res`

Same changes to handler dict type and dispatch.

---

## Phase I — CommandGenerator callback

**File:** `reventless/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res`

```rescript
// Before:
let generateCommand = async (payload: CommandGenerator.payload) => {
  ...
  meta.msgId
}

// After:
let generateCommand = (payload: CommandGenerator.payload) =>
  Effect.promise(async () => {
    ...
    meta.msgId
  })
```

**File:** `reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res`

```rescript
// handleResolversEvent wraps generateCommand. Type changes flow automatically:
// (event, _context) => event->generateCommand
// Now returns Effect.t<string, unit, unit> instead of promise<string>
```

---

## Phase J — RuntimeEnvironment implementations

**File:** `reventless/reventless-in-memory/src/adapter/Runtime/RuntimeEnvironment_InMemory.res`

```rescript
// Rename:
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<event, context, 'r> = "%identity"
// (was asEventHandler → eventHandler)
```

**File:** `reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res`

```rescript
// Rename:
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<event, context, 'r> = "%identity"
```

---

## Phase K — In-memory connect code update

The `connect` functions in in-memory channel adapters call `handler(json, ctx)` on the
promise-based handler from the Deferred (which is `aggregateHandler` — still promise-based).
**These do not change** — the Deferred stores the outer promise-based handler, not the inner
effectHandlers.

---

## Verification

1. `npm run build` from root — zero warnings, zero errors
2. `cd reventless/reventless-in-memory && npm test` — all in-memory tests pass
3. `cd examples/online-shop-aggregates && npm run build` — example compiles
4. `cd examples/online-shop-dcb && npm run build` — example compiles

---

## Follow-On Work

1. **Per-callback Logger migration**: Update individual callbacks to use
   `Effect.serviceWithEffect(EffectLogger.tag, logger => logger.info(...))` instead of
   `Console.log`/`Logger.info`. Each callback is independent.
2. **RequestContext provision**: Extract correlationId from events at the dispatch point, provide
   via `Effect.provideService(RequestContext.tag, ...)`. Requires event-format-specific extraction.
3. **Remove `Runtime.runtimeLogger`**: Once all dispatch logging uses the Effect Logger service,
   the synchronous `runtimeLogger` type and `defaultLogger`/`silentLogger` can be removed.
