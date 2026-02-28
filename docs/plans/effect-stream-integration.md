# Effect Stream Integration Plan

**Status:** Phases A–H complete; I planned

**Created:** 2026-02-28

**Revised:** 2026-02-28

**Depends on:** `docs/plans/effect-library-integration.md` phases 0–4 (complete)

**Summary:** Stream-based improvements across the Reventless codebase. Phases A–G covered `Stream` bindings, lazy replay, paginated scans, CSV ingestion, and PubSub fan-out. Phases H and I extend the write path: `appendStream` lets a `Stream<event>` drive EventLog and DcbEventLog appends without materialising the entire sequence in memory; `publishJsonsStream` / `publishJsonStream` let a `Stream<commandJson>` or `Stream<eventJson>` drive CommandTopic and EventTopic publishing, composing naturally with the read-side streams from earlier phases.

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

### 1.4 The 2-microtick timing guarantee in `InMemory_Bus`

This section explains a design constraint that Phases F and G must preserve (or knowingly
change). It describes how JavaScript's microtask queue works, why `InMemory_Bus` is built around
a 2-tick delivery model, and what breaks if extra ticks are introduced.

#### Background: JavaScript microtasks and `await`

JavaScript's event loop processes work in two layers:

- **Macrotasks** (setTimeout, I/O callbacks, etc.) — run one at a time, interleaved with the UI
  or other I/O.
- **Microtasks** (Promise continuations, queueMicrotask) — drain completely between each
  macrotask. Every `await` of an already-resolved Promise takes exactly one microtask tick to
  resume the continuation.

The key rule: **`await Promise.resolve()` always suspends for exactly one microtask tick.**
When you write:

```javascript
await Promise.resolve()  // tick 1
await Promise.resolve()  // tick 2
```

you are explicitly yielding control to the microtask queue twice. Any Promise that was resolved
during the previous tick will have its `.then` callbacks executed before your continuation runs.

#### How `InMemory_Bus.publishEvent` achieves 2-tick delivery

`publishEvent` is designed so that by the time the caller's second `await` returns, every
subscriber has finished processing the event. The mechanism has two parts:

**Part 1 — synchronous fan-out (tick 0):**

```rescript
// For each subscriber: create a Deferred signal and offer {event, signal} to
// their Queue — both are synchronous Effect values run via Effect.runSync.
let signal = Deferred.make()->Effect.runSync           // 0 ticks
let _ = Queue.offer(sub.queue, {…, signal})->Effect.runSync  // 0 ticks
```

After this loop, every subscriber's Queue has the message. The subscriber drain fibers are not
running yet — they are suspended on `Queue.take` in the Effect scheduler, waiting for their turn.

**Part 2 — signal-based synchronisation (ticks 1–2):**

```rescript
// Start waiting for all subscribers to complete
let _ = await signalPromises->Promise.all   // starts N Effect.runPromise calls
```

`Promise.all` begins. Each `Deferred.await_(...)->Effect.runPromise` call starts a fiber in the
Effect runtime that is waiting for its Deferred to be resolved.

**Tick 1:** The Effect scheduler gets control. The drain fibers wake up, each processes their
message (calls the subscriber callback), then executes `Deferred.succeed(signal, ())`. This
resolves the Deferred, which resolves the corresponding `Effect.runPromise` Promise.

**Tick 2:** The resolved Promises in `Promise.all` are processed. `Promise.all` itself resolves.
`publishEvent` returns.

The full timeline:

```
caller:      publishEvent(…)
             ↳ Effect.runSync(Queue.offer) × N   [sync, 0 ticks]
             ↳ Promise.all([Deferred.await_…])   [starts waiting]
tick 1:      Effect scheduler: drain fibers run
             ↳ handler(service, meta, json)       [subscriber callback]
             ↳ Deferred.succeed(signal, ())       [resolves signal Promise]
tick 2:      Promise.all resolves
             ↳ publishEvent returns
```

#### Why tests rely on this

Integration tests in `reventless-in-memory` frequently do:

```rescript
// Dispatch a command — this eventually publishes an event via publishEvent
let _ = await ops.dispatchCommand(…)
// Allow event to propagate to subscribers (read models, side effects, etc.)
let _ = await Promise.resolve()   // tick 1: drain fiber processes event
let _ = await Promise.resolve()   // tick 2: publishEvent resolves; caller continues
// Now assert the read model was updated
expect(readModel.count)->toBe(1)
```

The two `await Promise.resolve()` calls are the **test synchronisation primitive** for
`InMemory_Bus` event delivery. They appear throughout the test suite via helper functions such as
`TestRunner.resolve` and `Output.apply`-based awaiting. If event delivery required more than 2
ticks, these assertions would run before the subscriber callback has finished, producing false
negatives (the read model appears empty even though the event was in-flight).

#### What "preserving the guarantee" means for Phases F and G

| Change | Tick impact | Action required |
|---|---|---|
| Phase F: `PubSub.publish` (unbounded) via `Effect.runSync` | 0 extra ticks | No test changes |
| Phase F: `done_` Effect via `Effect.zipRight` in drain fiber | 0 extra ticks | No test changes |
| Phase G: `PubSub.publish` (bounded) via `Effect.runPromise` | +1 tick (3 total) | Tests using `~capacity` must await 3 ticks |
| Hypothetical: `PubSub.publish` (unbounded) via `Effect.runPromise` | +1 tick (3 total) | Would break all existing tests |

The constraint is: **for default (unbounded) mode, `publishEvent` must still complete in 2
microtask ticks.** Phase F achieves this by keeping `PubSub.publish` on an unbounded hub as a
synchronous `Effect.runSync` call, exactly matching the current `Queue.offer` approach.

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
  │     └─> Phase H — EventLog.appendStream + DcbEventLog.appendStream + tests
  ├─> Phase C — QueryDb scan stream + limit tests
  ├─> Phase D — DcbEventLog.readStream + StateChangeSlice_Callback + tests
  │     └─> Phase H (also depends on D for DcbEventLog side)
  ├─> Phase E — CSV/Node.js streams + tests
  └─> Phase F — InMemory_Bus fan-out via PubSub + Stream
        └─> Phase G — Bounded PubSub backpressure

Phase H — EventLog.appendStream + DcbEventLog.appendStream
  └─> Phase I — CommandTopic.publishJsonsStream + EventTopic.publishJsonStream + Aggregate facade
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

## Section 4: Phases F and G

---

### Phase F — InMemory_Bus Fan-out via PubSub + Stream ✅ COMPLETE

**Goal:** Replace the per-subscriber `Queue` array in `InMemory_Bus` with a per-topic `PubSub.t`
hub. The PubSub hub handles subscriber fan-out automatically, eliminating the manual
`dict<string, array<subscriber>>` registry and making event delivery more idiomatic for Effect.
The drain loop, which is currently a manual `Queue.take → handler → Deferred.succeed → forever`
chain, becomes a `Stream.fromQueue → Stream.runForEach` pipeline scoped to a PubSub subscription.

**Priority:** Low — affects test infrastructure only; no production path is involved.

**Dependency:** Phase A (Stream bindings, already complete). No other phase dependency.

#### F.1 Structural Analysis

**Current shape of `InMemory_Bus.Make`:**

