# Plan: Stream-Based Handler Implementation (Phases J–P)

**Status:** Phases J–K–L–M–N–O–P complete; Phase Q planned

**Created:** 2026-02-28

**Analysis:** `docs/analysis/stream-based-runtime-handler-analysis.md`

**Preconditions:** Phases A–I of `docs/plans/done/effect-stream-integration.md` (complete)

**Summary:** Full implementation of stream-based interfaces at L2 (internal framework batch handler)
and L3 (in-memory Bus subscription). Phase I (StateChangeSlice streaming fold) was already completed
during the effect-stream-integration plan and is verified complete. This plan covers Phases J, K,
and L.

---

## Background

The analysis document identified three layers where stream-based handlers could apply:

- **L1 — Lambda boundary**: verdict = keep callback (not this plan)
- **L2 — Application batch handler**: internal `jsonEventsHandler` is array-based; full
  implementation changes it to `Stream.t<JSON.t>` inside the framework while the user-facing
  `eventsHandler` in `reventless-spec` gains a stream variant in `reventless-core`
- **L3 — InMemory Bus subscription**: `subscribeToEvents` exposes a raw stream alongside the
  existing callback API; `EventCollectorChannel_InMemory` is updated to use the stream path

Phase I status: `StateChangeSlice_Callback.Make.handleSingleCommand` already uses
`dcbEventLog.readStream(...)->Stream.runFold(...)` — confirmed complete.

---

## Phase J — collectNEvents Test Utility

**Scope:** Single new file in `reventless-in-memory`. Zero changes to existing APIs.

**Goal:** A test-only helper that subscribes to a bus topic and accumulates exactly N events,
returning them as an `Effect.t<array<collectedEvent>>`. Uses the existing `subscribeToEvents`
callback API so `done_` is handled automatically by the drain fiber.

### New file: `reventless-in-memory/src/TestUtils.res`

```rescript
// Test utilities for reventless-in-memory.
// Not intended for production use.

type collectedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
}

/**
 * Subscribe to topicName and return an Effect that resolves once exactly n events
 * have been delivered by the bus.
 *
 * The subscription is registered synchronously (before the returned Effect is run),
 * so events published after calling collectNEvents but before awaiting the Effect
 * are captured correctly.
 *
 * done_ is NOT embedded in collectedEvent — it is handled automatically by the
 * drain fiber inside InMemory_Bus.subscribeToEvents.
 */
let collectNEvents = (
  subscribeToEvents: (string, (string, ReventlessCore.Message.meta, JSON.t) => promise<unit>) => unit,
  topicName: string,
  n: int,
) => {
  let collected: ref<array<collectedEvent>> = ref([])
  let latch = Deferred.make()->Effect.runSync
  subscribeToEvents(topicName, async (service, meta, json) => {
    collected.contents->Array.push({service, meta, json})
    if Array.length(collected.contents) >= n {
      Deferred.succeed(latch, ())->Effect.runSync->ignore
    }
  })
  Deferred.await_(latch)->Effect.map(_ => collected.contents)
}
```

### Usage pattern in tests

```rescript
module Bus = InMemory_Bus.Make()
// Set up subscriptions before publishing
let collectEffect = TestUtils.collectNEvents(Bus.subscribeToEvents, "MyTopicEventTopic", 3)

// ... publish events ...

let events = await collectEffect->Effect.runPromise
// assert on events
```

### Files changed — complete

| File | Change |
|------|--------|
| `reventless-in-memory/src/test/TestRunner.res` | Added `collectedEvent` type and `collectNEvents` |
| `reventless-in-memory/tests/adapter/CollectNEventsTest.res` | **Created** — 5 tests, all passing |

---

## Phase K — L2 Stream Handler Types

**Scope:** Change the internal framework handler (`jsonEventsHandler`) from array-based to
stream-based. Add a stream variant for user-facing handlers in `reventless-core` without
modifying `reventless-spec` (which has no Effect dependency).

### K.1 — Internal framework type: `jsonEventsHandler`

**File:** `reventless-core/src/components/EventCollector/EventCollector.res`

The core internal handler type changes from:
```rescript
// Current
type jsonEventsHandler = array<JSON.t> => promise<unit>
```

to:

```rescript
// New
type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

// Backward-compat bridge for callers that still use array<JSON.t>
let fromArrayHandler: (array<JSON.t> => promise<unit>) => jsonEventsHandler =
  arrayHandler => stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(chunk =>
      Effect.promise(() => arrayHandler(chunk->Chunk.toArray))
    )
```

The `EventCollector.T` module type and `makeHandler` parameter update accordingly:
```rescript
module type T = {
  // ...
  let makeHandler: (
    ~eventCollector: component,
    ~eventsHandler: jsonEventsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>
}
```

### K.2 — Adapter type: `handleChannelEvent`

**File:** `reventless-core/src/components/EventCollector/EventCollector_Adapter.res`

```rescript
// Current
type channel<'callbackEvent, 'context, 'channelParts> = {
  // ...
  handleChannelEvent: EventCollector.jsonEventsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
}
```

The type alias flows through — no structural change needed here, since `jsonEventsHandler` is
the same name; the type behind it changes in K.1.

### K.3 — In-memory channel: `handleChannelEvent` implementation

**File:** `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res`

The current implementation wraps a single JSON in an array:
```rescript
// Current
handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
  ((json: JSON.t, _ctx) => handleEvents([json]))->Pulumi.Output.make,
```

New implementation wraps a single JSON in a `Stream.fromIterable`:
```rescript
// New
handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
  ((json: JSON.t, _ctx) =>
    handleEvents(Stream.fromIterable([json]))->Effect.runPromise
  )->Pulumi.Output.make,
```

### K.4 — AWS Lambda channel: `handleChannelEvent` implementation

**File:** `reventless-aws/src/adapter/EventCollector/EventCollectorChannel_Lambda.res` (or
equivalent SQS channel file)

