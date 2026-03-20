# Plan: Fix Component and Plugin Outputs ✅

## Problem

Plugin stack outputs are incomplete. The `Plugin.outputs` type defines 18 fields that are all populated internally during `Plugin_Builder.construct()`, but only `_interopMeta` is exported as a Pulumi stack output from `Platform.deployPlugin()`. The `"plugin"`, `"tasks"`, and `"eventMappers"` exports — which `Interstack` queries expect — are missing or incomplete.

Additionally, the `Plugin.outputs` type itself lacks a unified view of all infrastructure resources across components. Consumers cannot easily enumerate all resources a plugin provisions without traversing every sub-component's outputs individually.

### What the Guides Say Should Be in Outputs

From the output-types guide (`docs/guides/output-types-in-reventless-spec.md`):
- Output types are a **cross-stack serialization contract** — they define the JSON shape that `Interstack` deserializes from remote stacks
- `Interstack.stackDependenciesTasks` expects `array<Task.resolvedOutputs>` under the `"tasks"` stack export
- `Interstack.stackDependenciesEventMappers` expects `array<EventMapper.resolvedOutputs>` under the `"eventMappers"` stack export
- `Plugin_Helpers.getRemoteStorageResources` expects `Plugin.resolvedOutputs` under the `"plugin"` stack export (with `readModels` dict containing `queryDb.resources`)

From the platform-and-plugin guide (`docs/guides/platform-and-plugin-guide.md`):
- Plugins should expose resources of all components and extension point information
- Cross-plugin communication depends on extension point outputs being available cross-stack

### Current State

**What IS exported** (in `Platform.deployPlugin()`):
1. `_interopMeta` — field manifest for validation ✅

**What IS exported** (in `Platform.deployPlatform()`):
1. `apiId` — AppSync API ID ✅
2. `apiRoleArn` — AppSync role ARN ✅
3. `extensionPoints` — serialized admin extension points ✅

**What is NOT exported** from plugin stacks:
1. `"plugin"` — the full `Plugin.resolvedOutputs` (with readModels, extensionPoints, DCB slices)
2. `"tasks"` — `array<Task.resolvedOutputs>` (with bucket names, side effect sources)
3. `"eventMappers"` — `array<EventMapper.resolvedOutputs>` (with event collector resources)

**Interop types that exist but aren't wired to exports:**
- `ReventlessInterop.Plugin.resolvedOutputs` — defined, schema exists (but missing DCB slice fields)
- `ReventlessInterop.Task.resolvedOutputs` — defined, schema exists
- `ReventlessInterop.EventMapper.resolvedOutputs` — defined, schema exists

**Interop types that don't exist yet:**
- No `ReventlessInterop` types for DCB components: `DcbEventLog`, `StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `OutboundTranslationSlice`, `InboundTranslationSlice`
- These are needed because `Plugin.outputs` includes dicts of all 5 DCB slice types plus optional `dcbEventLog`, and cross-stack consumers may need to access DCB slice resources (e.g. QueryDb tables for StateViewSlice, AutomationSlice, OutboundTranslationSlice, InboundTranslationSlice)

**DCB slice infra output shapes** (what needs interop counterparts):

| Slice Type | `outputs` fields |
|---|---|
| `DcbEventLog` | `resources: array<Adapter.resource>`, `eventTopic: EventTopic.outputs` |
| `StateChangeSlice` | `resources: array<Adapter.resource>` |
| `StateViewSlice` | `resources: array<Adapter.resource>`, `queryDb: QueryDb.outputs` |
| `AutomationSlice` | `resources: array<Adapter.resource>`, `queryDb: QueryDb.outputs` |
| `OutboundTranslationSlice` | `resources: array<Adapter.resource>`, `queryDb: QueryDb.outputs` |
| `InboundTranslationSlice` | `resources: array<Adapter.resource>`, `queryDb: QueryDb.outputs` |

## Steps

### Step 1: Create interop types for DCB components ✅

Create `resolvedOutputs` types (Output.t-free counterparts) in `reventless-interop` for all DCB components. These are needed before the Plugin interop type can reference them.

**Types to create:**

1. **`DcbEventLog.resolvedOutputs`** — mirrors `DcbEventLog.outputs`:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
     eventTopic: EventTopic.resolvedOutputs,
   }
   ```

