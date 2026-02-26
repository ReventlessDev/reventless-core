# Component Testing Guide

This guide explains how Reventless components are tested, describes the two-layer test architecture, and provides a precise index of which component and which part of that component is covered by each test file.

---

## Concepts

### What is a component test?

A Reventless component is a deployable building block — EventLog, Aggregate, ReadModel, CommandTopic, and so on. Each component is built from up to four source files (see the component structure pattern):

| File | Role |
|------|------|
| `Component.res` | Type definitions and output record |
| `Component_Operations.res` | Runtime business logic (pure functions over adapter operations) |
| `Component_Callback.res` | Runtime event/command handlers (async, reads from topic, calls operations) |
| `Component_Builder.res` | Pulumi deploy-time factory; wires adapters together; returns `operations` via `Output.t` |

Testing these layers requires different approaches:

- **Operations** are pure business logic tested against mock adapter implementations. They run synchronously or with simple async; no Pulumi, no bus.
- **Callbacks** are async handler functions tested by wiring mock operations and feeding synthetic input. They verify the handler loop: decode → call operations → publish results.
- **Builders** are tested end-to-end using the in-memory platform. The builder is called with in-memory adapters; the test drives it via the bus and asserts on observable side effects.
- **Adapters** (the in-memory implementations themselves) are unit-tested in isolation to verify their own contract.

### Two-package, two-layer architecture

Tests live in two packages, forming a layered pyramid:

```
Layer 1 — reventless-core/tests/
  Unit tests for Operations and Callbacks
  ├── Mock adapters are hand-written closures over `ref` values
  ├── No Pulumi.Output — all synchronous or simple async
  ├── CJS Jest (no ESM)
  └── Covers: the logic inside each component's _Operations and _Callback modules

Layer 2 — reventless-in-memory/tests/
  ├── adapter/      — Unit tests for InMemory adapter modules
  │   ├── No Pulumi mock needed for most; uses TestRunner.setup() for those that do
  │   └── Covers: the in-memory adapter implementations themselves
  └── components/   — Builder E2E tests (integration)
      ├── Uses InMemory_Bus + in-memory adapters via _Builder.Make(Bus)
      ├── ESM Jest; uses TestRunner.resolve to await Output chains
      └── Covers: the full wired-up component from command dispatch to observable result
```

### Testing conventions

**Mock adapters** (Layer 1 and adapter tests) use factory functions that return closures over `ref` values — never global module-level refs. This gives each test a fresh, isolated mock:

```rescript
let makeMockStorage = () => {
  let data = ref([])
  let failNextWrites = ref(0)
  {
    operations: { append: async item => { ... }, read: async () => data.contents },
    getAll: () => data.contents,
    failNextWrites,
    reset: () => { data := []; failNextWrites := 0 },
  }
}
let mock = makeMockStorage()
let _ = beforeEach(() => mock.reset())
```

**Builder E2E tests** (Layer 2 components) resolve the Pulumi Output chain in `beforeAllAsync` before any test runs — Output chains are async (microtask-based):

```rescript
let _ = beforeAllAsync(async () => {
  let _ = await component->Maker.operations->TestRunner.resolve
  // Some components need a second resolve to register inner subscriptions
  let _ = await topicResource.name->TestRunner.resolve
})
```

**Async test bodies** use native Jest `test` (bound as `jestTest`) rather than `testPromise` from `@glennsl/rescript-jest`. `testPromise` discards the returned Promise, making tests appear synchronous and causing race conditions on shared state.

**Test naming** follows Given/When/Then style: `"ItemCreated preserves through round-trip"`, `"duplicate AddItem produces 0 events (ItemAlreadyExists)"`.

---

## Test File Index

### reventless-core — Unit tests

All files are under `reventless/reventless-core/tests/`.

