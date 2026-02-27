# Component Tests Plan

## Goal

Achieve comprehensive test coverage for all Reventless Core components, with tests organized
under `tests/<component>/` and all shared test helpers unified in `reventless-in-memory`.

---

## Scope

- **Reorganize** existing tests under `tests/<component>/` (no intermediate `components/` folder)
- **Dissolve** `test-helper/` in `reventless-core` — merge into `tests/`
- **Unify** shared test helpers and mock factories in `reventless-in-memory`
- **Add** tests for currently untested components

---

## Structural Constraint: Two Test Homes

`reventless-in-memory` depends on `reventless-core`. The reverse is not possible — adding that
dependency would be circular. This means:

| Test type | Location |
|-----------|----------|
| Pure unit tests (logic, no infrastructure) | `reventless/reventless-core/tests/<component>/` |
| Integration tests (need in-memory adapters) | `reventless/reventless-in-memory/tests/components/<component>/` |

---

## Phase 1 — Reorganize Existing Tests

### 1.1 reventless-core: flatten `tests/<component>/`

Current tests already sit in `tests/dcb/` and `tests/plugin/`. Move the top-level loose files
into component-named folders for consistency:

| Current | New |
|---------|-----|
| `tests/MessageTest.res` | `tests/message/MessageTest.res` |
| `tests/LoggerTest.res` | `tests/logger/LoggerTest.res` |
| `tests/FTPTest.res` | `tests/ftp/FTPTest.res` |
| `tests/StructuralSubtypingPoc.res` | `tests/poc/StructuralSubtypingPoc.res` |
| `tests/dcb/` | unchanged |
| `tests/plugin/` | unchanged |

**Action**: `git mv` each loose file into its component folder. No `rescript.json` change
needed — `tests/` is already declared with `"subdirs": true`.

### 1.2 reventless-in-memory: rename `tests/E2E/` → `tests/components/` and drop "E2E" suffix

| Current | New |
|---------|-----|
| `tests/E2E/aggregate/AggregateE2EFixtures.res` | `tests/components/aggregate/AggregateFixtures.res` |
| `tests/E2E/aggregate/AggregateE2ETest.res` | `tests/components/aggregate/AggregateTest.res` |
| `tests/E2E/readmodel/ReadModelE2EFixtures.res` | `tests/components/readmodel/ReadModelFixtures.res` |
| `tests/E2E/readmodel/ReadModelE2ETest.res` | `tests/components/readmodel/ReadModelTest.res` |
| `tests/E2E/dcb/DcbE2EFixtures.res` | `tests/components/dcb/DcbFixtures.res` |
| `tests/E2E/dcb/DcbE2ETest.res` | `tests/components/dcb/DcbTest.res` |
| `tests/E2E/counter/CounterE2EFixtures.res` | `tests/components/counter/CounterFixtures.res` |
| `tests/E2E/counter/CounterE2ETest.res` | `tests/components/counter/CounterTest.res` |
| `tests/E2E/stateviewslice/StateViewSliceE2EFixtures.res` | `tests/components/stateviewslice/StateViewSliceFixtures.res` |
| `tests/E2E/stateviewslice/StateViewSliceE2ETest.res` | `tests/components/stateviewslice/StateViewSliceTest.res` |

**Action**: `git mv tests/E2E tests/components`, then rename individual files with `git mv`.

No `rescript.json` change needed.

---

## Phase 2 — Dissolve `test-helper/` into `tests/`

### Why not remove the helpers entirely?

`reventless-core` cannot depend on `reventless-in-memory` (circular), so its own tests
(`PluginBehaviorTest`, `PluginProjectionTest`, `PluginFixtures`) need `BehaviorTest`,
`ProjectionTest`, and `TestFixtures` to be compiled as part of the `reventless-core` package.

Moving the helpers to `reventless-in-memory` is impossible for the same reason.

### Solution: merge into `tests/`

Rather than a separate `test-helper/` directory and source entry, place the helper files
directly at `tests/` root. Since `tests/` already has `"subdirs": true`, the ReScript compiler
picks them up. They remain part of the `ReventlessCore` namespace and are still reachable as
`ReventlessCore.TestFixtures`, `ReventlessCore.AsyncTest` etc.