The AWS channel receives an SQS batch. Current implementation likely calls `handleEvents(batch)`.
New implementation wraps the batch in `Stream.fromIterable`:

```rescript
// New
handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
  ((sqsEvent, ctx) =>
    handleEvents(Stream.fromIterable(sqsEvent.records->Array.map(r => r.body)))
    ->Effect.runPromise
  )->Pulumi.Output.make,
```

This is where streaming actually provides value for large SQS batches: lazy decoding via
`Stream.mapEffect` can be added later without changing the handler signature.

### K.5 — User-facing stream handler type in reventless-core

**File:** `reventless-core/src/components/EventCollector/EventCollector_Builder.res` (new helper)

Add an opt-in stream builder helper so user code written in Effect style can provide a stream
handler directly:

```rescript
// Convenience: wrap a stream eventsHandler into the internal jsonEventsHandler.
// Users call this when they want to write their handler as a Stream consumer.
let makeStreamHandler = (
  ~eventCollector: EventCollector.component,
  ~schema: S.t<'event>,
  ~eventsStreamHandler: Stream.t<'event, string, unit> => Effect.t<unit, string, unit>,
) => {
  let jsonHandler: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.try(
        ~catch=exn => JsExn.fromException(exn)->JsExn.message->Option.getOr("decode error"),
        () => json->S.parseOrThrow(schema),
      )
    )
    ->eventsStreamHandler

  makeHandler(~eventCollector, ~eventsHandler=jsonHandler)
}
```

### Files changed (Phase K) — complete

| File | Change |
|------|--------|
| `rescript-effect/src/Effect.res` | Added `trySync` binding (`Effect.try` in JS) |
| `reventless-core/src/components/EventCollector/EventCollector.res` | Changed `jsonEventsHandler` type; added `fromArrayHandler` bridge |
| `reventless-core/src/components/EventCollector/EventCollector_Builder.res` | Added standalone `makeStreamHandler` (outside `Make` functor) |
| `reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res` | Renamed array impl to `eventsHandlerImpl`; wrapped with `fromArrayHandler` |
| `reventless-core/src/components/EventMapper/EventMapper_Callback.res` | `CounterHandler.handleCounterEvents` type → `Counter.counterEventsHandler`; wrapped `handleJsonEvents` with `fromArrayHandler` |
| `reventless-core/src/components/ReadModel/ReadModel_Builder.res` | Wrapped `Callback.eventsHandler` with `fromArrayHandler` at call site |
| `reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` | Renamed local impl; wrapped with `fromArrayHandler` |
| `reventless-core/src/core/Core/Core_Helpers.res` | Wrapped `Callback.handleJsonEvents` with `fromArrayHandler` at call site |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | Wrapped `Callback.handleJsonEvents` with `fromArrayHandler` at call site |
| `reventless-core/tests/sideeffecthandler/SideEffectHandlerCallbackTest.res` | Updated `eventsHandler` calls to use `Stream.fromIterable` + `Effect.runPromise` |
| `reventless-core/tests/eventmapper/EventMapperCallbackTest.res` | Updated `handleJsonEvents` calls similarly |
| `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res` | Updated `handleChannelEvent` to use `Stream.fromIterable` + `Effect.runPromise` |
| `reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res` | Updated `handleDynamoDbOrSqsEvent` and `handleDynamoDbEvent` |
| `reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res` | Updated `handleStreamEvent` type annotation and call |

---

## Phase L — L3 InMemory Bus Stream Interface

**Scope:** Add `subscribeToEventStream` to `InMemory_Bus.T` that returns a scoped
`Effect.t<Stream.t<queuedEvent>>`. Keep `subscribeToEvents` for backward compatibility.
Update `EventCollectorChannel_InMemory.connect` to use the stream path.

### L.1 — Extend InMemory_Bus.T

**File:** `reventless-in-memory/src/adapter/InMemory_Bus.res`

Add to the module type `T`:
```rescript
module type T = {
  // ... existing fields ...

  /**
   * Stream-based alternative to subscribeToEvents.
   * Returns a scoped Effect that yields a Stream<queuedEvent> for the topic.
   * The subscriber count is incremented on scope open and decremented on scope close.
   * Callers MUST run msg.done_ after processing each message to unblock publishEvent.
   *
   * Use this for callers that want to compose the stream (filter, map, take) before consuming.
   * Use subscribeToEvents for simple fire-and-forget subscriptions.
   */
  let subscribeToEventStream: string => Effect.t<Stream.t<queuedEvent, unit, unit>, unit, Scope.t>
}
```

### L.2 — Implement subscribeToEventStream in Impl

**File:** `reventless-in-memory/src/adapter/InMemory_Bus.res`, inside `module Impl`

```rescript
let subscribeToEventStream = (topicName) => {
  let hub = switch eventHubs.contents->Dict.get(topicName) {
  | Some(h) => h
  | None =>
    let h: PubSub.t<queuedEvent> = makeHub()
    eventHubs.contents->Dict.set(topicName, h)
    h
  }
  // Acquire: increment count + subscribe to hub
  // Release: decrement count (publisher will send fewer done_ countdowns on next publish)
  Effect.acquireRelease(
    Effect.sync(() => {
      let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(0)
      subscriberCounts.contents->Dict.set(topicName, n + 1)
    })
    ->Effect.flatMap(_ => PubSub.subscribe(hub)),
    queue =>
      Effect.sync(() => {
        let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(1)
        subscriberCounts.contents->Dict.set(topicName, n - 1)
      })
      ->Effect.zipRight(Queue.shutdown(queue)),
  )
  ->Effect.map(queue => Stream.fromQueue(queue))
}
```

Note: `done_` safety is the caller's responsibility when using `subscribeToEventStream`.
Forgetting to run `msg.done_` will cause `publishEvent` to hang. This is the trade-off
documented in the analysis. The `subscribeToEvents` callback variant remains the safer default.

