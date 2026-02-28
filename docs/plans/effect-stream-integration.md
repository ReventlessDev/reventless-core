# Effect Stream Integration Plan

**Status:** Backlog — ready for implementation
**Created:** 2026-02-28
**Depends on:** `docs/plans/effect-library-integration.md` phases 0–4 (complete)
**Summary:** Identifies all places in the Reventless codebase where Effect `Stream` would improve
correctness, memory safety, or composability, and provides a phased, concrete implementation plan.

---

## Background

Phases 0–4 of the effect-library integration plan introduced Effect bindings for `Effect`, `Queue`,
`Deferred`, `Latch`, `PubSub`, `Schedule`, `Stm`, and `SynchronizedRef`. These primitives now power
core parts of the in-memory adapters.

Phase 5 of that plan identified `Stream`-based `EventLog.replay` as a candidate for large aggregate
support. This plan expands that placeholder into a full analysis covering every place in the codebase
where `Stream` would be beneficial, and provides actionable implementation steps.

**What Effect Stream is:** `Stream.t<'a, 'e, 'r>` is a lazy, composable, resource-safe sequence of
values. It integrates with Effect's structured concurrency: streams can be interrupted, zipped,
merged, paginated, and consumed one item at a time — without materialising the whole sequence in
memory. Key operations relevant to this codebase:

| Operation | Description |
|---|---|
| `Stream.fromIterable` | Wrap an in-memory array |
| `Stream.fromEffect` | Wrap a single Effect value |
| `Stream.fromQueue` | Drain a Queue until shutdown |
| `Stream.paginateEffect` | Multi-page DynamoDB queries via cursor state |
| `Stream.mapEffect` | Per-item async decode |
| `Stream.runCollect` | Materialise to array |
| `Stream.runFold` | Left fold for state accumulation |
| `Stream.take` | Limit without loading all |
| `Stream.runForEach` | Process each item for side effects |

---

## Section 1: Use Case Analysis

### Use Case 1 — EventLog.replay as Stream (Priority: Medium)

**Current implementation:**

`replay` loads all events for an aggregate ID into memory at once:

```rescript
// EventLog_Operations.res
let replay = async id => {
  let eventsJson = await Ops.storage.replay(id->Spec.Id.toString)
  eventsJson->decodeEvents(id->Spec.Id.toString)
}
```

`EventLogStorage_InMemory` returns a full array. `EventLogStorage_DynamoDB` paginates internally
but materialises all pages before returning. `Aggregate_Callback.res` folds over the array to
rebuild state, then discards it:

```rescript
let history = await Ops.eventLog.replay(id)
let result = await commands'->Array.reduce(
  Ok((updateState(None, history), []))->Promise.resolve,
  processCommand,
)
```

**Problem:** For long-lived aggregates with thousands of events, the entire history is loaded into
memory, decoded, and discarded after the fold. There is no early termination, and DynamoDB's
paginated results are buffered unnecessarily.

**Proposed Stream-based implementation:**

Add `replayStream` alongside `replay` (additive — no breaking change):

```rescript
// EventLog_Adapter.res — extend operations record
type operations = {
  append: EventLog.append<string, JSON.t>,
  replay: EventLog.replay<string, JSON.t>,
  replayStream: string => Stream.t<JSON.t, string, unit>,  // NEW
}

// EventLogStorage_InMemory.res
let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
  Stm.TRef.get(eventsRef)
  ->Stm.commit
  ->Effect.map(events => events->Dict.get(id)->Option.getOr([]))
  ->Stream.fromEffect
  ->Stream.flatMap(arr => Stream.fromIterable(arr))

// EventLog_Operations.res
let replayStream = id =>
  Ops.storage.replayStream(id->Spec.Id.toString)
  ->Stream.mapEffect(json =>
    Effect.sync(() => decodeEvent(id->Spec.Id.toString, json))
  )
```

`Aggregate_Callback.res` uses `runFold` to rebuild state without holding all events:

```rescript
// After
let currentState = await Ops.eventLog.replayStream(id)
  ->Stream.runFold(None, (stateOpt, event) => apply'(stateOpt, event))
  ->Effect.runPromise
let result = await commands'->Array.reduce(
  Ok((currentState, []))->Promise.resolve,
  processCommand,
)
```