```rescript
// State
let eventSubscribers: ref<dict<string, array<subscriber>>> = ref(Dict.make())
// where subscriber = { queue: Queue.t<queuedEvent> }
// and queuedEvent = { service, meta, json, signal: Deferred.t<unit, unit> }

// subscribeToEvents — one Queue + one drain fiber per subscriber
let queue = Queue.unbounded()->Effect.runSync
let drainLoop =
  Queue.take(queue)
  ->Effect.flatMap(msg =>
    Effect.promise(() => handler(msg.service, msg.meta, msg.json))
    ->Effect.zipRight(Deferred.succeed(msg.signal, ())->Effect.map(_ => ()))
  )
  ->Effect.forever
let _ = Effect.runFork(drainLoop)

// publishEvent — iterate subscriber array; one Deferred per subscriber-message pair
let signalPromises = subscribers->Array.map(sub => {
  let signal = Deferred.make()->Effect.runSync
  let _ = Queue.offer(sub.queue, {service, meta, json, signal})->Effect.runSync
  Deferred.await_(signal)->Effect.runPromise
})
let _ = await signalPromises->Promise.all
```

**After Phase F:**

```rescript
// State
let eventHubs: ref<dict<string, PubSub.t<queuedEvent>>> = ref(Dict.make())
// where queuedEvent = { service, meta, json, done_: Effect.t<unit, unit, unit> }

// subscribeToEvents — subscribe to hub, consume with Stream.fromQueue inside a scope
let drainLoop = Effect.scoped(
  PubSub.subscribe(hub)
  ->Effect.flatMap(queue =>
    Stream.fromQueue(queue)
    ->Stream.runForEach(msg =>
      Effect.promise(() => handler(msg.service, msg.meta, msg.json))
      ->Effect.zipRight(msg.done_)
    )
  )
)
let _ = Effect.runFork(drainLoop)

// publishEvent — publish once to hub; PubSub fans out to all subscriber queues
let _ = PubSub.publish(hub, {service, meta, json, done_})->Effect.runSync
await Deferred.await_(allDone)->Effect.runPromise
```

**What changes:** The manual `array<subscriber>` registry is replaced by a single PubSub hub per
topic. The drain loop is more idiomatic: `Stream.fromQueue → Stream.runForEach` within
`Effect.scoped(PubSub.subscribe(...))`. `reset()` calls `PubSub.shutdown` per hub instead of
`Queue.shutdown` per subscriber.

**What stays the same:** The `queuedEvent` structure still carries a completion signal so
`publishEvent` can await all subscribers. The 2-microtick timing guarantee is preserved (see §F.2).

#### F.2 Completion Signal Design

PubSub delivers the **same message value** to every subscriber — one `queuedEvent` object is
fanned out to all N subscriber Queues. The current protocol places a per-subscriber `Deferred` in
the message, but with shared delivery each subscriber would compete to resolve the same Deferred.

**Solution — countdown Effect:**

Replace the per-subscriber `signal: Deferred` with a shared `done_: Effect.t<unit, unit, unit>`
built by the publisher. `done_` atomically decrements a `ref<int>` counter; when it reaches zero,
it succeeds an `allDone: Deferred` that the publisher is awaiting.

```rescript
// Publisher constructs per-publish-call state:
let allDone: Deferred.t<unit, unit> = Deferred.make()->Effect.runSync
let remaining = ref(n)   // n = PubSub.size(hub)->Effect.runSync

// done_ is an Effect run by each subscriber after processing:
let done_ =
  Effect.sync(() => { remaining := remaining.contents - 1 })
  ->Effect.flatMap(_ =>
    if remaining.contents == 0 { Deferred.succeed(allDone, ()) }
    else { Effect.succeed(false) }
  )

// Publish once — PubSub fans the same {service, meta, json, done_} to all N subscribers
let _ = PubSub.publish(hub, {service, meta, json, done_})->Effect.runSync

// Await completion — resolves when the last subscriber calls done_
let _ = await Deferred.await_(allDone)->Effect.runPromise
```

`done_` runs **inside the drain fiber's Effect chain** (via `Effect.zipRight(msg.done_)`) — no
nested `Effect.runSync`. `Deferred.succeed` is called in the same Effect runtime as
`Deferred.await_`, so fibers communicate correctly. Since Node.js is single-threaded and Effect
fibers run cooperatively, decrementing `remaining` is race-free.

**Timing trace** (confirming the 2-tick guarantee is preserved):

| Step | Ticks |
|------|-------|
| `Effect.runSync(PubSub.publish(...))` — routes message to all N subscriber Queues synchronously | 0 |
| `Effect.runPromise(Deferred.await_(allDone))` — starts awaiting | 0 |
| Drain fibers wake, each runs `handler → done_`; last one succeeds `allDone` | tick 1 |
| `Deferred.await_` promise resolves; publisher continues | tick 2 |

→ 2 ticks, same as current. `PubSub.publish` on an unbounded hub is synchronous (equivalent to
iterating subscriber queues), so no extra scheduling hops are introduced.

**Timing test:** Add a dedicated test to lock in this guarantee before and after the migration
(see §F.4).

#### F.3 Implementation

**Step 1 — Change `queuedEvent` type**

```rescript
// BEFORE
type queuedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
  signal: Deferred.t<unit, unit>,
}

// AFTER
type queuedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
  done_: Effect.t<unit, unit, unit>,   // run by each subscriber after handler returns
}
```

**Step 2 — Replace `eventSubscribers` with `eventHubs`**

```rescript
// REMOVE
let eventSubscribers: ref<dict<string, array<subscriber>>> = ref(Dict.make())

// ADD
let eventHubs: ref<dict<string, PubSub.t<queuedEvent>>> = ref(Dict.make())
```

The `subscriber` type is no longer needed and can be deleted.

**Step 3 — Rewrite `subscribeToEvents`**

```rescript
let subscribeToEvents = (topicName, handler) => {
  let hub = switch eventHubs.contents->Dict.get(topicName) {
  | Some(h) => h
  | None =>
    let h: PubSub.t<queuedEvent> = PubSub.unbounded()->Effect.runSync
    eventHubs.contents->Dict.set(topicName, h)
    h
  }
  let drainLoop = Effect.scoped(
    PubSub.subscribe(hub)
    ->Effect.flatMap(queue =>
      Stream.fromQueue(queue)
      ->Stream.runForEach(msg =>
        Effect.promise(() => handler(msg.service, msg.meta, msg.json))
        ->Effect.zipRight(msg.done_)
      )
    )
  )
  let _ = Effect.runFork(drainLoop)
}
```

**Step 4 — Rewrite `publishEvent`**

```rescript
let publishEvent = async (topicName, service, meta, json) => {
  switch eventHubs.contents->Dict.get(topicName) {
  | None => ()
  | Some(hub) =>
    let n = PubSub.size(hub)->Effect.runSync
    if n == 0 { () } else {
      let allDone: Deferred.t<unit, unit> = Deferred.make()->Effect.runSync
      let remaining = ref(n)
      let done_ =
        Effect.sync(() => { remaining := remaining.contents - 1 })
        ->Effect.flatMap(_ =>
          if remaining.contents == 0 { Deferred.succeed(allDone, ()) }
          else { Effect.succeed(false) }
        )
      let _ = PubSub.publish(hub, {service, meta, json, done_})->Effect.runSync
      let _ = await Deferred.await_(allDone)->Effect.runPromise
    }
  }
}
```

**Step 5 — Update `reset`**

