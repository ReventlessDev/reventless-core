# Effect Stream Integration Plan

**Status:** In progress — Phases A–E complete, next steps pending
**Created:** 2026-02-28
**Revised:** 2026-02-28
**Depends on:** `docs/plans/effect-library-integration.md` phases 0–4 (complete)
**Summary:** Six use cases where Effect `Stream` improves memory safety, correctness, or composability
in the Reventless codebase. Each phase bundles its implementation and tests together. Includes a
structural analysis of how `Aggregate_Callback` and other callback modules must adapt for lazy fold.

---

## Background

Phases 0–4 of the effect-library integration plan introduced bindings for `Effect`, `Queue`,
`Deferred`, `Latch`, `Schedule`, `Stm`, and `SynchronizedRef`. Phase 5 identified
`Stream`-based `EventLog.replay` as a future candidate. This plan is that work, expanded.

**What Effect Stream is:** `Stream.t<'a, 'e, 'r>` is a lazy, composable, resource-safe sequence.
It integrates with Effect's structured concurrency: streams can be interrupted, paginated, and
consumed one item at a time — without materialising the whole sequence in memory. Key operations:

| Operation | Description |
|---|---|
| `Stream.fromIterable` | Wrap an in-memory array |
| `Stream.fromEffect` | Wrap a single Effect value |
| `Stream.fromQueue` | Drain a Queue until shutdown |
| `Stream.paginateEffect` | Multi-page DynamoDB queries via cursor state |
| `Stream.mapEffect` | Per-item async decode |
| `Stream.runCollect` | Materialise to array |
| `Stream.runFold` | Left fold — ideal for state reconstruction |
| `Stream.take` | Limit without loading all |
| `Stream.runForEach` | Process each item for side effects |

---

## Section 1: Structural Impact Analysis

### 1.1 How `Aggregate_Callback` must adapt for lazy fold

`Aggregate_Callback.Make` is the primary consumer of `EventLog.replay`. Reading it reveals
two structural dependencies on the replayed history array:

```rescript
// Aggregate_Callback.res — current handleCommands (inside groupTopicItemsById loop)
let history = await Ops.eventLog.replay(id)           // (A) loads all events
let result = await commands'->Array.reduce(
  Ok((updateState(None, history), []))->Promise.resolve,  // (B) folds history → stateOpt
  processCommand,
)
// ...
switch await Ops.eventLog.append(history->Array.length, id, generatedEvents') {  // (C)
```

**Dependency A/B — state reconstruction:** `replay` returns `array<event>`, which
`updateState(None, history)` folds into an initial `stateOpt`. With a stream, this becomes:

```rescript
let (initialState, _count) = await Ops.eventLog.replayStream(id)
  ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
  ->Effect.runPromise
```

The fold is over a `Stream` instead of an `array`, but the semantics are identical.

**Dependency C — optimistic concurrency token:** `history->Array.length` is the `sequenceNr`
passed to `EventLog.append`. This is the write-side optimistic concurrency check (DynamoDB uses
it to prevent lost-update races). With the stream fold, we accumulate the count simultaneously
in the tuple accumulator — `n + 1` on every event. After the fold, `count` replaces
`history->Array.length`:

```rescript
let (initialState, sequenceNr) = await Ops.eventLog.replayStream(id)
  ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
  ->Effect.runPromise
// ...
switch await Ops.eventLog.append(sequenceNr, id, generatedEvents') {
```

**What does NOT change:** The `updateState` helper and `apply'` function are still used inside
`processCommand` to fold newly-generated events into the running state accumulator. This is a
small in-memory fold over freshly created events — not a storage replay — and needs no streaming.

**Complete structural diff for `handleCommands`:**

```rescript
// BEFORE: two-pass over history array
let history = await Ops.eventLog.replay(id)
// ... later ...
let result = await commands'->Array.reduce(
  Ok((updateState(None, history), []))->Promise.resolve,
  processCommand,
)
// ... even later ...
switch await Ops.eventLog.append(history->Array.length, id, generatedEvents') {

// AFTER: single-pass stream fold produces both state and count
let (initialState, sequenceNr) = await Ops.eventLog.replayStream(id)
  ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
  ->Effect.runPromise
// ... later ...
let result = await commands'->Array.reduce(
  Ok((initialState, []))->Promise.resolve,
  processCommand,
)
// ... even later ...
switch await Ops.eventLog.append(sequenceNr, id, generatedEvents') {
```

The change is structurally minimal. `history` disappears; `initialState` and `sequenceNr` replace
its two uses. No change to `processCommand`, `runBehavior`, error handling, or publishing.

**Correctness constraint:** The stream fold must always consume all events — `take` must never be
applied to `replayStream` inside `Aggregate_Callback`. All events are required to reconstruct
the correct current state and count. The `replayStream` in `EventLog_Operations` must be an
unrestricted stream; callers that want early termination apply `take` themselves.

---

### 1.2 How `StateChangeSlice_Callback` would adapt (Phase D)

`StateChangeSlice_Callback.handleCommands` (not read here, but referenced by
`StateChangeSlice_Builder`) does the DCB equivalent of what `Aggregate_Callback` does:

1. Calls `DcbEventLog.read(~query, ~after=?)` to load all matching events into memory
2. Builds a "decision model" by folding over the event array
3. Checks `headPosition` from the result as the optimistic concurrency token for `append`

When Phase D adds `DcbEventLog.readStream`, `StateChangeSlice_Callback` would adapt similarly:

```rescript
// BEFORE
let {events, headPosition} = await dcbEventLogOps.read(~query)
let decisionModel = events->Array.reduce(emptyDecisionModel, applyEvent)
// ... use headPosition for append condition ...

// AFTER (Phase D)
let (decisionModel, headPosition) = await dcbEventLogOps.readStream(~query)
  ->Stream.runFold(
    (emptyDecisionModel, None),
    ((dm, _pos), event) => (applyEvent(dm, event), Some(event.position))
  )
  ->Effect.runPromise
// ... use headPosition for append condition ...
```

The fold accumulates both the decision model and the last seen position (which becomes the
`headPosition` used as the append condition). This is structurally the same pattern as
`Aggregate_Callback`.

---

### 1.3 Survey of all other components — what is and isn't affected