2. **`StateChangeSlice.resolvedOutputs`** — mirrors `StateChangeSlice.outputs`:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
   }
   ```

3. **`StateViewSlice.resolvedOutputs`** — mirrors `StateViewSlice.outputs`:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
     queryDb: QueryDb.resolvedOutputs,
   }
   ```
   Needs a `QueryDb.resolvedOutputs` interop type too (currently only `ReadModel.queryDb` exists with `{resources: array<Resource.t>}` — factor into shared type or create `QueryDb.resolvedOutputs`).

4. **`AutomationSlice.resolvedOutputs`** — same shape as StateViewSlice:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
     queryDb: QueryDb.resolvedOutputs,
   }
   ```

5. **`OutboundTranslationSlice.resolvedOutputs`** — same shape:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
     queryDb: QueryDb.resolvedOutputs,
   }
   ```

6. **`InboundTranslationSlice.resolvedOutputs`** — same shape:
   ```rescript
   @schema type resolvedOutputs = {
     resources: array<Resource.t>,
     queryDb: QueryDb.resolvedOutputs,
   }
   ```

**Also needed:** An `EventTopic.resolvedOutputs` type (check if it already exists — `CommandTopic.res` exists in interop). And a shared `QueryDb.resolvedOutputs` type (currently `ReadModel.queryDb` is `{resources: array<Resource.t>}` — consider whether to reuse or create a separate interop type).

**Files to create:**
- `reventless/reventless-interop/src/components/DcbEventLog.res`
- `reventless/reventless-interop/src/components/StateChangeSlice.res`
- `reventless/reventless-interop/src/components/StateViewSlice.res`
- `reventless/reventless-interop/src/components/AutomationSlice.res`
- `reventless/reventless-interop/src/components/OutboundTranslationSlice.res`
- `reventless/reventless-interop/src/components/InboundTranslationSlice.res`
- `reventless/reventless-interop/src/components/QueryDb.res` (shared resolved type)

**Files to check/update:**
- `reventless/reventless-interop/src/components/EventTopic.res` — verify `resolvedOutputs` exists
- `reventless/reventless-interop/rescript.json` — add new source files if needed

### Step 2: Add DCB slice fields to `Plugin.resolvedOutputs` ✅

Update the Plugin interop type to include all DCB component outputs.

**Current `Plugin.resolvedOutputs`:**
```rescript
@schema
type resolvedOutputs = {
  id: string,
  version: string,
  readModels?: dict<ReadModel.resolvedOutputs>,
  extensionPoints?: dict<ExtensionPoint.resolvedOutputs>,
}
```

**Updated to include DCB:**
```rescript
@schema
type resolvedOutputs = {
  id: string,
  version: string,
  readModels?: dict<ReadModel.resolvedOutputs>,
  extensionPoints?: dict<ExtensionPoint.resolvedOutputs>,
  dcbEventLog?: DcbEventLog.resolvedOutputs,
  stateChangeSlices?: dict<StateChangeSlice.resolvedOutputs>,
  stateViewSlices?: dict<StateViewSlice.resolvedOutputs>,
  automationSlices?: dict<AutomationSlice.resolvedOutputs>,
  outboundTranslationSlices?: dict<OutboundTranslationSlice.resolvedOutputs>,
  inboundTranslationSlices?: dict<InboundTranslationSlice.resolvedOutputs>,
}
```

All DCB fields are optional (`?`) so non-DCB plugins serialize without them, maintaining backward compatibility.

**Files to modify:**
- `reventless/reventless-interop/src/components/Plugin.res`

### Step 3: Add `"plugin"` stack export to `Platform.deployPlugin()` ✅

Export the serialized `Plugin.resolvedOutputs` from the plugin stack so that `Plugin_Helpers.getRemoteStorageResources()` can read it cross-stack.

**What to do:**
- In `Platform.deployPlugin()` (`reventless/reventless-aws/src/Platform.res`), after the plugin is built, serialize the plugin's outputs to `Plugin.resolvedOutputs` JSON and call `Pulumi.Pulumi.export("plugin", ...)`.
- The serialization requires resolving `Pulumi.Output.t` wrappers — use `Pulumi.Output.apply` chains to unwrap the nested outputs and build a `ReventlessInterop.Plugin.resolvedOutputs` record.
- Serialize using `S.reverseConvertToJsonOrThrow(ReventlessInterop.Plugin.resolvedOutputsSchema)`.
- **For DCB plugins:** The serialization must include `dcbEventLog`, `stateChangeSlices`, `stateViewSlices`, `automationSlices`, `outboundTranslationSlices`, and `inboundTranslationSlices` when present. Each dict entry's `Adapter.resource` array and optional `QueryDb.outputs.resources` must be resolved.

