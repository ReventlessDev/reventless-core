# Bundled Handler Implementation Review

**Date**: 2026-03-20
**Scope**: `reventless/reventless-aws/src/` — all bundled and non-bundled builder files, handler factories, and platform wiring

---

## 1. What Is Already Implemented

### Bundled Runtime Builders (13 files)

Every component type has a bundled runtime builder. All use the same pattern: accumulate handler specs during `forEventCollector`/`forCommandTopic` calls, then create a consolidated Lambda in `finish()`.

| Runtime Builder | Lambda Strategy | `finish()` | Status |
|---|---|---|---|
| `AggregateRuntime_Builder_Single_Bundled` | One Lambda for all aggregates | Functional | Working |
| `AggregateRuntime_Builder_PerAggregate_Bundled` | One Lambda per aggregate | Functional | Working |
| `AggregateRuntime_Builder_Micro_Bundled` | Three Lambdas per aggregate (CmdTopic, CmdGen, EvtMapper) | Functional | Working |
| `EventCollectorRuntime_Builder_Single_Bundled` | One Lambda for all read models | Functional | Working |
| `EventCollectorRuntime_Builder_PerEventCollector_Bundled` | One Lambda per read model | No-op (creates inline) | Working |
| `StateViewSliceRuntime_Builder_Single_Bundled` | One Lambda for all state view slices | Functional | **Not called** |
| `AutomationSliceRuntime_Builder_Single_Bundled` | One Lambda for all automation+outbound slices | Functional | **Not called** |
| `PluginRuntime_Builder_Bundled` | Admin EventCollector, Heartbeat, DCB CommandTopic | No-op (creates inline) | Working |
| `PluginExtensionPointRuntime_Builder_Bundled` | One Lambda per Plugin EP | N/A (creates inline) | Working |
| `ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled` | One Lambda per EP | N/A (creates inline) | Working |
| `SideEffectHandlerRuntime_Builder_Single_Bundled` | One Lambda for all side effect handlers | Functional | Working |
| `TaskRuntime_Builder_PerBucket_Bundled` | One Lambda per S3 bucket | No-op (creates inline) | Working |

### Bundled Component Builders (14 files)

| Component Builder | BundledConfig Fields | Runtime Builder Used |
|---|---|---|
| `Aggregate_Builder_Single_Bundled` | `specModulePath`, `behaviorModulePath` | `AggregateRuntime_Builder_Single_Bundled` |
| `Aggregate_Builder_PerAggregate_Bundled` | `specModulePath`, `behaviorModulePath` | `AggregateRuntime_Builder_PerAggregate_Bundled` |
| `Aggregate_Builder_Micro_Bundled` | `specModulePath`, `behaviorModulePath`, `mappingsModulePath?` | `AggregateRuntime_Builder_Micro_Bundled` |
| `ReadModel_Builder_Single_Bundled` | `specModulePath`, `mappingsModulePath` | `EventCollectorRuntime_Builder_Single_Bundled` |
| `ReadModel_Builder_PerReadModel_Bundled` | `specModulePath`, `mappingsModulePath` | `EventCollectorRuntime_Builder_PerEventCollector_Bundled` |
| `ExtensionPoint_Builder_Bundled` | `specModulePath`, `mappingsModulePath`, `publishToAggregatesQueueUrls` | `ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled` |
| `StateViewSlice_Builder_Bundled` | `specModulePath` | `StateViewSliceRuntime_Builder_Single_Bundled` |
| `AutomationSlice_Builder_Bundled` | `specModulePath` | `AutomationSliceRuntime_Builder_Single_Bundled` |
| `OutboundTranslationSlice_Builder_Bundled` | `specModulePath` | `AutomationSliceRuntime_Builder_Single_Bundled` (shared) |
| `Counter_Builder_Bundled` | `targetSpecModulePath`, `mappingsModulePath`, `publishQueueUrl` | `CounterHandler_DynamoDbStream_Bundled` |
| `Task_Builder_PerBucket_Bundled` | `callbackModulePaths`, `publishToAggregatesQueueUrls` | `TaskRuntime_Builder_PerBucket_Bundled` |
| `SideEffectHandler_Single_Bundled` | `sideEffectModulePaths` | `SideEffectHandlerRuntime_Builder_Single_Bundled` |

### Handler Factories (14 `.mjs` files)