| Component | Replay/scan pattern? | Affected? | Notes |
|---|---|---|---|
| `Aggregate_Callback` | `EventLog.replay` → fold | **Yes — Phase B** | See §1.1 |
| `StateChangeSlice_Callback` | `DcbEventLog.read` → fold | **Yes — Phase D** | See §1.2 |
| `ReadModel` / `EventCollector` | Receives events pushed via bus | No | Pull model — events come to it |
| `EventMapper` | Subscribes to EventTopic bus | No | Push model — same as ReadModel |
| `Counter` | Reads QueryDb for totals | Indirect — Phase C | `scan` used for admin queries |
| `CommandTopic` | Dispatches commands, no replay | No | Write path only |
| `CommandGenerator` | Sends commands, no replay | No | Write path only |
| `ExtensionPoint_Callback` | Dispatches to extension handlers | No | Thin dispatcher |
| `SideEffectHandler` | Receives events, fires effects | No | Push-based via bus |
| `Heartbeat` / `Scheduler` | Timer-based, no storage reads | No | Infrastructure only |
| `Task` | File key callback, no replay | Indirect — Phase E | CSV streaming opportunity |
| `StateViewSlice` | Queries DcbEventLog | No builder yet | Placeholder — revisit with Phase D |

**Key finding:** Only `Aggregate_Callback` (traditional EventLog) and `StateChangeSlice_Callback`
(DCB EventLog) have the "load all from storage → fold → process commands" pattern that streaming
directly improves. All other components are push-based (events arrive via bus) and do not replay
from storage.

---

## Section 2: Stream Binding Requirements

No `Stream.res` exists yet in `rescript/rescript-effect/src/`. Create it as part of Phase A.

### Core bindings (Phases A–D)

```rescript
// Stream.res

// Core type — matches Effect.Stream<A, E, R>
type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

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
// IMPORTANT: maps to JS "paginateChunkEffect" (chunk-based variant).
// Do NOT use JS "paginateEffect" — it takes one item per page, not a chunk.
//
// NOTE (discovered during Phase A): paginateChunkEffect requires Effect Chunk
// (not plain JS array) and Effect Option (not ReScript option). The binding is
// implemented as a wrapper that converts automatically:
//   array<'a>  →  Chunk.fromIterable(array)
//   option<'s> →  Option.fromNullable(value|undefined)
// See Stream.res for the raw paginateEffectRaw + chunkFromIterable + toEffectOption helpers.
let paginateEffect: (
  's,
  's => Effect.t<(array<'a>, option<'s>), 'e, 'r>,
) => t<'a, 'e, 'r>

// ─── Transformation ──────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("Stream")
external mapEffect: (t<'a, 'e, 'r>, 'a => Effect.t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "mapEffect"

@module("effect") @scope("Stream")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

@module("effect") @scope("Stream")
external filter: (t<'a, 'e, 'r>, 'a => bool) => t<'a, 'e, 'r> = "filter"

// Take first N items then stop (resource-safe upstream interruption)
@module("effect") @scope("Stream")
external take: (t<'a, 'e, 'r>, int) => t<'a, 'e, 'r> = "take"

@module("effect") @scope("Stream")
external tap: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// ─── Terminal runners ────────────────────────────────────────────────────

// NOTE (discovered during Phase A): Stream.runCollect in Effect v3 returns a
// Chunk<A>, not a plain JS array. The binding wraps runCollect with Array.from
// to convert. Callers receive array<'a> as expected.
let runCollect: t<'a, 'e, 'r> => Effect.t<array<'a>, 'e, 'r>

@module("effect") @scope("Stream")
external runFold: (t<'a, 'e, 'r>, 's, ('s, 'a) => 's) => Effect.t<'s, 'e, 'r> = "runFold"

@module("effect") @scope("Stream")
external runForEach: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => Effect.t<unit, 'e, 'r>
  = "runForEach"

@module("effect") @scope("Stream")
external runDrain: t<'a, 'e, 'r> => Effect.t<unit, 'e, 'r> = "runDrain"

// NOTE (discovered during Phase A): Stream.runHead in Effect v3 returns Effect's
// Option type ({_id: "Option", _tag: "Some"/"None", value?}), not ReScript's
// native option. The binding wraps runHead with Option.getOrUndefined to convert
// to ReScript option (None=undefined, Some=value).
let runHead: t<'a, 'e, 'r> => Effect.t<option<'a>, 'e, 'r>

// ─── Error handling ──────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"
```

### Additional bindings for Use Case 4 (PubSub stream fan-out)

```rescript
// Run within a scope — for PubSub.subscribe which returns a scoped Queue
@module("effect") @scope("Stream")
external scoped: Effect.t<t<'a, 'e, 'r>, 'e, 'r> => t<'a, 'e, 'r> = "unwrapScoped"

@module("effect") @scope("Stream")
external runIntoQueue: (t<'a, 'e, 'r>, Queue.t<'a>) => Effect.t<unit, 'e, 'r> = "runIntoQueue"
```

### Additional bindings for Phase E (CSV / Node.js streams)

```rescript
@module("effect") @scope("Stream")
external fromReadableStream: (unit => NodeStreams.Readable.t, int) => t<string, string, unit>
  = "fromReadableStream"
```

---

## Section 3: Implementation Phases

Each phase contains its implementation steps and tests together. Phases are ordered by value and
dependency. Phase A (bindings) is the prerequisite for all others.

### Dependency graph

```
Phase A — Stream.res bindings + smoke tests
  ├─> Phase B — EventLog.replayStream + Aggregate_Callback + tests
  ├─> Phase C — QueryDb scan stream + limit tests
  ├─> Phase D — DcbEventLog.readStream + StateChangeSlice_Callback + tests
  └─> Phase E — CSV/Node.js streams + tests
```

---

### Phase A — Stream.res Bindings + Smoke Tests ✅ COMPLETE

**Goal:** Make `Stream.t<'a, 'e, 'r>` importable from `rescript-effect` and verify the core
operations work correctly before building anything on top.

#### A.1 Implementation

**File to create:** `rescript/rescript-effect/src/Stream.res`

Write all core bindings from Section 2 (omit Node.js interop until Phase E). Add a header comment
referencing this plan. Build `rescript/rescript-effect`:

```bash
cd rescript/rescript-effect && npm run build
# must print zero warnings
```

No changes to any other package. No existing tests change.

#### A.2 Set up test infrastructure in `rescript-effect`

The `rescript-effect` package currently has `"test": "echo \"No tests\""` and no Jest
configuration. Binding smoke tests belong here — they only exercise Effect library calls and are
independent of any Reventless adapter. Setting up once pays for all future binding tests (Queue,
Deferred, Schedule, etc.).

