# Add Component Output Fields to Platform Outputs

## Problem

`deployPlugin` exports detailed component outputs (aggregates, readModels, extensionPoints, slices, dcbEventLog, tasks, eventMappers) via `exportPluginOutputs()`. However, `deployPlatform` and `makePlatform` do not export equivalent outputs for their components:

- **`deployPlatform`** only exports `apiId`, `apiRoleArn`, and `extensionPoints`
- **`makePlatform`** exports nothing — all plugin component outputs are discarded (`_plugins`)

Additionally, the admin's internal Plugin aggregate and Plugin read model (which back the PluginExtensionPoint) are not built as standalone components. They exist only as behavioral specs (`PluginSpec`, `PluginBehavior`, `PluginReadModelSpec`, `PluginProjection`) used by the extension point mapping, but no infrastructure (EventLog DynamoDB table, CommandTopic SQS queue, QueryDb DynamoDB table) is created for them.

This means:
1. Operators cannot inspect platform-deployed component infrastructure via `pulumi stack output`
2. The PluginExtensionPoint's `publishToAggregates` dict has no "Plugin" entry — commands like `ConnectPlugin` fail to reach the aggregate

## Goal

1. Build the admin's Plugin aggregate and Plugin read model as real infrastructure components
2. Make `deployPlatform` and `makePlatform` export all component output fields (aggregates, readModels, extensionPoints, DCB slices) using the same serialization pattern as `deployPlugin`

## Implementation Plan

### Step 1: Extend Admin.construct output type — DONE

**File**: `reventless/reventless-core/src/admin/Platform_Admin.res`

Extended the `outputs` type with component and DCB slice output fields. The return type now includes:

```rescript
type outputs = {
  adminFragment: ReventlessInfra.Api.schemaFragment,
  dcbMutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  dcbQueryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  dcbEventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  extensionPointsOutputs: Pulumi.Output.t<array<ExtensionPoint.outputs>>,
  aggregatesOutputs: dict<Aggregate.outputs>,
  readModelsOutputs: dict<ReadModel.outputs>,
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
  stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  automationSlicesOutputs: dict<AutomationSlice.outputs>,
  outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
}
```

The `construct` function returns all fields from the existing local variables and `dcbResult`.

### Step 2: Create exportPlatformOutputs helper — DONE

**File**: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

Added `exportPlatformOutputs` function that serializes admin component outputs as Pulumi stack exports. Follows the same pattern as `exportPluginOutputs` but only exports non-empty component dicts to avoid cluttering stack output with empty values.

Accepts all component output types: extensionPoints, aggregates, readModels, dcbEventLog, and all 5 DCB slice types (stateChangeSlices, stateViewSlices, automationSlices, outboundTranslationSlices, inboundTranslationSlices).

### Step 3: Wire exportPlatformOutputs in deployPlatform — DONE

**File**: `reventless/reventless-aws/src/Platform.res`

Captured admin outputs (`_admin` → `admin`), replaced `exportAdminExtensionPoints()` with `exportPlatformOutputs(...)` passing all component and DCB slice fields. Removed the now-unused `exportAdminExtensionPoints` function.

### Step 4: Wire plugin outputs in makePlatform — DONE

**File**: `reventless/reventless-aws/src/Platform.res`

Captured plugin components (`_plugins` → `pluginComponents`), export first plugin's outputs via `exportPluginOutputs` (monolithic mode = typically single plugin).

### Step 5: Build Plugin aggregate as a standalone component — DONE

**File**: `reventless/reventless-aws/src/Platform.res`

Built the Plugin aggregate using `Aggregate_Builder_Single.Make` inside `MakeWithConfig`, then passed it to `Admin.construct` via `~aggregates=[module(PluginAggregate)]` in both `deployPlatform` and `makePlatform`.

```rescript
module PluginAggregate: (
  ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
) = Aggregate_Builder_Single.Make(
  ReventlessCore.PluginSpec,
  ReventlessCore.PluginBehavior,
  ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  { let specModulePath = ""; let behaviorModulePath = "" },
)
```

This creates real infrastructure: EventLog DynamoDB table, CommandTopic SQS FIFO queue, EventTopic (DynamoDB Streams → SNS), and a per-aggregate Lambda handler. The aggregate's `name` = `"Plugin"` matches what `PluginExtensionPoint_Plugin.Impl.Aggregate` expects, so `publishToAggregates.get("Plugin")` will now succeed.

### Step 6: Build Plugin read model as a standalone component — DONE

**File**: `reventless/reventless-aws/src/Platform.res`

Built the Plugin read model using `ReadModel_Builder_Single.Make`, with a `PluginReadModelMappings` wrapper to satisfy the `Reventless.Projection.Mappings` module type. Passed to `Admin.construct` via `~readModels=[module(PluginReadModel)]`.

```rescript
module PluginReadModelMappings: Reventless.Projection.Mappings
  with module Target := ReventlessCore.PluginReadModelSpec = {
  module M = Reventless.Projection.Mappings.Make(ReventlessCore.PluginReadModelSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = ReventlessCore.PluginProjection.mappings->Obj.magic
}

module PluginReadModel = ReadModel_Builder_Single.Make(
  ReventlessCore.PluginReadModelSpec,
  PluginReadModelMappings,
  { let specModulePath = ""; let mappingsModulePath = "" },
)
```

This creates: QueryDb DynamoDB table, EventCollector subscription to the Plugin aggregate's EventTopic, and a per-read-model Lambda handler.