Fourteen hand-written JavaScript files reconstruct handler chains at Lambda runtime:

| Factory | Lines | Purpose |
|---|---|---|
| `BundledAggregateHandlerFactory.mjs` | 98 | Aggregate command handler chain |
| `BundledAdminEventCollectorHandlerFactory.mjs` | 279 | Admin EventCollector (plugin lifecycle) |
| `BundledAutomationSliceHandlerFactory.mjs` | 84 | AutomationSlice TODO-list handler |
| `BundledCommandGeneratorHandlerFactory.mjs` | 44 | CommandGenerator (AppSync → SQS) |
| `BundledCounterHandlerFactory.mjs` | 145 | Counter DynamoDB stream handler |
| `BundledDcbCommandTopicHandlerFactory.mjs` | 156 | DCB CommandTopic composite handler |
| `BundledEventMapperHandlerFactory.mjs` | 100 | EventMapper (source→target event mapping) |
| `BundledExtensionPointHandlerFactory.mjs` | 94 | ExtensionPoint command routing |
| `BundledHeartbeatHandlerFactory.mjs` | 52 | Heartbeat command publisher |
| `BundledPluginExtensionPointHandlerFactory.mjs` | 245 | Plugin ExtensionPoint (full queryEngine) |
| `BundledReadModelHandlerFactory.mjs` | 66 | ReadModel projection handler |
| `BundledSideEffectHandlerFactory.mjs` | 48 | SideEffectHandler dispatch |
| `BundledStateViewSliceHandlerFactory.mjs` | 68 | StateViewSlice projection handler |
| `BundledTaskHandlerFactory.mjs` | 89 | Task S3 bucket handler |

### Utility Files (2 `.mjs` files)

| Utility | Lines | Purpose |
|---|---|---|
| `Util_Bundle.mjs` | 113 | esbuild wrapper for bundling entry points |
| `Util_EntryPoint.mjs` | 916 | Code generator producing JS entry point source strings |

### Platform Hook Wiring

Seven hooks are set in the AWS `Platform.res`:

| Hook | Status | Action |
|---|---|---|
| `onDcbEventLogCreated` | Implemented | Extracts DynamoDB table name |
| `onDcbCommandTopicCreated` | Implemented | Extracts SQS queue URL |
| `onDcbSlicesCreated` | **No-op (placeholder)** | Should call `finish()` on slice builders |
| `onHeartbeatEpChannelAvailable` | Implemented | Extracts EP queue URL |
| `preResolversSchemaHook` | Implemented | Pushes schema to AppSync |
| `dcbAppSyncResolverHook` | Implemented | Creates DCB AppSync resolvers |
| `inboundAppSyncResolverHook` | Implemented | Creates inbound AppSync resolvers |

---

## 2. What Is Still Missing

### Critical: DCB Slice `finish()` Never Called

The `onDcbSlicesCreated` hook in `Platform.res:380-384` is a no-op:

```rescript
let () = ReventlessCore.Plugin_Helpers.onDcbSlicesCreated.contents = Some(
  _dcbEventLogUnknown => {
    Console.log("[Platform] onDcbSlicesCreated: slice finish() deferred (bundled slices pending)")
  },
)
```

This means:
- `StateViewSliceRuntime_Builder_Single_Bundled.finish()` is never called → no `AllStateViewSlices` Lambda
- `AutomationSliceRuntime_Builder_Single_Bundled.finish()` is never called → no `AllAutomationSlices` Lambda

The bundled runtime builders are fully implemented and ready. The missing piece is wiring the hook to call `finish()`.

### Critical: Plugin `_Bundled.res` Files Don't Use Bundled Slice Builders

`OrderingPlugin_Bundled.res:64-72` creates DCB slices via `Platform.StateViewSlice.Make(Spec)` — the non-bundled path. This means:
- The non-bundled runtime builder accumulates specs but creates Lambdas via `CallbackFunction` → serialization failure
- Even if `finish()` were called, the *bundled* runtime builder has no specs registered because the *non-bundled* path was used

The fix requires the `_Bundled.res` files to use bundled slice builders (e.g., `Platform.StateViewSlice.Bundled.Make(Spec, Config)`) or bypass `Platform.T` entirely as is done for aggregates.

### Not Yet Covered: Components Without Bundled Variants

