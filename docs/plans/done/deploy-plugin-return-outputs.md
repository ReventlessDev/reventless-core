# Plan: Return pluginOutputs from deployPlugin

**Status:** Done
**Related:** `private-consumer-repo/docs/plans/console-oq2-plugin-registry-persistence.md`

## Goal

Change `deployPlugin` to return `Plugin.outputs` so callers can access the deployed component metadata. This unblocks the business repo's plugin-info persistence — the SDK layer can derive the component list from the returned outputs and write it to DynamoDB, without core needing to know about the Plugin RM store pattern.

## Why

Currently `deployPlugin` returns `unit`. The `pluginOutputs` (aggregates, readModels, slices, etc.) are exported to Pulumi stack state via `exportPluginOutputs` and then discarded. The calling code in each plugin stack has no programmatic access to what was actually deployed.

The business repo needs this data to write `plugin-info:*` entries to the Plugin RM table at deploy time. Without the return value, the only options are: (a) duplicate the component list manually, or (b) put the DynamoDB write inside core's `deployPlugin`, coupling core to a business-layer concern.

Returning the outputs keeps the responsibility boundary clean: core deploys and reports what it deployed; the SDK layer decides what to do with that information.

## Steps

### Step 1 — Change return type in Platform.T

**File:** `reventless/reventless-infra/src/types/Platform.res` (line 193)

```rescript
// Before:
let deployPlugin: (~version: string, ~plugin: module(PluginMaker)) => unit

// After:
let deployPlugin: (~version: string, ~plugin: module(PluginMaker)) => Plugin.outputs
```

The `Plugin.outputs` type is already defined in `reventless/reventless-infra/src/components/Plugin.res` and contains all the component dicts (`aggregates`, `readModels`, `stateChangeSlices`, etc.) as `Pulumi.Output.t` values.

### Step 2 — Return pluginOutputs from AWS Platform implementation

**File:** `reventless/reventless-aws/src/Platform.res` — inside `deployPlugin` (line 780)

Add `pluginOutputs` as the return value:

```rescript
let deployPlugin = (~version, ~plugin: module(PluginMaker)) => {
    Console.log(`[Platform:deployPlugin] v${version}`)
    let scheduler = makeScheduler()

    module P = unpack(plugin)
    let pluginComponent = P.make(~scheduler, ~api=appSyncApi, ~apiRole=appSyncApiRole)

    Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())

    let pluginOutputs: ReventlessCore.Plugin.outputs =
      (pluginComponent->Obj.magic: ReventlessCore.Plugin.component)->ReventlessCore.Component.outputs
    ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)

    pluginOutputs  // ← NEW: return instead of discarding
  }
```

### Step 3 — Return pluginOutputs from in-memory Platform implementation

Check the in-memory platform's `deployPlugin` (if it exists) and apply the same change. If in-memory doesn't implement `deployPlugin`, this step is skipped.

### Step 4 — Update callers in core examples

5 call sites return `unit` today. Since ReScript allows ignoring return values, existing callers continue to work without changes. However, for cleanliness, verify these compile:

- `examples/online-shop-hybrid/catalog-aws/src/Main.res`
- `examples/online-shop-hybrid/ordering-aws/src/Main.res`
- `docs/templates/deploy-aws/plugin-Main.res`

If the compiler warns about unused return values, prefix with `let _ =`.

### Step 5 — Validation

1. `npx rescript clean && npx rescript build` — zero errors
2. All existing test suites pass
3. No behavior change — `exportPluginOutputs` still runs, Pulumi exports unchanged

## Files changed

| File | Change |
|------|--------|
| `reventless-infra/src/types/Platform.res` | `deployPlugin` return type: `unit` → `Plugin.outputs` |
| `reventless-aws/src/Platform.res` | Return `pluginOutputs` from `deployPlugin` |
| In-memory Platform (if applicable) | Same return type change |

## What this unblocks

After this change, private-consumer-repo plugin stacks can:

```rescript
let pluginOutputs = Platform.deployPlugin(~version=..., ~plugin=module(Catalog))
// SDK helper derives component list from pluginOutputs and writes plugin-info to DynamoDB
```

The `PluginRmStore` helper, the plugin-info JSON construction, and the DynamoDB write all live in private-consumer-repo (reventless-sdk), not in core.