**DynamoDB implementation** uses `Stream.paginateEffect` to page through DynamoDB one batch at a
time — cursor state is `option<JSON.t>` (lastEvaluatedKey):

```rescript
// EventLogStorage_DynamoDB
let replayStream = table => id =>
  Stream.paginateEffect(None, lastKey =>
    Effect.tryPromise({
      "try": () => queryByIdPage(table.name, id, lastKey),
      "catch": err => (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("query error"),
    })
    ->Effect.map(page => (page.items, page.lastKey))
  )
```

**Priority rationale:** The in-memory case gains no real benefit (data is already in memory). The
DynamoDB case avoids buffering thousands of events on every command. The main value is
architectural: establishing that aggregate state can be rebuilt via a fold over a stream, enabling
future pagination without changing business logic.

---

### Use Case 2 — DcbEventLog.read as Paginated Stream (Priority: Low)

**Current implementation:**

`DcbEventLog_Operations.read` loads the full result then maps over the array:

```rescript
let read = async (~query, ~after=?) => {
  let rawResult = await Ops.storage.read(~query, ~after?)
  let events = rawResult.events->Array.map(decodeEvent)
  { events, headPosition: ?rawResult.headPosition }
}
```

`StateChangeSlice_Builder` reads the full log on every command to build the decision model.

**Problem:** For global event logs serving as the DCB source-of-truth, the entire matching event set
is loaded on every command. As tag indexes grow, this becomes a bottleneck. The `headPosition` is
only needed at the end; there is no way to page or stop early.

**Proposed Stream-based implementation:**

Add `readStream` to `DcbEventLog_Adapter.operations`:

```rescript
type readStream<'event> =
  (~query: Reventless.DcbTag.query, ~after: Reventless.DcbTag.sequencePosition=?) =>
  Stream.t<sequencedEvent<'event>, string, unit>
```

In-memory implementation pages by threading the last seen position:

```rescript
let readStream = (~query, ~after=?) =>
  Stream.paginateEffect(after, currentAfter =>
    Effect.promise(() => read(~query, ~after=?currentAfter))
    ->Effect.map(result => (result.events, result.headPosition))
  )
  ->Stream.flatMap(events => Stream.fromIterable(events))
```

**Priority rationale:** Additive improvement for large DCB deployments. Current array-based
implementation works correctly for all known use cases. Implement after Use Case 1 patterns are
established.

---

### Use Case 3 — QueryDb Scan as Stream (Priority: Low)

**Current implementation:**

`InMemory_Bus` exposes `registerQueryDbScan` / `getQueryDbScan` with type `unit => array<JSON.t>`.
`QueryEngine_InMemory.scan` silently ignores the `~limit` parameter:

```rescript
scan: async (~readModelName, ~filterConfigs as _, ~limit as _) =>
  switch Bus.getQueryDbScan(readModelName) {
  | Some(scanAll) => scanAll()  // ignores limit
  | None => []
  },
```

**Problem:** `scan` forces loading all read model items into memory regardless of `~limit`. The
`limit` parameter has been wired through the type system but is never honoured.

**Proposed Stream-based implementation:**

Add a parallel stream registry alongside the existing scan registry:

```rescript
// InMemory_Bus.T — new registrations
let registerQueryDbStream: (string, unit => Stream.t<JSON.t, string, unit>) => unit
let getQueryDbStream: string => option<unit => Stream.t<JSON.t, string, unit>>
```

`QueryDbStorage_InMemory` registers the stream:

```rescript
Bus.registerQueryDbStream(name, () =>
  allItems.contents->Stream.fromIterable
)
```

`QueryEngine_InMemory.scan` honours `~limit`:

```rescript
scan: async (~readModelName, ~filterConfigs as _, ~limit=?) => {
  switch Bus.getQueryDbStream(readModelName) {
  | Some(makeStream) =>
    let stream = switch limit {
    | Some(n) => makeStream()->Stream.take(n)
    | None => makeStream()
    }
    await stream->Stream.runCollect->Effect.runPromise
  | None =>
    switch Bus.getQueryDbScan(readModelName) {
    | Some(scanAll) => scanAll()
    | None => []
    }
  }
},
```

Keep the existing `registerQueryDbScan` for backward compatibility.

**Priority rationale:** Scan is only used in the GraphQL admin/reporting API, not the event
processing hot path. Implement after the Stream binding foundations are in place.

---