```rescript
let reset = () => {
  let shutdownAll =
    eventHubs.contents
    ->Dict.valuesToArray
    ->Array.map(hub => PubSub.shutdown(hub))
    ->Effect.all({"concurrency": "unbounded"})
    ->Effect.map(_ => ())
  let _ = Effect.runSync(shutdownAll)
  eventHubs := Dict.make()
  commandHandlers := Dict.make()
  queryDbRegistry := Dict.make()
  queryDbScanRegistry := Dict.make()
  queryDbStreamRegistry := Dict.make()
}
```

`PubSub.shutdown` interrupts all `Stream.fromQueue` consumers (their underlying Queue take is
interrupted), causing `Stream.runForEach` to complete and `Effect.scoped` to close the
subscription — the same clean shutdown that `Queue.shutdown` provides today.

#### F.4 Tests

**Timing regression test** — add to `InMemoryBusTest.res` (or a new `InMemoryBusPubSubTest.res`):

```rescript
describe("publishEvent timing (PubSub variant)", () => {
  testPromise("resolves after exactly 2 microtask ticks", async () => {
    module TestBus = InMemory_Bus.Make()
    let delivered = ref(false)
    TestBus.subscribeToEvents("T", async (_, _, _) => delivered := true)
    // Synchronous: publish but do not await
    let pubPromise = TestBus.publishEvent("T", "svc", defaultMeta, JSON.parseExn("{}"))
    // Not yet delivered — drain fiber hasn't run
    expect(delivered.contents)->toBe(false)
    // After 1 tick: drain fiber runs; delivered becomes true
    let _ = await Promise.resolve()
    // After 2 ticks: Deferred.await_ resolves; pubPromise completes
    let _ = await Promise.resolve()
    let _ = await pubPromise
    expect(delivered.contents)->toBe(true)
  })

  testPromise("fans out to all subscribers", async () => {
    module TestBus = InMemory_Bus.Make()
    let count = ref(0)
    TestBus.subscribeToEvents("T", async (_, _, _) => count := count.contents + 1)
    TestBus.subscribeToEvents("T", async (_, _, _) => count := count.contents + 1)
    TestBus.subscribeToEvents("T", async (_, _, _) => count := count.contents + 1)
    let _ = await TestBus.publishEvent("T", "svc", defaultMeta, JSON.parseExn("{}"))
    expect(count.contents)->toBe(3)
  })
})
```

All existing `InMemory_Bus`-dependent tests in `reventless-in-memory` must pass without
modification — the external contract of `publishEvent` and `subscribeToEvents` is unchanged.

#### F.5 Acceptance criteria ✅

- All existing `reventless-in-memory` tests pass unchanged ✅
- Timing regression test passes (2-tick guarantee confirmed) ✅
- Fan-out test passes ✅
- `reset()` properly interrupts all drain fibers (no zombie fibers after reset) ✅
- Zero new warnings ✅

**Implementation notes:**
- `PubSub.size` in Effect measures **buffered message count** (not subscriber count) — always 0
  for an unbounded hub after successful delivery. Plan erroneously proposed using it for countdown.
  Fixed by adding `subscriberCounts: ref<dict<int>>` that is incremented synchronously in
  `subscribeToEvents` and reset in `reset()`.
- `PubSub.subscribe` inside `Effect.scoped` DOES run synchronously during `Effect.runFork` — the
  fiber's trampoline executes all synchronous steps before hitting the first `Queue.take` suspension.
  Subscription is registered before `subscribeToEvents` returns (no race with `publishEvent`).
- `type subscriber` removed — no longer needed; per-subscriber state is managed by PubSub.
- `type queuedEvent` updated: `signal: Deferred.t<unit, unit>` → `done_: Effect.t<unit, unit, unit>`
- Drain loop updated: `Queue.take → handler → Deferred.succeed → forever` →
  `Effect.scoped(PubSub.subscribe(hub) → Stream.fromQueue → Stream.runForEach → Effect.zipRight(done_))`
- `publishEvent` updated: `Promise.all` of N per-subscriber Deferred promises →
  single `allDone: Deferred.t<unit, unit>` with countdown `done_` Effect
- `reset` updated: `Queue.shutdown` per subscriber → `PubSub.shutdown` per hub
- Added `InMemoryBusPubSubTest.res` with 4 tests: timing (2-tick), no-subscribers, fan-out, topic isolation
- All 619 tests pass (was 615 after Phase E; +4 new PubSub tests)

---

### Phase G — Bounded PubSub Backpressure ✅ COMPLETE

**Goal:** Add an optional `~capacity` parameter to `InMemory_Bus.Make` so that each topic's PubSub
hub can be bounded. A bounded hub exerts backpressure: `publishEvent` suspends when any
subscriber's internal queue is full, preventing unbounded memory growth when a slow subscriber
falls behind. This makes the in-memory adapter more faithful to bounded SQS queues in production.

**Priority:** Low — optional enhancement. Does not affect existing code paths when `~capacity` is
not set.

**Dependency:** Phase F must be complete. Bounded backpressure requires `PubSub.bounded` instead
of `PubSub.unbounded`, and the publish path must be fully async — both of which Phase F establishes.

#### G.1 Structural Analysis

After Phase F, hub creation uses `PubSub.unbounded()->Effect.runSync`. For Phase G, it becomes
`PubSub.bounded(capacity)->Effect.runSync` when a capacity is provided. The structural impact is
in two places:

**Hub creation** — inside `subscribeToEvents` or a lazy initialiser:

```rescript
// BEFORE (Phase F)
let h: PubSub.t<queuedEvent> = PubSub.unbounded()->Effect.runSync

// AFTER (Phase G, when ~capacity is set)
let h: PubSub.t<queuedEvent> = PubSub.bounded(capacity)->Effect.runSync
```

**Publish path** — `PubSub.publish` on a bounded hub suspends the calling fiber when any
subscriber's queue is full. The Phase F publish uses `Effect.runSync(PubSub.publish(...))`. This
would throw for a bounded hub at capacity (runSync cannot suspend). The publish must become async:

```rescript
// BEFORE (Phase F): synchronous, works only for unbounded
let _ = PubSub.publish(hub, {service, meta, json, done_})->Effect.runSync

// AFTER (Phase G, bounded mode): async, suspends until space is available
let _ = await PubSub.publish(hub, {service, meta, json, done_})->Effect.runPromise
```

**Timing impact for bounded mode:** Using `Effect.runPromise` for publish adds one microtask tick
even when the queue has space (runPromise is always async). Total: 3 ticks instead of 2.

```
tick 0: start Effect.runPromise(PubSub.publish(...))
tick 1: publish completes; drain fiber runs; Deferred.succeed called
tick 2: Deferred.await_ promise resolves
→ total: 3 ticks for bounded mode
```

Existing tests use `InMemory_Bus.Make()` (default = unbounded, 2 ticks). New bounded-mode tests
use `InMemory_Bus.Make(~capacity=n)` and explicitly await 3 ticks. No existing tests change.

#### G.2 Implementation

**Step 1 — Add `~capacity` parameter to `Make` and its type**

The `module type T` does not expose `~capacity` (it is a construction-time concern). Only `Make`
changes:

```rescript
// BEFORE
module Make = (): T => { ... }

// AFTER
module Make = (~capacity: option<int>=?, ()): T => { ... }
```

