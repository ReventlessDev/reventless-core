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
├── <Component>Fixtures.res    # Spec modules, mock wiring, test data
└── <Component>Test.res        # All test cases for this component
```

For components with meaningfully different pure-logic and integration tests:

```
<component>/
├── <Component>Fixtures.res
├── <Component>OperationsTest.res   # Pure logic (sync or async with mocks)
└── <Component>Test.res             # Builder wiring + in-memory run-through
```

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
- [x] **Final** `npm test` across all packages; confirm no regressions
  - reventless-core: 131 tests, 13 suites — all pass
  - reventless-in-memory: 118 tests, 26 suites — all pass

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