#### Utility / infrastructure tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `message/MessageTest.res` | `ReventlessCore.Message` | `splitMessage` and `combineMessage` JSON encoding for tagged union variants; `generateMeta` meta construction; round-trip encode→decode for command and event envelopes |
| `EventMappingTest.res` | `ReventlessCore.ExtensionMapping` | Pure mapping logic: `mapIncomingEvent` action production, `AbstractPublishAggregateCommand` routing, `AbstractPublishExtensionPointCommand` routing |
| `BehaviorTest.res` | `ReventlessCore.BehaviorTest` | Test harness helper module; verifies the Given/When/Then DSL used by `PluginBehaviorTest` |
| `ProjectionTest.res` | `ReventlessCore.ProjectionTest` | Test harness helper module; verifies the event→state DSL used by `PluginProjectionTest` |

#### Plugin-level tests (Aggregate + ReadModel via Behavior/Projection helpers)

| File | Module under test | What is tested |
|------|------------------|----------------|
| `plugin/PluginBehaviorTest.res` | `Reventless.Aggregate.Behavior` | Aggregate decide/reduce loop via the `BehaviorTest` DSL: initial state, command → event emission, duplicate command rejection, state accumulation across multiple events |
| `plugin/PluginProjectionTest.res` | `Reventless.ReadModel.Projection` | ReadModel `project` function via the `ProjectionTest` DSL: event → state upsert, event → state delete, multi-event projection chains |

#### DCB component tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `dcb/DcbTagTest.res` | `Reventless.DcbTag` | Pure functions: `jsonValueToString` for all JSON value types (string, number, boolean, null, array, object); tag extraction from `@s.matches`-annotated schema fields |
| `dcb/DcbEventLogOperationsTest.res` | `ReventlessCore.DcbEventLog_Operations` | `append` encodes events via sury and stores them; `read` decodes and returns sequenced events; round-trip for all variant types including tagged int fields; `after` parameter filters by position; `publishJson` called on append success; storage error suppresses publish |
| `dcb/DcbStateChangeSliceTest.res` | `ReventlessCore.StateChangeSlice_Operations` | `decide` → `reduce` loop: command produces events, decision model accumulates, duplicate command returns error, events stored and published |

#### Aggregate tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `aggregate/AggregateCallbackTest.res` | `ReventlessCore.Aggregate_Callback` | `handleCommands` handler loop: Create command on new aggregate appends event and returns `Ok(reference)`; subsequent command replays history before deciding; behavior returning no events returns `Ok` with no storage write; `append` failure returns `Error(reference)`; retry on optimistic concurrency conflict |

#### EventLog tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `eventlog/EventLogOperationsTest.res` | `ReventlessCore.EventLog_Operations` | `append` stores encoded events and calls `publishJson`; `replay` returns decoded events in order; empty replay for unknown aggregate; storage failure suppresses publish; round-trip encode→decode for event variants |

#### EventTopic tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `eventtopic/EventTopicOperationsTest.res` | `ReventlessCore.EventTopic_Operations` | `publish` encodes message and calls the publisher; message envelope preserves `id`, `meta`, and event payload; publisher error propagated |

#### EventMapper tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `eventmapper/EventMapperTest.res` | `ReventlessCore.EventMapper` | Pure mapping functions: source event → target command translation; identity mapping; nil mapping (no output) |
| `eventmapper/EventMapperCallbackTest.res` | `ReventlessCore.EventMapper_Callback` | Handler loop: incoming event decoded → `mapEvent` called → `publishToAggregates` invoked with translated commands; unknown event type handled gracefully |

#### ExtensionPoint tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `extensionpoint/ExtensionPointOperationsTest.res` | `ReventlessCore.ExtensionPoint_Operations` | `applyCommandAction`: `AbstractPublishAggregateCommand` dispatches to correct aggregate publisher; `AbstractPublishExtensionPointCommand` calls extension point publisher; `AbstractCall` invokes callback; unknown aggregate name throws |
| `extensionpoint/ExtensionPointCallbackTest.res` | `ReventlessCore.ExtensionPoint_Callback` | `handleIncomingCommands` loop: decodes command from topic item → calls mapping → calls `applyCommandAction`; returns `Ok(reference)` per item; batch of two items both resolved; storage or dispatch failure returns `Error(reference)` |

#### QueryDb tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `querydb/QueryDbOperationsTest.res` | `ReventlessCore.QueryDb_Operations` | `project` applies `Projection.action` variants: `Upsert` saves state, `Delete` removes it, `NoOp` leaves state unchanged; `save` persists encoded JSON; `load` decodes stored JSON |