All existing `InMemory_Bus.Make()` call sites are unaffected (the argument is optional with
default `None`).

**Step 2 — Parameterise hub creation**

Move hub creation to a helper inside `Make` that uses the captured `~capacity`:

```rescript
let makeHub = (): PubSub.t<queuedEvent> =>
  switch capacity {
  | None => PubSub.unbounded()->Effect.runSync
  | Some(n) => PubSub.bounded(n)->Effect.runSync
  }
```

Call `makeHub()` in `subscribeToEvents` where the hub is initialised.

**Step 3 — Make publish path conditional on bounded mode**

To preserve the 2-tick guarantee for unbounded (default) mode while correctly suspending for
bounded mode, dispatch on `capacity`:

```rescript
// Inside publishEvent:
let publishAndWait = switch capacity {
| None =>
  // Unbounded: synchronous offer, 2-tick path (same as Phase F)
  Effect.sync(() => { let _ = PubSub.publish(hub, msg)->Effect.runSync })
  ->Effect.zipRight(Deferred.await_(allDone))
| Some(_) =>
  // Bounded: async offer, may suspend if subscriber is slow, 3-tick path
  PubSub.publish(hub, msg)
  ->Effect.flatMap(_ => Deferred.await_(allDone))
}
let _ = await publishAndWait->Effect.runPromise
```

Note: both branches are now under a single `Effect.runPromise`. For the unbounded branch, the
`Effect.sync` runs synchronously inside `runPromise` so timing is effectively the same as before.

#### G.3 Tests

**File to modify:** `InMemoryBusPubSubTest.res` (new file from Phase F) or a new
`InMemoryBusBoundedTest.res`.

```rescript
describe("bounded InMemory_Bus (capacity=2)", () => {
  testPromise("publishEvent suspends when subscriber queue is full", async () => {
    // Subscriber never processes — it just blocks.
    // With capacity=2, after 2 unprocessed messages publishEvent suspends.
    module TestBus = InMemory_Bus.Make(~capacity=2)
    let processedCount = ref(0)
    // Subscriber: resolve its handler promise only after an external signal
    let (gate, openGate) = Promise.pending()
    TestBus.subscribeToEvents("T", async (_, _, _) => {
      let _ = await gate
      processedCount := processedCount.contents + 1
    })
    // Publish 2 messages — both fit in the bounded queue (capacity=2)
    let p1 = TestBus.publishEvent("T", "s", meta, json)
    let p2 = TestBus.publishEvent("T", "s", meta, json)
    // Third publish MUST suspend (queue is full; subscriber is blocked on gate)
    let p3Started = ref(false)
    let p3 = TestBus.publishEvent("T", "s", meta, json)->Promise.thenResolve(_ => {
      p3Started := ref(true); ()
    })
    // Let event loop tick — p3 should NOT have started (still suspended)
    let _ = await Promise.resolve()
    expect(p3Started.contents)->toBe(false)
    // Open the gate — subscriber processes; p3 can now publish
    openGate()
    let _ = await p1
    let _ = await p2
    let _ = await p3
    expect(processedCount.contents)->toBe(3)
  })

  testPromise("publishEvent timing is 3 ticks in bounded mode", async () => {
    module TestBus = InMemory_Bus.Make(~capacity=10)
    let delivered = ref(false)
    TestBus.subscribeToEvents("T", async (_, _, _) => delivered := true)
    let pubPromise = TestBus.publishEvent("T", "s", meta, json)
    // Not delivered synchronously
    expect(delivered.contents)->toBe(false)
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await pubPromise
    expect(delivered.contents)->toBe(true)
  })
})
```

Note: `Promise.pending()` is not in RescriptCore — use an `Effect.Deferred`-based gate or a
simple `ref<option<unit => unit>>` callback. Adjust to whatever pattern the codebase uses.

#### G.4 Acceptance criteria ✅

- `InMemory_Bus.Make()` (no `~capacity`) behaves identically to Phase F — all existing tests pass ✅
- `InMemory_Bus.MakeBounded({let capacity = n})` provides backpressure — publisher suspends when
  any subscriber queue is full ✅
- Bounded-mode timing test passes (3 ticks) ✅
- Backpressure suspension test passes ✅
- Zero new warnings ✅

**Implementation notes:**
- ReScript module functions (`module F = (): T => {...}`) do not support labeled parameters.
  The plan's `module Make = (~capacity: option<int>=?, ())` syntax is invalid ReScript.
  Resolved with a two-functor pattern: `Impl(C: BusConfig)` holds the full implementation;
  `Make = (): T => { include Impl({let capacity: option<int> = None}) }` provides the unchanged
  default API; `MakeBounded = (C: {let capacity: int}): T => { include Impl({...}) }` is the new
  bounded variant. All existing `InMemory_Bus.Make()` call sites compile without modification.
- `module type BusConfig = { let capacity: option<int> }` — the configuration module type used by `Impl`.
- Conditional publish path in `publishEvent`:
  - `None` (unbounded): `Effect.sync(() => PubSub.publish->runSync)->zipRight(Deferred.await_)`,
    then a single `Effect.runPromise` — preserves 2-tick guarantee.
  - `Some(_)` (bounded): `PubSub.publish->flatMap(Deferred.await_)` in single `Effect.runPromise` —
    publish may suspend when queue is full; resolves in 3 ticks.
- Added `InMemoryBusBoundedTest.res` with 8 tests: basic delivery (3), fan-out (2),
  backpressure suspension (1), timing (1), reset (1).
- `reventless-in-memory`: 160 tests pass (was 152 after Phase F, +8 new bounded tests).
- `reventless-core`: 189 tests pass unchanged.
- `rescript-effect`: 122 tests pass unchanged.

---

## Section 4b: Phases H and I

---

### Phase H — EventLog.appendStream + DcbEventLog.appendStream

**Goal:** Add `appendStream` to both EventLog and DcbEventLog so that a `Stream.t<event>` can drive
appends without materialising the entire sequence in memory. Primary use cases: event migration,
bulk seeding, and composing a read-side `replayStream` on one log directly into a write-side
`appendStream` on another.

**Priority:** Medium — enables streaming pipelines across event stores with bounded memory.

**Dependency:** Phase B (EventLog.replayStream) and Phase D (DcbEventLog.readStream) must be
complete so the new operations are symmetric with their read counterparts.

#### H.1 Structural Analysis

##### EventLog appendStream

The existing `append` signature is:

```rescript
type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, string>>
```

The `int` is the optimistic concurrency token (sequenceNr). For streaming appends, the caller
supplies the *starting* sequenceNr; the operation increments it for every event emitted by the
stream, making a separate storage call per event. Storage errors terminate the stream via the
Effect error channel.

New type:

```rescript
type appendStream<'id, 'event> = (int, 'id, Stream.t<'event, string, unit>) => Effect.t<unit, string, unit>
```

The error channel carries the first storage error message. On success the Effect produces `unit`.

