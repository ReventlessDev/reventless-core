# Plan: Stream Usage Improvements

Based on the analysis in `docs/analysis/stream-usage-analysis.md` (generated 2026-03-01).

## Overview

The framework has solid streaming architecture in its core callbacks (Aggregate, StateChangeSlice,
ReadModel, InMemory_Bus). This plan addresses the gaps: places where streams are unnecessarily
materialised, where lazy streaming should be introduced, and non-idiomatic patterns that should
be cleaned up.

Phases are ordered by impact. Each phase is independently deployable.

---

## Phase A — DcbEventLog `readStream` fan-out (HIGH IMPACT)

**File:** `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` lines 534–549

### Problem

When a DCB query has multiple `queryItem`s (multi-tag queries), each per-tag `Stream.paginateEffect`
stream is immediately collected via `Stream.runCollect`, then all results are merged/sorted in
memory before being re-emitted as a new stream:

```rescript
query
->Array.map(queryItem =>
  executeQueryItemStream(table, queryItem, ~after?)
  ->Stream.runCollect              // ← defeats backpressure
)
->Effect.all({"concurrency": "unbounded"})  // ← all sub-queries run simultaneously
->Effect.map(results => { merge; deduplicate; sort })
->Stream.fromEffect
->Stream.flatMap(events => Stream.fromIterable(events))
```

Consequences:
- Downstream `Stream.take(n)` calls in `StateChangeSlice_Callback` cannot short-circuit DynamoDB
  pagination — all pages are fetched before the first element is emitted.
- All sub-query results land in RAM simultaneously before any result is returned.
- Unbounded `Effect.all` concurrency fires all DynamoDB sub-queries at once.

### Key fact: sub-streams are already position-ordered

The DcbEventLog DynamoDB table GSIs all use `rangeKey: "position"`. DynamoDB returns items within
a GSI query in ascending range-key order by default. This means:
- `queryBySingleTagStream` → items arrive in position order ✓
- `queryByCompositeTagsStream` → items arrive in position order ✓
- `scanWithFilterStream` (full scan, no tags) → DynamoDB makes **no ordering guarantee** ✗

This distinction is central to the A2 decision.

### Solution

Two sub-tasks:

**A1 — Bound concurrency.** Change `Effect.all({"concurrency": "unbounded"})` to
`Effect.all({"concurrency": 3})`. This is a one-line fix with no architecture change, safe to
ship immediately.

**A2 — Remove inner `runCollect`.** This requires deciding on merge semantics for
multi-queryItem queries. The two options differ in implementation complexity, memory behaviour,
and the semantics of the public `readStream` API.

---

#### Option 1: Keep eager collection — add clarity

**What changes:** Only A1 (bounded concurrency). The `runCollect` stays. Add a doc comment
explaining the eager behaviour and why it exists.

**What does NOT change:** `readStream` continues to collect all DynamoDB pages for all sub-queries
into memory before emitting the first element.

**Consequences:**
- **Memory:** For a query matching N tags, each with P DynamoDB pages of K events: all N×P×K
  events land in RAM simultaneously. For a large catalog with tens of thousands of events per tag,
  this can easily reach hundreds of MB.
- **Latency to first element:** Caller receives no elements until all sub-queries are fully
  fetched and sorted. DynamoDB pages are fetched in parallel (bounded by A1), but all must
  complete before any result is returned.
- **Backpressure:** `Stream.take(n)` downstream does NOT short-circuit DynamoDB fetching — the
  full result set is always loaded regardless of how many items the caller actually consumes.
  `StateChangeSlice_Callback` calls `Stream.runFold` (consumes all), so backpressure is irrelevant
  today, but it makes `readStream` semantically deceptive as a `Stream.t`.
- **Correctness for scan queries:** The scan case (`scanWithFilterStream`) returns unordered
  items, which is why they must be collected and globally sorted before emission. There is no
  way to lazily merge an unordered scan.
- **Complexity:** Zero — no code change beyond A1 and a comment.

**When to choose:** Current query patterns do not involve large event sets, or the added latency
and memory use are acceptable. Useful as an interim step while Option 2 is designed.

