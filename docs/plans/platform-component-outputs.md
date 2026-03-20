# Add Component Output Fields to Platform Outputs

## Problem

`deployPlugin` exports detailed component outputs (aggregates, readModels, extensionPoints, slices, dcbEventLog, tasks, eventMappers) via `exportPluginOutputs()`. However, `deployPlatform` and `makePlatform` do not export equivalent outputs for their components:

- **`deployPlatform`** only exports `apiId`, `apiRoleArn`, and `extensionPoints`
- **`makePlatform`** exports nothing — all plugin component outputs are discarded (`_plugins`)

This means operators and cross-stack consumers cannot inspect platform-deployed component infrastructure (DynamoDB tables, SQS queues, Lambda functions, etc.) via `pulumi stack output`.

## Goal

Make `deployPlatform` and `makePlatform` export all component output fields using the same serialization pattern as `deployPlugin`.

## Current Architecture

### deployPlugin (already complete)
```
Platform.res:deployPlugin()
  → Plugin.make() returns Plugin.component
  → Component.outputs → Plugin.outputs
  → Plugin_Helpers.exportPluginOutputs(pluginOutputs)
    → Pulumi.export("aggregates", ...)
    → Pulumi.export("readModels", ...)
    → ... (all component dicts)
```

### deployPlatform (missing component outputs)
```
Platform.res:deployPlatform()
  → Admin.construct() returns {adminFragment, dcbMutationEntries, ...}
  → Pulumi.export("apiId", ...)
  → Pulumi.export("apiRoleArn", ...)
  → exportAdminExtensionPoints()
  // ← no component outputs exported
```

### makePlatform (missing plugin outputs)
```
Platform.res:makePlatform()
  → Admin.construct() → discarded
  → plugins.map(P.make()) → _plugins (discarded)
  // ← no outputs exported at all
```

## Implementation Plan

### Step 1: Return plugin component from Admin.construct

**File**: `reventless/reventless-core/src/admin/Platform_Admin.res`

`Admin.construct` internally creates components (aggregates, read models, extension points, event collector) but only returns schema-related fields. We need it to also return the underlying plugin component so its outputs can be exported.

Currently the admin builds components directly (not via `Plugin_Builder.construct`), so there is no single `Plugin.component` to return. Instead, add the built component outputs to the return type:

```rescript
type outputs = {
  adminFragment: ReventlessInfra.Api.schemaFragment,
  dcbMutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  dcbQueryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  dcbEventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  // NEW: component output dicts for stack export
  extensionPointsOutputs: Pulumi.Output.t<array<ExtensionPoint.outputs>>,
  aggregatesOutputs: array<Aggregate.outputs>,
  readModelsOutputs: array<ReadModel.outputs>,
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
}
```

Then return the additional fields from `construct`:

```rescript
{
  adminFragment,
  dcbMutationEntries: dcbResult.mutationEntries,
  dcbQueryEntries: dcbResult.queryEntries,
  dcbEventLogEntries: dcbResult.eventLogEntries,
  extensionPointsOutputs,
  aggregatesOutputs: aggregatesWithoutEventMappers,
  readModelsOutputs,
  dcbEventLogOutputs: dcbResult.dcbEventLogOutputs,
}
```

**Considerations**:
- `extensionPointsOutputs` is computed inside a `Pulumi.Output.apply` chain (line 152-210), so it's already `Pulumi.Output.t<array<ExtensionPoint.outputs>>` — return it as-is
- `aggregatesWithoutEventMappers` (line 138) is `array<Aggregate.outputs>` — available synchronously
- `readModelsOutputs` (line 147) is `array<ReadModel.outputs>` — available synchronously
- `dcbResult.dcbEventLogOutputs` is `option<DcbEventLog.outputs>` — available from DcbBuilder result

### Step 2: Create exportPlatformOutputs helper

**File**: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

Add a new function that serializes admin component outputs as Pulumi stack exports, following the same pattern as `exportPluginOutputs`:

```rescript
let exportPlatformOutputs = (
  ~extensionPointsOutputs: Pulumi.Output.t<array<ExtensionPoint.outputs>>,
  ~aggregatesOutputs: array<Aggregate.outputs>,
  ~readModelsOutputs: array<ReadModel.outputs>,
  ~dcbEventLogOutputs: option<DcbEventLog.outputs>,
) => {
  // Extension points — convert array to named dict
  Pulumi.Pulumi.export(
    "extensionPoints",
    extensionPointsOutputs->Pulumi.Output.flatMap(eps =>
      eps
      ->Array.map(ep =>
        ep
        ->ExtensionPoint.toResolvedOutputs
        ->Pulumi.Output.apply(resolved => (
          ep.name,
          resolved->S.reverseConvertToJsonOrThrow(
            ReventlessInterop.ExtensionPoint.resolvedOutputsSchema,
          ),
        ))
      )
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray->JSON.Encode.object)
    ),
  )

  // Aggregates — convert array to named dict
  let aggregatesDict =
    aggregatesOutputs
    ->Array.map(agg => (agg.name, agg))
    ->Dict.fromArray
  Pulumi.Pulumi.export(
    "aggregates",
    serializeDictExport(
      aggregatesDict->Pulumi.Output.make,
      Aggregate.toResolvedOutputs,
      ReventlessInterop.Aggregate.resolvedOutputsSchema,
    ),
  )

  // ReadModels — convert array to named dict
  let readModelsDict =
    readModelsOutputs
    ->Array.map(rm => (rm.name, rm))
    ->Dict.fromArray
  Pulumi.Pulumi.export(
    "readModels",
    serializeDictExport(
      readModelsDict->Pulumi.Output.make,
      ReadModel.toResolvedOutputs,
      ReventlessInterop.ReadModel.resolvedOutputsSchema,
    ),
  )

  // DCB event log — optional single value
  Pulumi.Pulumi.export(
    "dcbEventLog",
    switch dcbEventLogOutputs {
    | Some(dcbOutputs) =>
      dcbOutputs
      ->DcbEventLog.toResolvedOutputs
      ->Pulumi.Output.apply(resolved =>
        resolved->S.reverseConvertToJsonOrThrow(
          ReventlessInterop.DcbEventLog.resolvedOutputsSchema,
        )
      )
    | None => Pulumi.Output.make(Obj.magic(JSON.Encode.null))
    },
  )
}
```