**Note**: `PluginReadModelSpec` exports extra types (`status`, `queryResult`, `statusSchema`) beyond what `ReadModel.Spec` requires. The `PluginReadModel` module is left without explicit type annotation to avoid sealing those extra types away.

**Note**: The `PluginProjection.mappings` uses `Obj.magic` to bridge the nominal type gap between the two `Mappings.Make` instantiations — structurally identical but nominally distinct.

**Runtime wiring** — DONE via `onAdminComponentsCreated` hook:
- Added hook in `Plugin_Helpers` that fires from `Platform_Admin.construct` after aggregates and read models are built but before extension points
- In `deployPlatform`, the hook extracts Plugin aggregate CommandTopic queue URL and Plugin read model QueryDb table name, then calls both `PluginExtensionPointRuntime_Builder.registerPluginExtensionPoint` and `PluginRuntime_Builder.registerConfig` with all values (including `appSyncApiId` and `clonerEnabled`)
- This ensures the EP Lambda has `PTA_Plugin_QUEUE_URL` and `PLUGIN_RM_TABLE` env vars, and the Admin EventCollector Lambda has `PLUGIN_RM_TABLE`

### Step 5c: Fix deployment issues — DONE

Three issues discovered during deployment:

1. **Empty `specModulePath`/`behaviorModulePath`** — the Single builders use these paths to bundle Lambda handlers via esbuild. Empty strings caused `Could not resolve ""`. Fixed by setting actual module paths using `Util_Bundle.resolveModule`:
   - `@reventlessdev/reventless-core/src/admin/PluginSpec.res.mjs`
   - `@reventlessdev/reventless-core/src/admin/PluginBehavior.res.mjs`
   - `@reventlessdev/reventless-core/src/admin/PluginReadModelSpec.res.mjs`
   - `@reventlessdev/reventless-core/src/admin/PluginProjection.res.mjs`

2. **AppSync resolvers for internal components** — both `ReadModel_Builder_Single` and `Aggregate_Builder_Single` create AppSync resolvers (query fields for read models, mutation fields for aggregates). The Plugin read model and aggregate are internal — accessed via `queryEngine`/`publishToAggregates`, not GraphQL. Fixed by creating NoResolver builder variants:
   - `QueryDbResolvers_AppSync_NoOp.res` — no-op QueryDb resolver adapter (AppSync types, no resources)
   - `CommandGeneratorResolvers_AppSync_NoOp.res` — no-op CommandGenerator resolver adapter (AppSync types, no resources)
   - `ReadModel_Builder_NoResolver.res` — ReadModel builder using NoOp QueryDb resolver
   - `Aggregate_Builder_NoResolver.res` — Aggregate builder using NoOp CommandGenerator resolver

3. **`m.apply is not a function`** — `Pulumi.Output.make(dict)` deeply resolves nested Outputs inside the dict, stripping `Pulumi.Output.t` wrappers from fields like `commandTopic`, `commandGenerator`. When `toResolvedOutputs` then calls `.flatMap()` on these unwrapped values, it crashes. Fixed by adding `serializePlainDictExport` helper that serializes plain dicts directly without wrapping in `Pulumi.Output.make`.

### Step 7: Verify

- [x] `npm run build` compiles without errors or warnings
- [x] Deploy a platform stack → verify `pulumi stack output` shows extensionPoints, aggregates (Plugin), readModels (Plugin)
- [x] Deploy a plugin stack → verify existing exports unchanged
- [x] Deploy monolithic → verify plugin component outputs appear

## Files Changed

| File | Change | Status |
|------|--------|--------|
| `reventless/reventless-core/src/admin/Platform_Admin.res` | Extend `outputs` type with component + DCB slice fields; return from `construct`; fire `onAdminComponentsCreated` hook | DONE |
| `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` | Add `exportPlatformOutputs`, `serializePlainDictExport`, and `onAdminComponentsCreated` hook | DONE |
| `reventless/reventless-aws/src/Platform.res` | Wire outputs in `deployPlatform` and `makePlatform`; build Plugin aggregate (NoResolver) and read model (NoResolver); set `onAdminComponentsCreated` hook for runtime wiring | DONE |
| `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync_NoOp.res` | No-op AppSync QueryDb resolver adapter | NEW |
| `reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync_NoOp.res` | No-op AppSync CommandGenerator resolver adapter | NEW |
| `reventless/reventless-aws/src/components/ReadModel_Builder_NoResolver.res` | ReadModel builder variant using NoOp resolver | NEW |
| `reventless/reventless-aws/src/components/Aggregate_Builder_NoResolver.res` | Aggregate builder variant using NoOp resolver | NEW |

## Risk Assessment

- **Platform_Admin.res**: Low risk. Adding fields to the return type is additive. `onAdminComponentsCreated` hook is opt-in (no-op when unset).
- **Plugin_Helpers.res**: Low risk. New functions; no changes to existing `exportPluginOutputs` or `serializeDictExport`.
- **Platform.res (steps 3-4)**: Low risk. Capturing previously-discarded return values.
- **Platform.res (steps 5-6)**: Medium risk. Adds real infrastructure to the platform stack:
  - Plugin aggregate: EventLog DynamoDB table, CommandTopic SQS FIFO queue, EventTopic (DynamoDB Streams), per-aggregate Lambda handler
  - Plugin read model: QueryDb DynamoDB table, EventCollector subscription to Plugin EventTopic, per-read-model Lambda handler
  - Runtime wiring via `onAdminComponentsCreated` hook ensures EP and EventCollector Lambdas have correct env vars
- **NoResolver builders**: Low risk. Identical to Single builders except resolvers produce no resources. Reusable for any future internal components.