---

#### Option 2: Lazy position-ordered merge (true streaming)

**What changes:** Replace `runCollect + Effect.all + in-memory sort` with a streaming merge that
emits elements in position order without collecting any sub-stream upfront.

**How it works:**

For **tag-based queries** (single-tag and composite-tag GSIs), each sub-stream is already
sorted by position. We can merge N sorted streams into one sorted stream using a k-way merge:
maintain one "head" element per sub-stream (fetched lazily), always emit the one with the smallest
position, advance only that sub-stream. Deduplication becomes a simple "skip if same position as
previous" check since duplicates will be adjacent after position-order merge.

For **scan-based queries** (no tags), items arrive in unspecified order. A lazy merge-sort is
impossible — a full table scan must be collected before any globally-sorted result can be emitted.
The implementation would handle this case by falling back to the current eager strategy.

**Concrete API sketch:**

```rescript
// A new helper for k-way sorted merge
let mergeSortedStreams: (
  array<Stream.t<rawSequencedEvent, string, unit>>,
  (rawSequencedEvent, rawSequencedEvent) => int  // comparator
) => Stream.t<rawSequencedEvent, string, unit>

let readStream = table => (~query, ~after=?) => {
  let streams = query->Array.map(qi => executeQueryItemStream(table, qi, ~after?))
  switch streams {
  | [single] => single->Stream.map(fromItem)
  | _ =>
    let hasScan = query->Array.some(qi => qi.tags == None)
    if hasScan then
      // Scan sub-queries cannot be lazily merged — fall back to eager collect
      streams->collectAndMergeEagerly(~concurrency=3)
    else
      // All sub-streams are position-sorted GSI queries — merge lazily
      mergeSortedStreams(streams, (a, b) => String.compare(a.position, b.position))
      ->Stream.map(fromItem)
      ->deduplicate    // skip consecutive events with the same position
  }
}
```

The `mergeSortedStreams` implementation requires holding one buffered element per sub-stream in
an Effect `Ref`. There is no built-in in rescript-effect for this — it requires ~30–50 lines of
custom Effect logic.

**Consequences:**
- **Memory:** O(n_consumed + k) where k is the number of sub-streams. For a `Stream.take(100)`
  across 3 tags, only ~100 events need to be in RAM at once regardless of total event count.
- **Latency to first element:** The first element is emitted as soon as the first DynamoDB pages
  from all sub-streams have returned (one concurrent DynamoDB request per sub-stream). No waiting
  for later pages.
- **Backpressure:** `Stream.take(n)` genuinely short-circuits DynamoDB fetching. Once n elements
  are consumed, remaining DynamoDB pages are never requested.
- **Scan queries:** Still eager (unavoidable). If a multi-queryItem call mixes tag-based and
  scan-based queryItems, the entire call falls back to eager.
- **Complexity:** Medium. Requires implementing a k-way merge (~40 lines). The fallback path
  for scan queries must be tested separately.
- **Risk:** The k-way merge logic must correctly handle sub-stream exhaustion (when one tag has
  fewer events than another) and stream errors.

**When to choose:** Event logs are large (thousands of events per tag), callers may consume
partial results via `Stream.take`, or memory efficiency is a concern.

---

**Recommended path:** Implement A1 now. Implement A2 Option 2 when there is a concrete need
(large event sets observed in production, or `Stream.take` is used in callers). Option 1 is only
useful as a documentation fix — the code is already effectively Option 1 minus the clarifying
comment.

### Acceptance criteria
- `Effect.all` in `readStream` is bounded (A1).
- (A2 Option 2) A `Stream.take(5)` on a 2-tag query issues at most 2 DynamoDB requests total
  (one initial page per sub-stream), verified with a mock that counts requests.

---

## Phase B — True lazy pagination for `EventLog.replayStream` and `QueryDb.loadStream` (HIGH IMPACT)

**Files:**
- `reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` lines 39–47
- `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` lines 5–15
- `rescript-aws-sdk/src/DynamoDb_DocumentClient.res` (`queryRecursive`, `scanRecursive`)