### L.3 — Update EventCollectorChannel_InMemory.connect to use stream

**File:** `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res`

Replace the `subscribeToEvents` callback inside `connect` with `subscribeToEventStream`:

```rescript
let connect = (~name as _, ~channelSpecs, ~runtime, ~opts as _) => {
  channelSpecs->Array.forEach(({eventTopics}: ...) => {
    eventTopics->Dict.valuesToArray->Array.forEach((topicOutputs: ...) => {
      topicOutputs.resources->Array.forEach(resource => {
        let _ = resource.name->Pulumi.Output.apply(topicName => {
          // Use stream interface: drain fiber lives here, done_ is explicit.
          let drainEffect = Effect.scoped(
            Bus.subscribeToEventStream(topicName)
            ->Effect.flatMap(stream =>
              stream->Stream.runForEach(msg => {
                Effect.promise(async () => {
                  let handler =
                    await runtime.parts.handlerDeferred->Deferred.await_->Effect.runPromise
                  await handler(msg.json, ())
                })
                ->Effect.zipRight(msg.done_)  // must run done_ to unblock publishEvent
              })
            )
          )
          let _ = Effect.runFork(drainEffect)
          runtime.parts.subscriptionLatch->Latch.open_->Effect.runPromise->ignore
        })
      })
    })
  })
  []
}
```

### Files changed — Phase L (complete)

| File | Change |
|------|--------|
| `reventless-in-memory/src/adapter/InMemory_Bus.res` | Added `subscribeToEventStream` to `T` and implemented in `Impl` |
| `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res` | Updated `connect` to use `subscribeToEventStream` with explicit `done_` |

**Note on `Scope.t`** (open question 2): No `Scope.res` binding exists in `rescript-effect`. The return type of `subscribeToEventStream` uses `unit` for the requirements parameter `'r` in the module type signature. Since callers always wrap with `Effect.scoped` (which satisfies the runtime Scope requirement), this is safe in practice. The implementation's unconstrained `'r` unifies with `unit` at the module boundary.

---

## Execution Order

```
Phase J   →  Phase K   →  Phase L
(no deps)    (needs J    (needs K if we
              to test)     use stream in
                           channel connect)
```

Phase J can be implemented independently. Phase K changes the internal handler type and must be
followed by updating all adapter implementations (K.3, K.4). Phase L builds on top of Phase K
because `EventCollectorChannel_InMemory.connect` will call the stream-based handler it gets from
the runtime (which is now stream-based after K.3).

---

## Testing Plan

### Phase J tests
- Unit test `collectNEvents` with a fresh `InMemory_Bus.Make()` bus
- Verify that: events published before the Effect resolves are captured
- Verify that: the Effect resolves exactly when N events arrive, not before

### Phase K tests
- Existing `EventCollectorTest` suite must still pass (the array callback bridge `fromArrayHandler` ensures backward compat)
- Add new test: pass a `Stream.runForEach`-based handler directly to `makeStreamHandler`
- Verify lazy decoding: publish 3 events, handler only sees 2 via `Stream.take(2)`

### Phase L tests
- Existing `EventCollectorChannel_InMemory` tests must still pass
- Add test: `subscribeToEventStream` returns a composable stream
- Verify `done_` is correctly run inside the new drain fiber (publishEvent resolves)
- Verify subscriber count decrement on scope close (no hanging publishEvent after scope ends)

---

## Open Questions

1. **AWS Lambda EventCollector channel**: The file path for `EventCollectorChannel_Lambda.res`
   (or equivalent) should be confirmed before Phase K.4 is implemented.

2. **Scope type annotation**: `subscribeToEventStream` return type uses `Scope.t` as the
   requirement. Confirm `Scope` binding is available in the existing `rescript-effect` bindings.

3. **Queue.shutdown vs Deferred for scope release**: When the stream scope closes (e.g., in
   tests using `Stream.take`), `Queue.shutdown` will terminate `Stream.fromQueue`. Confirm this
   does not interfere with the hub's other subscribers.

4. **Subscriber count race in L.2**: The count is incremented/decremented synchronously in
   Effect.sync, but `publishEvent` reads it from a separate callsite. If multiple
   subscribe/unsubscribe operations race with a publishEvent, the count may be stale. This is
   the same limitation as the current `subscribeToEvents` implementation; document but do not
   fix in this plan.

---

## Phase M — Native Stream Event Handlers

**Scope:** Remove all `fromArrayHandler` bridges from callback modules. Rewrite every
array-based event-handler implementation as a native stream consumer. Apply the naming
convention below to all handler types and values throughout the codebase.

**Naming convention (established across Phases M and N):**

> `json` in the name signals the handler works with `JSON.t` (the wire format).
> No qualifier signals the handler works with typed domain objects (`'event`, `'command`).
> Types are nouns; values are verbs.

| Encoding | Direction | Type name | Value name |
|----------|-----------|-----------|------------|
| Typed | events | `eventsHandler` | `handleEvents` |
| Typed | commands | `commandsHandler` | `handleCommands` |
| JSON | events | `jsonEventsHandler` | `handleJsonEvents` |
| JSON | commands | `jsonCommandsHandler` | `handleJsonCommands` |

### M.1 — Type renames: apply the json/typed naming rule

Several types are JSON-based but their names lack the `json` qualifier. Rename them now so
the type vocabulary is consistent before rewriting implementations.

**`Counter.counterEventsHandler` → `Counter.jsonEventsHandler`**

File: `reventless-spec/src/components/Counter.res`

```rescript
// Before
type counterEventsHandler = array<JSON.t> => promise<unit>

// After — renamed AND changed to stream shape
type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>
```

The `counter` prefix was redundant: the module already says `Counter`. The `json` qualifier
makes the encoding explicit. All callers update their type references accordingly.

**`Extension.eventHandler` → `Extension.jsonEventsHandler`**

File: `reventless-core/src/components/Extension/Extension.res`

```rescript
// Before
type eventHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>