| Current | New |
|---------|-----|
| `test-helper/AsyncTest.res` | `tests/AsyncTest.res` |
| `test-helper/BehaviorTest.res` | `tests/BehaviorTest.res` |
| `test-helper/EventMappingTest.res` | `tests/EventMappingTest.res` |
| `test-helper/ProjectionTest.res` | `tests/ProjectionTest.res` |
| `test-helper/TestFixtures.res` | `tests/TestFixtures.res` |

**Actions**:
1. `git mv test-helper/AsyncTest.res tests/AsyncTest.res` (and same for each file)
2. Remove the `test-helper` source entry from `rescript.json`
3. Delete the now-empty `test-helper/` directory (remove `.gitkeep` too)

### Eliminate duplicated `AsyncTest.res` in reventless-in-memory

After the move, `reventless-in-memory/src/test/AsyncTest.res` is still a verbatim copy.
Replace it with a re-export:

```rescript
// Re-export AsyncTest from reventless-core — no duplication.
include ReventlessCore.AsyncTest
```

All callers in `reventless-in-memory` already reference `AsyncTest` in the local namespace,
so no call site changes are needed.

### `BehaviorTest.res` and `ProjectionTest.res`: two versions are intentional

The `reventless-core` versions reference `ReventlessCore.Behavior.T` and `ReventlessCore.Message`.
The `reventless-in-memory` versions reference `Reventless.Behavior.T` and `Reventless.Handler`.
These serve different dependency graphs and are both needed. No deduplication.

---

## Phase 3 — Add Shared Mock Factories

Currently, each fixture file defines mock storage inline. Extract the reusable patterns into
named modules under `reventless-in-memory/src/test/Mocks/`:

**`Mocks/MockEventLogStorage.res`**
In-memory event log conforming to `ReventlessCore.EventLog_Adapter.storage`.
Wraps `EventLogStorage_InMemory` with `reset()` and `failNextAppends: ref<int>`.

**`Mocks/MockDcbEventLogStorage.res`**
DCB event log mock conforming to `ReventlessCore.DcbEventLog_Adapter.storage`.
Extracted and parameterized from `DcbFixtures.makeMockStorage`.

**`Mocks/MockQueryDbStorage.res`**
In-memory query DB conforming to `ReventlessCore.QueryDb_Adapter.storage`.
Wraps `QueryDbStorage_InMemory` with `reset()` and `failNextWrites: ref<int>`.

**`Mocks/MockPublisher.res`**
Captures `publishJson` calls for assertion.
Returns `{publishJson, publishedMessages: ref<...>, reset}`.

After creating these, update any fixture file that inlined the same logic to use the shared module.

---

## Phase 4 — Add Missing Component Tests

### Component test inventory

| Component | Unit test (reventless-core) | Integration test (reventless-in-memory) | Status |
|-----------|-----------------------------|-----------------------------------------|--------|
| `Message` | `tests/message/MessageTest.res` | — | exists → reorganize |
| `Plugin` | `tests/plugin/PluginBehaviorTest.res` | — | exists → reorganize |
| `Plugin` | `tests/plugin/PluginProjectionTest.res` | — | exists → reorganize |
| `DcbEventLog` | `tests/dcb/DcbEventLogOperationsTest.res` | `tests/components/dcb/DcbTest.res` | exists → reorganize |
| `StateChangeSlice` | `tests/dcb/DcbStateChangeSliceTest.res` | `tests/components/dcb/DcbTest.res` | exists → reorganize |
| `DcbTag` | `tests/dcb/DcbTagTest.res` | — | exists → reorganize |
| `Aggregate` | — | `tests/components/aggregate/AggregateTest.res` | exists → reorganize |
| `ReadModel` | — | `tests/components/readmodel/ReadModelTest.res` | exists → reorganize |
| `Counter` | — | `tests/components/counter/CounterTest.res` | exists → reorganize |
| `StateViewSlice` | — | `tests/components/stateviewslice/StateViewSliceTest.res` | placeholder → implement |
| `EventLog` | `tests/eventlog/EventLogOperationsTest.res` | `tests/components/eventlog/EventLogTest.res` | **missing → add** |
| `CommandTopic` | `tests/commandtopic/CommandTopicOperationsTest.res` | `tests/components/commandtopic/CommandTopicTest.res` | **missing → add** |
| `EventTopic` | `tests/eventtopic/EventTopicOperationsTest.res` | `tests/components/eventtopic/EventTopicTest.res` | **missing → add** |
| `EventCollector` | — | `tests/components/eventcollector/EventCollectorTest.res` | **missing → add** |
| `EventMapper` | `tests/eventmapper/EventMapperTest.res` | — | **missing → add** |
| `QueryDb` | `tests/querydb/QueryDbOperationsTest.res` | `tests/components/querydb/QueryDbTest.res` | **missing → add** |
| `CommandGenerator` | — | `tests/components/commandgenerator/CommandGeneratorTest.res` | **missing → add** |
| `Scheduler` | — | `tests/components/scheduler/SchedulerTest.res` | **missing → add** |
| `Heartbeat` | — | `tests/components/heartbeat/HeartbeatTest.res` | **missing → add** (adapter tested) |
| `Task` | — | `tests/components/task/TaskTest.res` | **missing → add** |
| `ExtensionPoint` | `tests/extensionpoint/ExtensionPointOperationsTest.res` | `tests/components/extensionpoint/ExtensionPointTest.res` | **missing → add** |
| `SideEffectHandler` | — | `tests/components/sideeffecthandler/SideEffectHandlerTest.res` | **missing → add** |