### Problem

Both `replayStream` and `loadStream` use the `fromEffect + flatMap(fromIterable)` bridge:

```rescript
Effect.tryPromise(() => tryReplay(table.name, id))   // ← loads all pages into one array
->Stream.fromEffect
->Stream.flatMap(arr => Stream.fromIterable(arr))
```

Internally, `queryRecursive` is a recursive loop that accumulates all DynamoDB pages before
returning. Despite the `Stream.t` return type, all events are in memory before the first element
is emitted. A comment in the file explicitly acknowledges this:
_"Full pagination will be added when queryByIdPage is implemented."_

`DcbEventLog.readStream` already uses `Stream.paginateEffect` correctly — the fix here is to
apply the same pattern to `EventLog` and `QueryDb`.

### Solution

**B1 — Add `queryByIdPage` to `DynamoDb_DocumentClient.res`.**
Implement a cursor-aware single-page query function:
```rescript
let queryByIdPage: (tableName, id, ~exclusiveStartKey: option<JSON.t>=?) =>
  promise<{items: array<JSON.t>, nextKey: option<JSON.t>}>
```

**B2 — Replace `tryReplay` with `Stream.paginateEffect` in `EventLogStorage_DynamoDb_Runtime.res`.**
```rescript
let replayStream = table => id =>
  Stream.paginateEffect(None, cursor =>
    Effect.tryPromise(() => queryByIdPage(table.name, id, ~exclusiveStartKey=cursor))
    ->Effect.map(page => (page.items, page.nextKey))
  )
  ->Stream.flatMap(Stream.fromIterable)
```

**B3 — Same for `QueryDb.loadStream`.** Apply the same `paginateEffect` pattern to
`QueryDbStorage_DynamoDb_Runtime.res`.

### Acceptance criteria
- `Stream.take(3)` on an aggregate with 100 events issues at most 1–2 DynamoDB requests (one page),
  not a full recursive fetch.
- Existing aggregate replay tests still pass.

---

## Phase C — `CsvStream` true lazy streaming (MEDIUM IMPACT)

**File:** `reventless-core/src/util/CsvStream.res` lines 16–36

### Problem

All CSV rows are accumulated in a `ref(array)` before the stream begins emitting. `Stream.take(2)`
on a 1M-row CSV file reads the entire file first. The file comment documents this limitation.

```rescript
let rows = ref([])
CSV.parseFile(~path, ...)
->CSV.onData(row => rows := rows.contents->Array.concat([row]))  // ← O(n²), fully eager
->CSV.onEnd(_ => resolve(Ok(rows.contents)))
```

### Solution

Bridge the `csv-parse` `onData` callback into an Effect `Queue`, then drain it as a `Stream.fromQueue`:

```rescript
let parseRows = (~path: string): Stream.t<CSV.row, string, unit> =>
  Stream.fromEffect(
    Queue.bounded(256)->Effect.flatMap(queue =>
      Effect.sync(() => {
        CSV.parseFile(~path, ...)
        ->CSV.onData(row => Queue.offer(queue, row)->Effect.runSync->ignore)
        ->CSV.onEnd(_ => Queue.shutdown(queue)->Effect.runSync->ignore)
        ->CSV.onError(e => Queue.shutdown(queue)->Effect.runSync->ignore)
        queue
      })
    )
  )
  ->Stream.flatMap(queue => Stream.fromQueue(queue))
```

