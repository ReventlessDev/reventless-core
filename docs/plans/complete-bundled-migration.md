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

### Step 7: Wire bundled DCB slice builders (BLOCKED)

**Still missing:** DCB EventCollector Lambdas (`AllStateViewSlices`, `AllAutomationSlices`)

The `onDcbSlicesCreated` hook + `finish()` mechanism works — Lambdas start being created. But two blockers prevent completion:

**Blocker 1: Non-bundled path hits serialization error.** `EventCollectorRuntime_Builder_Single.finish()` creates `CallbackFunction` Lambdas → Pulumi closure walker fails on Effect-TS (the same root cause that motivated the entire bundled migration).

**Blocker 2: Bundled path blocked by Platform functor constraint.** The bundled slice builders (`StateViewSlice_Builder_Bundled`, etc.) need `api`/`apiRole` for QueryDb resolvers. These are only available inside `Platform.MakeWithConfig`, but:
- `ReventlessInfra.Platform.T` erases `Bundled` sub-modules from the functor output
- Creating bundled builders outside the functor (with `apiConfigRef`) causes `ReventlessCore` vs `ReventlessInfra` type mismatches when used in `DcbSpec` inside the functor

**Proposed fix:** Add `api` and `apiRole` values to the `ReventlessInfra.Platform.T` interface. This allows bundled slice builders to be created inside the functor where types unify correctly. Small interface change — `api` and `apiRole` are already abstract types in the interface, just missing the value bindings.

**Alternative:** Have the bundled slice builders NOT create QueryDb resolvers (defer resolver creation to a separate hook). The bundled handler only needs the table name, not the full AppSync wiring. Resolvers could be created by the non-bundled path or via a dedicated hook.

## Other changes

- `Platform.res` — added `apiConfigRef` + `getApiConfig()` for external api/apiRole access
- `Platform.res` — added `Bundled` sub-modules on StateViewSlice/AutomationSlice/OutboundTranslationSlice (currently unused due to Blocker 2)

## Key Lessons

1. **ReScript DCE is aggressive**: Module-level `let () = fn()` calls inside constrained functors are removed. Side-effect registration must happen in plain JS entry points or through values that are consumed.

2. **`finish()` timing**: `forEventCollector` runs inside nested `Output.apply` chains. Calling `finish()` synchronously after slice creation is too early. Must defer via `Output.flatMap` + setTimeout or wait for all slice operations to resolve.

3. **Functor constraints erase extra bindings**: `include BaseModule` + adding `module Bundled = ...` inside a constrained functor removes `Bundled` from the output. Only bindings declared in the module type survive.

4. **`registerDcbConfig` from index.mjs**: Works reliably because `index.mjs` runs before any ReScript module init, and plain JS side effects are never DCE'd.