**Note**: The admin typically has 0 user aggregates and 0 user read models in `deployPlatform` (they're passed as empty arrays). The main useful outputs are `extensionPoints` and `dcbEventLog`. However, exporting all fields keeps consistency with the plugin pattern and supports future admin aggregates/read models.

### Step 3: Wire exportPlatformOutputs in deployPlatform

**File**: `reventless/reventless-aws/src/Platform.res`

In `deployPlatform` (line 548), capture the admin construct result and call `exportPlatformOutputs`:

```rescript
let deployPlatform = (~version) => {
  // ... existing code ...

  let admin = Admin.construct(  // was: let _admin =
    ~version, ~extensionPoints=[module(PluginExtensionPoint)],
    ~aggregates=[], ~readModels=[], ~scheduler,
    ~resourceNaming=Util_ResourceNaming.operations,
    ~api=appSyncApi, ~apiRole=appSyncApiRole, ~dcbSpec=None,
  )

  // ... existing schema push + API exports ...

  // Export component outputs (same pattern as deployPlugin)
  ReventlessCore.Plugin_Helpers.exportPlatformOutputs(
    ~extensionPointsOutputs=admin.extensionPointsOutputs,
    ~aggregatesOutputs=admin.aggregatesOutputs,
    ~readModelsOutputs=admin.readModelsOutputs,
    ~dcbEventLogOutputs=admin.dcbEventLogOutputs,
  )
}
```

This replaces the existing `exportAdminExtensionPoints()` call since `exportPlatformOutputs` now exports extension points with the same format.

### Step 4: Wire plugin outputs in makePlatform

**File**: `reventless/reventless-aws/src/Platform.res`

In `makePlatform` (line 477), capture plugin components and export their outputs:

```rescript
let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
  // ... existing scheduler + admin code ...

  let admin = Admin.construct(  // was: let _admin =
    ~version, ~extensionPoints=[], ~aggregates=[], ~readModels=[],
    ~scheduler, ~resourceNaming=Util_ResourceNaming.operations,
    ~api=appSyncApi, ~apiRole=appSyncApiRole, ~dcbSpec=None,
  )

  // Build each plugin and collect outputs
  let pluginComponents = plugins->Array.map(plugin => {
    module P = unpack(plugin)
    P.make(~scheduler, ~api=appSyncApi, ~apiRole=appSyncApiRole)
  })

  // Export first plugin's outputs (monolithic mode = single plugin)
  // For multi-plugin monolithic, prefix exports with plugin name.
  switch pluginComponents->Array.get(0) {
  | Some(pluginComponent) =>
    let pluginOutputs: ReventlessCore.Plugin.outputs =
      (pluginComponent->Obj.magic: ReventlessCore.Plugin.component)
      ->ReventlessCore.Component.outputs
    ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)
  | None => ()
  }

  // ... existing splitApi code ...
}
```

**Design decision**: In monolithic mode (`makePlatform`), there's typically one plugin. If multiple plugins exist, each plugin's outputs could collide on export keys (both export "aggregates", etc.). Two options:
- **Option A** (simpler): Export only the first plugin's outputs — matches the common single-plugin case
- **Option B** (complete): Prefix exports with plugin name (`"catalog.aggregates"`, `"ordering.aggregates"`)

This plan uses Option A. Option B can be added later if multi-plugin monolithic deployments need distinct outputs.

### Step 5: Verify

- [ ] `npm run build` compiles without errors or warnings
- [ ] Deploy a platform stack → verify `pulumi stack output` shows extensionPoints, aggregates, readModels, dcbEventLog
- [ ] Deploy a plugin stack → verify existing exports unchanged
- [ ] Deploy monolithic → verify plugin component outputs appear

## Files Changed

| File | Change |
|------|--------|
| `reventless/reventless-core/src/admin/Platform_Admin.res` | Extend `outputs` type and `construct` return with component output fields |
| `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` | Add `exportPlatformOutputs` function |
| `reventless/reventless-aws/src/Platform.res` | Wire outputs in `deployPlatform` and `makePlatform` |

## Risk Assessment

- **Platform_Admin.res**: Low risk. Adding fields to the return type is additive. Existing callers that destructure with `let {adminFragment, ...} = Admin.construct(...)` won't break — ReScript allows extra fields.
- **Plugin_Helpers.res**: Low risk. New function, no changes to existing `exportPluginOutputs`.
- **Platform.res**: Low risk. Capturing previously-discarded return values (`_admin` → `admin`, `_plugins` → `pluginComponents`). No behavioral changes to existing deployment paths.
- **No interop type changes needed**: The same `ReventlessInterop` schemas already used by `exportPluginOutputs` are reused here.
