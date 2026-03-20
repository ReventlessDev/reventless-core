# Plan: Bundled Handler Cleanup

## Goal

Complete the bundled Lambda handler migration by:
1. Unblocking DCB slice Lambdas (`AllStateViewSlices`, `AllAutomationSlices`)
2. Removing dead non-bundled builders that use broken `CallbackFunction` path
3. Dropping the "Bundled" suffix — bundling is now the only viable AWS approach
4. Extracting shared code to reduce duplication
5. Fixing known bugs and inconsistencies

Based on analysis: `docs/analysis/bundled-handler-implementation-review.md`

---

## Step 1: Wire `onDcbSlicesCreated` Hook

**Goal**: Unblock DCB slice Lambda creation.

**Files to modify:**
- `reventless/reventless-aws/src/Platform.res` — replace no-op `onDcbSlicesCreated` hook with calls to `finish()`:
  ```rescript
  let () = ReventlessCore.Plugin_Helpers.onDcbSlicesCreated.contents = Some(
    _dcbEventLogUnknown => {
      StateViewSliceRuntime_Builder_Single_Bundled.finish()
      AutomationSliceRuntime_Builder_Single_Bundled.finish()
    },
  )
  ```

**Files to modify:**
- `examples/online-shop-hybrid/ordering-aws/src/OrderingPlugin_Bundled.res` — switch DCB slices from `Platform.StateViewSlice.Make(Spec)` to bundled builders:
  ```rescript
  module OrdersViewSlice = Platform.StateViewSlice.Bundled.Make(OrderingPlugin.OrdersView, {
    let specModulePath = resolveModule(orderingPkg ++ "/Order/StateViewSlice/OrdersView.res.mjs")
  })
  ```
  Same for `AvailableProductsViewSlice`, `AutoShipOrderSlice`, `SendOrderConfirmationSlice`.

- `examples/online-shop-hybrid/catalog-aws/src/CatalogPlugin_Bundled.res` — same pattern for `ProductsViewSlice`, `ProductDemandViewSlice`.

**Verification**: `npm run build` from root. Deploy to alpha stack — expect 9 Lambdas (7 existing + `AllStateViewSlices` + `AllAutomationSlices`).

---

## Step 2: Fix Bugs

**2a. `SideEffectHandlerWithQueue.res` alias bug**
- File: `reventless/reventless-aws/src/components/SideEffectHandlerWithQueue.res`
- Bug: includes `SideEffectHandler_PerSideEffectHandler` instead of `SideEffectHandlerWithQueue_PerSideEffectHandler`
- Fix: `include SideEffectHandlerWithQueue_PerSideEffectHandler`

**2b. Counter `BundledConfig` field naming**
- File: `reventless/reventless-aws/src/components/Counter_Builder_Bundled.res`
- Bug: uses `targetSpecModulePath` instead of `specModulePath`
- Fix: rename to `specModulePath` for consistency. Update any consumers.

**2c. `Obj.magic` type coercion for Lambda functions**
- File: `reventless/reventless-aws/src/util/Util_Lambda.res`
- Change `runtimeParts` type from `{ lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t> }` to use `PulumiAws.Lambda.Function.t` (or a shared type alias)
- Update `RuntimeEnvironment_Lambda.res` to remove `Obj.magic` coercion at lines 101-102, 170-171
- Update `Util_EventSourceMapping.res` and `EventCollectorChannel_Helpers.res` to match

**Verification**: `npm run build` — zero warnings.

---

## Step 3: Extract Shared Handler Factory Helpers

**Goal**: Deduplicate JavaScript handler factory boilerplate.

**Create**: `reventless/reventless-aws/src/adapter/Runtime/HandlerFactoryHelpers.mjs`

Extract into it:
1. `patchSpecId(specModule)` — `{ ...spec, Id: spec.Id || IdString }` (used 6+ times)
2. `makeQueueRef(url)` / `makeTableRef(name)` — infrastructure stub construction (used 10+ times)
3. `scanByTableName(client, tableName, filterConfigs)` — the duplicated DynamoDB scan function (used in 2 files, diverged)
   - Use the Plugin EP version (complete with all 11 comparison operators)
   - Replace both copies in `BundledAdminEventCollectorHandlerFactory.mjs` and `BundledPluginExtensionPointHandlerFactory.mjs`