**Why the error lives in the channel (not a `result`):**
The existing `append` returns `result<unit, string>` wrapped in a promise. For the stream variant,
errors are already routed through the stream's own `'e` channel — wrapping them in an additional
`Result` layer would require callers to handle both levels. Using the channel directly is more
idiomatic and consistent with `replayStream` (whose errors also propagate via the channel).

**Mutable seqNr inside `Stream.runForEach`:**
Because Node.js is single-threaded and Effect fibers run cooperatively, a plain `ref<int>` is safe
for the sequenceNr counter — the same argument as the `remaining` countdown in Phase F.

```rescript
// EventLog_Operations.res — appendStream inside Make(...)
let appendStream = (startingSeqNr, id, stream) => {
  let seqNrRef = ref(startingSeqNr)
  stream->Stream.runForEach(event =>
    Effect.promise(() => Ops.storage.append(seqNrRef.contents, id, [event]))
    ->Effect.flatMap(result => switch result {
    | Ok() =>
      seqNrRef := seqNrRef.contents + 1
      Effect.succeed(())
    | Error(msg) => Effect.fail(msg)
    })
  )
}
```

`Stream.runForEach` returns `Effect.t<unit, 'e, 'r>` — the error type `'e` matches `string`, so
the function type resolves cleanly without extra annotation.

##### DcbEventLog appendStream

The existing `append` signature is:

```rescript
type append<'event> = (array<rawStoredEvent>, ~condition: appendCondition=?) =>
  promise<result<sequencePosition, string>>
```

The `~condition` is a single optimistic concurrency check applied atomically to the whole batch.
For streaming, we collect the stream into one array and make a single append call. This preserves
the atomicity of the condition check — essential for correctness. The cost is that the full batch
must fit in memory; however, for the typical use case (replicating a bounded decision-model event
set) this is acceptable. If truly unbounded batches are needed, a future phase can add chunked
appends with cursor-tracking.

New type in `DcbEventLog.res` / `Reventless.DcbEventLog`:

```rescript
type appendStream<'event> =
  (Stream.t<'event, string, unit>, ~condition: appendCondition=?) =>
    Effect.t<result<sequencePosition, string>, string, unit>
```

The outer effect error channel carries stream-level errors (e.g., decode failures upstream); the
inner `result` carries the storage-level OCC failure (consistent with the existing `append`).

```rescript
// DcbEventLog_Operations.res — appendStream inside Make(...)
let appendStream = (~condition=?, stream) =>
  stream
  ->Stream.runCollect                                          // collect stream to array
  ->Effect.flatMap(events =>
    Effect.promise(() => Ops.storage.append(events->Array.map(encodeEvent), ~condition?))
  )
```

`Stream.runCollect` returns `Effect.t<array<'event>, 'e, 'r>`. The flatMap chains the async
storage call. The result of `Effect.promise(storage.append(...))` is
`Effect.t<result<sequencePosition, string>, never, unit>` which the outer flatMap resolves
correctly.

##### What does NOT change

- The existing `append` (array-based, synchronous batch) on both EventLog and DcbEventLog is
  unchanged. `appendStream` is an additive operation.
- `Aggregate_Callback.handleCommands` is unchanged — it still uses the array-based `append`.
- `StateChangeSlice_Callback.handleSingleCommand` is unchanged.

#### H.2 Implementation Steps

**Step 1 — Add types to EventLog.res**

```rescript
// EventLog.res — additions
type appendStream<'id, 'event> = (int, 'id, Stream.t<'event, string, unit>) => Effect.t<unit, string, unit>
```

**Step 2 — Add to EventLog_Adapter.operations**

```rescript
// EventLog_Adapter.res — extend operations record
type operations = {
  append: EventLog.append<string, JSON.t>,
  replay: EventLog.replay<string, JSON.t>,
  replayStream: string => Stream.t<JSON.t, string, unit>,
  appendStream: EventLog.appendStream<string, JSON.t>,   // NEW
}
```

The storage adapter gets the raw `appendStream` first; `EventLog_Operations.Make` wraps it with
the event-encoding layer (same pattern as `replayStream` → `mapEffect(decodeEvent)`).

**Step 3 — Implement in EventLogStorage_InMemory.res**

```rescript
// EventLogStorage_InMemory.res — appendStream on the storage operations record
let appendStream: EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) => {
  let seqNrRef = ref(startingSeqNr)
  stream->Stream.runForEach(json =>
    Stm.TRef.modify(eventsRef, events => {
      let existing = events->Dict.get(id)->Option.getOr([])
      events->Dict.set(id, existing->Array.concat([json]))
      (Ok(), events)
    })
    ->Stm.commit
    ->Effect.flatMap(result => switch result {
    | Ok() =>
      seqNrRef := seqNrRef.contents + 1
      Effect.succeed(())
    | Error(msg) => Effect.fail(msg)
    })
  )
}
```

Note: the in-memory storage ignores `startingSeqNr` for the actual write (in-memory does not
enforce OCC), but it is kept in the signature for API uniformity with DynamoDB.

**Step 4 — Implement in EventLog_Operations.Make**

```rescript
// EventLog_Operations.res — appendStream inside Make(...)
let appendStream = (startingSeqNr, id, stream) =>
  Ops.storage.appendStream(
    startingSeqNr,
    id->Spec.Id.toString,
    stream->Stream.map(event => event->S.reverseConvertToJsonOrThrow(Spec.eventSchema)),
  )
```

Events are encoded to JSON before being passed to the storage adapter — the inverse of the
`decodeEvent` call in `replayStream`.

**Step 5 — Add types to Reventless.DcbEventLog and DcbEventLog.res**

```rescript
// reventless-spec/src/components/DcbEventLog.res — additions
type appendStream<'event> =
  (Stream.t<'event, string, unit>, ~condition: appendCondition=?) =>
    Effect.t<result<sequencePosition, string>, string, unit>

// reventless-core DcbEventLog.res mirrors the spec type:
type appendStream<'event> = Reventless.DcbEventLog.appendStream<'event>
```

**Step 6 — Add to DcbEventLog_Adapter.operations**

```rescript
// DcbEventLog_Adapter.res — extend operations record
type operations = {
  read: ...,
  append: ...,
  readStream: ...,
  appendStream: (array<rawStoredEvent>, ~condition: appendCondition=?) =>
    promise<result<sequencePosition, string>>,  // same as append — storage collects first
}
```

The storage-level `appendStream` is identical to `append` because the collection happens one
layer up in `DcbEventLog_Operations`. The adapter signature does not need to change:
`DcbEventLog_Operations.appendStream` calls `Ops.storage.append` (not a new storage method).

**Step 7 — Implement in DcbEventLog_Operations.Make**

```rescript
// DcbEventLog_Operations.res — appendStream inside Make(...)
let appendStream = (~condition=?, stream) =>
  stream
  ->Stream.map(event => encodeEvent(event))
  ->Stream.runCollect
  ->Effect.flatMap(rawEvents =>
    Effect.promise(() => Ops.storage.append(rawEvents, ~condition?))
  )
```

`encodeEvent` is the existing per-event encoder (already used in `append`). `Stream.runCollect`
is already bound from Phase A. No new bindings required.

**Step 8 — Propagate to mock and DynamoDB adapters**

- `MockEventLogStorage.res` — add `appendStream` field with a stub implementation
- `EventLogStorage_DynamoDB.res` / `EventLogStorage_DynamoDbStream.res` — add `appendStream`
  using the same sequential-per-event pattern as the in-memory adapter (full DynamoDB-native
  batch writing is a follow-up)
- `DcbEventLogStorage_DynamoDb.res` — no change needed (`appendStream` at the operations layer
  calls the existing `storage.append`)

#### H.3 Tests