### Priority order for new tests

1. **StateViewSlice** — placeholder exists; complete the implementation test
2. **EventLog** — central to all event-sourced components
3. **CommandTopic / EventTopic** — messaging backbone
4. **QueryDb / EventCollector** — read-side infrastructure
5. **EventMapper** — pure mapping logic (simplest)
6. **Scheduler / Heartbeat / Task** — adapters already tested; wire up builders
7. **CommandGenerator / ExtensionPoint / SideEffectHandler** — lower priority

### Test file structure per component

```
<component>/
├── <Component>Fixtures.res         # Spec modules, mock wiring, test data
├── <Component>CallbackTest.res     # Callback handler logic (where logic is non-trivial)
└── <Component>Test.res             # Operations + builder wiring
```

A separate `CallbackTest.res` is warranted only when the `*_Callback.res` source contains
meaningful business logic (not just a thin dispatch wrapper).

---

## File structure after completion

### reventless/reventless-core/

```
tests/
├── AsyncTest.res              (moved from test-helper/)
├── BehaviorTest.res           (moved from test-helper/)
├── EventMappingTest.res       (moved from test-helper/)
├── ProjectionTest.res         (moved from test-helper/)
├── TestFixtures.res           (moved from test-helper/)
├── message/
│   └── MessageTest.res
├── logger/
│   └── LoggerTest.res
├── plugin/
│   ├── PluginFixtures.res
│   ├── PluginBehaviorTest.res
│   └── PluginProjectionTest.res
├── dcb/
│   ├── DcbFixtures.res
│   ├── DcbTagTest.res
│   ├── DcbEventLogOperationsTest.res
│   └── DcbStateChangeSliceTest.res
├── eventlog/
│   ├── EventLogFixtures.res
│   └── EventLogOperationsTest.res
├── commandtopic/
│   ├── CommandTopicFixtures.res
│   └── CommandTopicOperationsTest.res
├── eventtopic/
│   ├── EventTopicFixtures.res
│   └── EventTopicOperationsTest.res
├── eventmapper/
│   ├── EventMapperFixtures.res
│   └── EventMapperTest.res
├── querydb/
│   ├── QueryDbFixtures.res
│   └── QueryDbOperationsTest.res
└── extensionpoint/
    ├── ExtensionPointFixtures.res
    └── ExtensionPointOperationsTest.res
```

### reventless/reventless-in-memory/