| Component | Non-Bundled Builder | Bundled Needed? | Reason |
|---|---|---|---|
| `InboundTranslationSlice_Builder` | Yes | No | Routes through DCB CommandTopic Lambda (no own Lambda) |
| `StateChangeSlice_Builder` | Yes | No | Registers with CommandTopic directly (no own Lambda) |
| `DcbEventLog_Builder` | Yes | No | Infrastructure only (DynamoDB table, no Lambda) |
| `DataCleaner` | Commented out | No | Entire module is commented out |

These components don't need bundled variants because they don't create Lambda functions.

---

## 3. No-Ops and Stubs

### `finish()` No-Ops (Correct)

These are correct no-ops because their Lambdas are created inline during registration:

- `PluginRuntime_Builder_Bundled.finish()` — Admin EventCollector, Heartbeat, and DCB CommandTopic Lambdas are created in `forPluginEventCollector`, `forPluginHeartbeat`, `forDcbCommandTopic`
- `EventCollectorRuntime_Builder_PerEventCollector_Bundled.finish()` — Lambda created per EventCollector in `forEventCollector`
- `TaskRuntime_Builder_PerBucket_Bundled.finish()` — Lambda created per bucket in `forBucketCallback`

### `onDcbSlicesCreated` Hook (Incorrect No-Op)

This is the only incorrect no-op. Should call `StateViewSliceRuntime_Builder_Single_Bundled.finish()` and `AutomationSliceRuntime_Builder_Single_Bundled.finish()`.

### Stubs in Handler Factories

Several handler factories stub out infrastructure that isn't available at Lambda runtime:

- `BundledExtensionPointHandlerFactory.mjs:44,55` — `scheduler` and `queryEngine` throw errors if called. This is correct for extension points that don't need them, but could mask bugs if future extensions do.
- `BundledEventMapperHandlerFactory.mjs:62-75` — `queryEngine` is a no-op. Mappings that call `queryEngine.get()` will silently return `undefined`.

---

## 4. Code Duplication

### High: Projection-Side Runtime Builders (~75% identical)

Four files share nearly identical structure — array accumulation, `grandParent` tracking, indexed env vars, `finish()` creates single Lambda, connects EventCollector channels:

- `EventCollectorRuntime_Builder_Single_Bundled.res` (192 lines)
- `StateViewSliceRuntime_Builder_Single_Bundled.res` (185 lines)
- `AutomationSliceRuntime_Builder_Single_Bundled.res` (193 lines)
- `SideEffectHandlerRuntime_Builder_Single_Bundled.res` (176 lines)

The only differences: factory module path, entry point generator function called, and `AutomationSliceRuntime` has `dcbQueueUrlRef` integration.

**Opportunity**: Extract a shared `BundledProjectionRuntimeBuilder` parameterized by factory module, entry point generator, and optional extra env vars.

### High: Aggregate Component Builders (~99% identical)

- `Aggregate_Builder_Single_Bundled.res` (64 lines)
- `Aggregate_Builder_PerAggregate_Bundled.res` (62 lines)
- `Aggregate_Builder_Micro_Bundled.res` (64 lines)

All three do the same thing: create inner builder, call `make()`, extract table name, call `registerBundledAggregate()`. The only difference is which runtime builder they reference. `Micro_Bundled` additionally passes `mappingsModulePath`.

### Medium: Handler Factory Duplication

1. **`scanByTableName`** copied verbatim between:
   - `BundledAdminEventCollectorHandlerFactory.mjs` (lines 55-105)
   - `BundledPluginExtensionPointHandlerFactory.mjs` (lines 50-131)

   The Plugin EP version has 8 additional comparison operators. They **will diverge** — bug fix to one won't apply to the other.

2. **`jsonEventsHandler` pattern** nearly identical between:
   - `BundledAutomationSliceHandlerFactory.mjs` (lines 56-79)
   - `BundledStateViewSliceHandlerFactory.mjs` (lines 43-63)

3. **Module Id patching** (`{ ...specModule, Id: specModule.Id || IdString }`) repeated 6+ times across factories.

4. **Queue/table object construction** (`{ id: queueUrl, name: queueUrl, arn: "" }`) repeated 10+ times.

### Medium: Non-Bundled Component Builders

The non-bundled builders are tiny (8-27 lines each) and mostly identical — just wiring different adapter modules to the core builder:

- `StateViewSlice_Builder.res` (21 lines)
- `AutomationSlice_Builder.res` (21 lines)
- `OutboundTranslationSlice_Builder.res` (21 lines)

Could be a single parameterized builder.

---

## 5. Inconsistencies

### Naming: "Bundled" in File Names

25 of 158 `.res` files in `reventless-aws/src/` have "Bundled" in the name. The "Bundled" suffix was introduced when bundling was opt-in alongside the `CallbackFunction` approach. Now that **all** AWS Lambda handlers must be bundled (CallbackFunction fails with Effect-TS), the suffix is vestigial.

| Area | Non-Bundled Files | Bundled Files | Can Non-Bundled Be Removed? |
|---|---|---|---|
| Aggregate builders | 4 files | 3 files | Partially — `Aggregate_Builder_Micro` is the default alias, but its internal runtime builder uses `CallbackFunction` |
| ReadModel builders | 3 files | 2 files | Partially — same issue |
| EP builder | 1 file | 1 file | Yes, if CallbackFunction path is removed |
| Slice builders | 3 files (SV, AS, OTS) | 3 files | No — non-bundled used by in-memory via core builders |
| Counter builder | 1 file | 1 file | `CounterHandler_DynamoDbStream` still uses `CallbackFunction.make` |
| Task builder | 2 files | 1 file | Yes |
| SideEffect builders | 5 files | 1 file | Yes for the 4 that use core builders directly |

**The slice builders are special**: `StateViewSlice_Builder.res` (non-bundled) delegates to `ReventlessCore.StateViewSlice_Builder.Make(...)` with AWS adapters. This is the builder that `Platform.StateViewSlice.Make(Spec)` uses. It's the infrastructure creation path — even bundled slices create their infrastructure (DynamoDB tables, AppSync resolvers) through it. The bundled variant just adds `registerBundledStateViewSlice()` on top.

### BundledConfig Field Naming

- Aggregates: `specModulePath`, `behaviorModulePath`
- ReadModels: `specModulePath`, `mappingsModulePath`
- Counter: `targetSpecModulePath` (inconsistent — should be `specModulePath`)
- Task: `callbackModulePaths` (dict, not single path — different semantics, acceptable)

### Aggregate_Builder_PerAggregate.res Naming Bug

`Aggregate_Builder_PerAggregate.res:6` uses `ReventlessCore.AggregateRuntime_Builder_Single.Make(...)` (Single, not PerAggregate). The file name says "PerAggregate" but it uses the "Single" runtime builder. This is either a naming inconsistency or a deliberate choice that isn't documented.

### SideEffectHandlerWithQueue.res Alias Bug

`SideEffectHandlerWithQueue.res` includes `SideEffectHandler_PerSideEffectHandler` instead of a "WithQueue" variant. This appears to be a copy-paste error.

### OutboundTranslationSlice Registers as AutomationSlice

`OutboundTranslationSlice_Builder_Bundled.res:54` calls `AutomationSliceRuntime_Builder_Single_Bundled.registerBundledAutomationSlice()`. This is intentional (outbound translation slices share the automation slice Lambda), but the function name is misleading. A wrapper like `registerBundledOutboundTranslationSlice()` that delegates to the automation runtime builder would be clearer.

### `CallbackFunction.t` Type Used for Bundled Lambdas

`RuntimeEnvironment_Lambda.res:101-102` coerces `Lambda.Function.t` → `Lambda.CallbackFunction.t` via `Obj.magic` so that bundled Lambdas fit into the type system that expects `CallbackFunction.t`. The `runtimeParts` type in `Util_Lambda.res:2` is `{ lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>, ... }`. This should be updated to `Lambda.Function.t` (or a union type) to eliminate the `Obj.magic`.

---

## 6. JavaScript Files Assessment

### Why JavaScript Instead of ReScript?

The 16 `.mjs` files exist for three distinct reasons:

**1. Code generation (cannot be ReScript):**
- `Util_EntryPoint.mjs` (916 lines) — generates JavaScript source code strings using template literals. Expressing this in ReScript would require double-escaping backticks and `${}` interpolations, making it unreadable. This file is a code generator, not runtime code.