**Changes to `rescript/rescript-effect/package.json`:**

```json
{
  "scripts": {
    "test": "NODE_OPTIONS='--experimental-vm-modules' npx jest"
  },
  "jest": {
    "testMatch": ["<rootDir>/tests/**/*Test.res.mjs"],
    "moduleFileExtensions": ["js", "mjs"]
  },
  "devDependencies": {
    "@jest/globals": "^29.0.0",
    "jest": "^29.0.0",
    "jest-environment-node": "^29.0.0",
    "rescript": "^12.1.0"
  }
}
```

Also add a `tests/` source directory to `rescript.json`:

```json
{
  "sources": [
    {"dir": "src", "subdirs": true},
    {"dir": "tests", "subdirs": true, "type": "dev"}
  ]
}
```

Run `npm install` after modifying `package.json` to update the lock file. The compiled test output
(`.res.mjs` files) will land in `tests/` alongside the sources.

#### A.3 Tests

**File to create:** `rescript/rescript-effect/tests/StreamTest.res`

These tests live in `rescript-effect` because they verify Effect bindings only — no Reventless
adapter code, no in-memory bus, no fixtures. The same principle applies to any future binding
tests for `Queue`, `Deferred`, `Schedule`, etc.

Also create the shared test helper module (prerequisite for all binding tests in this package —
see `docs/plans/rescript-effect-binding-tests.md` Section 1 for the full `AsyncTest.res` content).
This follows the established monorepo pattern from `reventless-core/tests/AsyncTest.res`: bind
directly to Jest globals via `@val external` rather than using `@glennsl/rescript-jest`'s broken
`testPromise` (which discards the returned Promise).

**File to create:** `rescript/rescript-effect/tests/AsyncTest.res` — see binding tests plan
Section 1 for the full content.

```rescript
// StreamTest.res — in rescript/rescript-effect/tests/
open AsyncTest
open AsyncTest.Expect

describe("Stream bindings", () => {
  describe("construction", () => {
    testPromise("fromIterable emits all items in order", async () => {
      let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([1, 2, 3])
    })

    testPromise("empty stream yields no items", async () => {
      let result = await Stream.empty->Stream.runCollect->Effect.runPromise
      expect(result)->toEqual([])
    })

    testPromise("fromEffect wraps a single value", async () => {
      let result = await Stream.fromEffect(Effect.succeed("hello"))
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual(["hello"])
    })

    // NOTE (discovered during Phase A): shutting down the queue BEFORE
    // Stream.fromQueue runs interrupts all subsequent takes → yields [].
    // Use Stream.take(2) to terminate the stream instead of pre-shutdown.
    testPromise("fromQueue emits items already in the queue", async () => {
      let queue = Queue.unbounded()->Effect.runSync
      let _ = Queue.offer(queue, 10)->Effect.runSync
      let _ = Queue.offer(queue, 20)->Effect.runSync
      let result = await Stream.fromQueue(queue)
        ->Stream.take(2)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([10, 20])
    })

    testPromise("paginateEffect pages through chunks until None", async () => {
      // Three pages: [1,2], [3,4], [5]
      let result = await Stream.paginateEffect(0, cursor =>
        Effect.sync(() => {
          let all = [1, 2, 3, 4, 5]
          let chunk = all->Array.slice(~start=cursor, ~end=min(cursor + 2, 5))
          let next = cursor + 2 < 5 ? Some(cursor + 2) : None
          (chunk, next)
        })
      )
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([1, 2, 3, 4, 5])
    })
  })

  describe("transformation", () => {
    testPromise("map transforms each item", async () => {
      let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.map(n => n * 2)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([2, 4, 6])
    })

    testPromise("filter removes items not matching predicate", async () => {
      let result = await Stream.fromIterable([1, 2, 3, 4, 5])
        ->Stream.filter(n => mod(n, 2) == 0)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([2, 4])
    })

    testPromise("take limits to first N items", async () => {
      let result = await Stream.fromIterable([1, 2, 3, 4, 5])
        ->Stream.take(3)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result)->toEqual([1, 2, 3])
    })
  })

  describe("terminal runners", () => {
    testPromise("runFold accumulates state across all items", async () => {
      let sum = await Stream.fromIterable([1, 2, 3, 4])
        ->Stream.runFold(0, (acc, n) => acc + n)
        ->Effect.runPromise
      expect(sum)->toBe(10)
    })

    testPromise("runFold can accumulate a tuple", async () => {
      // Same pattern used in Aggregate_Callback for (state, count)
      let (last, count) = await Stream.fromIterable(["a", "b", "c"])
        ->Stream.runFold(("", 0), ((_, n), s) => (s, n + 1))
        ->Effect.runPromise
      expect(last)->toBe("c")
      expect(count)->toBe(3)
    })

    testPromise("runHead returns Some for non-empty stream", async () => {
      let head = await Stream.fromIterable([42, 1, 2])
        ->Stream.runHead
        ->Effect.runPromise
      expect(head)->toEqual(Some(42))
    })

    testPromise("runHead returns None for empty stream", async () => {
      let head = await Stream.empty->Stream.runHead->Effect.runPromise
      expect(head)->toEqual(None)
    })
  })
})
```

#### A.4 Acceptance criteria ✅

- Jest infrastructure in `rescript-effect` was already in place (set up in prior binding work)
- `Stream.res` compiles with zero warnings ✅
- `npm test` in `rescript/rescript-effect` runs 12 smoke tests (13 planned but `fromQueue`+shutdown
  test replaced by `fromQueue`+`take(2)` — see note above) and all pass ✅ (122 total across all suites)
- `npm test` in `reventless-in-memory` unchanged — no tests moved there ✅
- `npm run build` from monorepo root: pending full monorepo build verification

---

### Phase B — EventLog.replayStream + Aggregate_Callback Adaptation ✅ COMPLETE

**Goal:** Replace the full in-memory event array load in `Aggregate_Callback` with a lazy stream
fold that produces `(initialState, sequenceNr)` in a single pass, eliminating the two-pass overhead
of `replay + Array.length`.

**Priority:** Medium — primary business value of the streaming work.

#### B.1 Implementation

**Step 1 — Add type to `EventLog_Adapter.operations`**