4. `makeJsonEventsHandler(callback)` — shared streaming handler pattern (used by StateViewSlice and AutomationSlice factories)

**Update**: All 14 `Bundled*HandlerFactory.mjs` files to import from `HandlerFactoryHelpers.mjs`.

**Verification**: Deploy to alpha — all Lambdas still work (handler behavior unchanged).

---

## Step 4: Remove Non-Bundled Builders

**Goal**: Remove dead code that uses broken `CallbackFunction` path.

### 4a. Delete non-bundled component builders

These files use non-bundled runtime builders that create Lambdas via `CallbackFunction.make` → fails with Effect-TS:

| File to Delete | Reason |
|---|---|
| `components/Aggregate_Builder_Micro.res` | Uses `AggregateRuntime_Builder_Micro` (CallbackFunction) |
| `components/Aggregate_Builder_Single.res` | Uses `AggregateRuntime_Builder_Single` (CallbackFunction) |
| `components/Aggregate_Builder_PerAggregate.res` | Uses `AggregateRuntime_Builder_Single` (CallbackFunction) |
| `components/ReadModel_Builder_Single.res` | Uses `EventCollectorRuntime_Builder_Single` (CallbackFunction) |
| `components/ReadModel_Builder_PerReadModel.res` | Uses `EventCollectorRuntime_Builder_PerEventCollector` (CallbackFunction) |
| `components/ExtensionPoint_Builder.res` | Uses `ExtensionPointRuntime_Builder_PerExtensionPoint` (CallbackFunction) |
| `components/SideEffectHandler_Single.res` | Uses core `EventCollectorRuntime_Builder_Single` (CallbackFunction) |
| `components/SideEffectHandler_PerSideEffectHandler.res` | Uses core `EventCollectorRuntime_Builder_PerEventCollector` (CallbackFunction) |
| `components/SideEffectHandlerWithQueue_Single.res` | Uses core builder with SQS channel (CallbackFunction) |
| `components/SideEffectHandlerWithQueue_PerSideEffectHandler.res` | Same |
| `components/Task_Builder_PerBucket.res` | Uses `TaskRuntime_Builder_PerBucket` (CallbackFunction) |
| `components/Counter_Builder.res` | Uses `CounterHandler_DynamoDbStream` (CallbackFunction) |
| `adapter/Counter/CounterHandler_DynamoDbStream.res` | Direct `CallbackFunction.make` call |

**Do NOT delete** (still used by bundled variants internally):
- `components/StateViewSlice_Builder.res` — `StateViewSlice_Builder_Bundled.Make(Api)` uses this for infrastructure creation
- `components/AutomationSlice_Builder.res` — same
- `components/OutboundTranslationSlice_Builder.res` — same
- `components/StateChangeSlice_Builder.res` — no Lambda handler
- `components/InboundTranslationSlice_Builder.res` — no Lambda handler
- `components/DcbEventLog_Builder.res` — infrastructure only

### 4b. Remove `CallbackFunction.make` from `RuntimeEnvironment_Lambda.res`

Delete the `make()` function (lines ~16-45) that uses `Lambda.CallbackFunction.make`. Keep `makeBundled()` and `makeBundledFromEntryPoint()`.

### 4c. Update alias files

Change alias files to point to the (still-named) bundled variants:

| Alias File | Old | New |
|---|---|---|
| `Aggregate_Builder.res` | `include Aggregate_Builder_Micro` | `include Aggregate_Builder_Single_Bundled` |
| `ReadModel_Builder.res` | `include ReadModel_Builder_PerReadModel` | `include ReadModel_Builder_Single_Bundled` |
| `SideEffectHandler.res` | `include SideEffectHandler_PerSideEffectHandler` | `include SideEffectHandler_Single_Bundled` |
| `SideEffectHandlerWithQueue.res` | `include SideEffectHandler_PerSideEffectHandler` (bug) | delete file (no bundled WithQueue variant) |
| `Task_Builder.res` | `include Task_Builder_PerBucket` | `include Task_Builder_PerBucket_Bundled` |