### Use Case 4 — InMemory_Bus Fan-out via Stream (Priority: Low / Evaluate)

**Current implementation:**

Each subscriber has a `Queue.unbounded<queuedEvent>` and a drain fiber started via
`Effect.runFork`. The drain loop uses `Effect.forever` — this is essentially a `Stream.fromQueue`
pattern written manually.

**Problem:** The `Deferred` completion signal is a manual synchronization layer for what
`Stream.fromQueue` already provides natively. The `PubSub` module (already bound) natively handles
the fan-out topology with built-in backpressure.

**Proposed Stream-based alternative:**

Replace the per-subscriber `Queue` + drain loop with `PubSub.subscribe` → `Stream.fromQueue`:

```rescript
// Future InMemory_Bus — stream-based subscriber
let drainStream = (topicName, handler) =>
  Stream.scoped(PubSub.subscribe(getPubSub(topicName)))
  ->Stream.flatMap(queue => Stream.fromQueue(queue))
  ->Stream.mapEffect(msg =>
    Effect.promise(() => handler(msg.service, msg.meta, msg.json))
  )
  ->Stream.runDrain
```

**Priority rationale:** The current `Queue` + `Deferred` implementation works correctly and has
been carefully tuned for 2-microtick resolution in tests (documented in `InMemory_Bus.res`).
Moving to PubSub-based streams would change the delivery timing guarantees. Before implementing,
measure whether the 2-tick resolution is preserved. This is an architectural improvement, not a
correctness fix.

---

### Use Case 5 — CSV / Task File Processing as Stream (Priority: Low)

**Current implementation:**

`FastCSV.res` uses Node.js event-based streaming (`.on("data", row => ...)`, `.on("end", ...)`).
There is no backpressure — the parser pushes rows as fast as it reads them. `Task` provides a
file-triggered callback but no streaming abstraction for file contents.

**Problem:** For large CSV files (100k+ rows), users must implement their own buffering. There is
no way to express backpressure from a slow consumer to the file reader.

**Proposed Stream-based implementation:**

Add a `fromReadableStream` binding to `Stream.res`:

```rescript
@module("effect") @scope("Stream")
external fromReadableStream: (unit => NodeStreams.Readable.t, int) => t<string, string, unit>
  = "fromReadableStream"
```

Provide a utility `CsvStream.res` that bridges `FastCSV` to `Stream.t<FastCSV.row, string, unit>`.
The `Task` callback could optionally receive a stream instead of just a key.

**Priority rationale:** Requires the most novel work (a Channel wrapper for Node.js streams).
The payoff is real for large CSV imports but affects only a subset of use cases. Implement after
Phases A and B are stable.

---

### Use Case 6 — Bounded Queue Backpressure (Priority: Low / Evaluate)

**Current situation:** `Queue.unbounded()` per subscriber — if a subscriber is slow, the queue
grows without limit. The publisher awaits completion (via `Deferred`) which creates implicit
backpressure, but does not protect against memory growth under extreme load.

**Proposed:** Replace `Queue.unbounded` with `Queue.bounded(n)` per subscriber. `Queue.offer`
blocks when the queue is full, providing natural backpressure. The publisher would switch from
`Effect.runSync` to an async offer path.

**Priority rationale:** Not a current pain point. The current design was deliberately tuned for
2-microtick test resolution. Bounded queues change the concurrency model. Defer to a future
backpressure-focused pass.

---

## Section 2: Stream Binding Requirements

No `Stream.res` exists yet in `rescript/rescript-effect/src/`. Create a new file
`rescript/rescript-effect/src/Stream.res` with the following bindings.

### Phase A bindings (required for Use Cases 1–3)