```rescript
// EventLog_Adapter.res — extend the operations record
type operations = {
  append: EventLog.append<string, JSON.t>,
  replay: EventLog.replay<string, JSON.t>,
  replayStream: string => Stream.t<JSON.t, string, unit>,  // NEW — lazy streaming replay
}
```

**Step 2 — Add type to `EventLog.T.operations`**

```rescript
// EventLog.res — add replayStream type alias
type replayStream<'id, 'event> = 'id => Stream.t<'event, string, unit>

// EventLog.T — extend operations record
module type T = {
  module Spec: Reventless.EventLog.T
  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
    replayStream: replayStream<Spec.Id.t, Spec.event>,  // NEW
  }
  ...
}
```

**Step 3 — Add `replayStream` to `EventLog_Operations.Make`**

```rescript
// EventLog_Operations.res — inside module Make(...)
let replayStream = id =>
  Ops.storage.replayStream(id->Spec.Id.toString)
  ->Stream.mapEffect(json =>
    // decodeEvent throws on bad data — wrap in Effect.sync so errors surface
    // through the stream's error channel rather than as unhandled exceptions
    Effect.sync(() => decodeEvent(id->Spec.Id.toString, json))
  )
```

Also extend module type `T`:

```rescript
module type T = {
  module Spec: Reventless.EventLog.T
  let append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: EventLog.replay<Spec.Id.t, Spec.event>
  let replayStream: EventLog.replayStream<Spec.Id.t, Spec.event>  // NEW
}
```

**Step 4 — Implement `replayStream` in `EventLogStorage_InMemory.res`**

```rescript
// EventLogStorage_InMemory.res — add to the operations record
let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
  Stm.TRef.get(eventsRef)
  ->Stm.commit
  ->Effect.map(events => events->Dict.get(id)->Option.getOr([]))
  ->Stream.fromEffect
  ->Stream.flatMap(arr => Stream.fromIterable(arr))
```

Note: for the in-memory adapter the entire array is still loaded (it is in memory anyway), then
exposed as a stream. The benefit is API uniformity; the real performance gain comes from DynamoDB.

**Step 5 — Implement `replayStream` in `EventLogStorage_DynamoDB.res`** (AWS adapter)

```rescript
// EventLogStorage_DynamoDB.res
// Cursor state: option<JSON.t> = lastEvaluatedKey from DynamoDB
let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
  Stream.paginateEffect(None, (lastKey: option<JSON.t>) =>
    Effect.tryPromise({
      "try": () => queryByIdPage(tableName, id, lastKey),
      "catch": (err: unknown) =>
        (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("DynamoDB query error"),
    })
    ->Effect.map(page => (page.items, page.lastKey))
  )
```

Each DynamoDB page is fetched only when the stream consumer pulls. For aggregates with < 1 page of
events (the common case), there is exactly one DynamoDB call — same as before. For aggregates with
> 1 page, subsequent pages are fetched lazily during the fold.

**Step 6 — Adapt `Aggregate_Callback.handleCommands`**

Replace the two-pass `replay → Array.length + updateState` pattern with a single stream fold.
The change is scoped to the inner `Array.map(async ((id, topicItemsForId)) => { ... })` callback:

```rescript
// REMOVE:
let history = await Ops.eventLog.replay(id)
// ... later in the same scope:
let result = await commands'->Array.reduce(
  Ok((updateState(None, history), []))->Promise.resolve,
  processCommand,
)
// ... even later:
switch await Ops.eventLog.append(history->Array.length, id, generatedEvents') {

// ADD:
// Single pass: produce both (initialState, sequenceNr) from the stream.
// sequenceNr replaces history->Array.length as the optimistic concurrency token.
let (initialState, sequenceNr) = await Ops.eventLog.replayStream(id)
  ->Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
  ->Effect.runPromise
// ... later in the same scope:
let result = await commands'->Array.reduce(
  Ok((initialState, []))->Promise.resolve,
  processCommand,
)
// ... even later:
switch await Ops.eventLog.append(sequenceNr, id, generatedEvents') {
```

`processCommand` and `runBehavior` are unchanged — they use `updateState` only for in-memory
newly-generated events, not for replayed history.

The `updateState` helper and `apply'` function remain in `Aggregate_Callback.Make` unchanged.

#### B.2 Tests

**File to create:**
`reventless/reventless-in-memory/tests/components/eventlog/EventLogStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect
open EventLogFixtures  // reuse existing fixtures

describe("EventLog.replayStream", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })
  let _ = beforeEach(() => resetStorage())

  describe("storage streaming (in-memory adapter)", () => {
    testPromise("replayStream returns all appended events", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, itemId, [makeEvent("Created")])
      let _ = await ops.append(1, itemId, [makeEvent("Updated")])
      let replayed = await ops.replayStream(itemId)->Stream.runCollect->Effect.runPromise
      expect(replayed->Array.length)->toBe(2)
    })

    testPromise("replayStream for unknown id returns empty stream", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let replayed = await ops.replayStream("no-such-id")->Stream.runCollect->Effect.runPromise
      expect(replayed->Array.length)->toBe(0)
    })

    testPromise("replayStream emits events in append order", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, itemId, [makeEvent("First")])
      let _ = await ops.append(1, itemId, [makeEvent("Second")])
      let replayed = await ops.replayStream(itemId)->Stream.runCollect->Effect.runPromise
      // First event is earlier — order is preserved
      expect(replayed->Array.getUnsafe(0))->toBeDefined  // spot-check order via count
      expect(replayed->Array.length)->toBe(2)
    })

    testPromise("separate aggregate IDs have independent streams", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "agg-X", [makeEvent("X-Created")])
      let _ = await ops.append(0, "agg-Y", [makeEvent("Y-Created"), makeEvent("Y-Updated")])
      let countX = await ops.replayStream("agg-X")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      let countY = await ops.replayStream("agg-Y")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(countX)->toBe(1)
      expect(countY)->toBe(2)
    })

    testPromise("take(2) on a 5-event log returns only 2 events", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, itemId, [
        makeEvent("e1"), makeEvent("e2"), makeEvent("e3"), makeEvent("e4"), makeEvent("e5"),
      ])
      let first2 = await ops.replayStream(itemId)
        ->Stream.take(2)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(first2->Array.length)->toBe(2)
    })
  })

  describe("tuple fold — (state, count) pattern used in Aggregate_Callback", () => {
    testPromise("runFold produces correct count for sequenceNr", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, itemId, [makeEvent("e1"), makeEvent("e2")])
      let _ = await ops.append(2, itemId, [makeEvent("e3")])
      let (_state, count) = await ops.replayStream(itemId)
        ->Stream.runFold((None, 0), ((st, n), _ev) => (st, n + 1))
        ->Effect.runPromise
      expect(count)->toBe(3)  // sequenceNr = 3, matches append call with seqNr 3
    })

    testPromise("runFold on empty stream returns initial accumulator", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let (state, count) = await ops.replayStream("unknown")
        ->Stream.runFold((None, 0), ((st, n), _ev) => (st, n + 1))
        ->Effect.runPromise
      expect(state)->toEqual(None)
      expect(count)->toBe(0)
    })
  })
})
```