Also add new alias: `Counter_Builder.res` → `include Counter_Builder_Bundled`.

### 4d. Update `Platform.res` non-bundled references

`Platform.res` line 133 uses `Aggregate_Builder_Micro.Make(...)` for `Platform.Aggregate.Make`. Change to bundled builder. Same for `ReadModel` (line 172), `ExtensionPoint` (line 190), `Task` (line 209), `Counter` (line 220).

**Verification**: `npm run build` — compiles. `npm test` — all tests pass. Deploy to alpha.

---

## Step 5: Rename Away From "Bundled"

**Goal**: Drop the "Bundled" suffix since bundling is now the only approach.

### 5a. Rename component builders

Use `git mv` for all renames. All renames in `reventless/reventless-aws/src/components/`:

| Old Name | New Name |
|---|---|
| `Aggregate_Builder_Single_Bundled.res` | `Aggregate_Builder_Single.res` |
| `Aggregate_Builder_PerAggregate_Bundled.res` | `Aggregate_Builder_PerAggregate.res` |
| `Aggregate_Builder_Micro_Bundled.res` | `Aggregate_Builder_Micro.res` |
| `ReadModel_Builder_Single_Bundled.res` | `ReadModel_Builder_Single.res` |
| `ReadModel_Builder_PerReadModel_Bundled.res` | `ReadModel_Builder_PerReadModel.res` |
| `ExtensionPoint_Builder_Bundled.res` | `ExtensionPoint_Builder.res` |
| `StateViewSlice_Builder_Bundled.res` | keep (used internally alongside non-bundled `StateViewSlice_Builder.res`) |
| `AutomationSlice_Builder_Bundled.res` | keep |
| `OutboundTranslationSlice_Builder_Bundled.res` | keep |
| `Counter_Builder_Bundled.res` | `Counter_Builder.res` (replace the alias) |
| `Task_Builder_PerBucket_Bundled.res` | `Task_Builder_PerBucket.res` (replace the alias) |
| `SideEffectHandler_Single_Bundled.res` | `SideEffectHandler_Single.res` |

**Note**: The three slice `_Bundled` builders (StateViewSlice, AutomationSlice, OutboundTranslation) coexist with non-bundled builders of the same name that handle infrastructure creation. They keep the `_Bundled` suffix until Step 7 extracts a shared functor.

### 5b. Rename runtime builders

All renames in `reventless/reventless-aws/src/adapter/Runtime/`:

| Old Name | New Name |
|---|---|
| `AggregateRuntime_Builder_Single_Bundled.res` | `AggregateRuntime_Builder_Single.res` |
| `AggregateRuntime_Builder_PerAggregate_Bundled.res` | `AggregateRuntime_Builder_PerAggregate.res` |
| `AggregateRuntime_Builder_Micro_Bundled.res` | `AggregateRuntime_Builder_Micro.res` |
| `EventCollectorRuntime_Builder_Single_Bundled.res` | `EventCollectorRuntime_Builder_Single.res` |
| `EventCollectorRuntime_Builder_PerEventCollector_Bundled.res` | `EventCollectorRuntime_Builder_PerEventCollector.res` |
| `StateViewSliceRuntime_Builder_Single_Bundled.res` | `StateViewSliceRuntime_Builder_Single.res` |
| `AutomationSliceRuntime_Builder_Single_Bundled.res` | `AutomationSliceRuntime_Builder_Single.res` |
| `PluginRuntime_Builder_Bundled.res` | `PluginRuntime_Builder.res` |
| `PluginExtensionPointRuntime_Builder_Bundled.res` | `PluginExtensionPointRuntime_Builder.res` |
| `ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled.res` | `ExtensionPointRuntime_Builder_PerExtensionPoint.res` |
| `SideEffectHandlerRuntime_Builder_Single_Bundled.res` | `SideEffectHandlerRuntime_Builder_Single.res` |
| `TaskRuntime_Builder_PerBucket_Bundled.res` | `TaskRuntime_Builder_PerBucket.res` |