#### CommandGenerator tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `commandgenerator/CommandGeneratorCallbackTest.res` | `ReventlessCore.CommandGenerator_Callback` | `generateCommand` decodes payload arguments, constructs `commandJson` with correct id and encoded command, calls `publishJsons`; unknown command name returns error |

#### Counter tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `counter/CounterCallbackTest.res` | `ReventlessCore.Counter_Callback` | `addToCounterTarget` increments counter and saves reference; duplicate `targetRef` is deduplicated; `count` operation writes to ReferencesDb and CountsDb |

#### SideEffectHandler tests

| File | Module under test | What is tested |
|------|------------------|----------------|
| `sideeffecthandler/SideEffectHandlerCallbackTest.res` | `ReventlessCore.SideEffectHandler_Callback` | `handleEvents` loop: decodes event from topic → calls `execute` callback with extracted id and payload; batch of events calls execute once per event; execute error does not crash handler |

---

### reventless-in-memory — Adapter unit tests

All files are under `reventless/reventless-in-memory/tests/adapter/`.

These tests verify the in-memory adapter implementations themselves — the modules that sit between the builder and the abstract adapter interface.

| File | Module under test | What is tested |
|------|------------------|----------------|
| `CommandTopicChannelTest.res` | `CommandTopicChannel_InMemory` | `encodeMessage` produces `{id, meta, command}` JSON shape; `decodeId` extracts id string from encoded body, returns `""` for non-object / missing / non-string id; `publishJsons` dispatches each command to the bus with the full encoded body; multiple commands dispatched in order; `connect` registers a bus handler that invokes the runtime `handlerRef`; dispatch with no `handlerRef` set does not crash |
| `CounterHandlerTest.res` | `CounterHandler_InMemory` | `addToCounterTarget` increments counter by target amount; duplicate `targetRef` is deduplicated (idempotent); different `targetRef` values accumulate; `count` writes batch of increments; `reset` clears all in-memory state |
| `DcbEventLogStorageTest.res` | `DcbEventLogStorage_InMemory` | `append` stores events and returns incrementing string position; appending multiple events in one call returns position of last event; `read` with empty query returns all events; `read` filters by `eventType`; `read` filters by `tags`; `read` with `after` parameter skips events at or before that position; `headPosition` equals position of last appended event; `headPosition` is absent when store is empty; conditional `append` returns `Error` when condition query matches existing events; conditional `append` succeeds when condition query matches no events; conditional `append` with `after` only checks events after that position |
| `EventCollectorChannelTest.res` | `EventCollectorChannel_InMemory` | `make` collects all event topic resources as channel resources; empty `eventTopics` dict produces empty resources; `connect` subscribes the `handleEvents` callback to each event topic on the bus; event published to subscribed topic reaches the callback; extra await needed before first publish (one microtask tick for `resource.name.apply` inside connect) |
| `EventTopicPublisherTest.res` | `EventTopicPublisher_InMemory` | `make` returns one resource whose name resolves to the topic name; `publishJson` delivers event to subscriber on the same topic; `publishJson` does not deliver to subscriber on a different topic; multiple subscribers on same topic all receive the event |
| `HeartbeatRunnerTest.res` | `HeartbeatRunner_InMemory` | `connect` sets up an interval that invokes the runtime handler at each tick (verified with Jest fake timers); interval fires exactly once per period advance; `reset` clears all active intervals; no-handler state (handlerRef is None) does not throw |
| `QueryDbStorageTest.res` | `QueryDbStorage_InMemory` | `save` stores state; `load` retrieves by id; `load` returns empty for unknown id; second `save` overwrites previous value for same id; `saveBatch` stores multiple items each loadable by id; `count` returns the increment value; `delete` removes item (subsequent `load` returns empty); `deleteBatch` removes multiple items; scan function (registered on bus) returns all saved items after `save`; scan excludes deleted items after `delete` |
| `QueryEngineTest.res` | `QueryEngine_InMemory` | `query` by id returns items saved in the matching `QueryDbStorage`; `query` with explicit `key` overrides the id parameter; `query` for unknown read model name returns empty array; `scan` returns all items across all stored entries for a named read model |
| `ScheduledPublisherTest.res` | `ScheduledPublisher_InMemory` | `createSchedule` with `Minutes(n)` rate fires event at each interval (fake timers); `createSchedule` with `Single(...)` rate fires once and never again; `deleteSchedule` removes schedule so no event fires after deletion; `reset` clears all active timers |
| `TaskBucketTest.res` | `TaskBucket_InMemory` | `makeHandler` calls callback with `eventName` and `key` extracted from JSON; uses `"ObjectCreated"` default when `eventName` field is absent; returns command array from callback; `make` creates component without throwing (smoke test) |

