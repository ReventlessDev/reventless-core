# Plan: Complete Bundled Lambda Migration

## Goal

Fix the remaining gaps in the bundled Lambda handler migration. The `bundled-lambda-handlers.md` plan was marked complete, but several components still use non-bundled `CallbackFunction` paths that fail silently due to Pulumi serialization errors. This results in missing Lambda resources in deployed stacks.

## Problem

Deploying the ordering-aws stack produces only 4 Lambda functions (AllReadModels, AllAggregates, OrderingPluginEventColl, DeadLetterQueue). The following are missing:

1. **DCB CommandTopic Lambda** — `forDcbCommandTopic` is a no-op stub in `PluginRuntime_Builder_Bundled`
2. **DCB EventCollector Lambda** — DCB slices (StateViewSlice, AutomationSlice, OutboundTranslationSlice) use non-bundled `EventCollectorRuntime_Builder_Single` which calls `CallbackFunction` and fails silently
3. **Heartbeat Lambda** — `forPluginHeartbeat` is a no-op stub in `PluginRuntime_Builder_Bundled`
4. **Extension Point Lambda** — EP name mismatch: registered as `Spec.name` (e.g. `"Orders"`) but looked up as full component name (e.g. `"OrderingOrdersExtPoint"`)

## Diagnostics from `pulumi up`

```
PluginRuntime_Builder_Bundled: forPluginHeartbeat is a no-op stub
PluginRuntime_Builder_Bundled: forDcbCommandTopic is a no-op stub
ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled: no bundled info for OrderingOrdersExtPoint
EventCollectorChannel_Helpers.connectLambda AllAggregates: eventTopicResources: []
EventCollectorChannel_Helpers.connectLambda AllAggregates: resources: []
```

## Architecture Context

### How DCB CommandTopic works

`Plugin_Builder.res` creates the DCB infrastructure via `Dcb_Builder.res`:

1. `Dcb_Builder.construct()` creates a composite handler that routes:
   - SQS messages from StateChangeSlices
   - InboundTranslationSlice receive functions
   - AppSync direct invocations (CommandGenerator payload format)
2. Returns a `dcbRuntimeSetup` closure that calls `PluginRuntimeBuilder.forDcbCommandTopic(~handler, ~connect)`
3. The handler is a `Pulumi.Output.t<effectHandler>` (a closure)
4. The connect function wires SQS + AppSync resolvers

**Non-bundled path** (`PluginRuntime_Builder_Single`): Creates a `CallbackFunction` Lambda with the handler closure. Works when closures don't capture Effect-TS.

**Bundled path** (`PluginRuntime_Builder_Bundled`): Currently a no-op stub.

### How DCB EventCollector works

DCB slices (StateViewSlice, AutomationSlice, OutboundTranslationSlice) each create an EventCollector that subscribes to the DcbEventLog DynamoDB stream. The EventCollector runtime builder collects all handlers and creates a single Lambda.

**Non-bundled path** (`EventCollectorRuntime_Builder_Single`): Creates a `CallbackFunction` Lambda with captured handler closures → fails silently with Effect serialization.

**Bundled path** (`StateViewSliceRuntime_Builder_Single_Bundled` etc.): Exists but not wired through Platform.res or plugin files.

### How Heartbeat works

`Plugin_Builder.res` creates a Heartbeat component that sends periodic `PluginExtensionPointSpec.Heartbeat(timeout)` commands. The handler is a simple closure that publishes to the PluginExtensionPoint CommandTopic.

### EP name mismatch

`ExtensionPoint_Builder_Bundled.Make()` calls `registerBundledExtensionPoint(~name=Spec.name, ...)` at functor-body time. But `ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled.forCommandTopic` looks up by `commandTopicResource.name` which includes the Plugin prefix (e.g. `"OrderingOrdersExtPoint"`). The names don't match.

## Steps

### Step 1: Fix EP name mismatch

The simplest fix: move the `registerBundledExtensionPoint` call from the functor body into the `make` function, where the full component name is available. Or: change the lookup in `forCommandTopic` to strip prefixes and match against `Spec.name`.

**Option A (preferred)**: Register inside `make` using the component's resource name.

**Files to modify:**
- `reventless-aws/src/components/ExtensionPoint_Builder_Bundled.res` — move registration into `make`, use component resource name

**Verify:** Deploy and check that `no bundled info for` warning disappears and EP Lambda is created.