// After
type jsonEventsHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
```

Singular `event` → plural `events` for consistency; `json` qualifier added.

**`ExtensionPoint.eventHandler` → `ExtensionPoint.jsonEventsHandler`**

File: `reventless-core/src/components/ExtensionPoint/ExtensionPoint.res`

Same rename as Extension above.

All `operations` records referencing these types (`incomingEventHandler`,
`outgoingEventHandler`) use the renamed type but keep their field names.

### M.2 — SideEffectHandler_Callback

**File:** `reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res`

Remove `eventsHandlerImpl` + `EventCollector.fromArrayHandler` bridge. Rewrite as a native
stream handler. Rename the exposed value from `eventsHandler` to `handleJsonEvents` (JSON-based
handler, verb form):

```rescript
// Before — module type T
let eventsHandler: EventCollector.jsonEventsHandler

// After — module type T
let handleJsonEvents: EventCollector.jsonEventsHandler
```

```rescript
// Before — implementation
let eventsHandlerImpl = (eventsJson': array<JSON.t>) => {
  eventsJson'
  ->Array.map(async eventJson' => ...)
  ->Promise.all
  ->Util.Promise.toUnit
}
let eventsHandler = EventCollector.fromArrayHandler(eventsHandlerImpl)

// After — implementation
let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
  stream
  ->Stream.mapEffect(eventJson' =>
    switch Spec.sideEffects->findSideEffect(eventJson') {
    | Some((eventObj, eventMeta, sideEffect)) =>
      Effect.promise(async () => {
        module SideEffect = unpack(sideEffect)
        // ... same logic as before ...
      })
    | None => Effect.succeed(())
    }
  )
  ->Stream.runDrain
```

### M.3 — ReadModel_Callback

**File:** `reventless-core/src/components/ReadModel/ReadModel_Callback.res`

Current `eventsHandler` is `array<JSON.t> => promise<unit>`, wrapped at the builder call site
with `fromArrayHandler`. Convert to a native stream handler, remove the call-site wrapper, and
rename to `handleJsonEvents`:

```rescript
// Before
let eventsHandler = jsons => {
  jsons
  ->Array.mapWithIndex((json, idx) => {
    json->EventProjector.map(~sourceName=Some(sourceName))
  })
  ->Array.flat
  ->Projection.handleActions(Spec.operations, ReadModelSpec.subIdConfig)
}

// After
let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
  stream
  ->Stream.mapEffect(json =>
    Effect.sync(() => {
      let sourceName = (json->Message.decode(Reventless.Message.contextSchema)).meta.service
      Console.log2(`ReadModel ${ReadModelSpec.name}: handling event from ${sourceName}:`, json)
      json->EventProjector.map(~sourceName=Some(sourceName))
    })
  )
  ->Stream.flatMap(actions => Stream.fromIterable(actions))
  ->Stream.runForEach(action =>
    Effect.promise(() =>
      Projection.handleAction(Spec.operations, ReadModelSpec.subIdConfig, action)
    )
  )
```

Also remove `fromArrayHandler` wrapper in `ReadModel_Builder.res` and update the call site
reference from `Callback.eventsHandler` to `Callback.handleJsonEvents`.

### M.4 — EventMapper_Callback

**File:** `reventless-core/src/components/EventMapper/EventMapper_Callback.res`

The `commonEventsHandler` design is "collect all actions then publish as a batch". This
ordering guarantee must be preserved in the stream version using `Stream.runFold`.

In `MakeEventCollectorHandler`, rename `eventsHandler` → `handleJsonEvents`. Use
`Stream.runFold` to accumulate all actions before publishing (preserves the current
batch-then-publish ordering guarantee):

```rescript
// MakeEventCollectorHandler

let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
  stream
  ->Stream.mapEffect(eventJson' =>
    Effect.sync(() => {
      switch findMapping(Mappings.mappings, eventJson') {
      | Some((eventObj, eventMeta, mapping)) => ... // produce actions list
      | None => []
      }
    })
  )
  ->Stream.flatMap(actions => Stream.fromIterable(actions))
  ->Stream.runFold(([], []), ((publishers, counters), action) =>
    switch action {
    | Publisher(p) => (publishers->Array.concat([p]), counters)
    | Counter(c)   => (publishers, counters->Array.concat([c]))
    }
  )
  ->Effect.flatMap(((publisherPromises, counterActions)) =>
    Effect.promise(async () => {
      let entries = (await publisherPromises->Promise.all)->Array.flat
      await doCount(counterActions)
      await Ops.publishJsons(entries)
    })
  )
```

In `MakeCounterHandler`, `handleCounterEvents` keeps its semantic name (it is a scoped
internal helper, not a primary module export). Its type reference updates from
`Counter.counterEventsHandler` to `Counter.jsonEventsHandler` (the rename from M.1):

```rescript
// Type reference updated; semantic name kept
let handleCounterEvents: Counter.jsonEventsHandler = stream =>
  stream
  ->Stream.mapEffect(...)
  ->Stream.runFold(...)
  ->Effect.flatMap(...)
```

Update the `CounterHandler` module type field accordingly:

```rescript
// Before
module type CounterHandler = {
  let handleCounterEvents: Counter.counterEventsHandler
  ...
}
// After
module type CounterHandler = {
  let handleCounterEvents: Counter.jsonEventsHandler
  ...
}
```

Remove `fromArrayHandler` wrapper in `EventMapper_Builder.res` and update the call site
reference from `Callback.eventsHandler` to `Callback.handleJsonEvents`.

### M.5 — Naming standardisation: EventCollector_Builder parameter rename

The `makeStreamHandler` function in `EventCollector_Builder.res` accepts a typed event stream
handler via `~eventsStreamHandler`. The `Stream` suffix is redundant once all handlers are
stream-based — rename the parameter to `~eventsHandler` (typed, no `json` qualifier, no
`stream` suffix):

```rescript
// Before
let makeStreamHandler = (
  ~eventCollector: EventCollector.component,
  ~schema: S.t<'event>,
  ~eventsStreamHandler: Stream.t<'event, string, unit> => Effect.t<unit, string, unit>,
) => { ... }

// After
let makeStreamHandler = (
  ~eventCollector: EventCollector.component,
  ~schema: S.t<'event>,
  ~eventsHandler: Stream.t<'event, string, unit> => Effect.t<unit, string, unit>,
) => { ... }
```

`handleJsonEvents` in `EventMapper_Callback.EventCollectorHandler`, `Core_Helpers.res`, and
`Plugin_Helpers.res` is already correct — no rename needed there.

### Files changed — Phase M (complete)

| File | Change |
|------|--------|
| `reventless-spec/src/components/Counter.res` | Rename `counterEventsHandler` → `jsonEventsHandler`; change type to stream |
| `reventless-core/src/components/EventCollector/EventCollector.res` | Rename `makeHandler ~eventsHandler` → `~jsonEventsHandler`; remove `fromArrayHandler` entirely |
| `reventless-core/src/components/EventCollector/EventCollector_Builder.res` | Rename `~eventsStreamHandler` → `~jsonEventsHandler` in `makeStreamHandler`; rename `~eventsHandler` → `~jsonEventsHandler` in `makeHandler` |
| `reventless-core/src/components/Extension/Extension.res` | Rename type `eventHandler` → `jsonEventsHandler`; rename operations fields `incomingEventHandler` → `incomingJsonEventsHandler`, `outgoingEventHandler` → `outgoingJsonEventsHandler` |
| `reventless-core/src/components/Extension/Extension_Operations.res` | Rename module type T bindings and implementation functions accordingly |
| `reventless-core/src/components/Extension/Extension_Builder.res` | Update operations record construction to use new field names |
| `reventless-core/src/components/ExtensionPoint/ExtensionPoint.res` | Rename type `eventHandler` → `jsonEventsHandler`; rename operations field `outgoingEventHandler` → `outgoingJsonEventsHandler` |
| `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res` | Rename `outgoingEventHandler` → `outgoingJsonEventsHandler` |
| `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Builder.res` | Update local vars and operations construction |
| `reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res` | Native stream handler; rename `eventsHandler` → `handleJsonEvents` in module type and implementation |
| `reventless-core/src/components/SideEffectHandler/SideEffectHandler_Builder.res` | `~eventsHandler=` → `~jsonEventsHandler=` |
| `reventless-core/src/components/ReadModel/ReadModel_Callback.res` | Native stream handler; rename `eventsHandler` → `handleJsonEvents` |
| `reventless-core/src/components/ReadModel/ReadModel_Builder.res` | Remove `fromArrayHandler`; `~eventsHandler=` → `~jsonEventsHandler=` |
| `reventless-core/src/components/EventMapper/EventMapper_Callback.res` | Native stream handlers; `CounterHandler` module type uses `Counter.jsonEventsHandler` |
| `reventless-core/src/components/EventMapper/EventMapper_Builder.res` | `~eventsHandler=` → `~jsonEventsHandler=` |
| `reventless-core/src/components/Plugin/Plugin_Callback.res` | Rename type `eventHandler` → `jsonEventsHandler`, `eventHandlersByService` → `jsonEventsHandlersByService`; native stream handler |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | Rename derived types and functions; update `serviceNameToEventHandlers` → `serviceNameToJsonEventsHandlers`; `~eventsHandler=` → `~jsonEventsHandler=` |
| `reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` | Convert to native stream; `~eventsHandler=` → `~jsonEventsHandler` (pun) |
| `reventless-core/src/core/Core/Core_Callback.res` | Rename Spec field `outgoingExtensionPointEventHandlers` → `outgoingExtensionPointJsonEventsHandlers` |
| `reventless-core/src/core/Core/Core_Helpers.res` | Rename param `~extensionPointsOutgoingEventHandlers` → `~extensionPointsOutgoingJsonEventsHandlers`; `~eventsHandler=` → `~jsonEventsHandler=` |
| `reventless-core/src/core/Core/Core_Builder.res` | Rename local var `extensionPointsOutgoingEventHandlers` → `extensionPointsOutgoingJsonEventsHandlers` |
| `reventless-core/tests/extensionpoint/ExtensionPointOperationsTest.res` | `EpOps.outgoingEventHandler` → `outgoingJsonEventsHandler` |
| `reventless-core/tests/eventmapper/EventMapperCallbackTest.res` | Update tests to use stream input directly |
| `reventless-core/tests/sideeffecthandler/SideEffectHandlerCallbackTest.res` | Update tests to use stream input directly |
| `reventless-core/tests/counter/CounterFixtures.res` | `mockJsonEventsHandler` as stream handler |
| `reventless-in-memory/tests/components/counter/CounterFixtures.res` | `~jsonEventsHandler=` stream handler |

---

## Phase N — Stream Command Handler Type

**Scope:** Change `CommandTopic.jsonCommandsHandler` from array to stream type — the same
transformation Phase K applied to `EventCollector.jsonEventsHandler`. Add a
`fromArrayCommandsHandler` bridge for callers that cannot yet be migrated.

`handleJsonCommands` is already the correct name per the naming convention (JSON-encoded
command handler, verb form) — no rename is needed.

### N.1 — Change jsonCommandsHandler type

**File:** `reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res`

```rescript
// Before
type jsonCommandsHandler = array<topicItem<JSON.t>> => promise<array<result<string, string>>>

// After
type jsonCommandsHandler =
  Stream.t<topicItem<JSON.t>, string, unit> => Effect.t<array<result<string, string>>, string, unit>

// Backward-compat bridge
let fromArrayCommandsHandler: (
  array<topicItem<JSON.t>> => promise<array<result<string, string>>>
) => jsonCommandsHandler =
  arrayHandler => stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(chunk =>
      Effect.promise(() => arrayHandler(chunk->Chunk.toArray))
    )
```

The global registry `handlerEntry.handler` field type changes accordingly.

### N.2 — CommandTopic_Callback

**File:** `reventless-core/src/components/CommandTopic/CommandTopic_Callback.res`

Rewrite as a native stream handler. `handleJsonCommands` is already the correct name and is
kept:

```rescript
// module type T — name unchanged
module type T = {
  let handleJsonCommands: CommandTopic.jsonCommandsHandler
}

// Implementation — rewritten as native stream consumer
let handleJsonCommands: CommandTopic.jsonCommandsHandler = stream =>
  stream
  ->Stream.mapEffect(({Reventless.CommandTopic.reference, command: json}) =>
    Effect.sync(() =>
      switch json->Message.decodeCommand'(Spec.Id.schema, Spec.commandSchema) {
      | command' => Some({Reventless.CommandTopic.reference, command: command'})
      | exception err =>
        Logger.error(~loc=__LOC__, `Couldn't decode command:`, err)
        None
      }
    )
  )
  ->Stream.filterMap(x => x)
  ->Stream.runCollect
  ->Effect.flatMap(chunk =>
    Effect.promise(() => Ops.commandsHandler(chunk->Chunk.toArray))
  )