---

### reventless-in-memory — Builder E2E tests

All files are under `reventless/reventless-in-memory/tests/components/`.

These are integration tests. Each test calls a `_Builder.Make(Bus)` functor, creates a component, resolves its `operations` Output chain, then drives it via the bus or operations directly and observes effects.

| Directory / File | Builder under test | What is tested end-to-end |
|-----------------|-------------------|--------------------------|
| `aggregate/AggregateTest.res` | `InMemory_Bus`, `EventLogStorage_InMemory`, `Aggregate_Builder` | **Part 1 — InMemory_Bus primitives**: `publishEvent` calls all subscribers for a topic; `dispatchCommand` calls the registered handler; `reset` clears all handlers and subscribers. **Part 2 — EventLogStorage_InMemory raw adapter**: `append` stores events and `replay` returns them; `replay` returns empty for unknown id; multiple appends accumulate. **Part 3 — Aggregate E2E**: CreateItem command dispatched via `publishJsons` produces an ItemCreated event on the event topic; duplicate CreateItem for same id produces no events (AlreadyExists decision); CreateItem for a different id produces one event |
| `commandgenerator/CommandGeneratorTest.res` | `CommandGenerator_Builder` | `makeHandler` returns a resolver; invoking it with a `CreateCGItem` payload publishes the correct `commandJson` with id and encoded command fields; `make` creates the component without throwing |
| `commandtopic/CommandTopicTest.res` | `CommandTopic_Builder` | Dispatching a command to the bus channel reaches the wired handler; handler receives correct JSON payload; unregistered channel dispatch is silently ignored |
| `counter/CounterTest.res` | `Counter_Builder` | `addToCounterTarget` increments the in-memory counter by 1; calling with the same `targetRef` twice results in count of 1 (deduplication); calling with different `targetRef` values accumulates to 2; `count` operation writes to the ReferencesDb registered on the bus (verifiable by name lookup) |
| `dcb/DcbTest.res` | `DcbEventLog_Builder`, `StateChangeSlice_Builder` | AddItem command dispatched via `StateChangeSlice` command topic produces 1 event on the DCB event topic; duplicate AddItem for same entity id produces 0 events (ItemAlreadyExists guard); AddItem for a new entity id produces 1 event; direct `ops.read(~query=[])` on the event log returns appended events; `ops.read(~query=[{eventTypes: ["ItemAdded"]}])` returns only matching events |
| `eventcollector/EventCollectorTest.res` | `EventCollector_Builder` | Events published to subscribed topics are delivered to the collector's `handleEvents` callback; collector subscribes to all provided event topic resources; unsubscribed topic is not delivered |
| `eventlog/EventLogTest.res` | `EventLog_Builder` | `append` stores events and `replay` returns them in order; `append` publishes to the event topic (captured subscriber count); `replay` returns empty for unknown id; multiple appends accumulate events in order; separate aggregate ids have independent event logs |
| `eventtopic/EventTopicTest.res` | `EventTopic_Builder` | `publishJson` delivers event to all subscribers on the topic; multiple subscribers all receive the event; non-subscriber topics receive nothing |
| `extensionpoint/ExtensionPointTest.res` | `ExtensionPoint_Builder` | Dispatching a `Forward` command to the EP's CommandTopic channel (`Spec.name ++ "ExtPointCmdTopic"`) calls `publishToAggregates` with an `Execute` command on the target aggregate; the aggregate command id matches the `targetId` from the original command; dispatching to an unknown channel neither throws nor calls `publishToAggregates` |
| `heartbeat/HeartbeatTest.res` | `Heartbeat_Builder` | `makeHandler` returns a handler; `connect` sets up an interval that fires the handler once per 1-minute period (verified with fake timers); two interval advances fire the handler twice; `make` creates the component without throwing |
| `querydb/QueryDbTest.res` | `QueryDb_Builder` | `save` stores state; `load` retrieves it; `saveBatch` stores multiple items; `delete` removes an item; `deleteBatch` removes multiple; `count` increments correctly; `scan` returns all stored items |
| `readmodel/ReadModelTest.res` | `ReadModel_Builder` | Publishing an ItemCreated event to the read model's source event topic causes the event to be projected into QueryDb state (retrieved via `ops.load`); query for unknown id returns empty; multiple events project into independent state entries per id |
| `scheduler/SchedulerTest.res` | `Scheduler_Builder` | `createSchedule` with `Minutes(1)` rate fires a bus event on each 60-second fake-timer advance; `createSchedule` with `Single(...)` fires exactly once (no further fires after); `deleteSchedule` cancels a recurring schedule so no event fires |
| `sideeffecthandler/SideEffectHandlerTest.res` | `SideEffectHandler_Builder` | Publishing an `OrderPlaced` event to the handler's source topic triggers `execute` with the correct aggregate id and order id; multiple events trigger `execute` once per event in order |
| `stateviewslice/StateViewSliceTest.res` | `StateViewSlice_Builder` | Appending an `ItemAdded` event to the DCB event log projects into QueryDb state (name field set correctly); `ItemRenamed` event updates the existing projection; `ItemRemoved` event deletes the projection entry (subsequent load returns empty); multiple items projected independently; query for unknown id returns empty |
| `task/TaskTest.res` | *(placeholder)* | Smoke test only — verifies the test file executes. Real Task adapter tests are in `adapter/TaskBucketTest.res` |

