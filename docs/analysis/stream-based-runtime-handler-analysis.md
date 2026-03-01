# Stream-Based Runtime Handler Analysis

**Status:** Analysis complete — implementation plan at `docs/plans/stream-handler-implementation.md`

**Created:** 2026-02-28

**Revised:** 2026-02-28

**Depends on:** Phases A–I of `docs/plans/done/effect-stream-integration.md` (complete)

**Summary:** Analysis of whether replacing the callback-based `Runtime.eventHandler` with a
stream-based interface makes sense. Covers feasibility, advantages, consequences, and a
recommended path at three distinct layers: the AWS Lambda boundary, the application-layer
batch handler, and the in-memory Bus subscription interface.

---

## Background

The framework's event handling model today is purely **callback-push**:

```
Event occurs
  → Bus.publishEvent / SQS invocation
  → Platform calls eventHandler(batch, ctx)
  → Handler processes batch, returns promise<unit>
  → Platform acknowledges completion
```

The type lives in `reventless-core/src/adapter/Runtime/Runtime.res`:

```rescript
type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>
```

And at the application layer (`reventless-spec/src/types/Handler.res`):

```rescript
type eventsHandler<'id, 'event> = ('id, array<Message.event'<'id, 'event>>) => promise<unit>
type jsonEventsHandler = array<JSON.t> => promise<unit>   // inside EventCollector
```

Phases F and G of the stream-integration plan already replaced the **internal** fan-out mechanism
in `InMemory_Bus` with Effect PubSub + `Stream.fromQueue` drain loops. The *interface* exposed to
callers of `subscribeToEvents` and to `EventCollector.makeHandler` remains callback-based.

This plan asks: should the callback interface itself be replaced with a stream interface, and at
which layer?

---

## Three Distinct Layers

The handler interface appears at three separable levels, each with different constraints:

| Layer | Current Interface | Lives In |
|-------|-----------------|---------|
| **L1 — AWS Lambda boundary** | `(SQSEvent, LambdaContext) => promise<unit>` | `RuntimeEnvironment_Lambda.res` |
| **L2 — Application batch handler** | `array<JSON.t> => promise<unit>` | `EventCollector.res`, `CommandTopic_Callback`, `Aggregate_Callback` |
| **L3 — In-memory Bus subscription** | `(service, meta, JSON.t) => promise<unit>` callback passed to `subscribeToEvents` | `InMemory_Bus.res`, `EventCollectorChannel_InMemory.res` |

Each layer must be evaluated independently.

---

## Layer 1 — AWS Lambda Boundary

### Current model

Lambda is invoked once per **batch** (SQS: up to 10 000 records per invocation). The runtime
calls the handler function, waits for the returned promise, then acknowledges or NACKs. There is
no persistent in-process state between invocations.

`RuntimeEnvironment_Lambda.res` wraps a `Pulumi.Output.t<eventHandler<SQSEvent, context, unit>>`
into a `CallbackFunction`, which is the AWS Lambda function definition. The handler signature is
dictated by the AWS Lambda runtime protocol.

### What a stream interface would look like

```rescript
// Hypothetical
type streamHandler<'event, 'context> =
  (Stream.t<'event>, 'context) => Effect.t<unit, 'e, 'r>
```

Inside the Lambda function we would wrap the incoming SQS batch as a stream:

```rescript
callback: async (event, ctx) => {
  let stream = event.records->Stream.fromIterable
  await streamHandler(stream, ctx)->Effect.runPromise
}
```

### Does it make sense?

**No — not at this level.** Reasons:

1. **The Lambda protocol does not stream.** AWS delivers a finite, bounded batch per invocation.
   Wrapping it in `Stream.fromIterable` gives you a stream over a materialized array — you
   already hold all records in memory. The stream abstraction adds zero memory benefit.

2. **Long-running stream fibers conflict with Lambda's billing model.** Lambda charges for wall
   time. A perpetually-open Stream.fromQueue fiber would keep the invocation alive indefinitely,
   which is structurally wrong. Each invocation must terminate.

3. **Handler composition would break.** The current pattern of
   `RuntimeEnvironment_Lambda.make(~handler: Output.t<eventHandler>)` means the Lambda function
   is assembled at deploy time. A stream handler would require a different `environmentMaker`
   type, breaking all existing `forComponent` / `forEventCollector` usages.

4. **No throughput gain.** SQS delivers messages in batches already deduplicated and ordered per
   message group. A stream over the batch offers no parallelism advantage that `Promise.all`
   over the array doesn't already provide.

**Verdict:** Keep L1 as-is. The callback model matches the Lambda invocation contract exactly.

---

## Layer 2 — Application Batch Handler

### Current model

`EventCollector_Builder` (`EventCollector_Builder.res`) feeds decoded events to user code via:

```rescript
type eventsHandler<'id, 'event> = ('id, array<Message.event'<'id, 'event>>) => promise<unit>
```

Inside `EventCollector.makeHandler`, the incoming JSON batch is decoded and passed as an array.
`Aggregate_Callback` similarly receives an array of commands. `StateChangeSlice_Builder` folds
events with a state accumulator before calling the user's handler.

### What a stream interface would look like

```rescript
// Hypothetical
type eventsStreamHandler<'id, 'event> =
  ('id, Stream.t<Message.event'<'id, 'event>, 'e, 'r>) => Effect.t<unit, 'e, 'r>
```

Each event arrives from the stream one at a time; the handler chains Effect operations:

```rescript
let myHandler = (id, stream) =>
  stream->Stream.runForEach(event =>
    Effect.promise(() => processEvent(id, event))
  )
```

### Advantages at L2

1. **Lazy decoding.** If the batch contains 10 000 events, the current model decodes them all to
   `array<event>` before invoking the handler. A stream approach would decode each record only
   when the handler demands it via `Stream.runForEach` or `Stream.take`. For large SQS batches
   this saves a significant allocation spike.

2. **Early termination.** With `Stream.take(n)` or `Stream.takeWhile`, the handler can stop
   processing after finding what it needs. Currently the only way to short-circuit is to throw
   inside the promise, which is fragile.

3. **Natural Effect composition.** Error handling, retry, and logging can be composed at the
   stream level with `Stream.mapEffect`, `Stream.retry`, etc., rather than wrapping the whole
   promise in a try/catch.

4. **Backpressure into the channel.** If the channel provides events via a Queue, a slow handler
   automatically exerts backpressure on the publisher (via bounded Queue semantics in Phase G).
   With the current callback model, all events are materialized before the handler is called —
   backpressure is lost.

### Consequences at L2

1. **All user-facing handler types change.** Every aggregate's `commandsHandler`, every read
   model's `eventsHandler`, and every extension point's handler would need updating from
   `array<msg> => promise<unit>` to `Stream.t<msg> => Effect.t<unit>`. This is a **breaking
   API change** affecting every downstream plugin and application.

2. **Effect dependency imposed on users.** Currently application code can ignore Effect entirely
   and work in plain `promise<unit>`. A stream handler mandates `Effect` at the application
   boundary, which is a significant conceptual step for new users.

3. **StateChangeSlice and similar fold-based components are trickier.** The current
   `StateChangeSlice_Builder` folds the event array into a final state before calling the DB.
   With a stream, this becomes `Stream.runFold(initialState, folder)` — possible but requires
   rethinking the builder.

4. **AWS Lambda: no net gain.** As noted at L1, Lambda delivers a bounded batch. Lazy decoding
   saves some allocations, but for typical event sizes (< 100 records) the impact is negligible.

5. **Backward compatibility is hard.** A bridge `fromPromiseHandler(array<e> => promise<unit>)
   => Stream.t<e> => Effect.t<unit>` could be provided, but it re-materializes the array and
   defeats the purpose.

### Narrower alternative: stream-based EventLog replay only

A more surgical change at L2 would limit streaming to **replay paths** — where events can number
in the millions. The `EventLog.replay` and `DcbEventLog.readStream` already return `Stream.t`
(Phases B and D). The `eventsHandler` for live processing (small bounded batches) can stay as
`array<event> => promise<unit>`.

This is the **recommended scoping**: streaming for unbounded read paths, callbacks for bounded
live paths.

---

## Layer 3 — In-Memory Bus Subscription

### Current model

`InMemory_Bus.T` exposes:

```rescript
let subscribeToEvents: (string, (string, meta, JSON.t) => promise<unit>) => unit
```

The caller registers a callback. Internally (Phase F) the Bus creates a PubSub hub and a
`Stream.fromQueue` drain fiber that calls the callback for each message.

### What a stream interface would look like

```rescript
// Hypothetical alternative Bus interface
let subscribeToEvents: string => Effect.t<Stream.t<queuedEvent, 'e, 'r>, 'e, 'r>
```

Callers would compose the stream directly:

```rescript
Bus.subscribeToEvents("MyTopic")
->Effect.flatMap(stream =>
  stream->Stream.runForEach(msg =>
    Effect.promise(() => handler(msg.service, msg.meta, msg.json))
    ->Effect.zipRight(msg.done_)
  )
)
->Effect.scoped
->Effect.runFork
->ignore
```

### Does it make sense?

**Partially — but the current design is already equivalent.** The internal drain loop in
`InMemory_Bus.subscribeToEvents` already does exactly the above. The callback API is a
thin wrapper. Exposing a raw Stream would:

1. **Give callers more composability** — they could `Stream.filter`, `Stream.map`, or
   `Stream.take` before running the stream. This is useful for testing (e.g., collect only the
   first N events before asserting).