```

### N.3 — AWS SQS command channel runtime

**File:** `reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res`

Wrap the SQS batch in `Stream.fromIterable`, same pattern as the EventCollector SQS channel:

```rescript
// Before
let topicItems = records->Array.map(...)->Belt.Array.zip(jsons)->Array.map(...)
switch await handleCommands(topicItems) { ... }

// After
let topicItems = records->Array.map(...)->Belt.Array.zip(jsons)->Array.map(...)
let _ = await (Stream.fromIterable(topicItems)->handleJsonCommands->Effect.runPromise)
```

### N.4 — In-memory CommandTopic channel

**File:** `reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`

Wrap a single dispatched command in `Stream.fromIterable([cmd])`:

```rescript
// Before
handleChannelCommand: handleJsonCommands => (cmd => handleJsonCommands([cmd]))->Pulumi.Output.make

// After
handleChannelCommand: handleJsonCommands =>
  (cmd =>
    handleJsonCommands(Stream.fromIterable([cmd]))->Effect.runPromise
  )->Pulumi.Output.make
```

### Files changed — Phase N (complete)

| File | Change |
|------|--------|
| `reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res` | New `jsonCommandsHandler` stream type; `fromArrayCommandsHandler` bridge; `callHandlerWithArray` helper |
| `reventless-core/src/components/CommandTopic/CommandTopic_Callback.res` | Rewrite as native stream handler; `handleJsonCommands` name unchanged |
| `reventless-core/src/components/CommandTopic/CommandTopic_Builder.res` | Rewrite `filteringHandler` as native stream handler |
| `reventless-core/src/components/StateChangeSlice/StateChangeSlice_Builder.res` | Rewrite `makeJsonHandler` as native stream handler |
| `reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res` | `Stream.fromIterable` + `Effect.runPromise` |
| `reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res` | Wrap single command in stream |
| `reventless-in-memory/tests/components/dcb/DcbFixtures.res` | Updated `publishJsons` to use `callHandlerWithArray` |
| `examples/dcb/ordering/tests/E2E/OrderingE2ETest.res` | Updated handler dispatch to use `callHandlerWithArray` |
| `examples/dcb/catalog/tests/E2E/CatalogE2ETest.res` | Updated handler dispatch to use `callHandlerWithArray` |
| `reventless-core/tests/commandtopic/CommandTopicCallbackFixtures.res` | **Created** — test spec, mock ops, helpers |
| `reventless-core/tests/commandtopic/CommandTopicCallbackTest.res` | **Created** — 5 tests, all passing |

---

## Phase O — QueryDb Stream Reads

**Scope:** Add `loadStream` to the `QueryDb.operations` record and implement it in DynamoDB and
in-memory adapters. This provides lazy consumption of read-model state without materialising
the whole array — important for large read models.

No existing callers are broken: `loadStream` is a new field added alongside `load`.

**Framework-wide availability:** Because `QueryDb.operations` is a required record type, adding
`loadStream` means it is wired up and available throughout the entire framework — in every builder
(`QueryDb_Builder`, `ReadModel_Builder`, `StateViewSlice_Builder`), every adapter (DynamoDB,
InMemory), and every mock/test fixture. Callers at any level of the stack (read model handlers,
user application code, extension points) can access `ops.loadStream(id)` directly. It is not a
test-only feature; the tests merely happen to be the first explicit callers.

### O.1 — Add loadStream type and field

**File:** `reventless-core/src/components/QueryDb/QueryDb.res`

```rescript
// New type
type loadStream<'id, 'state> =
  'id => Stream.t<'state, Reventless.QueryDb.storageError, unit>