**2. Build tooling (better as JavaScript):**
- `Util_Bundle.mjs` (113 lines) — calls the esbuild API directly, manages temp files, creates Pulumi AssetArchives. No ReScript bindings exist for esbuild, and the imperative file-system workflow is cleaner in JS.

**3. Handler factories (could be ReScript but with trade-offs):**
The 14 `Bundled*HandlerFactory.mjs` files reconstruct handler chains at Lambda runtime by dynamically composing ReScript modules. They are JavaScript because:
- They receive spec/behavior modules as **dynamic imports** (objects with arbitrary shapes), not as ReScript functor parameters
- They patch module shapes at runtime (e.g., adding missing `Id` aliases)
- They construct infrastructure stubs (fake DynamoDB table references from env vars)

In theory, these could be written in ReScript with extensive `external` bindings and `Obj.magic` casts. In practice, the dynamic module composition pattern maps more naturally to JavaScript's structural typing.

### Should They Be Consolidated?

**Yes, partially.** The 14 handler factories share significant boilerplate:

1. **Extract into shared helpers** (immediate win, no architecture change):
   - `patchSpecId(specModule)` — the `{ ...spec, Id: spec.Id || IdString }` pattern (6+ occurrences)
   - `makeQueueRef(url)` / `makeTableRef(name)` — infrastructure stub construction (10+ occurrences)
   - `scanByTableName(tableName, filterConfigs)` — the duplicated DynamoDB scan function

2. **Extract `jsonEventsHandler` pattern** into a shared streaming helper (used by StateViewSlice, AutomationSlice, and potentially OutboundTranslationSlice factories).

3. **Do not consolidate** the factories themselves — each has component-specific handler chain logic that benefits from being explicit and self-contained.

---

## 7. Can We Remove the Non-Bundled Path?

### Current Usage of `CallbackFunction.make`

Only two files still call `Lambda.CallbackFunction.make`:

1. **`RuntimeEnvironment_Lambda.res:24`** — the non-bundled `make()` function. Used by non-bundled component builders (`Aggregate_Builder_Micro`, `ReadModel_Builder_Single`, etc.).

2. **`CounterHandler_DynamoDbStream.res:17`** — the non-bundled counter handler. There is a bundled variant (`CounterHandler_DynamoDbStream_Bundled`), but the non-bundled is still wired through `Counter_Builder.res`.

### What Happens If We Remove Non-Bundled Builders?

**Can remove (AWS platform uses bundled exclusively):**
- `Aggregate_Builder_Micro.res`, `Aggregate_Builder_Single.res`, `Aggregate_Builder_PerAggregate.res`
- `ReadModel_Builder_Single.res`, `ReadModel_Builder_PerReadModel.res`
- `ExtensionPoint_Builder.res`
- `SideEffectHandler_Single.res`, `SideEffectHandler_PerSideEffectHandler.res`, `SideEffectHandlerWithQueue_*.res`
- `Task_Builder_PerBucket.res`
- `CounterHandler_DynamoDbStream.res` (if Counter_Builder.res switches to bundled)
- `RuntimeEnvironment_Lambda.make()` function (the non-bundled variant)

**Cannot remove (still needed for infrastructure creation in bundled path):**
- `StateViewSlice_Builder.res` — used by `StateViewSlice_Builder_Bundled.Make(ApiConfig)` internally (via `ReventlessCore.StateViewSlice_Builder.Make(...)`)
- `AutomationSlice_Builder.res` — same reason
- `OutboundTranslationSlice_Builder.res` — same reason
- `StateChangeSlice_Builder.res` — no Lambda handler, always works
- `InboundTranslationSlice_Builder.res` — same
- `DcbEventLog_Builder.res` — same

**Verdict**: The non-bundled component builders (Aggregate, ReadModel, ExtensionPoint, SideEffectHandler, Task, Counter) are dead code on AWS. The non-bundled `RuntimeEnvironment_Lambda.make()` is the `CallbackFunction` entrypoint that doesn't work with Effect-TS. These can all be removed or marked deprecated.

However, the **alias files** (`Aggregate_Builder.res`, `ReadModel_Builder.res`, `Task_Builder.res`, `SideEffectHandler.res`) that `include` non-bundled variants should switch to include the bundled variants instead. This would make bundled the default and remove the "Bundled" suffix from the public API.

### Should We Rename Away From "Bundled"?

**Yes, but incrementally.** The migration path:

1. **Phase 1**: Make bundled the default by changing alias files:
   - `Aggregate_Builder.res` → `include Aggregate_Builder_Single_Bundled` (instead of `Aggregate_Builder_Micro`)
   - `ReadModel_Builder.res` → `include ReadModel_Builder_Single_Bundled` (instead of `ReadModel_Builder_PerReadModel`)

2. **Phase 2**: Rename files to drop "Bundled" suffix, keeping the old names as deprecated re-exports for a transition period.

3. **Phase 3**: Remove old non-bundled files and deprecated re-exports.

The runtime builders should follow the same pattern. The "Bundled" suffix adds noise without information since bundling is now the only viable approach on AWS.

---

## 8. Improvement Opportunities

### Architecture

1. **Extract `BundledProjectionRuntimeBuilder` functor**: The four projection-side runtime builders are ~75% identical. A shared functor parameterized by (factory module path, entry point generator, extra env var producer) would eliminate ~500 lines of duplication.

2. **Unify `CallbackFunction.t` and `Function.t` types**: The `runtimeParts` type should use `Lambda.Function.t` directly instead of casting through `Obj.magic`. This requires updating `Util_Lambda.res`, `Util_EventSourceMapping.res`, and `EventCollectorChannel_Helpers.res`.

3. **Make bundled the default**: Change alias files to point to bundled variants. The non-bundled path only served as a stepping stone during the migration.

4. **Wire `onDcbSlicesCreated`**: The immediate fix — call `finish()` on both slice runtime builders. This unblocks DCB slice Lambdas.

5. **Update `_Bundled.res` plugin files**: Switch DCB slices from `Platform.StateViewSlice.Make(Spec)` to bundled builders (either via updated `Platform.T` or direct `ReventlessAws` imports).

### Code Quality

6. **Extract shared handler factory helpers**: `patchSpecId`, `makeQueueRef`, `makeTableRef`, `scanByTableName` — deduplicate across 14 factory files.

7. **Fix `scanByTableName` divergence**: The Admin EventCollector version is missing 8 comparison operators that the Plugin ExtensionPoint version has. Extract to a shared module.

8. **Fix `SideEffectHandlerWithQueue.res` alias**: Points to the wrong module.

9. **Document `Aggregate_Builder_PerAggregate.res`**: Uses `Single` runtime builder despite "PerAggregate" name — clarify if intentional.

10. **Rename `registerBundledAutomationSlice` in OutboundTranslation context**: The function name should reflect that outbound translation slices are registered on the automation runtime builder.

### File Count Reduction

If the non-bundled path is removed and aliases updated:

| Current | After Cleanup |
|---|---|
| 25 `*Bundled*.res` files | 25 files (renamed, no "Bundled" suffix) |
| ~20 non-bundled builder `.res` files | 0 (removed) |
| 5 alias `.res` files | 5 (point to renamed files) |
| 14 handler factory `.mjs` files | 14 (consolidate helpers) |
| 2 utility `.mjs` files | 2 (unchanged) |

Net reduction: ~20 files removed, 25 files renamed.

---

## 9. Summary

### What Works
- All major component types have bundled builders and runtime builders
- Handler factories correctly reconstruct handler chains at Lambda runtime
- Platform hooks wire DCB lifecycle events (3 of 4 implemented)
- Entry point code generation and esbuild bundling pipeline is solid

### What's Blocked
- DCB slice Lambdas (`AllStateViewSlices`, `AllAutomationSlices`) — `onDcbSlicesCreated` hook is a no-op
- `_Bundled.res` plugin files use non-bundled slice builders

### What Should Be Cleaned Up
- Non-bundled component builders are dead code on AWS (CallbackFunction fails)
- "Bundled" suffix is vestigial — bundling is the only viable AWS approach
- Handler factory code duplication (shared helpers not extracted)
- `CallbackFunction.t` / `Function.t` type coercion via `Obj.magic`
- Several naming bugs and alias errors

### Recommended Priority
1. Wire `onDcbSlicesCreated` hook + update `_Bundled.res` plugin files (unblocks DCB slices)
2. Extract shared handler factory helpers (reduces bug risk from divergent copies)
3. Make bundled the default + remove non-bundled dead code (reduces maintenance surface)
4. Extract `BundledProjectionRuntimeBuilder` functor (reduces ~500 lines of duplication)