---

## How the two layers complement each other

| Concern | Layer 1 (core unit tests) | Layer 2 (in-memory adapter + E2E) |
|---------|--------------------------|----------------------------------|
| Business logic (decide, reduce, project) | ✅ Direct, fast, no infrastructure | ✅ Covered transitively via E2E |
| Encoding / round-trip correctness | ✅ Explicit round-trip tests | ✅ Implicitly exercised |
| Retry on conflict | ✅ Counter-based failure injection | — |
| Adapter contract (storage, publisher) | Mock-based only | ✅ Real in-memory adapter |
| Builder wiring (Output chains, bus subscriptions) | — | ✅ Primary coverage |
| Timer / scheduling behaviour | — | ✅ Fake-timer tests |
| Full pipeline (command → event → projection) | — | ✅ End-to-end |

When adding a new component, write Layer 1 tests first (faster feedback, no bus setup needed), then Layer 2 tests to verify the builder correctly wires everything together.

---

## Adding tests for a new component

1. **Layer 1** — create `reventless-core/tests/<component>/`:
   - `<Component>Fixtures.res` — minimal test spec, mock adapter factory, test data
   - `<Component>OperationsTest.res` — tests for `<Component>_Operations.Make`
   - `<Component>CallbackTest.res` — tests for `<Component>_Callback.Make` (if applicable)

2. **Layer 2 adapter** — create `reventless-in-memory/tests/adapter/<Component>AdapterTest.res`:
   - Test the `<Component>_InMemory` adapter module directly
   - Verify contract: all operations defined in the adapter interface behave correctly

3. **Layer 2 builder** — create `reventless-in-memory/tests/components/<component>/<Component>Test.res`:
   - Use `InMemory_Bus.Make()` + `<Component>_Builder.Make(Bus)`
   - Drive via `ops.publishJsons` or direct `ops` calls; assert on bus state or captured side effects
   - `beforeAllAsync`: resolve Output chain(s) before any test runs
   - Use `jestTest` (native `test` binding), not `testPromise`

See `docs/plans/component-testing-guide.md` for the full pattern guide including mock adapter templates, type annotation gotchas, and test naming conventions.
