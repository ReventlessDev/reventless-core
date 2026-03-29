# Plan: Deploy-Time vs Runtime Separation (Option D — Hybrid)

**Analysis**: [docs/analysis/done/deploy-runtime-separation.md](../analysis/done/deploy-runtime-separation.md)

## Overview

Make the deploy-time / runtime boundary explicit and consistent across all three adapter packages:
1. Rename `Runtime/` folders to `RuntimeBuilder/` (all three packages)
2. Rename `Scheduler/` to `ScheduledPublisher/` in in-memory (match AWS)
3. Split mixed in-memory adapter files into deploy + `_Runtime` pairs
4. Consolidate scattered GraphQL files in in-memory

## Step 1: Rename `Runtime/` to `RuntimeBuilder/` — base adapter (reventless-core)

**Why**: The `Runtime/` folder contains deploy-time orchestration builders, not runtime code. The name is misleading.

**Files to move** (all under `reventless/reventless-core/src/adapter/`):

| From | To |
|------|-----|
| `Runtime/Runtime.res` | `RuntimeBuilder/Runtime.res` |
| `Runtime/AggregateRuntime_Builder.res` | `RuntimeBuilder/AggregateRuntime_Builder.res` |
| `Runtime/AggregateRuntime_Builder_Common.res` | `RuntimeBuilder/AggregateRuntime_Builder_Common.res` |
| `Runtime/AggregateRuntime_Builder_Single.res` | `RuntimeBuilder/AggregateRuntime_Builder_Single.res` |
| `Runtime/AggregateRuntime_Builder_Micro.res` | `RuntimeBuilder/AggregateRuntime_Builder_Micro.res` |
| `Runtime/AggregateRuntime_Builder_PerAggregate.res` | `RuntimeBuilder/AggregateRuntime_Builder_PerAggregate.res` |
| `Runtime/EventCollectorRuntime_Builder.res` | `RuntimeBuilder/EventCollectorRuntime_Builder.res` |
| `Runtime/EventCollectorRuntime_Builder_Single.res` | `RuntimeBuilder/EventCollectorRuntime_Builder_Single.res` |
| `Runtime/EventCollectorRuntime_Builder_PerEventCollector.res` | `RuntimeBuilder/EventCollectorRuntime_Builder_PerEventCollector.res` |
| `Runtime/ExtensionPointRuntime_Builder.res` | `RuntimeBuilder/ExtensionPointRuntime_Builder.res` |
| `Runtime/ExtensionPointRuntime_Builder_PerExtensionPoint.res` | `RuntimeBuilder/ExtensionPointRuntime_Builder_PerExtensionPoint.res` |
| `Runtime/PluginRuntime_Builder.res` | `RuntimeBuilder/PluginRuntime_Builder.res` |
| `Runtime/PluginRuntime_Builder_Single.res` | `RuntimeBuilder/PluginRuntime_Builder_Single.res` |
| `Runtime/PluginRuntime_Builder_Micro.res` | `RuntimeBuilder/PluginRuntime_Builder_Micro.res` |
| `Runtime/TaskRuntime_Builder.res` | `RuntimeBuilder/TaskRuntime_Builder.res` |
| `Runtime/TaskRuntime_Builder_PerBucket.res` | `RuntimeBuilder/TaskRuntime_Builder_PerBucket.res` |

**Impact**: ReScript resolves modules by name, not path — folder renames don't affect imports. Only `rescript.json` `sources` entries need updating if the folder is listed explicitly. Verify by building.

- [ ] Create `RuntimeBuilder/` folder
- [ ] `git mv` all files
- [ ] Update `rescript.json` sources if folder is referenced
- [ ] Build and verify no breakage

## Step 2: Rename `Runtime/` to `RuntimeBuilder/` — AWS adapter

**Files to move** (under `reventless/reventless-aws/src/adapter/`):

| From | To |
|------|-----|
| `Runtime/RuntimeEnvironment.res` | `RuntimeBuilder/RuntimeEnvironment.res` |
| `Runtime/RuntimeEnvironment_Lambda.res` | `RuntimeBuilder/RuntimeEnvironment_Lambda.res` |

