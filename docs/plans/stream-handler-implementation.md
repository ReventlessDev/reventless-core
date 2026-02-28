# Plan: Stream-Based Handler Implementation (Phases J–L)

**Status:** Phase J complete; Phases K–L pending

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

### Files to change (Phase K)

| File | Change |
|------|--------|
| `reventless-core/src/components/EventCollector/EventCollector.res` | Change `jsonEventsHandler` type; add `fromArrayHandler` bridge |
| `reventless-core/src/components/EventCollector/EventCollector_Builder.res` | Add `makeStreamHandler`; update `makeHandler` to bridge to Effect.runPromise |
| `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res` | Update `handleChannelEvent` to use `Stream.fromIterable` + `Effect.runPromise` |
| `reventless-aws/src/adapter/EventCollector/EventCollectorChannel_*.res` | Update `handleChannelEvent` similarly (wrap SQS batch in stream) |

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

### Files to change (Phase L)

| File | Change |
|------|--------|
| `reventless-in-memory/src/adapter/InMemory_Bus.res` | Add `subscribeToEventStream` to `T` and implement in `Impl` |
| `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res` | Update `connect` to use `subscribeToEventStream` with explicit `done_` |

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