This makes `Stream.take(n)` cause the CSV parser to pause after `n` rows (via Node.js Readable
backpressure through the queue's bounded capacity).

**Note:** The queue bridge needs to handle the `shutdown` correctly when the stream is interrupted
mid-file. Test with a large file and `Stream.take(10)`.

### Acceptance criteria
- `parseRows(~path)->Stream.take(5)->Stream.runCollect->Effect.runPromise` does not read the
  entire file (verified with a spy on `onData` call count).

---

## Phase D — Publisher adapters: stream-aware batching (LOW IMPACT)

**Files:**
- `reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res`
- `reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_FIFO.res`
- `reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS.res`
- `reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_FIFO.res`
- `reventless-in-memory/src/adapter/EventTopic/EventTopicPublisher_InMemory.res`
- `reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`

### Problem

All publisher adapters collect the full stream before sending:
```rescript
stream->Stream.runCollect->Effect.flatMap(items => Effect.promise(() => batchPublish(items)))
```

This is correct for current use (SQS/SNS batch limit is 10, publish streams are always small).
However it does not scale if publish streams grow (e.g., bulk event import, fan-out to many
destinations) and loads all items into memory before the first message is sent.

### Solution

Replace `runCollect` + bulk send with `Stream.grouped(10)` + per-chunk send:
```rescript
stream
->Stream.grouped(10)
->Stream.runForEach(chunk =>
  Effect.promise(() => batchPublish(chunk->Chunk.toArray))
)
```

This sends messages as soon as each group of 10 is available, caps RAM usage at one chunk, and
maintains SNS/SQS batch limits.

**Priority note:** This is a low-priority cleanup. Only schedule if publish streams may exceed
a few dozen items in practice, or if memory profiling shows publisher allocation is notable.

### Acceptance criteria
- A publish stream of 25 items results in exactly 3 `batchPublish` calls (batches of 10, 10, 5).

---

## Phase E — `EventMapper_Callback`: `runCollect` → `runForEach` (LOW IMPACT)

**File:** `reventless-core/src/components/EventMapper/EventMapper_Callback.res` lines 161–163, 208–210

### Problem

Both `handleCounterEvents` and `handleJsonEvents` collect all events before processing:
```rescript
stream->Stream.runCollect->Effect.flatMap(chunk => /* process full array */)
```

Compare with `ReadModel_Callback` which uses `runForEach` — each event is processed as it arrives.
The collect here is unnecessary given the downstream operations process events independently.

### Solution

Refactor both handlers to `runForEach`:
```rescript
stream->Stream.runForEach(json => Effect.promise(() => handleSingleEvent(json)))
```

This requires extracting the per-event processing logic from the current array-based handler.

### Acceptance criteria
- Existing `EventMapper` tests pass unchanged.
- No `Stream.runCollect` in `EventMapper_Callback.res`.

---

## Phase F — `CommandTopic_Builder`: O(n²) fold → O(n) collect (TRIVIAL)

**File:** `reventless-core/src/components/CommandTopic/CommandTopic_Builder.res` line 58**

### Problem

```rescript
->Stream.runFold([], (acc, results) => acc->Array.concat(results))
```

`Array.concat` allocates a new array on every fold step — O(n²) total allocations. At SQS batch
sizes (≤10) this is harmless but inconsistent with good practice.

### Solution

Replace with a single `Stream.flatMap + Stream.runCollect`:
```rescript
->Stream.flatMap(results => Stream.fromIterable(results))
->Stream.runCollect
->Effect.map(chunk => chunk->Chunk.toArray)
```

Or, if the stream already emits arrays, use `Effect.map(Array.flat)` after `runCollect`.

### Acceptance criteria
- No `Array.concat` inside a fold in `CommandTopic_Builder.res`.

---

## Deferred / Out of Scope

- **`StateChangeSlice_Builder` / `CommandTopic_Callback` `runCollect`**: These collect decoded
  commands before passing to `handleCommands`. Removing the collect would require `handleCommands`
  to accept a stream — a larger API change. Deferred until the command handler API is revisited.

- **`InMemory_Bus` unbounded default**: The default `Make()` functor uses `PubSub.unbounded`.
  This is intentional for test code where backpressure is not the concern. Document the `MakeBounded`
  variant in the module header and leave the default as-is.

---

## Phase Status

| Phase | Priority | Status |
|---|---|---|
| A — DcbEventLog readStream fan-out | High | Not started |
| B — EventLog / QueryDb lazy pagination | High | Not started |
| C — CsvStream true lazy streaming | Medium | Not started |
| D — Publisher adapters stream batching | Low | Not started |
| E — EventMapper runCollect → runForEach | Low | Not started |
| F — CommandTopic O(n²) fold | Trivial | Not started |