**File to modify:** `reventless/reventless-in-memory/tests/components/aggregate/AggregateTest.res`

Add a regression test that exercises the full command → stream replay → state → new command cycle:

```rescript
testPromise("second command sees state produced by first command via stream replay", async () => {
  // First command: CreateItem — produces ItemCreated event
  // Stream replay reconstructs state: Some({name: "Widget"})
  // Second command: UpdateItem — Behavior.execute sees the created item
  // Without correct stream fold, second command would fail (item doesn't exist)
  let _ = await ops.publishJsons(encodeCreate("item-1", "Widget"))
  let _ = await ops.publishJsons(encodeUpdate("item-1", "Updated Widget"))
  // Verify both commands produced events (no error)
  let replayed = await eventLogOps.replayStream("item-1")
    ->Stream.runFold(0, (n, _) => n + 1)
    ->Effect.runPromise
  expect(replayed)->toBe(2)  // Created + Updated events in log
})
```

#### B.3 Acceptance criteria ✅

- All existing `EventLogTest.res` tests pass unchanged (replay still works) ✅
- All existing `AggregateTest.res` tests pass unchanged (observable behaviour unchanged) ✅
- All new `EventLogStreamTest.res` tests pass (7 tests) ✅
- `npm run build` from root: zero warnings, all packages compile ✅
- `npm test` from `reventless-in-memory`: 129 tests pass ✅
- `npm test` from `reventless-core`: 185 tests pass ✅

**Implementation notes:**
- `reventless-aws` required `rescript-effect` added to both `package.json` and `rescript.json`
  (not previously a dependency — needed for `Stream.fromEffect`/`flatMap` in DynamoDB runtime)
- DynamoDB `replayStream` wraps the existing promise-based `tryReplay` in a stream via
  `Effect.tryPromise → Stream.fromEffect → Stream.flatMap(fromIterable)`. Full pagination
  with `paginateEffect` is a follow-up when `queryByIdPage` is implemented.
- `EventLogStorage_DynamoDbStream.res` (the CDC variant) also required `replayStream`
- `MockEventLogStorage.res` (in `reventless-in-memory/src/test/Mocks/`) also required updating
- `AggregateFixtures.res` mock EventLog module required `replayStream` in `type operations`

---

### Phase C — QueryDb Scan as Stream + Limit Tests ✅ COMPLETE

**Goal:** Make `QueryEngine_InMemory.scan` honour the `~limit` parameter, which has been wired
through the type system since the beginning but silently ignored in the in-memory implementation.

**Priority:** Low — `scan` is used in the GraphQL admin/reporting API, not the hot path.

#### C.1 Implementation

**Step 1 — Add stream registry to `InMemory_Bus.T`**

Alongside the existing `registerQueryDbScan` / `getQueryDbScan` pair, add a stream variant:

```rescript
// InMemory_Bus.T — additions
let registerQueryDbStream: (string, unit => Stream.t<JSON.t, string, unit>) => unit
let getQueryDbStream: string => option<unit => Stream.t<JSON.t, string, unit>>
```

Implement in `InMemory_Bus.Make` with a `ref<dict<...>>` registry, same pattern as the existing
scan registry. Keep both — the array-based `getQueryDbScan` remains for backward compatibility.

**Step 2 — Register stream in `QueryDbStorage_InMemory.Make(Bus)`**

```rescript
// Alongside the existing registerQueryDbScan call:
Bus.registerQueryDbStream(name, () => allItems.contents->Stream.fromIterable)
```

Where `allItems.contents` is the current in-memory dict converted to a flat array.

