# Plan: Complete Bundled Lambda Migration

## Goal

Fix the remaining gaps in the bundled Lambda handler migration. The `bundled-lambda-handlers.md` plan was marked complete, but several components still use non-bundled `CallbackFunction` paths that fail silently due to Pulumi serialization errors. This results in missing Lambda resources in deployed stacks.

## Problem

Deploying the ordering-aws stack produced only 4 Lambda functions. The following were missing:

1. **DCB CommandTopic Lambda** — `forDcbCommandTopic` was a no-op stub
2. **DCB EventCollector Lambda** — DCB slices use non-bundled `EventCollectorRuntime_Builder_Single` which calls `CallbackFunction` and fails with serialization errors
3. **Heartbeat Lambda** — `forPluginHeartbeat` was a no-op stub
4. **Extension Point Lambda** — EP name mismatch prevented bundled info lookup

## Steps

### Step 1: Fix EP name mismatch ✅

Changed lookup in `ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled.forCommandTopic` from exact `Dict.get(epName)` to a two-phase lookup: exact match first, then suffix-based search with dot stripping across all registered names. Handles Plugin prefix + dot removal (e.g. `"Ordering.Orders"` registered → `"OrderingOrdersExtPoint"` looked up).

### Step 2: Wire DCB lifecycle hooks ✅

Added 4 hooks to `Plugin_Helpers.res` (core), called from `Dcb_Builder.res` and `Plugin_Builder.res`:
- `onDcbEventLogCreated` — AWS extracts DynamoDB table name for bundled DCB config
- `onDcbCommandTopicCreated` — AWS extracts SQS queue URL for AutomationSlice/OutboundTranslationSlice
- `onDcbSlicesCreated` — placeholder for calling `finish()` on bundled slice builders (blocked, see Step 7)
- `onHeartbeatEpChannelAvailable` — AWS extracts EP CommandTopic SQS queue URL for heartbeat

Also:
- `AutomationSliceRuntime_Builder_Single_Bundled.res` — added `dcbQueueUrlRef` + `setDcbQueueUrl` (global ref)
- `AutomationSlice_Builder_Bundled.res` / `OutboundTranslationSlice_Builder_Bundled.res` — removed `dcbQueueUrl` from `BundledConfig` (now set via hook)
- `Platform.res` — sets all hooks
- Core slice builders (`StateViewSlice_Builder`, `AutomationSlice_Builder`, `OutboundTranslationSlice_Builder`) — exposed `finish` from `EventCollectorRuntimeBuilder`

### Step 3: Implement bundled `forDcbCommandTopic` ✅

**Files created:**
- `BundledDcbCommandTopicHandlerFactory.mjs` — reconstructs DCB composite handler from spec modules + DynamoDB ops
- `Util_EntryPoint.mjs` — added `generateBundledDcbCommandTopicEntryPoint()`
- `Util_EntryPoint.res` — added types + FFI binding

**Files modified:**
- `PluginRuntime_Builder_Bundled.res` — implemented `forDcbCommandTopic` with `registerDcbConfig` pattern
- Plugin `index.mjs` files — call `registerDcbConfig` before ReScript module init (avoids ReScript DCE)

**Note**: `registerDcbConfig` must be called from plain JS (`index.mjs`) because ReScript's dead code elimination removes module-level side-effect calls inside functors constrained by `Platform.T`.

### Step 4: Implement bundled `forPluginHeartbeat` ✅

**Files created:**
- `BundledHeartbeatHandlerFactory.mjs` — publishes `Heartbeat(timeout)` command via SQS
- `Util_EntryPoint.mjs` — added `generateBundledHeartbeatEntryPoint()`
- `Util_EntryPoint.res` — added types + FFI binding

**Files modified:**
- `PluginRuntime_Builder_Bundled.res` — implemented `forPluginHeartbeat` with `registerHeartbeatConfig`
- `Plugin_Builder.res` — calls `onHeartbeatEpChannelAvailable` hook
- `Platform.res` — sets hook to extract SQS queue URL from remote channel resources

### Step 5: Wire bundled Task and Counter through Platform ✅

Added `Task.MakeBundled` and `Counter.MakeBundled` variants to Platform.res.

### Step 6: End-to-end verification (partial) ✅

**Deployed to ordering-aws alpha — 7 Lambdas (up from 4):**