```
src/test/
├── AsyncTest.res              (re-exports ReventlessCore.AsyncTest)
├── BehaviorTest.res           (unchanged)
├── ProjectionTest.res         (unchanged)
├── TestRunner.res             (unchanged)
└── Mocks/
    ├── MockEventLogStorage.res
    ├── MockDcbEventLogStorage.res
    ├── MockQueryDbStorage.res
    └── MockPublisher.res

tests/
├── adapter/                   (unchanged — 10 existing adapter tests)
└── components/
    ├── aggregate/
    │   ├── AggregateFixtures.res
    │   └── AggregateTest.res
    ├── readmodel/
    │   ├── ReadModelFixtures.res
    │   └── ReadModelTest.res
    ├── dcb/
    │   ├── DcbFixtures.res
    │   └── DcbTest.res
    ├── counter/
    │   ├── CounterFixtures.res
    │   └── CounterTest.res
    ├── stateviewslice/
    │   ├── StateViewSliceFixtures.res
    │   └── StateViewSliceTest.res
    ├── eventlog/
    │   ├── EventLogFixtures.res
    │   └── EventLogTest.res
    ├── commandtopic/
    │   ├── CommandTopicFixtures.res
    │   └── CommandTopicTest.res
    ├── eventtopic/
    │   ├── EventTopicFixtures.res
    │   └── EventTopicTest.res
    ├── eventcollector/
    │   ├── EventCollectorFixtures.res
    │   └── EventCollectorTest.res
    ├── querydb/
    │   ├── QueryDbFixtures.res
    │   └── QueryDbTest.res
    ├── commandgenerator/
    │   ├── CommandGeneratorFixtures.res
    │   └── CommandGeneratorTest.res
    ├── scheduler/
    │   ├── SchedulerFixtures.res
    │   └── SchedulerTest.res
    ├── heartbeat/
    │   ├── HeartbeatFixtures.res
    │   └── HeartbeatTest.res
    ├── task/
    │   ├── TaskFixtures.res
    │   └── TaskTest.res
    ├── extensionpoint/
    │   ├── ExtensionPointFixtures.res
    │   └── ExtensionPointTest.res
    └── sideeffecthandler/
        ├── SideEffectHandlerFixtures.res
        └── SideEffectHandlerTest.res
```

---

## Phase 5 — Callback Tests

The `*_Callback.res` files contain runtime handler logic and were not covered in Phase 4.
There are 12 callback modules; not all warrant dedicated test files.

### Callback module assessment

| Callback | Logic | Test file | Location |
|----------|-------|-----------|----------|
| `Aggregate_Callback` | **High**: groups by ID, replays event log, runs `create`/`execute`, appends events, handles append failures | `tests/aggregate/AggregateCallbackTest.res` | reventless-core — **add** |
| `StateChangeSlice_Callback` | **High**: read/reduce/decide/append with retry | already covered by `tests/dcb/DcbStateChangeSliceTest.res` | — |
| `EventMapper_Callback` | **High**: action splitting (Publisher vs Counter), `MakeCounterHandler` and `MakeEventCollectorHandler`, async dispatch, `doCount` retry loop | `tests/eventmapper/EventMapperCallbackTest.res` | reventless-core — **add** |
| `Counter_Callback` | **Medium**: `groupByCounterId`, zero-crossing detection, calls `counterEventsHandler` | `tests/counter/CounterCallbackTest.res` | reventless-core — **add** |
| `ReadModel_Callback` | **Low**: decodes event JSONs, runs projection mapper, calls `handleActions` — thin wrapper | cover in `tests/plugin/PluginProjectionTest.res` (already exercises this path) | — |
| `CommandTopic_Callback` | **Low**: decodes JSON commands, dispatches to typed handler — thin JSON decode wrapper | cover in `tests/commandtopic/CommandTopicTest.res` | — |
| `Heartbeat_Callback` | **Low**: forwards heartbeat events | cover in `tests/components/heartbeat/HeartbeatTest.res` | — |
| `SideEffectHandler_Callback` | **Medium**: `findSideEffect` by source name, decodes id + event, calls `SideEffect.execute`, try/catch per event | `tests/sideeffecthandler/SideEffectHandlerCallbackTest.res` | reventless-core — **add** |
| `ExtensionPoint_Callback` | **High**: `mapIncomingCommands` across all registered mappings, `applyCommandAction` routes `AbstractPublishCommand` to aggregate or `AbstractCall` to handler, error handling per action | `tests/extensionpoint/ExtensionPointCallbackTest.res` | reventless-core — **add** |
| `CommandGenerator_Callback` | **Medium-High**: extracts params via `Dict.slice(~start=1)`, builds plain-string vs TAG-object command JSON, validates against `commandSchema`, publishes and returns `msgId` | `tests/commandgenerator/CommandGeneratorCallbackTest.res` | reventless-core — **add** |
| `Plugin_Callback` | **Medium**: routes events across 4 handler dicts, `detectUnhandledEvent` | cover in `tests/plugin/PluginBehaviorTest.res` — existing test exercises this path | — |
| `StateViewSlice_Callback` | **Low**: maps events through `Spec.project`, calls `handleActions` — thin projection wrapper | cover in `tests/components/stateviewslice/StateViewSliceTest.res` | — |