```rescript
// Stream.res

// Core type — matches Effect.Stream<A, E, R>
type t<'a, 'e, 'r>

// ─── Construction ─────────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external fromEffect: Effect.t<'a, 'e, 'r> => t<'a, 'e, 'r> = "fromEffect"

@module("effect") @scope("Stream")
external fromIterable: array<'a> => t<'a, 'e, 'r> = "fromIterable"

// Drain a Queue until it is shut down
@module("effect") @scope("Stream")
external fromQueue: Queue.t<'a> => t<'a, 'e, 'r> = "fromQueue"

// Empty stream — terminates immediately
@module("effect") @scope("Stream")
external empty: t<'a, 'e, 'r> = "empty"

// Paginate with state cursor.
// Producer returns (chunk: array<'a>, nextCursor: option<'s>).
// Stream emits individual items; terminates when nextCursor is None.
// Note: maps to JS "paginateChunkEffect" (chunk-based variant).
@module("effect") @scope("Stream")
external paginateEffect: (
  's,
  's => Effect.t<(array<'a>, option<'s>), 'e, 'r>,
) => t<'a, 'e, 'r> = "paginateChunkEffect"

// ─── Transformation ───────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("Stream")
external mapEffect: (t<'a, 'e, 'r>, 'a => Effect.t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "mapEffect"

@module("effect") @scope("Stream")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

@module("effect") @scope("Stream")
external filter: (t<'a, 'e, 'r>, 'a => bool) => t<'a, 'e, 'r> = "filter"

// Take first N items then stop (resource-safe interruption of the upstream)
@module("effect") @scope("Stream")
external take: (t<'a, 'e, 'r>, int) => t<'a, 'e, 'r> = "take"

@module("effect") @scope("Stream")
external tap: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// ─── Terminal operations (runners) ────────────────────────────────────────

// Collect all items into an array
@module("effect") @scope("Stream")
external runCollect: t<'a, 'e, 'r> => Effect.t<array<'a>, 'e, 'r> = "runCollect"

// Left fold — accumulate state across all items
@module("effect") @scope("Stream")
external runFold: (t<'a, 'e, 'r>, 's, ('s, 'a) => 's) => Effect.t<'s, 'e, 'r> = "runFold"

// Process each item for side effects
@module("effect") @scope("Stream")
external runForEach: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => Effect.t<unit, 'e, 'r>
  = "runForEach"

// Drain the stream discarding all values
@module("effect") @scope("Stream")
external runDrain: t<'a, 'e, 'r> => Effect.t<unit, 'e, 'r> = "runDrain"

// Get just the first item (None for empty stream)
@module("effect") @scope("Stream")
external runHead: t<'a, 'e, 'r> => Effect.t<option<'a>, 'e, 'r> = "runHead"

// ─── Error handling ───────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"
```

### Additional bindings for Use Case 4 (PubSub stream fan-out)

```rescript
// Run within a scope — for PubSub.subscribe which returns a scoped Queue
@module("effect") @scope("Stream")
external scoped: Effect.t<t<'a, 'e, 'r>, 'e, 'r> => t<'a, 'e, 'r> = "unwrapScoped"

// Feed stream output into a Queue
@module("effect") @scope("Stream")
external runIntoQueue: (t<'a, 'e, 'r>, Queue.t<'a>) => Effect.t<unit, 'e, 'r> = "runIntoQueue"
```

### Additional bindings for Use Case 5 (CSV / Node.js streams)

```rescript
// Wrap a Node.js Readable stream with chunk size in bytes
@module("effect") @scope("Stream")
external fromReadableStream: (unit => NodeStreams.Readable.t, int) => t<string, string, unit>
  = "fromReadableStream"
```

### Naming note on `paginateEffect`

Effect's JS API exports `paginateChunkEffect` for chunk-based pagination (each call produces an
`array<'a>`). The ReScript binding names it `paginateEffect` for ergonomics; the JS name in the
external is `"paginateChunkEffect"`. The stream emits individual items after flattening the chunks.
Do not use `"paginateEffect"` (JS name) — it works differently (single item per page, not chunks).

---

## Section 3: Implementation Plan

Phases are ordered smallest-increment-first. Each phase is independently deployable.

### Dependency graph

```
Phase A (Stream.res bindings)
  ├─> Phase B (EventLog.replayStream)     — primary business value
  ├─> Phase C (QueryDb scan stream)       — independent after A
  ├─> Phase D (DcbEventLog stream)        — build on Phase B patterns
  └─> Phase E (CSV/Node streams)          — independent after A
```

---

### Phase A — Add Stream.res Bindings

**Goal:** Make `Stream.t<'a, 'e, 'r>` available to all packages in the monorepo.

**Files to create:**
- `rescript/rescript-effect/src/Stream.res`

**Steps:**
1. Create `Stream.res` with all Phase A bindings from Section 2 (do not include Node.js interop yet).
2. Build `rescript/rescript-effect`: `cd rescript/rescript-effect && npm run build`. Zero warnings.
3. Add `Stream` to `rescript/rescript-effect/rescript.json` sources if not auto-discovered.
4. Verify the binding is importable from `reventless-in-memory` with a smoke test (see Section 4).