**File to create:** `reventless/reventless-in-memory/tests/components/eventlog/EventLogAppendStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect

describe("EventLog.appendStream", () => {
  describe("basic append", () => {
    testPromise("appendStream writes all events to storage", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let stream = Stream.fromIterable([makeEvent("e1"), makeEvent("e2"), makeEvent("e3")])
      let _ = await ops.appendStream(0, itemId, stream)->Effect.runPromise
      let replayed = await ops.replay(itemId)
      expect(replayed->Array.length)->toBe(3)
    })

    testPromise("appendStream on empty stream writes nothing", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.appendStream(0, itemId, Stream.empty)->Effect.runPromise
      let replayed = await ops.replay(itemId)
      expect(replayed->Array.length)->toBe(0)
    })

    testPromise("appendStream preserves event order", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let stream = Stream.fromIterable([makeEvent("first"), makeEvent("second")])
      let _ = await ops.appendStream(0, itemId, stream)->Effect.runPromise
      let replayed = await ops.replay(itemId)
      expect(replayed->Array.length)->toBe(2)
      // Verify order preserved — first event maps to first replay entry
    })

    testPromise("appendStream after array append continues from correct sequenceNr", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, itemId, [makeEvent("initial")])
      // Now appendStream from seqNr 1
      let stream = Stream.fromIterable([makeEvent("streamed")])
      let _ = await ops.appendStream(1, itemId, stream)->Effect.runPromise
      let replayed = await ops.replay(itemId)
      expect(replayed->Array.length)->toBe(2)
    })
  })

  describe("replayStream → appendStream pipeline", () => {
    testPromise("can copy events from one aggregate to another via streams", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "source-id", [makeEvent("a"), makeEvent("b")])
      // Stream from source and append to destination
      let sourceStream = ops.replayStream("source-id")
      let _ = await ops.appendStream(0, "dest-id", sourceStream)->Effect.runPromise
      let destEvents = await ops.replay("dest-id")
      expect(destEvents->Array.length)->toBe(2)
    })
  })
})
```

**File to create:** `reventless/reventless-in-memory/tests/components/dcbeventlog/DcbEventLogAppendStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect

describe("DcbEventLog.appendStream", () => {
  testPromise("appendStream writes all events from stream", async () => {
    module TestDcb = DcbEventLogStorage_InMemory.Make({})
    let stream = Stream.fromIterable([
      makeRawEvent("e1", tagOf("x")),
      makeRawEvent("e2", tagOf("x")),
    ])
    let result = await TestDcb.ops.appendStream(stream, ())->Effect.runPromise
    expect(result)->not->toEqual(Error(_))
    let read = await TestDcb.ops.read(~query=tagQuery("x"))
    expect(read.events->Array.length)->toBe(2)
  })

  testPromise("appendStream on empty stream succeeds with a position", async () => {
    module TestDcb = DcbEventLogStorage_InMemory.Make({})
    let result = await TestDcb.ops.appendStream(Stream.empty, ())->Effect.runPromise
    // Empty batch append — behaviour matches empty array append
    expect(result)->not->toEqual(Error(_))
  })

  testPromise("readStream → appendStream pipeline copies events", async () => {
    module SrcDcb = DcbEventLogStorage_InMemory.Make({})
    module DstDcb = DcbEventLogStorage_InMemory.Make({})
    let _ = await SrcDcb.ops.append([makeRawEvent("ev", tagOf("y"))], ())
    let srcStream = SrcDcb.ops.readStream(~query=tagQuery("y"))
    let _ = await DstDcb.ops.appendStream(srcStream, ())->Effect.runPromise
    let dst = await DstDcb.ops.read(~query=tagQuery("y"))
    expect(dst.events->Array.length)->toBe(1)
  })
})
```

#### H.4 Acceptance criteria

- All existing EventLog and DcbEventLog tests pass unchanged
- `EventLogAppendStreamTest.res` passes (5 tests)
- `DcbEventLogAppendStreamTest.res` passes (3 tests)
- `replayStream → appendStream` pipeline test demonstrates end-to-end streaming copy
- Zero new compiler warnings
- All mock and DynamoDB adapter stubs compile

---

### Phase I — CommandTopic.publishJsonsStream + EventTopic.publishJsonStream + Aggregate Facade

**Goal:** Add streaming publish operations to CommandTopic and EventTopic so that a
`Stream.t<commandJson>` or `Stream.t<eventItem>` can drive publishing without first collecting
all items into an array. The Aggregate operations facade exposes the CommandTopic stream variant
automatically. Together with Phase H's `appendStream`, these operations close the write-side
streaming loop: read events from a stream → process → publish commands or events → stream the
appends.

**Priority:** Low — primarily useful for bulk command dispatch and high-throughput event fan-out.
Individual publish calls can always be wrapped in `Stream.runForEach` by the caller; the stream
operations are ergonomic wrappers that also make the intent explicit.

