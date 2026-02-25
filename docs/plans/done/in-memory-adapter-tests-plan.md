# Plan: Adapter Unit Tests for reventless-in-memory

## Context

The `reventless/reventless-in-memory/` package has a single test file (`tests/AggregateE2ETest.res`)
that covers `InMemory_Bus`, `EventLogStorage_InMemory`, and the full aggregate E2E flow.
All other adapter modules are untested. This plan adds unit tests for every remaining
in-memory adapter, following the patterns established by the existing test suite.

## Adapters Already Covered

| Adapter | File | Tests In |
|---------|------|----------|
| InMemory_Bus | src/adapter/InMemory_Bus.res | AggregateE2ETest.res |
| EventLogStorage_InMemory | src/adapter/EventLog/EventLogStorage_InMemory.res | AggregateE2ETest.res |
| Aggregate E2E wiring | components/Aggregate_Builder.res | AggregateE2ETest.res |

## New Test Files to Create

All files go into `reventless/reventless-in-memory/tests/`.
The jest config matches `tests/**/*Test.res.mjs` and rescript.json lists `tests/` as a source dir.

### 1. `tests/EventTopicPublisherTest.res`
**Adapter:** `src/adapter/EventTopic/EventTopicPublisher_InMemory.res`
**Needs Pulumi mock:** Yes
- `make` returns one resource whose name resolves to the topic name
- `publishJson` calls Bus.publishEvent with correct topic name, service, meta, json
- Publishing to different topic names routes to correct subscribers (isolation)

### 2. `tests/CommandTopicChannelTest.res`
**Adapter:** `src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`
**Needs Pulumi mock:** Yes
- `encodeMessage` produces `{id, meta, command}` JSON shape
- `decodeId` extracts the id string from an encoded message body
- `decodeId` returns empty string for non-object input
- `publishJsons` dispatches each command to the bus (handler receives full body)
- `connect` registers a handler; subsequent dispatch reaches the runtime handlerRef
- `handleChannelEvent` creates a handler that passes full body as the command and extracts reference

### 3. `tests/EventCollectorChannelTest.res`
**Adapter:** `src/adapter/EventCollector/EventCollectorChannel_InMemory.res`
**Needs Pulumi mock:** Yes
- `make` collects all eventTopic resources into channel resources
- `make` with empty eventTopics produces empty resources
- `connect` subscribes to event topics via bus; published events reach runtime handlerRef
- Events from multiple topics all delivered to the same handler

### 4. `tests/QueryDbStorageTest.res`
**Adapter:** `src/adapter/QueryDb/QueryDbStorage_InMemory.res`
**Needs Pulumi mock:** Yes
- `save` stores a state; `load` retrieves it
- `load` returns empty array for unknown id
- `save` overwrites previous state for same id
- `saveBatch` stores multiple items; each loadable by id
- `count` returns the increment value
- `delete` removes item; subsequent `load` returns empty
- `deleteBatch` removes multiple items
- After `save`, scan function returns all stored items
- Registers itself in bus for lookup by QueryEngine

### 5. `tests/QueryEngineTest.res`
**Adapter:** `src/adapter/QueryEngine/QueryEngine_InMemory.res`
**Needs Pulumi mock:** Yes
- `query` by id returns items saved in the matching QueryDbStorage
- `query` by explicit string key (key parameter overrides id)
- `scan` returns all items from the matching QueryDbStorage
- `query` for unknown readModelName returns empty array
- `scan` for unknown readModelName returns empty array

### 6. `tests/CounterHandlerTest.res`
**Adapter:** `src/adapter/Counter/CounterHandler_InMemory.res`
**Needs Pulumi mock:** No (module-level refs, no Pulumi)
- `addToCounterTarget` increments counter by target amount
- Same `(counterId, targetRef)` pair counted only once (deduplication)
- Different targetRef values for same counterId accumulate
- Multiple counters tracked independently
- `getCount` returns 0 for unknown counterId
- `reset` clears all counter values and deduplication state