**Acceptance criteria:**
- `Stream.res` compiles with zero warnings.
- `Stream.fromIterable([1, 2, 3])->Stream.runCollect->Effect.runPromise` resolves to `[1, 2, 3]`.
- No changes to any existing test.

---

### Phase B — EventLog.replayStream

**Goal:** Aggregates rebuild state by folding over a stream of events, not by loading all events
into memory first.

**Files to modify:**
1. `reventless/reventless-core/src/components/EventLog/EventLog_Adapter.res`
   - Add `replayStream: string => Stream.t<JSON.t, string, unit>` to `operations`
2. `reventless/reventless-core/src/components/EventLog/EventLog_Operations.res`
   - Add `replayStream` to module type `T` and functor `Make`
3. `reventless/reventless-core/src/components/EventLog/EventLog.res`
   - Add `replayStream` type alias if needed for external API
4. `reventless/reventless-in-memory/src/adapter/EventLog/EventLogStorage_InMemory.res`
   - Implement `replayStream` using `Stream.fromEffect->Stream.flatMap(Stream.fromIterable)`
5. `reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDB.res` (if exists)
   - Implement `replayStream` using `Stream.paginateEffect` with DynamoDB LastEvaluatedKey cursor
6. `reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res`
   - Replace `replay` + `updateState(None, history)` fold with `replayStream->Stream.runFold`

**Acceptance criteria:**
- All existing `EventLogTest.res` and `AggregateTest.res` tests pass unchanged.
- New `EventLogStreamTest.res` tests pass (see Section 4).
- Zero new warnings.
- `npm run build` in the root compiles all modules without errors.

---

### Phase C — QueryDb Scan as Stream

**Goal:** `QueryEngine_InMemory.scan` honours the `~limit` parameter by using a stream.

**Files to modify:**
1. `reventless/reventless-in-memory/src/adapter/InMemory_Bus.res`
   - Add `registerQueryDbStream` / `getQueryDbStream` to `T` and `Make`
2. `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_InMemory.res`
   - Register the stream alongside the existing array scan
3. `reventless/reventless-in-memory/src/adapter/QueryEngine/QueryEngine_InMemory.res`
   - Prefer stream registry; fall back to array scan; honour `~limit` via `Stream.take`

**Acceptance criteria:**
- Existing `QueryEngineTest.res` passes unchanged.
- New test with `~limit=2` on a 5-item QueryDb returns exactly 2 items.
- `~limit` not provided returns all items.
- Zero new warnings.

---

### Phase D — DcbEventLog.read as Paginated Stream

**Goal:** DCB decision-model building can page through events without loading the full result set.

**Files to modify:**
1. `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Adapter.res`
   - Add `readStream` to `operations` type
2. `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res`
   - Implement `readStream` using storage's `read` function with cursor threading
3. `reventless/reventless-in-memory/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res`
   - Implement `replayStream` using `Stream.paginateEffect`
4. Update `StateChangeSlice_Builder` to optionally use `readStream`

**Acceptance criteria:**
- Existing DCB E2E tests pass unchanged.
- New `DcbEventLogStreamTest.res` covers empty stream, single page, and multi-page cursor cases.

---

### Phase E — CSV / Node.js Readable as Effect Stream

**Goal:** Provide a streaming CSV parser backed by Effect Stream for use in Task callbacks.

**Files to create / modify:**
1. `rescript/rescript-effect/src/Stream.res` — add `fromReadableStream` binding
2. `reventless/reventless-core/src/util/CsvStream.res` (new file) — bridge FastCSV to Stream
3. Document usage in a Task callback example

**Acceptance criteria:**
- `CsvStream.parseRows(~path)` produces a `Stream.t<FastCSV.row, string, unit>`.
- Test with a temporary CSV file verifies all rows are emitted in order.
- Test with `Stream.take(2)` verifies early termination (file handle closed).

---

## Section 4: Test Plan

### Phase A — Stream Binding Smoke Tests

**File to create:** `reventless/reventless-in-memory/tests/adapter/StreamBindingTest.res`

Test cases:

```rescript
open AsyncTest
open AsyncTest.Expect

describe("Stream bindings (smoke)", () => {
  testPromise("fromIterable emits all items", async () => {
    let result = await Stream.fromIterable([1, 2, 3])
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result)->toEqual([1, 2, 3])
  })

  testPromise("take limits items", async () => {
    let result = await Stream.fromIterable([1, 2, 3, 4, 5])
      ->Stream.take(3)
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result)->toEqual([1, 2, 3])
  })

  testPromise("fromEffect wraps a single value", async () => {
    let result = await Stream.fromEffect(Effect.succeed("hello"))
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result)->toEqual(["hello"])
  })

  testPromise("paginateEffect pages through chunks", async () => {
    // Pages: [1,2] → cursor=2; [3,4] → cursor=4; [5] → done
    let result = await Stream.paginateEffect(0, cursor =>
      Effect.sync(() => {
        let all = [1, 2, 3, 4, 5]
        let chunk = all->Array.slice(~start=cursor, ~end=cursor + 2)
        let next = cursor + 2 < 5 ? Some(cursor + 2) : None
        (chunk, next)
      })
    )
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result)->toEqual([1, 2, 3, 4, 5])
  })

  testPromise("runFold accumulates state", async () => {
    let sum = await Stream.fromIterable([1, 2, 3, 4])
      ->Stream.runFold(0, (acc, n) => acc + n)
      ->Effect.runPromise
    expect(sum)->toBe(10)
  })

  testPromise("empty stream runCollect returns empty array", async () => {
    let result = await Stream.empty->Stream.runCollect->Effect.runPromise
    expect(result)->toEqual([])
  })

  testPromise("fromQueue emits items until shutdown", async () => {
    let queue = Queue.unbounded()->Effect.runSync
    let _ = Queue.offer(queue, 1)->Effect.runSync
    let _ = Queue.offer(queue, 2)->Effect.runSync
    let _ = Queue.shutdown(queue)->Effect.runSync
    let result = await Stream.fromQueue(queue)->Stream.runCollect->Effect.runPromise
    expect(result)->toEqual([1, 2])
  })
})
```

---

### Phase B — EventLog.replayStream Tests

**File to create:**
`reventless/reventless-in-memory/tests/components/eventlog/EventLogStreamTest.res`

Test cases:

1. **Happy path** — append N events, `replayStream` collects all N
2. **Empty stream** — `replayStream` for unknown ID returns empty array
3. **Stream fold** — fold over events to count them (verifies lazy evaluation)
4. **`Stream.take` early termination** — append 5 events, `take(3)` returns only 3
5. **Separate aggregates** — two aggregate IDs have independent streams
6. **Order preservation** — events replay in append order

```rescript
// EventLogStreamTest.res — structure
describe("EventLog.replayStream", () => {
  let _ = beforeAllAsync(async () => {
    // resolve operations once to trigger Output chain
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })
  let _ = beforeEach(() => resetEventLog())  // clear in-memory storage

  testPromise("replayStream returns all appended events", ...)
  testPromise("replayStream for unknown id returns empty stream", ...)
  testPromise("runFold over stream counts events correctly", ...)
  testPromise("take(3) from 5-event log returns 3 events", ...)
  testPromise("separate aggregate IDs have independent streams", ...)
  testPromise("events are replayed in append order", ...)
})
```

**Aggregate regression test** (add to `AggregateTest.res`):

```rescript
testPromise("aggregate state is correct after stream-based replay", async () => {
  // Create item, then update it — final state matches expected
  // The stream fold is internal; observable contract is unchanged.
  // This is a regression guard for the Aggregate_Callback change.
  ...
  expect(finalState)->toEqual(expectedState)
})
```

---

### Phase C — QueryDb Scan with Limit Tests

**File to modify:** `reventless/reventless-in-memory/tests/adapter/QueryEngineTest.res`

Test cases to add:

```rescript
testPromise("scan with ~limit returns only N items", async () => {
  // Insert 5 items, scan with ~limit=2
  // Result has exactly 2 items
  expect(result->Array.length)->toBe(2)
})

testPromise("scan without ~limit returns all items", async () => {
  // Insert 5 items, scan without limit
  // Result has exactly 5 items
  expect(result->Array.length)->toBe(5)
})

testPromise("scan with ~limit larger than total returns all items", async () => {
  // Insert 3 items, scan with ~limit=10
  // Result has exactly 3 items (not padded)
  expect(result->Array.length)->toBe(3)
})
```

---