**Key concern:** The `plugin` export includes `readModels` with `queryDb.resources` and DCB slices with their own `queryDb.resources` — these are `Adapter.resource` records containing `name`, `id`, `urn`, `info`, `service` (all `Pulumi.Output.t<string>`). Each must be resolved before serialization.

**Files to modify:**
- `reventless/reventless-aws/src/Platform.res` — add export in `deployPlugin()`
- May need a helper in `Plugin_Helpers.res` or a new `toResolvedOutputs` function on Plugin

### Step 4: Add `"tasks"` stack export to `Platform.deployPlugin()` ✅

Export the serialized `array<Task.resolvedOutputs>` so that `Interstack.stackDependenciesTasks` can read it cross-stack.

**What to do:**
- In `Platform.deployPlugin()`, extract the tasks dict from plugin outputs, convert each `Task.outputs` → `Task.resolvedOutputs`, serialize to JSON array, and call `Pulumi.Pulumi.export("tasks", ...)`.
- `Task.outputs` has optional fields (`bucketNames?: dict<Pulumi.Output.t<string>>`, `sideEffectSources?: array<string>`). The `bucketNames` values are `Pulumi.Output.t<string>` — each must be resolved.
- Serialize using `S.reverseConvertToJsonOrThrow(ReventlessInterop.Task.resolvedOutputsSchema)`.

**Files to modify:**
- `reventless/reventless-aws/src/Platform.res` — add export in `deployPlugin()`
- May need a `Task.toResolvedOutputs` helper (similar to `ExtensionPoint.toResolvedOutputs`)

### Step 5: Add `"eventMappers"` stack export to `Platform.deployPlugin()` ✅

Export the serialized `array<EventMapper.resolvedOutputs>` so that `Interstack.stackDependenciesEventMappers` can read it cross-stack.

**What to do:**
- EventMapper outputs are nested inside `Aggregate.outputs.eventMapper?`. Iterate over all aggregates, extract event mappers where present, convert to `EventMapper.resolvedOutputs`, serialize, and export.
- `EventMapper.outputs` has `name`, `eventCollector: Pulumi.Output.t<EventCollector.outputs>`, optional `counter?: Counter.outputs`.
- Serialize using `S.reverseConvertToJsonOrThrow(ReventlessInterop.EventMapper.resolvedOutputsSchema)`.

**Files to modify:**
- `reventless/reventless-aws/src/Platform.res` — add export in `deployPlugin()`
- May need an `EventMapper.toResolvedOutputs` helper

### Step 6: Add `toResolvedOutputs` conversion functions ✅

Create conversion functions that resolve `Pulumi.Output.t` wrappers and produce interop-serializable records. Follow the pattern already established by `ExtensionPoint.toResolvedOutputs`.

**Functions to add:**

*Existing components:*
1. `Plugin.toResolvedOutputs: Plugin.outputs => Pulumi.Output.t<ReventlessInterop.Plugin.resolvedOutputs>` — resolves readModels, extensionPoints, and all DCB slice dicts
2. `Task.toResolvedOutputs: Task.outputs => Pulumi.Output.t<ReventlessInterop.Task.resolvedOutputs>` — resolves optional bucketNames
3. `EventMapper.toResolvedOutputs: EventMapper.outputs => Pulumi.Output.t<ReventlessInterop.EventMapper.resolvedOutputs>` — resolves eventCollector and optional counter
4. `ReadModel.toResolvedOutputs: ReadModel.outputs => Pulumi.Output.t<ReventlessInterop.ReadModel.resolvedOutputs>` — resolves queryDb resources
5. `Adapter.resource.toResolvedResource: Adapter.resource => Pulumi.Output.t<ReventlessInterop.Resource.t>` — base helper to resolve a single resource