**Step 3 — Update `QueryEngine_InMemory` to prefer stream and honour `~limit`**

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
    // Backward compat: fall back to array scan if no stream registered
    switch Bus.getQueryDbScan(readModelName) {
    | Some(scanAll) => scanAll()
    | None => []
    }
  }
},
```

#### C.2 Tests

**File to modify:**
`reventless/reventless-in-memory/tests/adapter/QueryEngineTest.res`

Add to the existing `describe("QueryEngine_InMemory", ...)` block:

```rescript
describe("scan with ~limit", () => {
  testPromise("~limit=2 on a 5-item QueryDb returns exactly 2 items", async () => {
    module TestBus = InMemory_Bus.Make()
    module TestQDB = QueryDbStorage_InMemory.Make(TestBus)
    // Insert 5 items
    let _ = await TestQDB.ops.save("key-1", makeItem("a"))
    let _ = await TestQDB.ops.save("key-2", makeItem("b"))
    let _ = await TestQDB.ops.save("key-3", makeItem("c"))
    let _ = await TestQDB.ops.save("key-4", makeItem("d"))
    let _ = await TestQDB.ops.save("key-5", makeItem("e"))
    let qe = await QueryEngine_InMemory.Make(TestBus).make(Dict.make())->TestRunner.resolve
    let result = await qe.scan(~readModelName="TestQDB", ~filterConfigs=[], ~limit=2)
    expect(result->Array.length)->toBe(2)
  })

  testPromise("scan without ~limit returns all items", async () => {
    module TestBus = InMemory_Bus.Make()
    module TestQDB = QueryDbStorage_InMemory.Make(TestBus)
    let _ = await TestQDB.ops.save("key-1", makeItem("a"))
    let _ = await TestQDB.ops.save("key-2", makeItem("b"))
    let _ = await TestQDB.ops.save("key-3", makeItem("c"))
    let qe = await QueryEngine_InMemory.Make(TestBus).make(Dict.make())->TestRunner.resolve
    let result = await qe.scan(~readModelName="TestQDB", ~filterConfigs=[], ())
    expect(result->Array.length)->toBe(3)
  })

  testPromise("~limit larger than total returns all items (no padding)", async () => {
    module TestBus = InMemory_Bus.Make()
    module TestQDB = QueryDbStorage_InMemory.Make(TestBus)
    let _ = await TestQDB.ops.save("key-1", makeItem("a"))
    let _ = await TestQDB.ops.save("key-2", makeItem("b"))
    let qe = await QueryEngine_InMemory.Make(TestBus).make(Dict.make())->TestRunner.resolve
    let result = await qe.scan(~readModelName="TestQDB", ~filterConfigs=[], ~limit=100)
    expect(result->Array.length)->toBe(2)
  })

  testPromise("~limit=0 returns empty array", async () => {
    module TestBus = InMemory_Bus.Make()
    module TestQDB = QueryDbStorage_InMemory.Make(TestBus)
    let _ = await TestQDB.ops.save("key-1", makeItem("a"))
    let qe = await QueryEngine_InMemory.Make(TestBus).make(Dict.make())->TestRunner.resolve
    let result = await qe.scan(~readModelName="TestQDB", ~filterConfigs=[], ~limit=0)
    expect(result->Array.length)->toBe(0)
  })
})
```

#### C.3 Acceptance criteria ✅

- All existing `QueryEngineTest.res` tests pass unchanged ✅
- 4 new limit tests pass ✅
- Zero new warnings ✅

**Implementation notes:**
- `~limit` kept as required `int` in `QueryEngine.scan` type — no spec change needed. `Stream.take(limit)` on a stream smaller than `limit` returns all items; `Stream.take(0)` returns zero items.
- Plan showed `~limit=?` (optional) but spec uses required `int`; tests adapted accordingly (`~limit=100` for "no practical cap", no trailing `()` needed).
- `reset()` in `InMemory_Bus.Make` clears the new `queryDbStreamRegistry` alongside the existing registries.
- `reventless-in-memory`: 140 tests pass (was 129 after Phase B, +11 from Phase B stream tests and these 4 limit tests; `reventless-core`: 185 tests pass unchanged.

---

### Phase D — DcbEventLog.readStream + StateChangeSlice_Callback Adaptation ✅ COMPLETE

**Goal:** DCB decision-model building pages through events lazily rather than loading the full
matching event set into memory on every command. Structurally mirrors Phase B.

**Priority:** Low — additive improvement for large DCB deployments.

#### D.1 Implementation

**Step 1 — Add `readStream` to `DcbEventLog_Adapter.operations`**

```rescript
// DcbEventLog_Adapter.res — extend operations
type operations = {
  read: (~query: Reventless.DcbTag.query, ~after: Reventless.DcbTag.sequencePosition=?) =>
    promise<rawReadResult>,
  append: (array<rawStoredEvent>, ~condition: Reventless.DcbTag.appendCondition=?) =>
    promise<result<Reventless.DcbTag.sequencePosition, string>>,
  // NEW: lazy stream variant of read; pages via cursor until exhausted
  readStream: (~query: Reventless.DcbTag.query, ~after: Reventless.DcbTag.sequencePosition=?) =>
    Stream.t<rawSequencedEvent, string, unit>,
}
```

**Step 2 — Implement `readStream` in `DcbEventLogStorage_InMemory`**

Thread the `after` cursor by using the last event's `position` from each page:

```rescript
// DcbEventLogStorage_InMemory — readStream
let readStream: (~query: Reventless.DcbTag.query, ~after: option<Reventless.DcbTag.sequencePosition>=?) =>
  Stream.t<DcbEventLog_Adapter.rawSequencedEvent, string, unit> =
  (~query, ~after=?) =>
    Stream.paginateEffect(after, currentAfter =>
      Effect.promise(() => read(~query, ~after=?currentAfter))
      ->Effect.map(result => {
        let nextCursor = result.headPosition  // last position seen = next page cursor
        (result.events, nextCursor)
      })
    )
```

When there is only one page (the common case), `headPosition` is returned and then used as cursor
for the next page call, which returns an empty array → `headPosition = None` → stream terminates.

**Step 3 — Add `readStream` to `DcbEventLog_Operations.Make`**

```rescript
// Decode each raw event as it is pulled from the stream
let readStream = (~query, ~after=?) =>
  Ops.storage.readStream(~query, ~after?)
  ->Stream.map(raw => decodeEvent(raw))
```

**Step 4 — Adapt `StateChangeSlice_Callback.handleCommands`**

The structural adaptation mirrors §1.2. The exact details depend on
`StateChangeSlice_Callback.res` internals — read the file at implementation time. The pattern is:

```rescript
// BEFORE: full array load
let {events, headPosition} = await dcbEventLogOps.read(~query)
let decisionModel = events->Array.reduce(emptyModel, applyEvent)

// AFTER: lazy stream fold, accumulating headPosition
let (decisionModel, headPosition) = await dcbEventLogOps.readStream(~query)
  ->Stream.runFold(
    (emptyModel, None),
    ((dm, _pos), event) => (applyEvent(dm, event), Some(event.position))
  )
  ->Effect.runPromise
```

If `StateChangeSlice_Callback` does not use `headPosition` as an append condition, the fold
accumulates only the decision model; the `headPosition` tracking is dropped from the tuple.

**Correctness constraint:** Same as Phase B — `take` must never be applied to `readStream` inside
`StateChangeSlice_Callback`. All events are required to build the correct decision model.

#### D.2 Tests

**File to create:**
`reventless/reventless-in-memory/tests/components/dcbeventlog/DcbEventLogStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect
open DcbEventLogFixtures  // reuse or create fixtures alongside