### What to test in each dedicated callback file

**`AggregateCallbackTest.res`** — mock `EventLog.operations` (replay + append):
- `handleCommands`: single command → event appended, reference returned `Ok`
- `handleCommands`: command on existing aggregate replays history correctly
- `handleCommands`: multiple commands for same ID processed sequentially (state accumulates)
- `handleCommands`: commands for different IDs processed independently
- `handleCommands`: behavior returns no events → no append, reference still `Ok`
- `handleCommands`: `eventLog.append` fails → reference returned `Error`
- `handleCommands`: `Behavior.execute` throws `InvalidEvent` → caught, no events appended

**`EventMapperCallbackTest.res`** — mock `publishJsons` and `queryEngine`:
- `MakeCounterHandler.handleCounterEvents`: event with matching mapping → publishes command JSON
- `MakeCounterHandler.handleCounterEvents`: event with no matching source → skipped (no publish)
- `MakeCounterHandler.handleCounterEvents`: invalid event JSON → skipped gracefully
- `MakeEventCollectorHandler.handleJsonEvents`: Count action → calls `count`
- `MakeEventCollectorHandler.handleJsonEvents`: AddToCounterTarget action → calls `addToCounterTarget`
- `MakeEventCollectorHandler.handleJsonEvents`: Publisher action → publishes command
- `MakeEventCollectorHandler.handleJsonEvents`: mixed actions → both publish and count called
- `doCount` retry: `count` throws → retries until success

**`CounterCallbackTest.res`** — mock `countsDbCount` and `counterEventsHandler`:
- `groupByCounterId`: groups multiple references by counter ID, sums increments
- `counterHandler`: count reaches zero → `CountFinished` event dispatched via `counterEventsHandler`
- `counterHandler`: count above zero → no `CountFinished` event, decrements DB
- `counterHandler`: multiple counters in one batch → each decremented independently

**`ExtensionPointCallbackTest.res`** — mock `publishToAggregates`, `scheduler`, `queryEngine`:
- `handleIncomingCommands`: `AbstractPublishCommand` → dispatches to correct aggregate's `publishJsons`
- `handleIncomingCommands`: `AbstractPublishCommand` for unknown aggregate → throws
- `handleIncomingCommands`: `AbstractCall` → handler called, `Ok(reference)` returned
- `handleIncomingCommands`: `AbstractCall` handler throws → `Error(reference)` returned
- `handleIncomingCommands`: multiple mappings, mixed actions → all resolved correctly

**`CommandGeneratorCallbackTest.res`** — mock `publishJsons`, provide a minimal `Behavior`:
- `generateCommand`: zero-param command (no extra params) → command JSON is plain string
- `generateCommand`: multi-param command → command JSON is `{TAG, param1, param2, ...}`
- `generateCommand`: valid command → `publishJsons` called with correct `{id, meta, commandJson}`
- `generateCommand`: meta has correct `msgId === correlationId`, `service === AggregateSpec.name`
- `generateCommand`: command fails schema validation → throws with descriptive error
- `generateCommand`: returns `msgId` string on success

**`SideEffectHandlerCallbackTest.res`** — mock `SideEffect.execute` and `queryEngine`:
- `eventsHandler`: event matching a registered side effect → `execute` called with decoded id + event
- `eventsHandler`: event with no matching source name → `execute` not called, no error
- `eventsHandler`: event with malformed JSON → caught gracefully, does not throw
- `eventsHandler`: `execute` throws → caught per-event, other events still processed
- `eventsHandler`: multiple events in batch → each handled independently

### Updated file structure additions (reventless-core/tests/)

```
tests/
├── aggregate/
│   ├── AggregateFixtures.res           (new)
│   └── AggregateCallbackTest.res       (new)
├── counter/
│   ├── CounterFixtures.res             (new)
│   └── CounterCallbackTest.res         (new)
├── eventmapper/
│   ├── EventMapperFixtures.res         (new)
│   ├── EventMapperTest.res             (new)
│   └── EventMapperCallbackTest.res     (new)
├── extensionpoint/
│   ├── ExtensionPointFixtures.res      (new — replaces placeholder)
│   ├── ExtensionPointOperationsTest.res (replace placeholder)
│   └── ExtensionPointCallbackTest.res  (new)
├── commandgenerator/
│   ├── CommandGeneratorFixtures.res    (new)
│   └── CommandGeneratorCallbackTest.res (new)
└── sideeffecthandler/
    ├── SideEffectHandlerFixtures.res   (new)
    └── SideEffectHandlerCallbackTest.res (new)
```