*DCB components (new):*
6. `DcbEventLog.toResolvedOutputs: DcbEventLog.outputs => Pulumi.Output.t<ReventlessInterop.DcbEventLog.resolvedOutputs>` — resolves resources + eventTopic.resources
7. `StateChangeSlice.toResolvedOutputs: StateChangeSlice.outputs => Pulumi.Output.t<ReventlessInterop.StateChangeSlice.resolvedOutputs>` — resolves resources array
8. `StateViewSlice.toResolvedOutputs: StateViewSlice.outputs => Pulumi.Output.t<ReventlessInterop.StateViewSlice.resolvedOutputs>` — resolves resources + queryDb.resources
9. `AutomationSlice.toResolvedOutputs: AutomationSlice.outputs => Pulumi.Output.t<ReventlessInterop.AutomationSlice.resolvedOutputs>` — resolves resources + queryDb.resources
10. `OutboundTranslationSlice.toResolvedOutputs: OutboundTranslationSlice.outputs => Pulumi.Output.t<ReventlessInterop.OutboundTranslationSlice.resolvedOutputs>` — resolves resources + queryDb.resources
11. `InboundTranslationSlice.toResolvedOutputs: InboundTranslationSlice.outputs => Pulumi.Output.t<ReventlessInterop.InboundTranslationSlice.resolvedOutputs>` — resolves resources + queryDb.resources

**Note:** StateViewSlice, AutomationSlice, OutboundTranslationSlice, and InboundTranslationSlice all share the same `{resources, queryDb}` output shape — consider a shared helper `resolveSliceWithQueryDb(outputs) => Pulumi.Output.t<{resources, queryDb}>` to avoid duplication.

**Files to modify/create:**
- `reventless/reventless-core/src/components/Plugin/Plugin.res` or `Plugin_Helpers.res`
- `reventless/reventless-core/src/components/Task/Task.res` (or add to existing Task module)
- `reventless/reventless-core/src/components/EventMapper/EventMapper.res`
- `reventless/reventless-core/src/components/ReadModel/ReadModel.res`
- `reventless/reventless-core/src/components/DcbEventLog/` — add `toResolvedOutputs`
- `reventless/reventless-core/src/components/StateChangeSlice/` — add `toResolvedOutputs`
- `reventless/reventless-core/src/components/StateViewSlice/` — add `toResolvedOutputs`
- `reventless/reventless-core/src/components/AutomationSlice/` — add `toResolvedOutputs`
- `reventless/reventless-core/src/components/OutboundTranslationSlice/` — add `toResolvedOutputs`
- `reventless/reventless-core/src/components/InboundTranslationSlice/` — add `toResolvedOutputs`

### Step 7: Update `_interopMeta` field manifest to include new exports ✅

The `toInteropMeta` function in `Plugin_Helpers.res` currently computes field manifests for `"tasks"`, `"eventMappers"`, and `"plugin"`. Update it to correctly reflect the fields present in the actual serialized exports, including the new DCB slice fields.

**What to check/update:**
- `taskFieldUnion` correctly identifies optional fields
- `pluginResolved` manifest must now include DCB fields when present: `dcbEventLog`, `stateChangeSlices`, `stateViewSlices`, `automationSlices`, `outboundTranslationSlices`, `inboundTranslationSlices`
- `eventMapperMinimal` manifest is accurate (currently uses hardcoded minimal — should match actual EventMapper output)
- The `pluginResolved` construction (lines 600-611 in `Plugin_Helpers.res`) currently only conditionally includes `readModels` and `extensionPoints` — extend the logic to also conditionally include DCB slice dicts when they are non-empty

**Files to modify:**
- `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` — update `toInteropMeta`

### Step 8: Export `"extensionPoints"` from plugin stacks (not just platform) ✅

Currently `extensionPoints` are only exported from the platform stack via `exportAdminExtensionPoints()`. Plugin stacks that define their own extension points should also export them so other plugin stacks can consume them via `Interstack`.

**What to do:**
- In `Platform.deployPlugin()`, if the plugin has extension points, serialize and export them using the same pattern as `exportAdminExtensionPoints()`.
- Use `ExtensionPoint.toResolvedOutputs` (already exists) and `ReventlessInterop.ExtensionPoint.resolvedOutputsSchema`.

**Files to modify:**
- `reventless/reventless-aws/src/Platform.res` — add EP export in `deployPlugin()`

### Step 9: Update in-memory Platform for consistency ✅

The in-memory platform doesn't use Pulumi stack exports, but its `Plugin.outputs` should be equally accessible for testing. Verify that `Plugin_Helpers.getInteropMeta()` works in in-memory mode and that the `builderOutputs` are fully populated.

**Files to check:**
- `reventless/reventless-in-memory/src/Platform.res`
- In-memory tests that consume plugin outputs

### Step 10: Add integration test for cross-stack output round-trip ✅

Create a test that verifies the serialization round-trip: `Plugin.outputs` → `resolvedOutputs` → JSON → parse back via `ReventlessInterop` schemas.