Also rename counter handler:
- `adapter/Counter/CounterHandler_DynamoDbStream_Bundled.res` → `adapter/Counter/CounterHandler_DynamoDbStream.res`

### 5c. Rename handler factory `.mjs` files

All renames in `reventless/reventless-aws/src/adapter/Runtime/`:

| Old Name | New Name |
|---|---|
| `BundledAggregateHandlerFactory.mjs` | `AggregateHandlerFactory.mjs` |
| `BundledAdminEventCollectorHandlerFactory.mjs` | `AdminEventCollectorHandlerFactory.mjs` |
| `BundledAutomationSliceHandlerFactory.mjs` | `AutomationSliceHandlerFactory.mjs` |
| `BundledCommandGeneratorHandlerFactory.mjs` | `CommandGeneratorHandlerFactory.mjs` |
| `BundledCounterHandlerFactory.mjs` | `CounterHandlerFactory.mjs` |
| `BundledDcbCommandTopicHandlerFactory.mjs` | `DcbCommandTopicHandlerFactory.mjs` |
| `BundledEventMapperHandlerFactory.mjs` | `EventMapperHandlerFactory.mjs` |
| `BundledExtensionPointHandlerFactory.mjs` | `ExtensionPointHandlerFactory.mjs` |
| `BundledHeartbeatHandlerFactory.mjs` | `HeartbeatHandlerFactory.mjs` |
| `BundledPluginExtensionPointHandlerFactory.mjs` | `PluginExtensionPointHandlerFactory.mjs` |
| `BundledReadModelHandlerFactory.mjs` | `ReadModelHandlerFactory.mjs` |
| `BundledSideEffectHandlerFactory.mjs` | `SideEffectHandlerFactory.mjs` |
| `BundledStateViewSliceHandlerFactory.mjs` | `StateViewSliceHandlerFactory.mjs` |
| `BundledTaskHandlerFactory.mjs` | `TaskHandlerFactory.mjs` |

### 5d. Update all references

After renaming, update all string references to the old names:
- Runtime builder `.res` files reference factory `.mjs` paths by string (e.g., `"@reventlessdev/reventless-aws/src/adapter/Runtime/BundledAggregateHandlerFactory.mjs"`) — ~16 occurrences
- `Util_EntryPoint.mjs` references factory paths in comments
- `Util_EntryPoint.res` function names have "Bundled" prefix (e.g., `generateBundledAggregateEntryPoint`) — rename to `generateAggregateEntryPoint` etc.
- `Platform.res` references renamed builder module names
- Example `_Bundled.res` files reference `ReventlessAws.Aggregate_Builder_Single_Bundled` → `ReventlessAws.Aggregate_Builder_Single`
- Example `index.mjs` files reference `PluginRuntime_Builder_Bundled.res.mjs` → `PluginRuntime_Builder.res.mjs`

### 5e. Rename example plugin files

| Old Name | New Name |
|---|---|
| `CatalogPlugin_Bundled.res` | `CatalogPlugin_Aws.res` |
| `OrderingPlugin_Bundled.res` | `OrderingPlugin_Aws.res` |

Update `Main.res` files to import the renamed modules.

### 5f. Rename `BundledConfig` module types

In all component builders, rename `BundledConfig` to just `Config`:
```rescript
// Before
module type BundledConfig = { let specModulePath: string }
// After
module type Config = { let specModulePath: string }
```

Also rename function names:
- `registerBundledAggregate` → `registerAggregate`
- `registerBundledReadModel` → `registerReadModel`
- `registerBundledStateViewSlice` → `registerStateViewSlice`
- `registerBundledAutomationSlice` → `registerAutomationSlice`
- `registerDcbConfig` → keep (called from JS `index.mjs`, "Dcb" is the distinguishing word)
- `registerHeartbeatConfig` → keep
- `registerConfig` → keep

**Verification**: `npm run build` — compiles. `npm test` — passes. Deploy to alpha — all Lambdas created and functional.

---

## Step 6: Unify Lambda Function Type