| Lambda | Status |
|--------|--------|
| `AllAggregates` | ✅ existing |
| `AllReadModels` | ✅ existing |
| `OrderingPluginEventColl` | ✅ existing |
| `DeadLetterQueue` | ✅ existing |
| `OrderingPlugin-dcb-command-topicCmdTopic` | ✅ **NEW** — DCB CommandTopic |
| `OrderingPluginHeartbeat` | ✅ **NEW** — Heartbeat + CloudWatch Events |
| `OrderingOrdersExtPointCmdTopic` | ✅ **NEW** — EP CommandTopic |

### Step 7: Wire bundled DCB slice builders ✅

**Previously blocked** by two issues, now both resolved:

**Blocker 1: Non-bundled path hits serialization error.** ~~`EventCollectorRuntime_Builder_Single.finish()` creates `CallbackFunction` Lambdas → Pulumi closure walker fails on Effect-TS.~~ **BYPASSED** — The bundled path uses `ProjectionRuntime_Builder_Single.finish()` → `RuntimeEnvironment_Lambda.makeBundledFromEntryPoint()`, which never touches `CallbackFunction`. The non-bundled path remains broken but is no longer used by bundled plugins.

**Blocker 2: Bundled path blocked by Platform functor constraint.** **RESOLVED** — Added `let api: api` and `let apiRole: role` value bindings to `ReventlessInfra.Platform.T`. Both implementations updated:
- AWS `Platform.MakeWithConfig`: `let api = appSyncApi` / `let apiRole = appSyncApiRole`
- In-memory `Platform.MakeWithConfig`: `let api = ()` / `let apiRole = ()`

**Plugin wiring:** The hybrid `_Aws` plugin variants (`OrderingPlugin_Aws.res`, `CatalogPlugin_Aws.res`) already use `Platform.StateViewSlice.Bundled.Make(...)`, `Platform.AutomationSlice.Bundled.Make(...)`, and `Platform.OutboundTranslationSlice.Bundled.Make(...)` with `specModulePath` configs. These are assembled into `DcbSpec` arrays alongside non-bundled `StateChangeSlice.Make(...)` slices (StateChangeSlices don't need bundled builders — they share the DCB CommandTopic Lambda).

**Full flow:**
1. Plugin creates slice modules via `Platform.*.Bundled.Make(Spec, Config)` → returns `StateViewSlice.T` etc.
2. Plugin assembles `DcbSpec` with arrays of first-class modules
3. `Dcb_Builder.construct` iterates slices, calling `.make(~dcbEventLog, ~opts)`
4. Each bundled `make` calls `registerStateViewSlice(~name, ~specModulePath, ~queryDbTableName)`
5. `onDcbSlicesCreated` hook fires → `StateViewSliceRuntime_Builder_Single.finish()` + `AutomationSliceRuntime_Builder_Single.finish()`
6. `finish()` generates consolidated entry point code and creates a single bundled Lambda per slice type

**Remaining:** Deploy and verify `AllStateViewSlices` and `AllAutomationSlices` Lambdas appear in the stack (extends Step 6 verification).

## Other changes

- `Platform.res` — added `apiConfigRef` + `getApiConfig()` for external api/apiRole access
- `Platform.res` — added `Bundled` sub-modules on StateViewSlice/AutomationSlice/OutboundTranslationSlice
- `ReventlessInfra.Platform.T` — added `let api: api` and `let apiRole: role` value bindings (Blocker 2 fix)
- AWS `Platform.MakeWithConfig` — exposed `api`/`apiRole` as module-level values
- In-memory `Platform.MakeWithConfig` — exposed `api`/`apiRole` as `unit` values

## Key Lessons

1. **ReScript DCE is aggressive**: Module-level `let () = fn()` calls inside constrained functors are removed. Side-effect registration must happen in plain JS entry points or through values that are consumed.

2. **`finish()` timing**: `forEventCollector` runs inside nested `Output.apply` chains. Calling `finish()` synchronously after slice creation is too early. Must defer via `Output.flatMap` + setTimeout or wait for all slice operations to resolve.

3. **Functor constraints erase extra bindings**: `include BaseModule` + adding `module Bundled = ...` inside a constrained functor removes `Bundled` from the output. Only bindings declared in the module type survive.

4. **`registerDcbConfig` from index.mjs**: Works reliably because `index.mjs` runs before any ReScript module init, and plain JS side effects are never DCE'd.