2. **Complicate the `done_` synchronization protocol.** Today `done_` is embedded in
   `queuedEvent` and runs inside the fiber's Effect chain. If callers get a raw stream, they
   must remember to run `msg.done_` themselves. Forgetting causes `publishEvent` to hang. This
   is a safety regression.

3. **Break `EventCollectorChannel_InMemory`'s channel connection code.** The channel's `connect`
   passes a callback to `subscribeToEvents`. Switching to a stream interface requires rewriting
   `connect` to `Effect.runFork` the stream manually — net zero simplification.

4. **Only relevant in-memory.** The AWS adapter doesn't use `InMemory_Bus.subscribeToEvents` at
   all. Changing this interface has zero effect on production code paths.

**Verdict at L3:** The current design is already internally stream-based. Exposing a Stream to
callers adds composability but introduces `done_` safety risks. A better alternative is to keep
the callback API and provide a **test utility** `collectNEvents(bus, topic, n)` that internally
subscribes and accumulates events:

```rescript
// Test utility (no change to Bus interface)
let collectNEvents = (bus, topicName, n) => {
  // Returns Effect.t<array<queuedEvent>>
  let collectedRef = ref([])
  let done = Deferred.make()->Effect.runSync
  bus.subscribeToEvents(topicName, async msg => {
    collectedRef.contents->Array.push(msg)
    if Array.length(collectedRef.contents) >= n {
      Deferred.succeed(done, ())->Effect.runSync->ignore
    }
  })
  Deferred.await_(done)->Effect.map(_ => collectedRef.contents)
}
```

---

## Summary Matrix

| Layer | Stream Interface Makes Sense? | Recommendation |
|-------|-------------------------------|----------------|
| **L1 — Lambda boundary** | No | Keep `(event, ctx) => promise<unit>` |
| **L2 — Application batch handler (live)** | Marginally, high migration cost | Keep array callback for live paths |
| **L2 — EventLog replay / unbounded reads** | Yes — already done | Phases B+D; extend to more replay paths |
| **L3 — In-memory Bus subscribe** | Already internal; exposing is risky | Add test-only `collectNEvents` utility |

---

## Overall Verdict

**The stream-based approach has already been applied where it makes the most sense:**
- EventLog replay returns `Stream.t` (Phase B)
- DcbEventLog readStream returns `Stream.t` (Phase D)
- QueryEngine scan uses `Stream.take` for memory-safe limiting (Phase C)
- InMemory_Bus fan-out uses PubSub + `Stream.fromQueue` internally (Phase F)

**What is NOT worth changing:**
- The `eventHandler<'event, 'context, 'result>` type at the Lambda boundary — it matches the
  AWS Lambda protocol and a streaming wrapper adds nothing
- The `eventsHandler = array<event> => promise<unit>` for live event processing — batches are
  small and bounded; the array allocation is not a problem
- The `InMemory_Bus.subscribeToEvents` callback API — the internal drain is already a stream;
  exposing it externally risks `done_` safety

**What may still be worth considering:**

1. **L2 partial: streaming StateChangeSlice fold** — If a single DCB command can match
   thousands of events (e.g., projection rebuild), folding via `Stream.runFold` in the slice
   builder avoids a large intermediate array. This is an internal change; the user-facing
   `eventsHandler` type does not change. Candidate for a future Phase I or J.

2. **L3 test utility** — A `collectNEvents` helper for test code that wraps the existing
   callback API in a Deferred-based accumulator. Small scope, high test ergonomics value.

3. **L2 future: commandsHandler for CommandTopic** — If commands are published as a `Stream`
   (Phase H adds `publishJsonsStream`), the handler receiving them could symmetrically be a
   stream consumer. This would be an opt-in alternative handler type, not a replacement.

---

## Decision

Do not replace the `Runtime.eventHandler` callback interface at the Lambda boundary (L1).
For L2 and L3, full stream-based implementation proceeds per
`docs/plans/stream-handler-implementation.md`:

- [x] **Phase I:** Streaming fold inside `StateChangeSlice_Callback` via `dcbEventLog.readStream→Stream.runFold` — **complete** (confirmed in `StateChangeSlice_Callback.res:30`)
- [x] **Phase J:** `collectNEvents` test utility in `reventless-in-memory` — **complete** (`TestRunner.res` + `CollectNEventsTest.res`, 5 tests passing)
- [ ] **Phase K:** L2 full — change internal `jsonEventsHandler` to `Stream.t<JSON.t>→Effect.t<unit>`; add `makeStreamHandler` in `EventCollector_Builder` — see plan
- [ ] **Phase L:** L3 full — add `subscribeToEventStream` to `InMemory_Bus.T`; update `EventCollectorChannel_InMemory.connect` to use stream with explicit `done_` — see plan