- [ ] Create `RuntimeBuilder/` folder
- [ ] `git mv` both files
- [ ] Update `rescript.json` sources if needed
- [ ] Build and verify

## Step 3: Rename `Runtime/` to `RuntimeBuilder/` — in-memory adapter

**Files to move** (under `reventless/reventless-in-memory/src/adapter/`):

| From | To |
|------|-----|
| `Runtime/RuntimeEnvironment_InMemory.res` | `RuntimeBuilder/RuntimeEnvironment_InMemory.res` |
| `Runtime/AggregateRuntime_Builder_InMemory.res` | `RuntimeBuilder/AggregateRuntime_Builder_InMemory.res` |
| `Runtime/EventCollectorRuntime_Builder_InMemory.res` | `RuntimeBuilder/EventCollectorRuntime_Builder_InMemory.res` |
| `Runtime/PluginRuntime_Builder_InMemory.res` | `RuntimeBuilder/PluginRuntime_Builder_InMemory.res` |

- [ ] Create `RuntimeBuilder/` folder
- [ ] `git mv` all files
- [ ] Update `rescript.json` sources if needed
- [ ] Build and verify

## Step 4: Rename `Scheduler/` to `ScheduledPublisher/` — in-memory adapter

**Why**: AWS uses `ScheduledPublisher/`, in-memory uses `Scheduler/`. Standardize on `ScheduledPublisher/`.

**File to move** (under `reventless/reventless-in-memory/src/adapter/`):

| From | To |
|------|-----|
| `Scheduler/ScheduledPublisher_InMemory.res` | `ScheduledPublisher/ScheduledPublisher_InMemory.res` |

- [ ] Create `ScheduledPublisher/` folder
- [ ] `git mv` the file
- [ ] Build and verify (module name unchanged, no import changes needed)

## Step 5: Split in-memory mixed files — storage components

Split each mixed file into a deploy-time file (keeps `make` / `Make` functor) and a `_Runtime` file (gets the actual storage operations).

### EventLogStorage_InMemory

**Current**: Single file with `makeStorage` (creates refs + operations) and `make`/`Make(Bus)` (registers with bus).

**Split**:
- `EventLogStorage_InMemory_Runtime.res` — the storage engine: `eventsRef`, `append`, `replay`, `replayStream`, `appendStream`. Exports a `make` function returning the operations record.
- `EventLogStorage_InMemory.res` — deploy-time: calls `Runtime.make()`, wraps in `Pulumi.Output.make`, registers with Bus. Keeps `make` and `Make(Bus)` functions.

- [ ] Create `EventLogStorage_InMemory_Runtime.res` with extracted storage logic
- [ ] Update `EventLogStorage_InMemory.res` to call the Runtime module
- [ ] Build and run tests

### DcbEventLogStorage_InMemory

**Current**: `matchesQuery`, `makeStorage` (creates refs + read/append logic), `make`/`Make(Bus)`.

**Split**:
- `DcbEventLogStorage_InMemory_Runtime.res` — `matchesQuery`, `posToInt`, ref-based store, `read`, `append`, `readStream`. Exports a `make` returning the operations.
- `DcbEventLogStorage_InMemory.res` — deploy-time: calls `Runtime.make()`, wraps in Output, registers with Bus.

- [ ] Create `DcbEventLogStorage_InMemory_Runtime.res`
- [ ] Update `DcbEventLogStorage_InMemory.res`
- [ ] Build and run tests

### QueryDbStorage_InMemory

**Current**: `Make(Bus)` functor with inline `store` ref, all CRUD operations, Bus registration.

**Split**:
- `QueryDbStorage_InMemory_Runtime.res` — `store` ref, `syncAll`, `load`, `loadStream`, `save`, `saveBatch`, `count`, `delete`, `deleteBatch`. Exports a `make` returning `(ops, scanFn, streamFn)`.
- `QueryDbStorage_InMemory.res` — `Make(Bus)` functor: calls `Runtime.make()`, registers with Bus, wraps in Output.

- [ ] Create `QueryDbStorage_InMemory_Runtime.res`
- [ ] Update `QueryDbStorage_InMemory.res`
- [ ] Build and run tests

### TaskBucket_InMemory