// Extended operations record
type operations<'id, 'state> = {
  load: load<'id, 'state>,
  loadStream: loadStream<'id, 'state>,   // NEW
  save: save<'id, 'state>,
  saveBatch: saveBatch<'id, 'state>,
  count: count<'id>,
  delete: delete<'id>,
  deleteBatch: deleteBatch<'id>,
}
```

### O.2 — QueryDb_Operations.res

**File:** `reventless-core/src/components/QueryDb/QueryDb_Operations.res`

Implement `loadStream` using the existing `load` operation:

```rescript
let loadStream = id =>
  Stream.fromEffect(
    Effect.tryPromise({
      "try": () => Ops.jsonOps.load(id->ReadModelSpec.Id.toString),
      "catch": err =>
        NotLoadedFromStorage(
          (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("loadStream error")
        ),
    })
    ->Effect.flatMap(result =>
      switch result {
      | Ok(jsons) => Effect.succeed(jsons)
      | Error(e) => Effect.fail(e)
      }
    )
  )
  ->Stream.flatMap(jsons =>
    Stream.fromIterable(jsons)
    ->Stream.mapEffect(json =>
      Effect.sync(() => decode(id, json))
      ->Effect.flatMap(r =>
        switch r {
        | Ok(s) => Effect.succeed(s)
        | Error(e) => Effect.fail(NotLoadedFromStorage(e))
        }
      )
    )
  )
```

### O.3 — DynamoDB adapter

**File:** `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res`

Add `loadStream` delegating to the existing `load` function wrapped as a one-shot stream
(using `Stream.fromEffect` + `Stream.flatMap(Stream.fromIterable(...))`):

```rescript
let loadStream = table =>
  id =>
    Effect.tryPromise({
      "try": () => Util_DynamoDb_Runtime.queryById(table, id),
      "catch": err =>
        QueryDb.NotLoadedFromStorage(
          (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("DynamoDB loadStream error")
        ),
    })
    ->Stream.fromEffect
    ->Stream.flatMap(items => Stream.fromIterable(items))
```

Future improvement: replace with `Stream.paginateEffect` to lazily page through DynamoDB
results without fetching all pages upfront (see Phase P).

### O.4 — In-memory adapter

**File:** `reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_InMemory.res`

```rescript
let loadStream = id =>
  load(id)
  ->Effect.fromPromise(...)
  ->Stream.fromEffect
  ->Stream.flatMap(result =>
    switch result {
    | Ok(items) => Stream.fromIterable(items)
    | Error(e) => Stream.fail(e)
    }
  )
```

### Files changed — Phase O (complete)

| File | Change |
|------|--------|
| `reventless-core/src/components/QueryDb/QueryDb.res` | Add `loadStream` type + field in `operations` |
| `reventless-core/src/components/QueryDb/QueryDb_Operations.res` | Implement `loadStream` (delegates to `Ops.jsonOps.loadStream`) |
| `reventless-core/src/components/QueryDb/QueryDb_Builder.res` | Add `loadStream: Operations.loadStream` to ops record |
| `reventless-core/src/components/ReadModel/ReadModel_Builder.res` | Add `loadStream` to `toProjectionOperations` destructure + record |
| `reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` | Add `loadStream` to `toProjectionOps` |
| `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` | Implement `loadStream` via `Stream.fromEffect` |
| `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb.res` | Add `loadStream: runtimeTable->loadStream` to ops record |
| `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res` | Add `loadStream: runtimeTable->loadStream` to ops record |
| `reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_InMemory.res` | Implement `loadStream` via `Stream.fromIterable`; add to ops record |
| `reventless-in-memory/src/test/Mocks/MockQueryDbStorage.res` | Add `loadStream` to ops record |
| `reventless-in-memory/src/test/ProjectionTest.res` | Add `loadStream` stub to inline ops record |
| `reventless-core/tests/querydb/QueryDbFixtures.res` | Add `loadStream` to mock ops |
| `reventless-core/tests/ProjectionTest.res` | Add `loadStream` stub to inline ops record |
| `reventless-in-memory/tests/components/querydb/QueryDbTest.res` | Add 2 `loadStream` tests |

---

## Phase P — DcbEventLog True Lazy Pagination (Optional)

**Scope:** Replace the recursive-fetch-then-wrap pattern in the DynamoDB DcbEventLog storage
adapter with `Stream.paginateEffect` so that DynamoDB pages are fetched lazily as the stream
is consumed.

This is a pure performance/memory optimisation — the observable order of events is unchanged.
Mark as optional because it requires `Stream.paginateEffect` to be confirmed available (or
added) in the `rescript-effect` bindings.

### P.1 — queryBySingleTagStream

**File:** `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`

```rescript
let queryBySingleTagStream = (
  table: runtimeTable,
  tagKey: string,
  tagValue: string,
  ~after: option<string>=?,
) =>
  Stream.paginateEffect(None, cursor =>
    Effect.promise(() =>
      queryPage(table, tagKey, tagValue, ~after?, ~lastEvaluatedKey=?cursor)
    )
    ->Effect.map(({items, lastEvaluatedKey}) =>
      (items->Option.getOr([]), lastEvaluatedKey)
    )
  )
  ->Stream.flatMap(items => Stream.fromIterable(items))
```

The existing `queryBySingleTag` (returns full array) is kept for callers that need the full
result. `readStream` in the operations layer is updated to call `queryBySingleTagStream`.

### P.2 — Same treatment for queryByCompositeTags and scanWithFilter

Same `Stream.paginateEffect` pattern applied to `queryByCompositeTags` and `scanWithFilter`.

### Precondition for Phase P

Confirm or add `Stream.paginateEffect` binding in `rescript-effect/src/Stream.res`:

```rescript
@send external paginateEffect: (
  'seed,
  'seed => Effect.t<('a, option<'seed>), 'err, 'r>,
) => Stream.t<'a, 'err, 'r> = "paginateEffect"
```

### Files changed — Phase P (complete)

| File | Change |
|------|--------|
| `rescript-effect/src/Stream.res` | Already present — `paginateEffect` was implemented as a ReScript wrapper over `paginateChunkEffect` |
| `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` | Added `queryBySingleTagStream`, `queryByCompositeTagsStream`, `scanWithFilterStream`, `executeQueryItemStream`, `readStream` |
| `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res` | Replaced inline `readStream` with `DcbEventLogStorage_DynamoDb_Runtime.readStream(runtimeTable)` |

**Implementation note:** `Stream.paginateEffect` already flattens each page's array into individual stream elements — no extra `Stream.flatMap(Stream.fromIterable)` is needed after it. The `*Stream` functions return `Stream.t<JSON.t, string, unit>` directly. The `readStream` function collects all query-item streams in parallel via `Effect.all`, then merges, deduplicates, and sorts before re-streaming.

---

---

## Phase Q — Migrate Framework `load` Call Sites to `loadStream`

**Scope:** Replace every internal framework call to `QueryDb.operations.load` with the
stream-based `loadStream`, making `loadStream` the canonical read path inside the framework.
The `load` field is kept on the type for backward compatibility with user code but is no longer
called by any framework module.

**Precondition:** Phase O complete (all adapters implement `loadStream`).

There are three kinds of call sites, each requiring a slightly different migration pattern.

---

### Q.1 — Projection.res (3 call sites)

**File:** `reventless-core/src/Projection.res`

`handleAction` currently destructures `{QueryDb.load: load, save, ...}` and calls
`await load(id)` in three action branches, expecting `result<array<state>, storageError>`.

The migration replaces the destructuring with `loadStream` and uses a local helper
`loadAll` that runs the stream and converts the Effect error channel back to `Result`:

```rescript
// New helper inside handleAction (or at module top)
let loadAll = id =>
  loadStream(id)
  ->Stream.runCollect
  ->Effect.map(Ok(_))
  ->Effect.catchAll(e => Effect.succeed(Error(e)))
  ->Effect.runPromise

// Destructuring change
let handleAction = async (
  action,
  {QueryDb.loadStream, save, saveBatch, delete, deleteBatch} as operations,
  subIdConfig,
) =>
```

Each `switch await load(id)` call site becomes `switch await loadAll(id)` — semantics
unchanged, but the load now goes through the stream path.

The three affected branches:
- `Update(id, update)` — expects exactly 0 or 1 states, errors on multiple
- `UpdateWithDefault(id, default, update)` — same, creates default on empty
- `UpdateMultiState(id, update)` — expects 0..N states with subIdConfig

---

### Q.2 — QueryEngine_InMemory.res (1 call site)

**File:** `reventless-in-memory/src/adapter/QueryEngine/QueryEngine_InMemory.res`

Current:
```rescript
switch Bus.getQueryDb(readModelName) {
| Some(ops) => (await ops.load(keyStr))->Result.getOr([])
| None => []
}
```

New — uses `loadStream` directly via Effect, discarding errors the same way:
```rescript
switch Bus.getQueryDb(readModelName) {
| Some(ops) =>
  await ops.loadStream(keyStr)
  ->Stream.runCollect
  ->Effect.orElse(_ => Effect.succeed([]))
  ->Effect.runPromise
| None => []
}
```

---

### Q.3 — QueryDbResolvers_GraphQL.res (2 call sites)

**File:** `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`

Both `byIdResolver` and the `byIdListResolvers` resolver contain the same pattern:

Current:
```rescript
let items = (await ops.load(id))->Result.mapOr([], v => v)
```

New:
```rescript
let items =
  await ops.loadStream(id)
  ->Stream.runCollect
  ->Effect.orElse(_ => Effect.succeed([]))
  ->Effect.runPromise
```

---

### Files changed — Phase Q

| File | Change |
|------|--------|
| `reventless-core/src/Projection.res` | Replace destructured `load` with `loadStream`; add `loadAll` helper; update 3 call sites |
| `reventless-in-memory/src/adapter/QueryEngine/QueryEngine_InMemory.res` | Replace `ops.load` with `ops.loadStream` + `Effect.orElse` |
| `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` | Replace `ops.load` with `ops.loadStream` + `Effect.orElse` at 2 call sites |

---

## Revised Execution Order

```
Phase J  →  Phase K  →  Phase L
                            ↓
                        Phase M  (native stream event handlers)
                            ↓
                        Phase N  (stream command handler type)
                            ↓
                        Phase O  (QueryDb loadStream)
                            ↓
                    Phase P (optional)   Phase Q (migrate load → loadStream)
```

Phases M, N, O are independent of each other once L is done; they can be implemented in
parallel or in any order within the L → M/N/O dependency boundary.
Phase Q depends on O and can run in parallel with P.

---

## Naming Convention Summary (all phases complete)

### Rule

> `json` in the name = handler works with `JSON.t` (wire format).
> No qualifier = handler works with typed domain objects (`'event`, `'command`).
> Types are nouns. Values are verbs.

| Encoding | Direction | Type name | Value name | Definition location |
|----------|-----------|-----------|------------|---------------------|
| Typed | events | `eventsHandler` | `handleEvents` | `Handler.res` (reventless-spec) |
| Typed | commands | `commandsHandler` | `handleCommands` | `Handler.res` / `CommandTopic.res` |
| JSON | events | `jsonEventsHandler` | `handleJsonEvents` | `EventCollector.res` |
| JSON | commands | `jsonCommandsHandler` | `handleJsonCommands` | `CommandTopic_Helpers.res` |

### Handler type inventory (stream shapes, after all phases)

| Type | Module | Signature |
|------|--------|-----------|
| `jsonEventsHandler` | `EventCollector` | `Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>` |
| `jsonEventsHandler` | `Counter` (renamed from `counterEventsHandler` in M.1) | `Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>` |
| `jsonEventsHandler` | `Extension` (renamed from `eventHandler` in M.1) | `(JSON.t, pluginDefinition) => promise<unit>` (stream migration TBD) |
| `jsonEventsHandler` | `ExtensionPoint` (renamed from `eventHandler` in M.1) | `(JSON.t, pluginDefinition) => promise<unit>` (stream migration TBD) |
| `jsonCommandsHandler` | `CommandTopic_Helpers` | `Stream.t<topicItem<JSON.t>, string, unit> => Effect.t<array<result<string, string>>, string, unit>` |
| `loadStream` | `QueryDb` (new in O.1) | `'id => Stream.t<'state, storageError, unit>` |