**What to test:**
- Plugin with aggregates, read models, tasks, extension points, and extensions
- DCB plugin with dcbEventLog, stateChangeSlices, stateViewSlices, automationSlices, outboundTranslationSlices, inboundTranslationSlices
- All `resolvedOutputs` schemas parse correctly from serialized JSON (including DCB interop types)
- `_interopMeta` field manifest matches actual serialized fields (including DCB fields)
- Empty dicts/arrays serialize correctly (edge case)
- Optional fields (no tasks, no event mappers, no DCB slices) serialize correctly
- Mixed plugin: aggregates + DCB slices in same plugin

**Files to create:**
- Test in `reventless/reventless-in-memory/tests/` or `reventless/reventless-core/tests/`

## Design Considerations

### Resource Resolution Chain

The main complexity is resolving nested `Pulumi.Output.t` values for serialization. For example, `Plugin.outputs.readModels` is `Pulumi.Output.t<dict<ReadModel.outputs>>`, where each `ReadModel.outputs.queryDb` is `QueryDb.outputs` containing `resources: array<Adapter.resource>`, and each `Adapter.resource` has `name: Pulumi.Output.t<string>`. This requires multiple levels of `Output.apply`/`Output.flatMap` chains.

Pattern to follow: `ExtensionPoint.toResolvedOutputs` in `reventless-core` already does this for extension points — resolve inner Outputs, build a resolved record, return it wrapped in a single `Output.t`.

### Backward Compatibility

Adding new stack exports is safe — existing stacks that don't export these fields will simply return `None` when queried via `Interstack.getOutputs()`. The `Compat.validateAndProject` layer in `Plugin_Helpers.getRemoteStorageResources` already handles missing fields gracefully.

### Performance

Each export adds one more serialized JSON value to Pulumi's stack state. Plugin outputs with many aggregates and read models could produce large JSON blobs. Consider whether to export the full nested resource details or just the essential fields (names, IDs, ARNs).

## Files Summary

| File | Change |
|------|--------|
| **Interop types (new)** | |
| `reventless/reventless-interop/src/components/DcbEventLog.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/StateChangeSlice.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/StateViewSlice.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/AutomationSlice.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/OutboundTranslationSlice.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/InboundTranslationSlice.res` | Create `resolvedOutputs` type |
| `reventless/reventless-interop/src/components/QueryDb.res` | Create shared `resolvedOutputs` type |
| **Interop types (modified)** | |
| `reventless/reventless-interop/src/components/Plugin.res` | Add DCB slice fields to `resolvedOutputs` |
| `reventless/reventless-interop/src/components/EventTopic.res` | Verify `resolvedOutputs` exists |
| **Conversion functions** | |
| `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` | Add/update `toResolvedOutputs`, update `toInteropMeta` for DCB fields |
| `reventless/reventless-core/src/components/Task/` | Add `Task.toResolvedOutputs` |
| `reventless/reventless-core/src/components/EventMapper/` | Add `EventMapper.toResolvedOutputs` |
| `reventless/reventless-core/src/components/ReadModel/` | Add `ReadModel.toResolvedOutputs` |
| `reventless/reventless-core/src/components/DcbEventLog/` | Add `DcbEventLog.toResolvedOutputs` |
| `reventless/reventless-core/src/components/StateChangeSlice/` | Add `StateChangeSlice.toResolvedOutputs` |
| `reventless/reventless-core/src/components/StateViewSlice/` | Add `StateViewSlice.toResolvedOutputs` |
| `reventless/reventless-core/src/components/AutomationSlice/` | Add `AutomationSlice.toResolvedOutputs` |
| `reventless/reventless-core/src/components/OutboundTranslationSlice/` | Add `OutboundTranslationSlice.toResolvedOutputs` |
| `reventless/reventless-core/src/components/InboundTranslationSlice/` | Add `InboundTranslationSlice.toResolvedOutputs` |
| `reventless/reventless-infra/src/adapter/Adapter.res` | Add `resource.toResolved` helper (if not already present) |
| **Platform exports** | |
| `reventless/reventless-aws/src/Platform.res` | Add `"plugin"`, `"tasks"`, `"eventMappers"`, `"extensionPoints"` exports to `deployPlugin()` (including DCB slices in `"plugin"`) |
| **Testing** | |
| `reventless/reventless-in-memory/src/Platform.res` | Verify consistency |
| `reventless/reventless-in-memory/tests/` | Add round-trip serialization test (aggregate + DCB plugins) |