**Goal**: Remove `Obj.magic` coercions between `Lambda.Function.t` and `Lambda.CallbackFunction.t`.

**Background**: After Step 4 removes `CallbackFunction.make`, the only Lambda creation path is `Lambda.Function.make`. But the type system still uses `CallbackFunction.t` everywhere because that was the original type. All bundled paths coerce `Function.t → CallbackFunction.t` via `Obj.magic`.

**Changes:**

1. `Util_Lambda.res` — change `runtimeParts.lambda` type from `Pulumi.Output.t<Lambda.CallbackFunction.t>` to `Pulumi.Output.t<Lambda.Function.t>`
2. `RuntimeEnvironment_Lambda.res` — remove `Obj.magic` coercions in `makeBundled` and `makeBundledFromEntryPoint`
3. `Util_EventSourceMapping.res` — update `~lambda` parameter type
4. `EventCollectorChannel_Helpers.res` — update `~lambda` parameter type
5. `CommandTopicChannel_Helpers.res` — update if needed
6. `Util_Lambda.toResource` — update parameter type
7. `Util_Lambda.fromOutput` — update to use `Lambda.Function.arn` etc.
8. `Util_Lambda.functionToCallbackFunction` — delete (no longer needed)
9. `Util_DeadLetterQueue.res` — update to use `Function.t` directly
10. `Types.res` — update `type function_` alias

**Verification**: `npm run build` — zero warnings, no `Obj.magic` related to Lambda types.

---

## Step 7: Extract Shared Projection Runtime Builder

**Goal**: Reduce ~500 lines of duplication across four projection-side runtime builders.

The following four files are ~75% identical:
- `EventCollectorRuntime_Builder_Single.res` (192 lines, was `*_Bundled`)
- `StateViewSliceRuntime_Builder_Single.res` (185 lines, was `*_Bundled`)
- `AutomationSliceRuntime_Builder_Single.res` (193 lines, was `*_Bundled`)
- `SideEffectHandlerRuntime_Builder_Single.res` (176 lines, was `*_Bundled`)

**Create**: `ProjectionRuntime_Builder_Single.res` — a shared functor parameterized by:
```rescript
module type Config = {
  let factoryModulePath: string
  let entryPointName: string
  let generateEntryPoint: entryPointConfig => string
  let extraEnvVars: (int, storedSpec) => dict<Pulumi.Input.t<string>>
}
```

Each existing file becomes a thin wrapper:
```rescript
// StateViewSliceRuntime_Builder_Single.res
include ProjectionRuntime_Builder_Single.Make({
  let factoryModulePath = "...StateViewSliceHandlerFactory.mjs"
  let entryPointName = "AllStateViewSlices"
  let generateEntryPoint = Util_EntryPoint.generateStateViewSliceEntryPoint
  let extraEnvVars = (_, _) => Dict.make()
})
```

`AutomationSliceRuntime_Builder_Single` adds DCB queue URL via `extraEnvVars`.

**Verification**: `npm run build`. Deploy to alpha — same Lambda behavior.

---

## Step 8: Reduce Aggregate Builder Duplication

**Goal**: The three aggregate component builders (`Single`, `PerAggregate`, `Micro`) are ~99% identical.

**Create**: `Aggregate_Builder_Common.res` — shared functor containing the `Make` functor body (create inner builder, call `make()`, extract table name, register). Parameterize by runtime builder module.

Each variant becomes:
```rescript
// Aggregate_Builder_Single.res
include Aggregate_Builder_Common.Make(AggregateRuntime_Builder_Single)
```

**Verification**: `npm run build`. Existing tests pass.

---

## Step Summary