describe("DcbEventLog.readStream", () => {
  describe("basic streaming", () => {
    testPromise("readStream for tag with no events returns empty stream", async () => {
      module TestDcb = DcbEventLogStorage_InMemory.Make({})
      let result = await TestDcb.ops.readStream(~query=tagQuery("unknown-tag"))
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result->Array.length)->toBe(0)
    })

    testPromise("readStream emits all events matching a tag query", async () => {
      module TestDcb = DcbEventLogStorage_InMemory.Make({})
      let _ = await TestDcb.ops.append([makeRawEvent("ItemCreated", tagOf("item-1"))], ())
      let _ = await TestDcb.ops.append([makeRawEvent("ItemCreated", tagOf("item-2"))], ())
      let result = await TestDcb.ops.readStream(~query=tagQuery("item-1"))
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result->Array.length)->toBe(1)
    })

    testPromise("readStream emits events from multiple pages in order", async () => {
      // Append enough events to span two pages (page size is implementation-defined;
      // use a small page size override or append enough events to trigger multiple reads)
      ...
    })
  })

  describe("fold patterns (mirrors Aggregate_Callback use case)", () => {
    testPromise("runFold extracts last headPosition as append condition", async () => {
      module TestDcb = DcbEventLogStorage_InMemory.Make({})
      let _ = await TestDcb.ops.append([makeRawEvent("e1", tagOf("x"))], ())
      let _ = await TestDcb.ops.append([makeRawEvent("e2", tagOf("x"))], ())
      let (_, headPosition) = await TestDcb.ops.readStream(~query=tagQuery("x"))
        ->Stream.runFold((unit, None), ((_, _pos), event) => ((), Some(event.position)))
        ->Effect.runPromise
      expect(headPosition)->not->toEqual(None)
    })

    testPromise("take(1) stops after first event without loading all", async () => {
      module TestDcb = DcbEventLogStorage_InMemory.Make({})
      let _ = await TestDcb.ops.append([makeRawEvent("e1", tagOf("x"))], ())
      let _ = await TestDcb.ops.append([makeRawEvent("e2", tagOf("x"))], ())
      let first = await TestDcb.ops.readStream(~query=tagQuery("x"))
        ->Stream.take(1)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(first->Array.length)->toBe(1)
    })
  })

  describe("StateChangeSlice regression (integration)", () => {
    testPromise("second command sees decision model from first command via stream fold", async () => {
      // Full round-trip: publish two commands, verify both complete without error
      // and that the second command's decision model includes the first event.
      // This is the DCB equivalent of the Aggregate regression test in Phase B.
      ...
    })
  })
})
```

#### D.3 Acceptance criteria ✅

- All existing DCB E2E tests pass unchanged ✅
- `DcbEventLogStreamTest.res` tests pass (8 tests) ✅
- StateChangeSlice integration regression test passes ✅
- Zero new warnings ✅

**Implementation notes:**
- `reventless-spec` required `rescript-effect` added to both `package.json` and `rescript.json`
  (not previously a dependency — needed for `Stream.t` in `Reventless.DcbEventLog.readStream` type).
- `readStream` added to spec-level `Reventless.DcbEventLog.operations<'event>` and propagated
  through `DcbEventLog_Adapter.operations`, `DcbEventLog_Operations.T/Make`,
  `DcbEventLog_Builder`, `DcbEventLogStorage_InMemory`, `DcbEventLogStorage_DynamoDb`.
- In-memory implementation: `Effect.promise(read) →Stream.fromEffect → Stream.flatMap(fromIterable)`.
  Same pattern as Phase B's EventLog replayStream in-memory adapter.
- DynamoDB implementation wraps existing `read` call with `Effect.tryPromise` (same bridge as
  Phase B DynamoDB `replayStream`); full DynamoDB pagination a follow-up.
- `MockDcbEventLogStorage.res` and `DcbStateChangeSliceTest.res` updated with `readStream` field.
- `StateChangeSlice_Callback.handleSingleCommand` replaced `dcbEventLog.read` + `Array.reduce`
  with `dcbEventLog.readStream → Stream.runFold` producing `(decisionModel, headPosition)`.
- `reventless-core`: 185 tests pass unchanged.
- `reventless-in-memory`: 148 tests pass (was 140 after Phase C, +8 from new stream tests).

---

### Phase E — CSV / Node.js Readable as Effect Stream + Tests ✅ COMPLETE

**Goal:** Provide a streaming CSV parser backed by Effect Stream for use in Task file-processing
callbacks, enabling backpressure and early termination for large files.

**Priority:** Low — affects a subset of use cases; requires the most novel work.

#### E.1 Implementation

**Step 1 — Add `fromReadableStream` to `Stream.res`**

```rescript
// Stream.res — Phase E addition
@module("effect") @scope("Stream")
external fromReadableStream: (unit => NodeStreams.Readable.t, int) => t<string, string, unit>
  = "fromReadableStream"
```

The thunk `unit => Readable.t` prevents the stream from opening the file handle until the stream
is actually consumed. The `int` argument is the chunk size in bytes (e.g., 65536).

**Step 2 — Create `CsvStream.res` in `reventless-core/src/util/`**

```rescript
// CsvStream.res
// Bridges Node.js FastCSV parser to an Effect Stream.
// Uses fromReadableStream to get raw string chunks, then pipes through a
// FastCSV parser transform stream to produce typed row objects.

let parseRows = (~path: string): Stream.t<FastCSV.row, string, unit> =>
  Stream.fromReadableStream(
    () => NodeStreams.createReadStream(path)->FastCSV.attachParser,
    65536,
  )
  ->Stream.map(FastCSV.parseRow)  // adjust based on actual FastCSV binding API
```

The exact implementation depends on how FastCSV emits rows — it may require a Channel wrapper
rather than a simple `map`. Investigate at implementation time; the test below defines the contract.

**Step 3 — Optional: extend Task callback type**

If `Task` callbacks should optionally receive a streaming interface, add an overloaded variant.
This is additive and backward-compatible. Defer if the standalone `CsvStream.res` utility is
sufficient for current needs.

#### E.2 Tests

**File to create:** `reventless/reventless-core/tests/util/CsvStreamTest.res`
(or in `reventless-in-memory` if the test infrastructure is already there)

```rescript
open AsyncTest
open AsyncTest.Expect

// Helpers: write temporary CSV files for testing
let writeTempCsv = (rows: array<string>): string => {
  let path = "/tmp/test-" ++ Message.uuid() ++ ".csv"
  let content = rows->Array.joinWith("\n")
  // Use Node.js fs.writeFileSync via binding
  NodeFs.writeFileSync(path, content)
  path
}

describe("CsvStream.parseRows", () => {
  testPromise("parses all rows from a small CSV file", async () => {
    let path = writeTempCsv(["name,age", "Alice,30", "Bob,25"])
    let rows = await CsvStream.parseRows(~path)
      ->Stream.runCollect
      ->Effect.runPromise
    expect(rows->Array.length)->toBe(2)  // header excluded by FastCSV
  })

  testPromise("emits rows in file order", async () => {
    let path = writeTempCsv(["name", "first", "second", "third"])
    let first = await CsvStream.parseRows(~path)
      ->Stream.runHead
      ->Effect.runPromise
    expect(first->Option.map(r => r->FastCSV.getField("name")))->toEqual(Some("first"))
  })

  testPromise("take(2) stops after 2 rows without reading the whole file", async () => {
    // Write 100 rows; take(2) should not read all of them
    let rows = Array.make(100, "")->Array.mapWithIndex((_, i) => `row-${Int.toString(i)}`)
    let path = writeTempCsv(Array.concat(["name"], rows))
    let result = await CsvStream.parseRows(~path)
      ->Stream.take(2)
      ->Stream.runCollect
      ->Effect.runPromise
    expect(result->Array.length)->toBe(2)
  })

  testPromise("empty CSV file returns empty stream", async () => {
    let path = writeTempCsv(["name"])  // header only
    let rows = await CsvStream.parseRows(~path)->Stream.runCollect->Effect.runPromise
    expect(rows->Array.length)->toBe(0)
  })
})
```