### Step 2: Wire bundled DCB slice builders through Platform

The bundled slice builders already exist but Platform.res only exposes the non-bundled variants. Add `MakeBundled` variants.

**Files to modify:**
- `reventless-aws/src/Platform.res` — add bundled variants:
  ```rescript
  module StateViewSlice = {
    // existing non-bundled Make...
    module Bundled = StateViewSlice_Builder_Bundled.Make(ApiConfig)
  }
  module AutomationSlice = {
    // existing non-bundled Make...
    module Bundled = AutomationSlice_Builder_Bundled.Make(ApiConfig)
  }
  module OutboundTranslationSlice = {
    // existing non-bundled Make...
    module Bundled = OutboundTranslationSlice_Builder_Bundled.Make(ApiConfig)
  }
  ```
  Note: `InboundTranslationSlice` does NOT need a bundled variant — it doesn't create its own Lambda (it registers mutations on the shared DCB CommandTopic Lambda).

**Files to modify:**
- `examples/online-shop-hybrid/catalog-aws/src/CatalogPlugin_Bundled.res` — switch StateViewSlice uses to bundled
- `examples/online-shop-hybrid/ordering-aws/src/OrderingPlugin_Bundled.res` — switch StateViewSlice, AutomationSlice, OutboundTranslationSlice to bundled

**Pattern for plugin files:**
```rescript
// Before:
module ProductsViewSlice = Platform.StateViewSlice.Make(CatalogPlugin.ProductsView)

// After:
module ProductsViewSlice = Platform.StateViewSlice.Bundled.Make(
  CatalogPlugin.ProductsView,
  { let specModulePath = resolveModule(catalogPkg ++ "/Product/ProductsView.res.mjs") },
)
```

Each bundled slice needs `specModulePath` pointing to the spec module that has the `project` function (StateViewSlice) or `todo`/`publishCommands` pattern (AutomationSlice/OutboundTranslationSlice).

**Verify:** Deploy and check that a DCB EventCollector Lambda appears (e.g. `AllStateViewSlices` or similar).

### Step 3: Implement bundled `forDcbCommandTopic`

The DCB CommandTopic handler is a composite handler created by `Dcb_Builder.res`. It routes SQS messages to StateChangeSlice handlers based on DCB tags. This is different from the aggregate CommandTopic — it doesn't use a Spec/Behavior pattern. Instead, it uses `DcbEventLog_Operations` and the DCB decision model.

**Approach:** The DCB CommandTopic handler closure captures:
- `dcbEventLogOps` (DcbEventLog storage operations)
- StateChangeSlice command handlers (one per slice)
- InboundTranslationSlice receive functions

These are all created at deploy time via Pulumi Outputs. The bundled version needs to reconstruct them at Lambda cold start from:
- DcbEventLog table name (env var)
- StateChangeSlice spec module paths (env vars)
- DCB event schema (from spec modules)

**Files to create:**
- `reventless-aws/src/adapter/Runtime/BundledDcbCommandTopicHandlerFactory.mjs` — factory that:
  1. Imports all StateChangeSlice spec modules
  2. Reconstructs `DcbEventLog_Operations` from table name
  3. Creates composite handler routing commands by DCB tag
  4. Handles InboundTranslationSlice commands (if present)