| Step | Type | Status | Notes |
|---|---|---|---|
| 1. Wire DCB hook | Feature | **DONE** | Added `Bundled` sub-modules to `Platform.T` and in-memory Platform; used `BundledSliceConfig` module type |
| 2. Fix bugs | Bugfix | **DONE** | 2a: fixed SideEffectHandlerWithQueue alias; 2b: renamed `targetSpecModulePath` → `specModulePath` in counter; 2c: deferred to Step 6 |
| 3. Extract JS helpers | Refactor | **DONE** | Created `HandlerFactoryHelpers.mjs` with `patchSpecId`, `makeTableRef`, `makeQueueRef`, `scanByTableName`; updated 11 factory files |
| 4. Remove non-bundled | Cleanup | **DONE** | Deleted 14 files; kept `SideEffectHandler_PerSideEffectHandler.res` (used by Task bundled builder); kept `RuntimeEnvironment_Lambda.make` (core module types require it); also deleted dead `Plugin_Aggregate_Builder.res` and `Plugin_ReadModel_Builder.res` |
| 5. Rename from "Bundled" | Rename | **DONE** | Renamed 38 .res files + 14 .mjs handler factories + 2 example plugins. Updated all module references, factory path strings, Util_EntryPoint types/functions, BundledConfig → Config, registerBundled* → register* |
| 6. Unify Lambda type | Refactor | **DONE** | Changed `runtimeParts.lambda` to `Function.t`, removed `functionToCallbackFunction`, updated `Util_EventSourceMapping`, `CommandTopicChannel_Helpers`, `EventCollectorChannel_Helpers`, `Types.res`, `Util_DeadLetterQueue`. Kept legacy `make` with `Obj.magic` coercion (needed by core module types) and one `Obj.magic` in `TaskBucket_S3` (S3 binding expects `CallbackFunction.t`) |
| 7. Extract projection builder | Refactor | **DONE** | Created `ProjectionRuntime_Builder_Single.res` shared functor; rewrote 4 runtime builders as thin wrappers |
| 8. Extract aggregate builder | Refactor | **SKIPPED** | Net savings ~60 lines vs complex module type; 3 files are 64 lines each, self-contained, rarely change |

### Implementation Adjustments (vs original plan)

**Step 1**: Plan assumed `Platform.T` already exposed `Bundled` sub-modules for DCB slices. Actually needed to:
- Add `BundledSliceConfig` module type to `reventless-infra/Platform.res`
- Add `Bundled` sub-modules to `StateViewSlice`, `AutomationSlice`, `OutboundTranslationSlice` in `Platform.T`
- Add corresponding implementations in in-memory Platform (ignore config, delegate to regular Make)

**Step 4**: Several adjustments from the plan:
- `SideEffectHandler_PerSideEffectHandler.res` could NOT be deleted — `Task_Builder_PerBucket_Bundled.res` still depends on it as a module parameter
- `RuntimeEnvironment_Lambda.make` could NOT be deleted — core builder module types (`Runtime.environmentMaker`) structurally require it. Defer removal to Step 6.
- `SideEffectHandlerWithQueue.res` deleted (as planned — no bundled WithQueue variant)
- Also discovered and deleted dead code: `Plugin_Aggregate_Builder.res`, `Plugin_ReadModel_Builder.res` (unreferenced)
- Platform.res `Make` wrappers for Aggregate/ReadModel/ExtensionPoint/Task/Counter now delegate to bundled builders with empty configs (satisfies Platform.T while being dead code)

**Step 7**: Created `ProjectionRuntime_Builder_Single.res` with a `Make` functor parameterized by:
- `info` type (registered per component), `registration` type (for entry point generation)
- `processHandler` callback (sets env vars, returns registration)
- `generateEntryPoint` callback (wraps specific `Util_EntryPoint` external)
- `name`, `builderName`, `factoryModulePath`, `infos` dict

Rewrote all 4 projection runtime builders as thin wrappers (~40 lines each, down from ~185-192). Unified `storedSpec` field name to `componentName` (was `readModelName`/`sliceName`/`sideEffectHandlerName`). Added missing `Console.log` to AutomationSlice's `forEventCollector` (was inconsistently omitted).

**Step 8**: Skipped. The three aggregate component builders are only 64 lines each and ~99% identical, differing only in the `AggregateRuntimeBuilder` module alias and Micro's optional `mappingsModulePath`. Extracting a shared functor would require defining a complex combined module type (satisfying both `AggregateRuntime_Builder.T` constraints and `registerAggregate` with varying signatures). Net savings ~60 lines at the cost of fragile module type plumbing.