---

## Phase 6 — Implement Placeholder Tests

Six test files were generated with `expect(true)->toBe(true)` stubs and need real content.
The comment in each explains the original blocker:

| File | Placeholder reason | Action |
|------|--------------------|--------|
| `reventless-core/tests/extensionpoint/ExtensionPointOperationsTest.res` | "requires plugin lifecycle setup" | Implement unit tests for `ExtensionPoint_Operations` (encode/decode, query logic); use mock adapter |
| `reventless-in-memory/tests/components/extensionpoint/ExtensionPointTest.res` | same | Wire up `ExtensionPoint_Builder` with in-memory adapters; test command routing end-to-end |
| `reventless-in-memory/tests/components/sideeffecthandler/SideEffectHandlerTest.res` | generic placeholder | Wire up `SideEffectHandler_Builder`; test event → side-effect execution path |
| `reventless-in-memory/tests/components/heartbeat/HeartbeatTest.res` | "adapter tests cover low-level" | Adapter tests exist; add builder-level test: heartbeat fires → event published to extension point |
| `reventless-in-memory/tests/components/scheduler/SchedulerTest.res` | "adapter tests cover low-level" | Adapter tests exist; add builder-level test: scheduler fires → event published on interval |
| `reventless-in-memory/tests/components/commandgenerator/CommandGeneratorTest.res` | "requires GraphQL server setup" | The GraphQL layer is optional; test the builder wiring without GraphQL by calling `generateCommand` directly via `TestRunner.resolve` |

## Phase 7 — Remaining Placeholders

After Phase 6, two placeholders remained:

| File | Placeholder reason | Resolution |
|------|--------------------|------------|
| `reventless-core/tests/extensionpoint/ExtensionPointOperationsTest.res` | "requires plugin lifecycle setup" | Implemented unit tests for `ExtensionPoint_Operations.Make.outgoingEventHandler`; covers AbstractPublishEvent, AbstractCall, AbstractPublishEventAsync, and unknown-aggregate error path |
| `reventless-in-memory/tests/components/task/TaskTest.res` | "adapter-level tests are in TaskBucketTest.res" | Fixed `TaskBucket_InMemory.make` to return a dummy resource (was `[]`, which caused `Array.getUnsafe(0)` to throw in `Task_Builder`); implemented builder integration tests for component creation and output structure |

### Notes on Phase 7 implementation

**ExtensionPointOperationsTest.res**: The operations module handles OUTGOING events from aggregates to the EP.
Tests exercise `outgoingEventHandler` with inline mock mappings that return each action type.
The "missing mapping" error path is also tested.

**TaskTest.res + TaskBucket_InMemory fix**: The task builder calls `(bucket.resources->Array.getUnsafe(0)).id`
unconditionally when `config.buckets` is present. `TaskBucket_InMemory.make` previously returned `{resources: []}`,
making it impossible to create a task with buckets in tests. The fix adds one dummy resource.
`TaskBucketTest.res` was updated to reflect the new expected resource count (1 instead of 0).

The callback-to-`publishToAggregates` path cannot be tested end-to-end from outside the builder because
`TaskRuntime_Builder_PerBucket.forBucketCallback` creates the runtime locally and `TaskBucket_InMemory.connect`
is a no-op. This path is covered at the unit level by `TaskBucketTest.res` (handler extraction)
and `Task_Builder.Make` (wiring).

---

## Implementation steps