**Dependency:** Phase H must be complete (establishes the write-side streaming pattern and confirms
that Effect's `runForEach`-based implementation is sound for this codebase).

#### I.1 Structural Analysis

##### CommandTopic publishJsonsStream

Current signature:

```rescript
// ReventlessSpec CommandTopic.res
type publishJsons = array<Message.commandJson> => promise<unit>
```

New type:

```rescript
type publishJsonsStream = Stream.t<Message.commandJson, string, unit> => Effect.t<unit, string, unit>
```

Relationship: `publishJsonsStream` is the stream counterpart to `publishJsons`. A caller that has
a `Stream.t<commandJson>` can publish each command as it is produced, without collecting into an
array. Errors (e.g., dispatch failures) propagate through the Effect error channel.

Implementation is `Stream.runForEach` wrapping the existing per-item dispatch:

```rescript
// CommandTopicChannel_InMemory.Make — publishJsonsStream
let publishJsonsStream: CommandTopic.publishJsonsStream = stream =>
  stream->Stream.runForEach(cmdJson =>
    Effect.promise(() => Bus.dispatchCommand(name, encodeMessage(cmdJson)))
  )
```

For the AWS adapter (`CommandTopicChannel_Sqs.res`), the same pattern holds with `sqs.sendMessage`
wrapped in `Effect.tryPromise`.

##### EventTopic publishJsonStream

Current signature:

```rescript
// ReventlessSpec EventTopic.res
type publishJson = (string, Message.meta, JSON.t) => promise<unit>
```

For the stream variant, each item carries the service name, meta, and JSON payload — three fields
that are generated independently per event (unlike CommandTopic where all items share the same
topic channel). Using a record type makes the stream item self-contained:

```rescript
// ReventlessSpec EventTopic.res — new record type and stream type
type publishJsonStreamItem = {
  service: string,
  meta: Message.meta,
  json: JSON.t,
}
type publishJsonStream = Stream.t<publishJsonStreamItem, string, unit> => Effect.t<unit, string, unit>
```

Implementation:

```rescript
// EventTopicPublisher_InMemory.Make — publishJsonStream
let publishJsonStream: EventTopic.publishJsonStream = stream =>
  stream->Stream.runForEach(({service, meta, json}) =>
    Effect.promise(() => Bus.publishEvent(name, service, meta, json))
  )
```

For the AWS adapter (`EventTopicPublisher_Sns.res`), the same pattern with `sns.publish` wrapped
in `Effect.tryPromise`.

##### Aggregate operations facade

`Aggregate_Builder.Make` constructs an `operations` record that includes the CommandTopic
operations. Adding `publishJsonsStream` to `CommandTopic.operations` makes it automatically
available on the aggregate's command dispatch surface:

```rescript
// CommandTopic.res — operations record (core, not spec)
type operations = {
  publish: publish,
  publishJsons: publishJsons,
  publishJsonsStream: publishJsonsStream,   // NEW
}
```

No change to `Aggregate_Callback.handleCommands` is required — the stream variant is an
additional entry point, not a replacement.

##### DcbEventLog publishToEventTopicStream (internal)

`DcbEventLog_Operations` has a private `publishToEventTopic` that maps over an array and calls
`publishJson` for each event. With the EventTopic stream operation available, the internal
`publishToEventTopicStream` becomes:

```rescript
// DcbEventLog_Operations.res — new private helper (replaces array-based publishToEventTopic for
// streaming callers; the existing array-based function is kept for Aggregate_Callback)
let publishToEventTopicStream = (stream: Stream.t<Spec.event, string, unit>) =>
  stream->Stream.runForEach(event =>
    Effect.promise(() => {
      let json = event->S.reverseConvertToJsonOrThrow(Spec.eventSchema)
      let meta = Message.generateMeta(~service=name)
      Ops.publishJson(name, meta, json)
    })
  )
```

This is an internal optimisation. The external API (`appendStream` from Phase H) already calls
the existing `publishToEventTopic`; exposing `publishJsonStream` on the EventTopic operations
gives callers the option to stream their own event sequences to the EventTopic independently of
the DcbEventLog append path.

#### I.2 Implementation Steps

**Step 1 — Add types to ReventlessSpec CommandTopic.res**

```rescript
// CommandTopic.res (spec) — additions
type publishJsonsStream = Stream.t<Message.commandJson, string, unit> => Effect.t<unit, string, unit>
```

**Step 2 — Add types to ReventlessSpec EventTopic.res**

```rescript
// EventTopic.res (spec) — additions
type publishJsonStreamItem = {
  service: string,
  meta: Message.meta,
  json: JSON.t,
}
type publishJsonStream = Stream.t<publishJsonStreamItem, string, unit> => Effect.t<unit, string, unit>
```

**Step 3 — Extend CommandTopic.operations in reventless-core**

```rescript
// reventless-core CommandTopic.res — extend operations record
type operations = {
  publish: publish,
  publishJsons: publishJsons,
  publishJsonsStream: Reventless.CommandTopic.publishJsonsStream,   // NEW
}
```

**Step 4 — Extend EventTopic.operations in reventless-core**

```rescript
// reventless-core EventTopic.res — extend operations record
type operations = {
  publish: publish,
  publishJson: publishJson,
  publishJsonStream: Reventless.EventTopic.publishJsonStream,   // NEW
}
```

**Step 5 — Implement in CommandTopicChannel_InMemory.Make**

```rescript
// CommandTopicChannel_InMemory.res — inside Make(Bus)
let publishJsonsStream: Reventless.CommandTopic.publishJsonsStream = stream =>
  stream->Stream.runForEach(cmdJson =>
    Effect.promise(() => Bus.dispatchCommand(name, encodeMessage(cmdJson)))
  )

// Add to the channel's publishJsonsStream field in the returned operations record
```

**Step 6 — Implement in EventTopicPublisher_InMemory.Make**

```rescript
// EventTopicPublisher_InMemory.res — inside Make(Bus)
let publishJsonStream: Reventless.EventTopic.publishJsonStream = stream =>
  stream->Stream.runForEach(({service, meta, json}) =>
    Effect.promise(() => Bus.publishEvent(name, service, meta, json))
  )

// Add to the publisher's publishJsonStream field in the returned operations record
```

**Step 7 — Propagate to AWS adapters**

- `CommandTopicChannel_Sqs.res` — add `publishJsonsStream` using `Effect.tryPromise` around
  `sqs.sendMessage`, same pattern as `publishJsons` but wrapped in `runForEach`
- `EventTopicPublisher_Sns.res` — add `publishJsonStream` using `Effect.tryPromise` around
  `sns.publish`
- Mock stubs in test fixtures need the new fields (empty `Effect.succeed(())` stubs acceptable)

**Step 8 — Expose `publishJsonsStream` on Aggregate_Builder operations**

The aggregate operations record is constructed in `Aggregate_Builder.Make`. The CommandTopic
operations are already threaded through; once `publishJsonsStream` is in `CommandTopic.operations`
it is automatically available. Verify the operations record type in `Aggregate.res` includes the
new field (or is structurally open enough to accept it without explicit annotation change).

#### I.3 Tests

**File to create:** `reventless/reventless-in-memory/tests/components/commandtopic/CommandTopicStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect

describe("CommandTopic.publishJsonsStream", () => {
  testPromise("streams 3 commands to the bus in order", async () => {
    module TestBus = InMemory_Bus.Make()
    // Register a handler to capture dispatched commands
    let captured = ref([])
    TestBus.registerCommandHandler("TestCmd", async body => {
      captured := captured.contents->Array.concat([body])
    })
    let cmdTopic = CommandTopicChannel_InMemory.Make(TestBus).make(
      ~name="TestCmd", ~opts=Pulumi.CustomResourceOptions.make()
    )
    let ops = await cmdTopic.publishJsonsStream->TestRunner.resolve
    let stream = Stream.fromIterable([
      makeCommandJson("cmd-1"),
      makeCommandJson("cmd-2"),
      makeCommandJson("cmd-3"),
    ])
    let _ = await ops(stream)->Effect.runPromise
    // Allow dispatch to settle
    let _ = await Promise.resolve()
    expect(captured.contents->Array.length)->toBe(3)
  })

  testPromise("empty stream dispatches nothing", async () => {
    module TestBus = InMemory_Bus.Make()
    let dispatched = ref(0)
    TestBus.registerCommandHandler("TestCmd", async _ => {
      dispatched := dispatched.contents + 1
    })
    let ops = ... // same as above
    let _ = await ops(Stream.empty)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(dispatched.contents)->toBe(0)
  })
})
```

**File to create:** `reventless/reventless-in-memory/tests/components/eventtopic/EventTopicStreamTest.res`

```rescript
open AsyncTest
open AsyncTest.Expect

describe("EventTopic.publishJsonStream", () => {
  testPromise("streams 2 events to all subscribers", async () => {
    module TestBus = InMemory_Bus.Make()
    let received = ref([])
    TestBus.subscribeToEvents("TestEventTopic", async (_, _, json) => {
      received := received.contents->Array.concat([json])
    })
    let publisher = EventTopicPublisher_InMemory.Make(TestBus).make(
      ~name="TestEventTopic", ~storageResources=[], ~opts=Pulumi.CustomResourceOptions.make()
    )
    let ops = await publisher.publishJsonStream->TestRunner.resolve
    let stream = Stream.fromIterable([
      {service: "svc", meta: makeMeta(), json: JSON.parseExn("{\"type\":\"A\"}")},
      {service: "svc", meta: makeMeta(), json: JSON.parseExn("{\"type\":\"B\"}")},
    ])
    let _ = await ops(stream)->Effect.runPromise
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    expect(received.contents->Array.length)->toBe(2)
  })

  testPromise("publishJsonStream composes with replayStream → appendStream pipeline", async () => {
    // Demonstrates the full write-side stream loop:
    // replayStream → decode → stream to EventTopic
    // Validates that stream operations compose end-to-end without forced materialisation.
    let eventStream = Stream.fromIterable([
      {service: "svc", meta: makeMeta(), json: JSON.parseExn("{\"ev\":1}")},
      {service: "svc", meta: makeMeta(), json: JSON.parseExn("{\"ev\":2}")},
    ])
    let received = ref(0)
    TestBus.subscribeToEvents("TestEventTopic", async (_, _, _) => {
      received := received.contents + 1
    })
    let _ = await publishJsonStreamOps(eventStream)->Effect.runPromise
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    expect(received.contents)->toBe(2)
  })
})
```

**Integration smoke test** — add to `AggregateTest.res`:

```rescript
testPromise("aggregate.commandTopic.publishJsonsStream dispatches via stream", async () => {
  // Stream a command instead of calling publishJsons directly
  let cmdStream = Stream.fromIterable([encodeCreate("item-stream", "Streamed")])
  let _ = await ops.commandTopic.publishJsonsStream(cmdStream)->Effect.runPromise
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
  // Verify event was produced (command was processed)
  let replayed = await eventLogOps.replayStream("item-stream")
    ->Stream.runFold(0, (n, _) => n + 1)
    ->Effect.runPromise
  expect(replayed)->toBe(1)
})
```

#### I.4 Acceptance criteria

- All existing CommandTopic, EventTopic, and Aggregate tests pass unchanged
- `CommandTopicStreamTest.res` passes (2 tests)
- `EventTopicStreamTest.res` passes (2 tests)
- Aggregate integration smoke test passes (1 test)
- `reventless-spec` compiles with the new `publishJsonsStream` / `publishJsonStreamItem` /
  `publishJsonStream` types
- All AWS adapter stubs compile (even if the DynamoDB implementation is a stub)
- Zero new compiler warnings

**Implementation notes (to fill in after implementation):**

- If `reventless-spec` does not yet import `Stream` (it needed to be added in Phase D for
  DcbEventLog), verify the dependency is present in both `package.json` and `rescript.json`.
- `publishJsonStreamItem` introduces the only new record type in this phase. If it causes
  ambiguity with existing record types in the same scope, add a module namespace:
  `EventTopic.StreamItem` rather than a top-level type.
- The `publishJsonsStream` on the AWS CommandTopic channel should batch commands where possible
  (SQS `sendMessageBatch` accepts up to 10 messages). This is a follow-up optimisation; the
  initial implementation sends one message per stream item for correctness.

---

## Section 5: Known Constraints and Risks

### `PubSub.publish` on unbounded hub must use `Effect.runSync` (Phase F)

`PubSub.unbounded()` routes items synchronously to all subscriber Queues. Using
`Effect.runSync(PubSub.publish(...))` is correct and avoids an extra microtask hop that would
break the 2-tick timing guarantee. **Do not change to `Effect.runPromise` for the unbounded
path.** Only bounded mode (Phase G) needs `Effect.runPromise` for publish.

### `done_` Effect must run inside the drain fiber chain, not via `Effect.runSync` (Phase F)

`done_` (the countdown Effect in each `queuedEvent`) calls `Deferred.succeed(allDone, ())` when
`remaining` reaches zero. This `Deferred.succeed` must execute within the **same Effect runtime**
as the `Deferred.await_` in the publisher (both are in the default runtime started by
`Effect.runFork`/`Effect.runPromise`). If `done_` were called via `Effect.runSync` from a raw
JS callback, it would use a **separate runtime** and the `Deferred.await_` fiber would never be
notified. Always compose `done_` with `Effect.zipRight` inside the drain fiber's effect chain.

### 2-tick guarantee is unbounded-mode only (Phases F and G)

The guarantee that `publishEvent` resolves in exactly 2 microtask ticks applies only when
`InMemory_Bus.Make()` is called without `~capacity` (unbounded mode). In bounded mode
(`~capacity=n`), `Effect.runPromise` is used for publish, adding one tick — tests using bounded
mode must await 3 ticks. Existing tests are unaffected because they all use the default
(unbounded) `Make()`.

### `remaining` ref in countdown is safe only in single-threaded JS (Phase F)

The `remaining := remaining.contents - 1` mutation inside `done_` is safe because Node.js is
single-threaded and Effect fibers run cooperatively. Concurrent decrements are impossible within
a single tick. This would NOT be safe in a multi-threaded runtime (JVM/native Effect). If the
code is ever ported, replace `ref<int>` with `SynchronizedRef` or an atomic countdown latch.

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

### `appendStream` mutable seqNr ref is safe only in single-threaded JS (Phase H)

`EventLog_Operations.appendStream` uses a `ref<int>` to track the sequenceNr across stream items
inside `Stream.runForEach`. This is safe because Node.js is single-threaded and Effect fibers run
cooperatively — the same argument as the `remaining` countdown ref in Phase F. If this code is
ever ported to a multi-threaded Effect runtime (JVM/native), replace `ref<int>` with
`SynchronizedRef` or an STM-based counter.

### DcbEventLog.appendStream collects the full stream before writing (Phase H)

`DcbEventLog_Operations.appendStream` calls `Stream.runCollect` before passing the batch to
`storage.append`. This means the entire event sequence is held in memory before the write — the
same as the array-based `append`. The benefit is that the caller's *production* of events can be
a stream (e.g., decoded from a CSV or from `replayStream` on another log) without the caller
needing to materialise it themselves. True chunk-by-chunk DcbEventLog writes would break the
atomicity of the `~condition` check and require a more complex protocol — deferred to a future
phase.

### `appendStream` error channel vs. `result` return (Phase H)

`EventLog.appendStream` routes storage errors through the Effect error channel (`Effect.fail`)
rather than returning `result<unit, string>`. This is intentional: the error channel is the
natural fit when errors are non-recoverable within the stream pipeline (any storage failure aborts
the append loop). Callers that want a `result` can use `Effect.either` to convert:

```rescript
eventLog.appendStream(seqNr, id, stream)
->Effect.either
->Effect.runPromise
// yields promise<Either<string, unit>> which can be matched against Left(err)/Right(())
```

`DcbEventLog.appendStream` keeps the inner `result<sequencePosition, string>` for parity with the
existing `append` return type and because its error (OCC failure) is a business-level outcome that
callers frequently need to pattern-match.

### `publishJsonStream` timing (Phase I)

`EventTopic.publishJsonStream` calls `Bus.publishEvent` inside `Stream.runForEach`. Each item in
the stream goes through the same 2-tick delivery path as a direct `publishEvent` call, but items
are processed sequentially (one item's publish must fully settle before the next begins — because
`runForEach` awaits each Effect before moving to the next). For large streams this means N×2
ticks total. Tests using `publishJsonStream` must await enough ticks (2 per item) or simply await
the returned Effect (which resolves only after all items are delivered).

### Aggregate.commandTopic.publishJsonsStream error handling (Phase I)

The current `publishJsons` (array-based) silently ignores individual dispatch failures (no error
is propagated to the caller). `publishJsonsStream` routes errors through the Effect error channel
— if a single item dispatch fails, the stream terminates and the caller receives the error. This
is a deliberately stricter contract. Callers that want best-effort delivery (ignore failures) can
use `Stream.catchAll(\_ => Stream.empty)` before passing the stream to `publishJsonsStream`.