### 7. `tests/DcbEventLogStorageTest.res`
**Adapter:** `src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res`
**Needs Pulumi mock:** Yes
- `append` stores events and returns incrementing position
- `read` with empty query returns all events
- `read` filters by eventType
- `read` filters by tags
- `read` with `after` skips events at or before that position
- `headPosition` equals the position of the last appended event
- `headPosition` absent when no events stored
- Conditional `append` with matching condition returns Error (conflict)
- Conditional `append` with no matching events succeeds
- Conditional `append` with `after` only checks events after that position

### 8. `tests/ScheduledPublisherTest.res`
**Adapter:** `src/adapter/Scheduler/ScheduledPublisher_InMemory.res`
**Needs Pulumi mock:** Yes
**Uses fake timers:** Yes — `jest.useFakeTimers()` / `jest.runAllTimers()`
- `createSchedule` single-shot: after `runAllTimers`, event published to bus
- `deleteSchedule` clears a named schedule; running timers doesn't fire it
- `reset` clears all active timers without error

### 9. `tests/HeartbeatRunnerTest.res`
**Adapter:** `src/adapter/Heartbeat/HeartbeatRunner_InMemory.res`
**Needs Pulumi mock:** No
**Uses fake timers:** Yes
- After `advanceTimersByTime(timeout*60*1000)`, handler is called once
- With handlerRef not yet set: interval fires without crash
- `reset` clears all intervals; subsequent advance doesn't fire handler

### 10. `tests/TaskBucketTest.res`
**Adapter:** `src/adapter/Task/TaskBucket_InMemory.res`
**Needs Pulumi mock:** No
- `makeHandler` calls callback with eventName and key extracted from JSON
- Uses "ObjectCreated" when JSON has no "eventName" field
- Uses empty string when JSON has no "key" field
- With non-object JSON uses defaults for both fields
- `make` returns empty resources and unit parts

## Test Patterns and Conventions

### Imports (all files)
```rescript
open Jest
open Expect
open ReventlessInMemory.AsyncTest
```

### Pulumi mock setup (files needing it)
```rescript
let _ = TestRunner.setup()   // at module level, before any Pulumi.Output.make
```

### Resolving Output in tests
```rescript
let ops = await storage.operations->TestRunner.resolve
```

### Fresh bus per test
Use `module TestBus = InMemory_Bus.Make()` inside each `testPromise` callback
for full isolation, or use `beforeEach(() => bus.reset())` at describe scope.

### Fake timer bindings (Scheduler/Heartbeat)
```rescript
type jestObj
@val external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external runAllTimers: jestObj => unit = "runAllTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"
```

### CounterHandler isolation
Module-level refs — call `CounterHandler_InMemory.reset()` in `beforeEach`.

## Key Reference Files

- `reventless/reventless-in-memory/tests/AggregateE2ETest.res` — canonical test pattern
- `reventless/reventless/tests/dcb/DcbFixtures.res` — mock factory with failure injection
- `reventless/reventless-in-memory/src/test/AsyncTest.res` — testPromise binding
- `reventless/reventless-in-memory/src/test/TestRunner.res` — setup/resolve/reset helpers

## Verification

```bash
cd reventless/reventless-in-memory
npm run build      # compile all test files
npm test           # run all tests
```

Expected: 10 test files, ~60–80 individual test cases, all passing.

## Out of Scope (deferred)

- `SideEffectHandler_InMemory` — requires `Reventless.Component.make` (Pulumi component infra)
- `GraphQL_Server` — HTTP server integration
- `CommandGeneratorResolvers_GraphQL`, `QueryDbResolvers_GraphQL` — GraphQL wiring
- `RuntimeEnvironment_InMemory`, `AggregateRuntime_Builder_InMemory`,
  `EventCollectorRuntime_Builder_InMemory` — indirectly covered by AggregateE2ETest