**Current**: `connect`, `makeHandler`, `make` — all in one file. `makeHandler` is runtime (callback logic), `make` is deploy-time (creates resources).

**Split**:
- `TaskBucket_InMemory_Runtime.res` — `makeHandler` (the callback handler that extracts eventName/key from JSON and calls the bucket callback).
- `TaskBucket_InMemory.res` — `connect`, `make` (deploy-time resource creation). References `TaskBucket_InMemory_Runtime.makeHandler`.

- [ ] Create `TaskBucket_InMemory_Runtime.res`
- [ ] Update `TaskBucket_InMemory.res`
- [ ] Build and run tests

### CounterHandler_InMemory

**Current**: Module-level `counterStore`/`targetRefStore` refs, `make` (returns handler record), `getCount`, `reset`.

**Split**:
- `CounterHandler_InMemory_Runtime.res` — `counterStore`, `targetRefStore`, `addToCounterTarget` logic, `getCount`, `reset`.
- `CounterHandler_InMemory.res` — `make` (deploy-time: calls Runtime, returns adapter record).

- [ ] Create `CounterHandler_InMemory_Runtime.res`
- [ ] Update `CounterHandler_InMemory.res`
- [ ] Build and run tests

## Step 6: Split in-memory mixed files — channel components

### CommandTopicChannel_InMemory

**Current**: `Make(Bus)` functor with `encodeMessage`, `decodeId` (runtime helpers), and `make` + `connect` (deploy-time).

**Split**:
- `CommandTopicChannel_InMemory_Runtime.res` — `encodeMessage`, `decodeId` (message encoding/decoding utilities used at runtime).
- `CommandTopicChannel_InMemory.res` — `Make(Bus)` with `make` and `connect`. Calls `CommandTopicChannel_InMemory_Runtime.encodeMessage` / `decodeId`.

- [ ] Create `CommandTopicChannel_InMemory_Runtime.res`
- [ ] Update `CommandTopicChannel_InMemory.res`
- [ ] Build and run tests

### CommandTopicRemoteChannel_InMemory

**Current**: `Make(Bus)` functor — small file, `make` returns resources + `remotePublish`. The encoding is inline runtime logic.

**Split**:
- `CommandTopicRemoteChannel_InMemory_Runtime.res` — not needed (reuse `CommandTopicChannel_InMemory_Runtime.encodeMessage`).
- `CommandTopicRemoteChannel_InMemory.res` — update to use shared runtime encoder from `CommandTopicChannel_InMemory_Runtime`.

- [ ] Update `CommandTopicRemoteChannel_InMemory.res` to use shared encoder
- [ ] Build and run tests

### EventTopicPublisher_InMemory

**Current**: `Make(Bus)` functor — `make` creates resources + `publishJson`/`publishJsonStream`. All logic is simple Bus dispatch.

**Decision**: **No split needed.** The "runtime" is just `Bus.publishEvent(name, ...)` — a single expression, not worth extracting. The file is already small (37 lines).

### EventCollectorChannel_InMemory

**Current**: `Make(Bus)` functor — `make` creates channel parts, `connect` sets up stream-based Bus subscription.

**Decision**: **No split needed.** The `connect` function is deploy-time wiring (sets up subscriptions during component build). The actual event handling is done via the `handlerDeferred` pattern which lives in `RuntimeEnvironment_InMemory`. No standalone runtime logic to extract.

## Step 7: Split in-memory mixed files — timer/scheduling components

### HeartbeatRunner_InMemory

**Current**: Timer management (`setIntervalJs`, `activeTimers` ref), `make` (sets up interval), `reset`.

**Split**:
- `HeartbeatRunner_InMemory_Runtime.res` — timer bindings, `activeTimers` ref, interval tick logic, `reset`.
- `HeartbeatRunner_InMemory.res` — `make` (deploy-time: creates runtime timer, returns resources).

- [ ] Create `HeartbeatRunner_InMemory_Runtime.res`
- [ ] Update `HeartbeatRunner_InMemory.res`
- [ ] Build and run tests

### ScheduledPublisher_InMemory

**Current**: `Make(Bus)` functor with timer management, `make` returns operations, `reset`.