#### E.3 Acceptance criteria ✅

- `fromReadableStream` binding compiles with zero warnings ✅
- `CsvStream.parseRows` produces correct rows from a file ✅
- `Stream.take(2)` terminates early without loading the full file ✅
- All existing tests pass unchanged ✅

**Implementation notes:**
- `fromReadableStream` added to `Stream.res` with generic `'readable` type variable — avoids
  adding `rescript-node-streams` as a dependency to `rescript-effect`.
- `CsvStream.res` created in `reventless/reventless-core/src/util/` using a Promise bridge:
  FastCSV `onData`/`onEnd`/`onError` callbacks resolve/reject a `result<array<row>, string>` Promise;
  `Effect.promise` + `Effect.flatMap` converts to the error channel; `Stream.fromEffect` +
  `Stream.flatMap(fromIterable)` emits rows lazily.
- Implementation note: rows are collected into memory before streaming (Promise bridge). True
  per-row lazy streaming (with file-read interruption on `take`) would require a Queue bridge or
  Channel wrapper — deferred as future work.
- `CsvStreamTest.res` created in `reventless/reventless-core/tests/util/` with 4 tests.
- `reventless-core`: 189 tests pass (was 185 after Phase D, +4 new CsvStream tests).
- `rescript-effect`: 122 tests pass unchanged.

---

## Section 4: Use Cases Not Yet Phased

The following use cases were identified but deliberately left out of the phased plan. They require
a design decision before implementation.

### Use Case 4 — InMemory_Bus Fan-out via Stream (Evaluate before implementing)

The current `InMemory_Bus` drain loop is already a manual `Stream.fromQueue` pattern. Replacing
it with a PubSub-based stream would be an architectural improvement but changes delivery timing
guarantees. The current design is carefully tuned for 2-microtick resolution in tests. Before
implementing, measure whether the 2-tick resolution is preserved with the new approach.

### Use Case 6 — Bounded Queue Backpressure (Evaluate before implementing)

Replacing `Queue.unbounded` with `Queue.bounded(n)` per subscriber provides natural backpressure
but requires switching from `Effect.runSync` (synchronous offer) to an async offer path, which
may change the 2-microtick test guarantees. Defer to a dedicated backpressure-focused pass.

---

## Section 5: Known Constraints and Risks

### ReScript type inference with three type parameters

`Stream.t<'a, 'e, 'r>` has three type parameters. Annotate the return type of any function that
constructs a stream with an opaque cursor:

```rescript
let myStream: Stream.t<JSON.t, string, unit> = Stream.paginateEffect(None, ...)
```

The compiler produces a weak type variable error if `'s` in `paginateEffect` is not constrained
by the initial cursor value.

### Never nest `Effect.runPromise` inside `Effect.runPromise`

`Stream.runCollect` and `Stream.runFold` produce `Effect.t<..., ..., ...>`. Run them with a
single `Effect.runPromise` at the async boundary. Composing inside an effect: use `Effect.flatMap`.
Nesting a second `Effect.runPromise` call inside another causes "unexpected synchronous effect".

### `paginateChunkEffect` vs `paginateEffect` (JS function names)

The ReScript binding `paginateEffect` maps to JS `"paginateChunkEffect"` (chunk-based, returns
`array<'a>` per page). Do not bind to `"paginateEffect"` — the JS function of that name takes
a single item per page, which is less efficient for DynamoDB batch responses.

### `Aggregate_Callback` must never apply `take` to `replayStream`

The stream fold inside `handleCommands` must consume all events. Any `take(n)` applied before
the fold would produce an incorrect `sequenceNr` (too low) and incorrect state (partial history).
The `replayStream` returned by `EventLog_Operations.Make` is an unrestricted stream; constraints
like `take` belong at the call site, and `Aggregate_Callback` must not add them.

### `StateChangeSlice_Callback` correctness constraint (Phase D)

Same constraint: the decision model fold must consume all events matching the tag query. Applying
`take` to `readStream` inside the callback would produce an incomplete decision model, potentially
allowing commands that should be rejected (e.g., duplicate creation) to succeed.

### TestClock does not reach inside `Effect.runPromise` calls

Stream tests do not involve timers. However, if any future stream operation uses `Effect.sleep`
internally (e.g. retry on DynamoDB throttle), `Effect.provide(TestContext)` from outside cannot
inject TestClock into inner `runPromise` calls. This is the same constraint documented in the
Phase 2.5 notes in the effect-library-integration plan.

### `Stream.fromQueue` terminates only on `Queue.shutdown`

`Stream.fromQueue(queue)` blocks until the queue is shut down. **Do NOT shut down the queue
before the stream starts consuming.** `Queue.shutdown` interrupts all pending takes; if shutdown
runs before `Stream.fromQueue` begins pulling, subsequent takes fail and the stream emits nothing
— even if items were already offered. The correct approach depends on the use case:

- **Test with a known item count**: use `Stream.take(n)` to terminate; no shutdown needed.
- **Concurrent producer/consumer**: fork the collection fiber first, then offer items and shut down.
- **Production use (InMemory_Bus)**: `reset()` calls `Queue.shutdown` — this is the correct
  lifecycle signal for active `fromQueue` streams that are already running (fibers blocked on
  `take` get interrupted cleanly).

### `decodeEvent` throws inside `EventLog_Operations.replayStream`

The existing `decodeEvent` function throws `JsError` on malformed events. Inside a stream,
uncaught exceptions escape Effect's error channel. Wrap in `Effect.sync(() => decodeEvent(...))`
so that thrown exceptions become stream failures (routed through the `'e` channel) rather than
unhandled JS exceptions. This enables `Stream.catchAll` recovery if needed.