### Phase D — DcbEventLog Stream Tests

**File to create:**
`reventless/reventless-in-memory/tests/components/dcbeventlog/DcbEventLogStreamTest.res`

Test cases:

1. **Empty stream** — `readStream` for a tag with no events returns empty
2. **Single page** — events fit in one read call; stream emits all correctly
3. **Multi-page cursor** — events span multiple read calls; stream concatenates all
4. **`runFold` to get last head position** — fold to extract the final sequence position
5. **`take` stops early** — `take(2)` on a 10-event stream fetches at most 2

---

### Phase E — CsvStream Tests

**File to create:** `reventless/reventless-core/tests/util/CsvStreamTest.res` (or similar)

Test cases:

1. **Parse small CSV file** — 3-row CSV, `runCollect` returns 3 rows in order
2. **Early termination** — `take(2)` on a 100-row CSV reads only 2 rows, no memory spike
3. **Empty file** — empty CSV returns empty stream
4. **Error handling** — malformed CSV propagates error through stream error channel

---

### General Test Patterns

1. **Fresh bus per test** — `module TestBus = InMemory_Bus.Make()` inside each `describe` block
2. **`beforeAllAsync` for Output resolution** — `await component->Component.operations->TestRunner.resolve`
3. **`beforeEach` for storage reset** — call `resetStorage()` between tests
4. **`testPromise`** — use `AsyncTest.testPromise`, not `@glennsl/rescript-jest`'s broken variant
5. **`Stream.runCollect->Effect.runPromise`** — standard pattern to get an array from a stream in tests
6. **No fake timers** — Stream tests do not use `setInterval`/`setTimeout`; fake timers not needed
7. **`fromQueue` tests must shut down the queue first** — `Stream.fromQueue` blocks until shutdown;
   call `Queue.shutdown(queue)->Effect.runSync` before `runCollect`
8. **Annotate abstract cursor types** — `Stream.paginateEffect` cursor `'s` may need annotation if
   not inferrable: `let stream: Stream.t<JSON.t, string, unit> = Stream.paginateEffect(None, ...)`

---

## Known Constraints and Risks

### ReScript type inference with three type parameters

`Stream.t<'a, 'e, 'r>` has three type parameters. Annotate the return type of any function that
constructs a stream with an opaque cursor. The compiler produces a weak type variable error if `'s`
in `paginateEffect` is polymorphic and not constrained by the initial value.

### Avoid nesting `Effect.runPromise` inside `Effect.runPromise`

`Stream.runCollect` produces `Effect.t<array<'a>, 'e, 'r>`. Run it with a single `Effect.runPromise`
at the async boundary. Do NOT call `Effect.runPromise` inside an effect that is itself run with
`Effect.runPromise` — this causes "unexpected synchronous effect" errors. Compose with
`Effect.flatMap` before the single boundary call.

### `paginateChunkEffect` vs `paginateEffect` (JS names)

The ReScript binding `paginateEffect` maps to JS `"paginateChunkEffect"`. Do not bind to
`"paginateEffect"` (the JS name) — it takes a single item per page, not a chunk, which is less
efficient for batch DynamoDB responses.

### TestClock does not reach inside stream runners

As documented in the rescript-effect memory notes, `Effect.provide(TestContext)` from outside
cannot inject TestClock into inner `Effect.runPromise` calls. Stream operations that use internal
`Effect.sleep` (e.g. throttled streams) will not respond to TestClock. This is not an issue for
Phases B–D (no timing in storage streams) but is relevant for Phase E if CSV parsing adds delays.

### `Stream.fromQueue` terminates on `Queue.shutdown`

`Stream.fromQueue(queue)` blocks until the queue is shut down. Tests must shut down the queue
before calling `runCollect`, or use `Stream.take(n)` to avoid waiting. In the production
`InMemory_Bus`, `reset()` calls `Queue.shutdown` on all subscriber queues — this is the correct
lifecycle signal that also terminates any active `fromQueue` streams.

### `Aggregate_Callback` change is behavioral-equivalent but structurally different

The `replayStream->Stream.runFold` replacement produces the same final state as
`updateState(None, history)`. The difference is that the fold runs lazily — if the aggregate has
a `take`-based stream, it would terminate early. For correctness, the aggregate must always fold
over all events (no `take`). The `replayStream` in `EventLog_Operations` must never apply `take`
internally.