**Split**:
- `ScheduledPublisher_InMemory_Runtime.res` — timer bindings, `activeTimers` ref, `rateToMs`, `isSingleShot`, `reset`.
- `ScheduledPublisher_InMemory.res` — `Make(Bus)` with `make` returning operations. References Runtime for timer management.

- [ ] Create `ScheduledPublisher_InMemory_Runtime.res`
- [ ] Update `ScheduledPublisher_InMemory.res`
- [ ] Build and run tests

## Step 8: Review remaining files — no split needed

These files are already correctly categorized and don't need splitting:

| File | Classification | Reason |
|------|---------------|--------|
| `InMemory_Bus.res` | Infrastructure | Shared bus — neither deploy nor runtime, it's the backbone |
| `InMemory_PluginSpec.res` | Deploy-time | Plugin spec configuration |
| `GraphQL_Server.res` | Runtime | Server lifecycle — already pure runtime |
| `MCP_Server.res` | Runtime | MCP server — already pure runtime |
| `SideEffectHandler_InMemory.res` | Deploy-time | Component creation, wraps ops in Output |
| `CommandGeneratorResolvers_InMemory.res` | Deploy-time | No-op resolver (no runtime logic) |
| `CommandGeneratorResolvers_GraphQL.res` | Deploy-time | GraphQL schema setup |
| `DcbCommandTopicResolvers_GraphQL.res` | Deploy-time | GraphQL schema setup |
| `InboundTranslationResolvers_GraphQL.res` | Deploy-time | GraphQL schema setup |
| `QueryDbResolvers_GraphQL.res` | Deploy-time | GraphQL schema setup |
| `QueryEngine_InMemory.res` | Runtime | Pure query logic — already correctly placed |
| `ClonerRunner_InMemory.res` | Deploy-time | No-op (13 lines) |
| `GraphQL_InMemory_Adapter.res` | Deploy-time | API adapter configuration |

## Step 9: Consolidate GraphQL files in in-memory

**Current layout** — GraphQL-related files are scattered:
```
adapter/
  Api/GraphQL_InMemory_Adapter.res
  CommandGenerator/CommandGeneratorResolvers_GraphQL.res
  CommandGenerator/DcbCommandTopicResolvers_GraphQL.res
  CommandGenerator/InboundTranslationResolvers_GraphQL.res
  QueryDb/QueryDbResolvers_GraphQL.res
  GraphQL_Server.res
```

**Decision**: **No move needed.** The GraphQL resolver files are co-located with their parent component (CommandGenerator, QueryDb) which is the correct organizational principle — same as AWS where `CommandGeneratorResolvers_AppSync.res` lives under `CommandGenerator/`. The `GraphQL_Server.res` and `Api/GraphQL_InMemory_Adapter.res` are in-memory-specific infrastructure with no AWS equivalent, so their current locations are fine.

## Step 10: Final verification

- [ ] `npx rescript clean` from monorepo root
- [ ] `npm run build` from monorepo root — zero warnings
- [ ] `npm run test` from `reventless/reventless-in-memory/` — all tests pass
- [ ] Review git diff — confirm only moves and the deploy/runtime split, no logic changes
- [ ] Commit with message: `refactor: separate deploy-time and runtime code in adapter packages`

## Summary of Changes

| Change | Packages affected | Files moved/created |
|--------|-------------------|-------------------|
| Rename `Runtime/` → `RuntimeBuilder/` | all three | ~22 files moved |
| Rename `Scheduler/` → `ScheduledPublisher/` | in-memory | 1 file moved |
| Split storage adapters | in-memory | 5 new `_Runtime` files |
| Split channel adapters | in-memory | 1 new `_Runtime` file |
| Split timer adapters | in-memory | 2 new `_Runtime` files |
| Update remote channel to use shared encoder | in-memory | 1 file edited |

**Total**: ~22 files moved, ~8 new files created, ~10 existing files edited.

## Execution Order

Steps 1-4 (folder renames) are independent of each other and can be done in any order. Steps 5-7 (file splits) depend on step 3 being done first (since RuntimeBuilder rename affects import paths in the split files). Step 10 is the final gate.

Recommended: do all folder renames first (steps 1-4), build to verify, then do all splits (steps 5-7), build to verify, then final check (step 10).