**Files to modify:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — add `generateBundledDcbCommandTopicEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — add types + FFI binding
- `reventless-aws/src/adapter/Runtime/PluginRuntime_Builder_Bundled.res` — implement `forDcbCommandTopic`:
  - Use registered DCB config (slice spec paths, table name, SQS queue)
  - Generate entry point code
  - Create bundled Lambda via `makeBundledFromEntryPoint`
  - Call `connect(~runtime)` to wire SQS + AppSync

**Config registration pattern:**
Add a `registerDcbConfig` function (similar to `registerConfig` for admin) that stores:
- DCB EventLog table name (`Pulumi.Output.t<string>`)
- Array of StateChangeSlice spec module paths
- Array of InboundTranslationSlice spec module paths (optional)
- DCB event schema module path

The plugin files would call this before the DCB assembly. Alternatively, the `PluginRuntime_Builder_Bundled` could collect the info from the `dcbSpec` passed to `Plugin.make`.

**Key challenge:** The DCB handler (`Dcb_Builder.res` lines 243-280) is a complex composite handler. The factory needs to faithfully reconstruct:
1. `DcbEventLog_Operations.Make(DcbEventLogSpec)(StorageOps)` — for DCB event log operations
2. Per-slice command routing based on DCB event schema tags
3. The `handleJsonCommands` path (SQS) and `handleCommand` path (AppSync direct invoke)

**Verify:** Deploy and check that DCB CommandTopic Lambda appears and StateChangeSlice commands are processed.

### Step 4: Implement bundled `forPluginHeartbeat`

The Heartbeat handler is simple: it publishes a `Heartbeat(timeout)` command to the PluginExtensionPoint CommandTopic via SQS.

**Files to create:**
- `reventless-aws/src/adapter/Runtime/BundledHeartbeatHandlerFactory.mjs` — factory that:
  1. Creates `publishJsons` from SQS queue URL env var
  2. Returns handler: `(event, context) => publishJsons([{id, meta, commandJson: Heartbeat(timeout)}])`

**Files to modify:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — add `generateBundledHeartbeatEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — add types + FFI binding
- `reventless-aws/src/adapter/Runtime/PluginRuntime_Builder_Bundled.res` — implement `forPluginHeartbeat`:
  - Extract PluginExtensionPoint SQS queue URL from the `connect` closure's `remoteChannel`
  - Generate entry point code
  - Create bundled Lambda via `makeBundledFromEntryPoint`
  - Call `connect(~runtime)` to wire CloudWatch Events schedule

**Env vars needed:**
- `EP_QUEUE_URL` — PluginExtensionPoint CommandTopic SQS queue URL
- `HEARTBEAT_ID` — Plugin ID string
- `HEARTBEAT_TIMEOUT` — timeout interval (seconds)

**Verify:** Deploy and check that Heartbeat Lambda appears and is triggered periodically.

### Step 5: Wire bundled Task and Counter through Platform (if used)

Platform.res still uses non-bundled `Task_Builder_PerBucket` and `Counter_Builder`. The bundled variants exist:
- `Task_Builder_PerBucket_Bundled`
- `Counter_Builder_Bundled`

**Files to modify:**
- `reventless-aws/src/Platform.res` — add `Task.MakeBundled` and `Counter.MakeBundled` variants

These are lower priority since the online-shop-hybrid example doesn't use Tasks or Counters. Include if other deployments need them.

### Step 6: End-to-end verification

Deploy all three stacks and verify:
- [ ] Platform stack: Admin components + AppSync API (same as before)
- [ ] Ordering stack: All Lambdas present:
  - [ ] AllAggregates (CustomerAggregate CommandTopic handler)
  - [ ] AllReadModels (CustomersReadModel EventCollector)
  - [ ] OrderingPluginEventColl (Admin EventCollector for Plugin EP)
  - [ ] DCB CommandTopic Lambda (PlaceOrder, ShipOrder, CancelOrder, SyncCatalogProduct)
  - [ ] DCB EventCollector Lambda(s) for StateViewSlices (OrdersView, AvailableProductsView)
  - [ ] DCB EventCollector Lambda for AutomationSlice (AutoShipOrder)
  - [ ] DCB EventCollector Lambda for OutboundTranslationSlice (SendOrderConfirmation)
  - [ ] Heartbeat Lambda
  - [ ] OrdersExtensionPoint CommandTopic Lambda
  - [ ] DeadLetterQueue Lambda
- [ ] Catalog stack: similar verification
- [ ] Invoke a command end-to-end and verify event flow through DCB

## Risk Assessment

- **DCB CommandTopic factory complexity**: The DCB handler is more complex than aggregate/readmodel handlers. The factory must reconstruct the composite routing logic faithfully. Test with multiple StateChangeSlices to verify correct tag-based routing.
- **EP name mismatch fix**: Changing registration timing from functor body to `make` could affect EP builders that register before `make` is called. Verify both plugin-level and platform-level EPs.
- **Slice builder `finish()` ordering**: DCB slice builders have their own `finish()` that must be called after all slices are registered. The Plugin_Builder handles this for non-bundled builders — verify the bundled path follows the same lifecycle.

## Dependencies

- All bundled handler factories from the original plan (Step 8) ✅
- `Util_EntryPoint` entry point generators ✅
- `RuntimeEnvironment_Lambda.makeBundledFromEntryPoint` ✅
- `Util_Bundle.resolveModule` ✅