- [x] **1a** `git mv` loose files in `reventless-core/tests/` into component subfolders
- [x] **1b** `git mv tests/E2E tests/components` in `reventless-in-memory`
- [x] **1c** Rename each `*E2E*.res` file to drop the "E2E" segment (fixtures + test files)
- [x] **1d** Verify `npm test` passes in both packages after the moves
- [x] **2a** `git mv` each `test-helper/*.res` → `tests/*.res` in `reventless-core`
- [x] **2b** Remove `test-helper` source entry from `reventless-core/rescript.json`; delete empty dir
- [x] **2c** Replace `reventless-in-memory/src/test/AsyncTest.res` with `include ReventlessCore.AsyncTest`
- [x] **2d** Build and test both packages
- [x] **3a** Create `src/test/Mocks/MockEventLogStorage.res`
- [x] **3b** Create `src/test/Mocks/MockDcbEventLogStorage.res` (extract from `DcbFixtures.res`)
- [x] **3c** Create `src/test/Mocks/MockQueryDbStorage.res`
- [x] **3d** Create `src/test/Mocks/MockPublisher.res`
- [x] **3e** Update fixture files that inlined those mocks to use the shared ones; build + test
- [x] **4a** Complete `StateViewSlice` integration test (placeholder exists)
- [x] **4b** Add `EventLog` unit + integration tests
- [x] **4c** Add `CommandTopic` / `EventTopic` unit + integration tests
- [x] **4d** Add `EventCollector` / `QueryDb` / `EventMapper` tests
- [x] **4e** Add `Scheduler` / `Heartbeat` / `Task` integration tests
- [x] **4f** Add `CommandGenerator` / `ExtensionPoint` / `SideEffectHandler` tests
- [x] **Final (Phase 4)** `npm test` across all packages; confirm no regressions
  - reventless-core: 131 tests, 13 suites — all pass
  - reventless-in-memory: 118 tests, 26 suites — all pass
- [x] **5a** Add `tests/aggregate/AggregateFixtures.res` + `AggregateCallbackTest.res`
- [x] **5b** Add `tests/eventmapper/EventMapperFixtures.res` + `EventMapperTest.res` + `EventMapperCallbackTest.res`
- [x] **5c** Add `tests/counter/CounterFixtures.res` + `CounterCallbackTest.res`
- [x] **5d** Add `tests/extensionpoint/ExtensionPointCallbackTest.res` (replace placeholder `ExtensionPointOperationsTest.res`)
- [x] **5e** Add `tests/commandgenerator/CommandGeneratorFixtures.res` + `CommandGeneratorCallbackTest.res`
- [x] **5f** Add `tests/sideeffecthandler/SideEffectHandlerFixtures.res` + `SideEffectHandlerCallbackTest.res`
- [x] **5g** `npm test` in reventless-core; 48 tests, 5 suites — all pass
- [x] **6a** Implement `tests/components/extensionpoint/ExtensionPointTest.res` (replace placeholder)
- [x] **6b** Implement `tests/components/sideeffecthandler/SideEffectHandlerTest.res` (replace placeholder)
- [x] **6c** Implement `tests/components/heartbeat/HeartbeatTest.res` (replace placeholder)
- [x] **6d** Implement `tests/components/scheduler/SchedulerTest.res` (replace placeholder)
- [x] **6e** Implement `tests/components/commandgenerator/CommandGeneratorTest.res` (replace placeholder)
- [x] **6f** `npm test` in reventless-in-memory; 125 tests, 26 suites — all pass
- [x] **7a** Implement `tests/extensionpoint/ExtensionPointOperationsTest.res` (reventless-core) — covers AbstractPublishEvent, AbstractCall, AbstractPublishEventAsync, unknown-aggregate error
- [x] **7b** Fix `TaskBucket_InMemory.make` to return a dummy resource; update `TaskBucketTest.res` expected count
- [x] **7c** Implement `tests/components/task/TaskTest.res` + `TaskFixtures.res` — covers component creation, output name, bucketNames structure, and bucket id resolution
- [x] **Final (Phase 7)** `npm test` across both packages; no regressions
  - reventless-core: 172 tests, 19 suites — all pass
  - reventless-in-memory: 129 tests, 26 suites — all pass

---

## Key gotchas to remember

- `git mv` preserves history; plain `mv` does not — always use `git mv` for tracked files
- `AsyncTest.res` in `reventless-in-memory` is a verbatim copy — replace with `include`
- `BehaviorTest` exists in two packages with different `Behavior.T` module paths — both intentional
- Module sealing with `: ModuleType` breaks type identity at call sites — leave spec annotations off
- DCB tags need `@s.matches(DcbTag.string)` on the **type expression** (after colon), not on field name
- `Array.getUnsafe(n).field` must use an intermediate `let` binding (ReScript parse issue)
- Integration tests need `beforeAllAsync` to resolve `Output` chains before tests run
- `testPromise` from `@glennsl/rescript-jest` is broken for async — always use `AsyncTest.testPromise`
