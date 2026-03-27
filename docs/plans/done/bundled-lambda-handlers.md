# Plan: Replace CallbackFunction with Bundled Lambda Handlers

## Goal

Replace Pulumi's `CallbackFunction` (inline closure serialization) with `aws.lambda.Function` + esbuild-bundled code assets. This eliminates all Pulumi serialization errors caused by non-serializable Effect-TS runtime closures.

## Background

Pulumi's `CallbackFunction` serializes JavaScript closures at deploy time. Any captured variable is walked recursively. Effect-TS's runtime (`FiberRuntime`, `consoleTag`, etc.) contains non-serializable objects, making it impossible to use Effect in any Lambda handler passed to `CallbackFunction`. See `docs/analysis/pulumi-effect-serialization.md`.

## Architecture Change

**Before**: Handler function (closure) -> `CallbackFunction` serializes it -> deploys inline code
**After**: Handler module (file) -> esbuild bundles it -> `aws.lambda.Function` deploys the bundle as a zip asset

The handler logic stays identical. Only the packaging changes.

## Steps

### Step 1: Add `aws.lambda.Function` bindings to `rescript-pulumi-aws` ✅

**Files created/modified**:
- `rescript/rescript-pulumi-pulumi/src/Asset.res` — `FileAsset`, `StringAsset`, `RemoteAsset` bindings
- `rescript/rescript-pulumi-pulumi/src/Archive.res` — `AssetArchive`, `FileArchive`, `RemoteArchive` bindings
- `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res` — added `Function` module with `make`, `get`, `args`, `functionEnvironment` types

The `Function.t` type includes `arn`, `id`, `name`, `invokeArn` as `Pulumi.Output.t<string>`. The `functionEnvironment.variables` uses `dict<Pulumi.Input.t<string>>` to support Pulumi Outputs as env var values.

- [x] Add `Function` module to `Lambda.res`
- [x] Add `Pulumi.Archive` / `Pulumi.Asset` bindings
- [x] Build and verify types compile

### Step 2: Create esbuild bundler utility ✅

**Files created**:
- `reventless/reventless-aws/src/util/Util_Bundle.mjs` — JS bundler (stays JS: uses `esbuild.buildSync`, `fs.mkdtempSync`, `import.meta.url`)
- `reventless/reventless-aws/src/util/Util_Bundle.res` — ReScript bindings

Bundle config: ESM format, node22 target, `@aws-sdk/*` externalized, CJS compatibility banner.

- [x] Add `esbuild` as a dependency of `reventless-aws`
- [x] Create `Util_Bundle.mjs` with `bundleHandler`, `bundleEntryPoint`, `resolveModule`
- [x] Create ReScript bindings
- [x] Test bundling — verified end-to-end with deployed Lambda

### Step 3: Add `makeBundled` to `RuntimeEnvironment_Lambda.res` ✅

Added `makeBundled` and `makeBundledFromEntryPoint` alongside existing `make` (non-breaking).

- [x] Add `makeBundled` to `RuntimeEnvironment_Lambda`
- [x] Add `makeBundledFromEntryPoint` for generated entry points
- [x] Add `bundledEnvironmentMaker` type to `Runtime.res`
- [x] Add `BundledEnvironment` module type
- [x] Add `Function.t` → `CallbackFunction.t` coercion

### Step 4: Bundled aggregate builder — Single strategy ✅

**Verified end-to-end on AWS** with the Category aggregate from online-shop-hybrid.

**Files created**:
- `reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single_Bundled.res` — standalone bundled runtime builder
- `reventless-aws/src/adapter/Runtime/BundledAggregateHandlerFactory.mjs` — cold-start handler chain reconstruction (stays JS: calls compiled ReScript functors dynamically)
- `reventless-aws/src/components/Aggregate_Builder_Single_Bundled.res` — AWS-level builder with `BundledConfig` functor param
- `reventless-aws/src/util/Util_PulumiShim.res` — fake Pulumi Outputs for runtime (converted from JS to ReScript)
- `reventless-aws/src/util/Util_EntryPoint.mjs` — entry point code generator (stays JS: produces JS template literals)
- `reventless-aws/src/util/Util_EntryPoint.res` — types + FFI bindings
- `reventless-aws/src/Platform.res` — added `Aggregate.MakeBundled` (not in Platform.T — AWS-specific)
- `examples/online-shop-hybrid/bundled-test-aws/` — minimal self-contained test stack

**Files modified**:
- `reventless-aws/src/util/Util_DeadLetterQueue.res` — converted from `CallbackFunction` to bundled `Lambda.Function`

- [x] Create `BundledAggregateHandlerFactory.mjs`
- [x] Create `AggregateRuntime_Builder_Single_Bundled.res`
- [x] Create `Aggregate_Builder_Single_Bundled.res`
- [x] Extend `Util_EntryPoint` with `generateBundledAggregateEntryPoint()`
- [x] Convert `Util_PulumiShim` from JS to ReScript
- [x] Convert `Util_DeadLetterQueue` from `CallbackFunction` to bundled Lambda
- [x] Build with zero warnings
- [x] Deploy to AWS and invoke Lambda end-to-end
- [x] Verify event written to DynamoDB

#### Lessons learned during Step 4

**`finish()` timing**: `forCommandTopic` runs inside `Output.apply` (async), so `storedSpecs` is empty when `finish()` is called synchronously after `make()`. The Plugin path already handles this — `Builder_Helpers.finishAggregates` calls `finish()` inside an `Output.apply` that depends on aggregate operations resolving. Direct callers must also defer `finish()` via `Output.apply`.

**ReScript `module Id = Id.String` compiles to `let Id;` (undefined)**: Module aliases don't produce runtime values in ESM exports. The `BundledAggregateHandlerFactory` patches the Spec module: `{ ...specModule, Id: specModule.Id || IdString }`. Future: pass Id module path in config for non-String Id types.

**`EventLog_Operations.Make` layer is required**: Raw `EventLogStorage_DynamoDb_Runtime` functions expect pre-serialized DynamoDB items. The `Aggregate_Callback` passes typed events `{id, meta, event}`. The `EventLog_Operations.Make(Spec)(Ops)` layer handles serialization (id + sequenceNr + type + data + meta decomposition), deserialization, and retry logic. The factory must use this layer, not raw storage ops.

**`RequestContext.res.mjs` path**: Located at `@reventlessdev/reventless-core/src/RequestContext.res.mjs`, NOT in `src/adapter/Runtime/`. Resolved via `Util_Bundle.resolveModule` at deploy time and passed as `requestContextModule` to the entry point generator.

**Behavior functor constraint**: The bundled builder's `Make` functor must use `Reventless.Behavior.T` (from reventless-spec), not `ReventlessCore.Behavior.T`, to match the Platform convention and avoid nominal type mismatches with user code.

**`Aggregate.T` return type**: The `Make` functor must be annotated with `): (ReventlessInfra.Aggregate.T with type api = ... and type component = ...)` to satisfy the Plugin assembly's module type expectations.

**JS files that must stay JS**:
- `Util_Bundle.mjs` — Node-specific APIs (`esbuild.buildSync`, `fs`, `import.meta.url`, `createRequire`)
- `Util_EntryPoint.mjs` — generates JS source code containing backtick template literals that ReScript's parser can't handle
- `BundledAggregateHandlerFactory.mjs` — calls compiled ReScript functors dynamically at runtime; ReScript's static module system can't express "apply a functor with a runtime-provided module value"

### Step 5: Update standalone Lambda creators

These files create `CallbackFunction` directly (not through RuntimeEnvironment):

1. **`CounterHandler_DynamoDbStream.res`** → Deferred to Step 8 (Counter_Builder)
   - The `counterHandler` callback captures deep closure chain: `countsDbCount` (QueryDb) + `jsonEventsHandler` (EventMapper → publishJsons → SQS). Cannot be converted independently — requires full Counter_Builder bundled variant.

2. **`ClonerRunner_Fargate.res`** ✅
   - Converted from `CallbackFunction` to bundled `Lambda.Function` with inline entry point code
   - Entry point reads env vars: `TASK_DEFINITION_ARN`, `CLUSTER_ARN`, `STACK_ORG/PROJECT/STACK`, `SUBNETS`
   - Uses `@aws-sdk/client-ecs` directly (externalized by esbuild, available in Lambda runtime)

3. **`Util_DeadLetterQueue.res`** ✅
   - Converted from `CallbackFunction` to bundled `Lambda.Function` with inline entry point code
   - Was hitting the 70MB serialized payload limit because Pulumi's closure walker pulled in the entire module graph

### Step 6: Resolve handler module paths at deploy time ✅

Module path resolution strategy: `createRequire` + `require.resolve` in `Util_Bundle.resolveModule()`.

- [x] Decide on module path resolution strategy
- [x] Implement `resolveModule` in `Util_Bundle.mjs`
- [x] Test with one handler end-to-end

### Step 7: End-to-end test ✅

Tested with `examples/online-shop-hybrid/bundled-test-aws/` — a minimal self-contained stack deploying one Category aggregate via the bundled builder.

- [x] Deploy stack with bundled Lambda (no prerequisites — creates own AppSync API)
- [x] Verify Lambda created with correct env vars (`HANDLER_0_TABLE`, `HANDLER_0_QUEUE_URL`, `HANDLER_0_QUEUE_ARN`)
- [x] Invoke Lambda with mock SQS event
- [x] Verify command decoded, event log replayed, behavior executed, event generated
- [x] Verify event written to DynamoDB with correct schema (id, sequenceNr, type, data, meta fields)

**Performance**: Init 563ms, execution 239ms, 114MB memory. Acceptable cold start.

Remaining:
- [x] Deploy full online-shop-hybrid with bundled builder replacing Micro path (platform deployed ✅)
- [x] Replace `SQS.Queue.onEvent` with `EventSourceMapping` in all connection paths ✅
  - **Fixed**: DcbEventLogStorage, phantom role, AppSync schema push + stitcher enum + resolver names (see issues #6-#10 below)
  - **Fixed**: Replaced all `SQS.Queue.onEvent` calls with direct `Lambda.EventSourceMapping.make` via `Util_EventSourceMapping.subscribeSqs`. This eliminates `QueueEventSubscription` resources and their Pulumi closure serialization. Changes:
    - `Util_EventSourceMapping.res` — added `subscribeSqs` (creates ESM with Lambda ARN + SQS queue ARN, no `startingPosition`)
    - `CommandTopicChannel_Helpers.subscribeLambda2SqsTopic` — now delegates to `subscribeSqs`
    - `EventCollectorChannel_Helpers.connectLambda` — SQS subscription loop now uses `subscribeSqs`
    - `Util_DeadLetterQueue.res` — replaced `onEvent` calls with `subscribeSqs`
  - Zero `SQS.Queue.onEvent` calls remain in framework code
- [x] Deploy catalog + ordering plugins with bundled aggregates ✅
  - **Fixed**: `Plugin.res` (AWS) used non-bundled `PluginRuntime_Builder_Micro` — switched to `PluginRuntime_Builder_Bundled.Make(EventCollectorChannel)`. This was the hidden source of 3 of the 4 serialization errors (`forDcbCommandTopic`, `forPluginHeartbeat`, `forPluginEventCollector`).
  - **Fixed**: `ExtensionPoint_Builder.res` (AWS) used non-bundled `ExtensionPointRuntime_Builder_PerExtensionPoint`. Updated both plugin files (`CatalogPlugin_Bundled.res`, `OrderingPlugin_Bundled.res`) to use `ExtensionPoint_Builder_Bundled.Make(Spec, Mappings, Config)` directly with module path config.
  - **Added**: `Platform.ExtensionPoint.MakeBundled` variant to Platform.res
  - **Result**: catalog-aws: 4 changes (77 unchanged), ordering-aws: 102 created from scratch. Zero serialization errors.

#### Issues fixed during Step 7 deployment:
1. **Duplicate StackReference URN**: `Interstack.res` and `Query.res` each created StackReferences with the same name as `Platform.MakeWithConfig`. Fixed by adding `makeWithName` binding to StackReference and using unique suffixes (`-interstack`, `-query`).
2. **ESM stack output nesting**: `Pulumi.export("apiId", ...)` goes inside the `default` ESM export, not as a top-level stack output. `StackReference.getOutput("apiId")` returns undefined. Fixed Platform to read from `default` output first, then extract keys.
3. **`finishAggregates` timing**: When aggregates have no EventMapper (`NoEventMappings`), `commandTopicOutputs` was empty → `finish()` called before `forCommandTopic` registered specs. Fixed to wait for ALL commandTopicOutputs, not just those from aggregates with event mappers.
4. **Deploy stacks missing dependencies**: `catalog-aws` and `ordering-aws` `rescript.json` needed `catalog-spec` and `ordering-spec` for cross-plugin extension point references.
5. **Platform functor type constraint**: Bundled plugins need `Platform` constrained with `type api = Types.AppSync.api and type role = Types.AppSync.role` so bundled builder types unify with Plugin assembly expectations.
6. **DCB EventLog missing DynamoDB Stream**: `DcbEventLogStorage_DynamoDb` created tables via `Util_DynamoDb.makeTable` (no stream enabled) and exposed them as `DynamoDb` service resources. But `EventTopicPublisher_DynamoDbStream` calls `findResource(DynamoDbStream)` on the storage resources. Fixed by switching to `Util_DynamoDbStream.makeTable(~streamViewType=NEW_IMAGE)` and `Util_DynamoDbStream.toResource`. Pre-existing bug — never hit because catalog-aws/ordering-aws plugin stacks were never deployed.
7. **Phantom role missing `id`/`name`**: Plugin stacks reconstruct the AppSync IAM role from StackReference `apiRoleArn`. The phantom role only had `arn`, but `QueryDbStorage_DynamoDb.dataSource` accesses `role.id` for the `RolePolicy` resource. Fixed by deriving `id` and `name` from the ARN (`arn:aws:iam::ACCOUNT:role/NAME` → extract last segment after `/`).
8. **AppSync resolvers created before schema push**: Plugin stacks create AppSync resolvers for plugin-specific Query fields, but the schema only has admin types (plugin schema stitched at runtime). Resolvers fail with "Type not found". Fixed by adding `preResolversSchemaHook` to `Plugin_Helpers`: AWS Platform pushes the plugin's schema fragment to AppSync via `startSchemaCreation` before resolvers are created. The hook returns `Output.t<unit>` chained into the resolver creation dependency chain. Polls `GetSchemaCreationStatus` until `ACTIVE`.
9. **GraphQL stitcher `extractLeadingName` ignores `enum` prefix**: `extractLeadingName("enum FooBar { ... }")` returned `"enum"` instead of `"FooBar"`. When both admin and plugin fragments contain enum types, the second enum was skipped as a "duplicate". Fixed by also stripping the `"enum "` prefix.
10. **QueryDb resolvers use unprefixed field names**: `QueryDbResolvers_AppSync.make` created resolvers with `field=name->uncapitalize` (e.g., `categories`) but the schema uses plugin-prefixed names (e.g., `Catalog_Category`). Fixed by checking `queryFieldNamesRegistry` for the plugin-prefixed name: `fieldNameForSingle = registryEntry.singleFieldName`.

### Step 8: Migrate remaining component types

Each component type follows the same pattern as the aggregate builder:
1. Create a `Bundled*HandlerFactory.mjs` that reconstructs the handler chain from imports + env vars
2. Create a `*Runtime_Builder_Single_Bundled.res` that collects descriptors and generates entry points
3. Create an AWS-level `*_Builder_Single_Bundled.res` with module path config

Components to migrate:
- [x] `AggregateRuntime_Builder_PerAggregate` (bundled variant)
- [x] `AggregateRuntime_Builder_Micro` (bundled variant)
- [x] `ReadModel_Builder_Single` (bundled variant)
- [x] `ReadModel_Builder_PerReadModel` (bundled variant)
- [x] `AutomationSlice_Builder` (bundled variant)
- [x] `StateViewSlice_Builder` (bundled variant)
- [x] `ExtensionPoint_Builder` (bundled variant)
- [x] `OutboundTranslationSlice_Builder` (bundled variant)
- [x] `SideEffectHandler_Builder` (bundled variant)
- [x] `Task_Builder` / `Task_Builder_PerBucket` (bundled variant)
- [x] `Counter_Builder` + `CounterHandler_DynamoDbStream` (bundled variant)

#### Step 8a: Aggregate PerAggregate bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_PerAggregate_Bundled.res` — per-aggregate bundled runtime builder (one Lambda per aggregate)
- `reventless-aws/src/components/Aggregate_Builder_PerAggregate_Bundled.res` — AWS builder functor with BundledConfig

Reuses existing `BundledAggregateHandlerFactory.mjs` and `Util_EntryPoint.generateBundledAggregateEntryPoint`. Each aggregate gets its own bundled Lambda with `HANDLER_0_TABLE/QUEUE_URL/QUEUE_ARN` env vars.

#### Step 8b: ReadModel bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledReadModelHandlerFactory.mjs` — factory that reconstructs ReadModel handler chain from Spec + Mappings modules + QueryDb table name
- `reventless-aws/src/adapter/Runtime/EventCollectorRuntime_Builder_Single_Bundled.res` — EventCollector bundled runtime builder for ReadModels
- `reventless-aws/src/components/ReadModel_Builder_Single_Bundled.res` — AWS builder functor with BundledConfig (specModulePath, mappingsModulePath)

**Files modified:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledReadModelEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledReadModelRegistration` type + FFI binding
- `reventless-aws/src/Platform.res` — added `ReadModel.MakeBundled`

**Handler chain reconstruction:**
- `BundledReadModelHandlerFactory.createReadModelHandler()` imports Spec + Mappings modules, creates QueryDb operations from table name via `QueryDbStorage_DynamoDb_Runtime`, applies `ReadModel_Callback.Make` functor, wraps in `EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent`
- `Id` module patching: same approach as aggregates (`specModule.Id || IdString`)

#### Step 8c: ReadModel PerReadModel bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector_Bundled.res` — per-EventCollector bundled runtime builder (one Lambda per ReadModel)
- `reventless-aws/src/components/ReadModel_Builder_PerReadModel_Bundled.res` — AWS builder functor with BundledConfig

Reuses `BundledReadModelHandlerFactory.mjs` and `generateBundledReadModelEntryPoint`. Each ReadModel gets its own bundled Lambda with `HANDLER_0_TABLE` and `HANDLER_0_SOURCE_URN` env vars.

#### Step 8d: StateViewSlice bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledStateViewSliceHandlerFactory.mjs` — factory that decodes DCB events via `Spec.project` and applies `Projection.handleAction` to QueryDb
- `reventless-aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single_Bundled.res` — bundled runtime builder for StateViewSlices
- `reventless-aws/src/components/StateViewSlice_Builder_Bundled.res` — AWS builder with BundledConfig (`specModulePath`)

#### Step 8e: AutomationSlice + OutboundTranslationSlice bundled variants ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledAutomationSliceHandlerFactory.mjs` — shared factory for both AutomationSlice and OutboundTranslationSlice (phase1/phase2 TODO pattern + publishJsons)
- `reventless-aws/src/adapter/Runtime/AutomationSliceRuntime_Builder_Single_Bundled.res` — bundled runtime builder
- `reventless-aws/src/components/AutomationSlice_Builder_Bundled.res` — AWS builder with BundledConfig (`specModulePath`, `dcbQueueUrl`)
- `reventless-aws/src/components/OutboundTranslationSlice_Builder_Bundled.res` — AWS builder sharing AutomationSlice runtime

**publishJsons reconstruction:** DCB CommandTopic SQS queue URL passed as env var, reconstructed via `CommandTopicChannel_SQS_Runtime.publishJsons(queue, "SQS_FIFO")`.

#### Step 8f: ExtensionPoint bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledExtensionPointHandlerFactory.mjs` — factory reconstructing CommandTopic + ExtensionPoint_Callback chain
- `reventless-aws/src/adapter/Runtime/ExtensionPointRuntime_Builder_PerExtensionPoint_Bundled.res` — per-EP bundled runtime builder
- `reventless-aws/src/components/ExtensionPoint_Builder_Bundled.res` — AWS builder with BundledConfig (`specModulePath`, `mappingsModulePath`, `publishToAggregatesQueueUrls`)

**publishToAggregates reconstruction:** Dict of aggregate name → SQS queue URL from env vars, each reconstructed via `publishJsons(queue, "SQS_FIFO")`.

**Limitations:** Scheduler and QueryEngine are no-ops in bundled mode. Will throw if actually called by a mapping. TODO: reconstruct from env vars if needed.

#### Step 8g: Plugin ExtensionPoint bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledPluginExtensionPointHandlerFactory.mjs` — specialized factory for the Plugin EP handler with working queryEngine (inline DynamoDB scan) and scheduler (via CloudWatch Events runtime + PulumiShim)
- `reventless-aws/src/adapter/Runtime/PluginExtensionPointRuntime_Builder_Bundled.res` — bundled runtime builder for the Plugin EP CommandTopic handler

**Files modified:**
- `reventless-aws/src/core/Plugin_ExtensionPoint_Builder.res` — switched from non-bundled `ExtensionPointRuntime_Builder_PerExtensionPoint` to `PluginExtensionPointRuntime_Builder_Bundled`
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledPluginExtensionPointEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledPluginExtensionPointRegistration` type + FFI binding

**Key design decisions:**
- **Inline DynamoDB scan**: QueryEngine_DynamoDb.res.mjs imports `@pulumi/pulumi` (in its `make` function). To avoid pulling Pulumi into the bundle, the factory implements DynamoDB scan directly using `@aws-sdk/lib-dynamodb` (externalized, available at Lambda runtime).
- **Scheduler via PulumiShim**: `ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(role)` expects `role.arn.get()`. Uses `Util_PulumiShim.val(roleArn)` to create a compatible fake output at Lambda cold start.
- **PluginExtensionPoint_Plugin.Make(Spec)**: Mapping module is instantiated at Lambda cold start with reconstructed `Spec.runtimeOps` (SQS send from `Util_PluginMessage_Runtime`) and `updateApiSchema=undefined` (only needed for EventCollector path, not CommandTopic).
- **Optional config**: `registerBundledPluginExtensionPoint` accepts optional `pluginReadModelTableName` and `schedulerRoleArn`. In Platform-only deployment (no Plugin ReadModel), these default to placeholder values — matching the non-bundled behavior where queryEngine/scheduler would also be empty.

#### Step 8h: Admin PluginRuntime_Builder bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/PluginRuntime_Builder_Bundled.res` — Bundled variant of `PluginRuntime_Builder_Micro` (functor taking `EventCollectorChannel`). Full `forPluginEventCollector` implementation with entry point generation; stubs `forPluginHeartbeat` and `forDcbCommandTopic`.
- `reventless-aws/src/adapter/Runtime/BundledAdminEventCollectorHandlerFactory.mjs` — Full factory reconstructing the Admin EventCollector handler chain:
  - SQS event parsing via `handleDynamoDbOrSqsEvent`
  - Admin Callback forwarding to EP outgoing handlers (inline)
  - `ExtensionPoint_Operations.Make` with Plugin EP mapping for outgoing event processing
  - `updateApiSchema` reconstruction: scans Plugin ReadModel, stitches schema via `GraphQL_Stitcher`, pushes to AppSync via `@aws-sdk/client-appsync`
  - Inline DynamoDB scan (avoids `@pulumi/pulumi` import chain from `QueryEngine_DynamoDb`)
  - Inline `injectAwsAuthAll` (avoids `@pulumi/pulumi` import chain from `AppSync_Adapter`)
  - CloudWatch Events scheduler via `ScheduledPublisher_CloudWatchEvents_Runtime` + PulumiShim
  - SNS EventTopic publishing for outgoing events
  - SQS message forwarding for ForwardCommand

**Files modified:**
- `reventless-aws/src/Platform.res` — Replaced `PluginRuntime_Builder_Micro.Make(...)` with `PluginRuntime_Builder_Bundled.Make(EventCollectorChannel)`. Calls `registerConfig(~appSyncApiId, ~clonerEnabled, ())` before creating the Plugin EP.
- `reventless-aws/src/util/Util_EntryPoint.mjs` — Added `generateBundledAdminEventCollectorEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — Added `bundledAdminEventCollectorConfig` type + FFI binding

**Why needed:** The Admin EventCollector handler also used `CallbackFunction` → serialization failure. Even though the Plugin EP CommandTopic was bundled, the Admin EventCollector still went through `PluginRuntime_Builder_Micro`.

**Config registration pattern:** `PluginRuntime_Builder_Bundled.registerConfig()` accepts optional `Pulumi.Output.t<string>` values for infrastructure references (AppSync API ID, Plugin ReadModel table, scheduler role/queue, EP EventTopic ARN). Platform calls `registerConfig` before `Admin.construct`. Values unavailable in Platform-only deployment default to `"NOT_AVAILABLE"` placeholders.

**Runtime capabilities:**
- SQS event parsing and message deletion
- Plugin event forwarding through EP outgoing handlers
- `mapOutgoingEvent` for PluginConnected/Disconnected/Reconnected/Deactivated/Activated
- SNS EventTopic publishing for outgoing events
- AppSync schema stitching on plugin connect/disconnect
- ForwardCommand (queryEngine scan + SQS send)
- Scheduler disconnect timeouts (CloudWatch Events)

**Verified**: Platform stack deployed successfully to AWS alpha.

#### Step 8i: Aggregate Micro bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledCommandGeneratorHandlerFactory.mjs` — factory reconstructing CommandGenerator handler chain: `makeGenerateCommand(publishJsons, serviceName, commandSchema)` → validates command → publishes to SQS
- `reventless-aws/src/adapter/Runtime/BundledEventMapperHandlerFactory.mjs` — factory reconstructing EventMapper handler chain: `MakeCounterHandler(Target)(Mappings)(Ops)` → `MakeEventCollectorHandler(Ops)` → `handleStreamEvent(handleJsonEvents)`. Patches Target.Id and each Mapping Source.Id for runtime gap. No-op counter/queryEngine (TODO).
- `reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Micro_Bundled.res` — Micro bundled runtime builder creating 3 separate Lambdas per aggregate:
  1. CommandTopic Lambda (SQS trigger → aggregate handler)
  2. CommandGenerator Lambda (AppSync invoke → command generation → SQS)
  3. EventMapper Lambda (DynamoDB stream trigger → event mapping → SQS)
- `reventless-aws/src/components/Aggregate_Builder_Micro_Bundled.res` — AWS builder functor with BundledConfig (specModulePath, behaviorModulePath, mappingsModulePath?)

**Files modified:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledCommandGeneratorEntryPoint()` and `generateBundledEventMapperEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledCommandGeneratorEntryPointConfig` and `bundledEventMapperEntryPointConfig` types + FFI bindings
- `reventless-aws/src/Platform.res` — added `Aggregate.MakeBundledMicro`

**BundledConfig for Micro:**
```rescript
module type BundledConfig = {
  let specModulePath: string
  let behaviorModulePath: string
  let mappingsModulePath: option<string>  // None if no EventMapper
}
```

**Key design: separate Lambdas per component type.** Unlike Single/PerAggregate (one Lambda handling all event types), Micro creates independent Lambdas:
- CommandTopic Lambda uses `BundledAggregateHandlerFactory.createCommandTopicHandler` (existing)
- CommandGenerator Lambda uses `BundledCommandGeneratorHandlerFactory.createCommandGeneratorHandler` (new)
- EventMapper Lambda uses `BundledEventMapperHandlerFactory.createEventMapperHandler` (new)

**EventMapper limitations:**
- Counter support is no-op (counter actions log but don't execute)
- QueryEngine is no-op (mappings using queryEngine will get empty results)
- These can be added later by passing table names in the config

#### Step 8j: SideEffectHandler bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledSideEffectHandlerFactory.mjs` — factory that imports SideEffect modules and creates SideEffectHandler_Callback with no-op queryEngine
- `reventless-aws/src/adapter/Runtime/SideEffectHandlerRuntime_Builder_Single_Bundled.res` — bundled runtime builder for SideEffectHandlers (collects descriptors, generates entry points)
- `reventless-aws/src/components/SideEffectHandler_Single_Bundled.res` — AWS builder with BundledConfig (`sideEffectModulePaths: array<string>`)

**Files modified:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledSideEffectEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledSideEffectRegistration` type + FFI binding

**Handler chain reconstruction:**
- `BundledSideEffectHandlerFactory.createSideEffectHandler()` imports SideEffect modules, creates `SideEffectHandler_Callback.Make({sideEffects, queryEngine: noOp})`, wraps in `handleStreamEvent`
- Multiple SideEffect modules per handler supported (all imported statically at cold start)

**Limitations:**
- QueryEngine is no-op (side effects using queryEngine will get empty results). Can be reconstructed from env vars if needed.

#### Step 8k: Task_Builder bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledTaskHandlerFactory.mjs` — factory that imports user's callback module, reconstructs `publishCommands` from SQS queue URL env vars, dispatches `PublishCommands` task actions via `CommandTopicChannel_SQS_Runtime.publishJsons`
- `reventless-aws/src/adapter/Runtime/TaskRuntime_Builder_PerBucket_Bundled.res` — per-bucket bundled runtime builder (one Lambda per bucket, created immediately like non-bundled PerBucket)
- `reventless-aws/src/components/Task_Builder_PerBucket_Bundled.res` — AWS builder with BundledConfig (`callbackModulePaths: dict<string>`, `publishToAggregatesQueueUrls: dict<Output.t<string>>`)

**Files modified:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledTaskBucketEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledTaskBucketEntryPointConfig` type + FFI binding

**BundledConfig:**
```rescript
module type BundledConfig = {
  let callbackModulePaths: dict<string>                       // bucketName → module path
  let publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>  // aggName → SQS queue URL
}
```

**Handler chain reconstruction:**
- `BundledTaskHandlerFactory.createTaskBucketHandler()` imports callback module, reconstructs publishCommands from env var SQS queue URLs
- S3 event → `handleBucketEvent(callback)` → `array<taskAction>` → dispatch PublishCommands via SQS

**Limitations:**
- CreateSchedule/DeleteSchedule task actions are no-ops in bundled mode (logged as warnings). Can be reconstructed from env vars if needed.
- The user's callback module must export `callback` matching `Task.bucketCallback` type as a pure function (no captured deploy-time closures).

#### Step 8l: Counter_Builder bundled variant ✅

**Files created:**
- `reventless-aws/src/adapter/Runtime/BundledCounterHandlerFactory.mjs` — factory that reconstructs the entire Counter handler chain:
  - Imports `Counter_Callback.Make` and `EventMapper_Callback.MakeCounterHandler`
  - Reconstructs `countsDbCount` from counts table name via `QueryDbStorage_DynamoDb_Runtime.count`
  - Reconstructs `publishJsons` from SQS queue URL env var
  - Reconstructs `handleCounterEvents` via `MakeCounterHandler(Target)(Mappings)({publishJsons, queryEngine})`
  - Inline `handleStreamEvent` reimplementation (partition DynamoDB stream records by ARN, parse references/counts)
- `reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Bundled.res` — bundled handler module satisfying `Counter_Adapter.Handler` interface. Creates bundled Lambda, subscribes to both DynamoDB streams via `Util_EventSourceMapping.subscribe`.
- `reventless-aws/src/components/Counter_Builder_Bundled.res` — AWS builder with BundledConfig (`targetSpecModulePath`, `mappingsModulePath`, `publishQueueUrl`)

**Files modified:**
- `reventless-aws/src/util/Util_EntryPoint.mjs` — added `generateBundledCounterEntryPoint()`
- `reventless-aws/src/util/Util_EntryPoint.res` — added `bundledCounterEntryPointConfig` type + FFI binding

**BundledConfig:**
```rescript
module type BundledConfig = {
  let targetSpecModulePath: string                // Target aggregate spec (name, Id, commandSchema)
  let mappingsModulePath: string                  // EventMapper Mappings module
  let publishQueueUrl: Pulumi.Output.t<string>    // SQS queue URL for target aggregate
}
```

**Handler chain reconstruction:**
The Counter is the most complex bundled handler. At cold start, the factory:
1. Reconstructs `countsDbCount` from DynamoDB table name
2. Reconstructs `publishJsons` from SQS queue URL
3. Creates `MakeCounterHandler(Target)(Mappings)({publishJsons, queryEngine})` — the EventMapper counter handler
4. Creates `Counter_Callback.Make({countsDbCount, jsonEventsHandler: counterHandler.handleCounterEvents})`
5. On each DynamoDB Stream event: partitions records by stream ARN (references vs counts), calls `callback.counterHandler(~references, ~counts)`

**Limitations:**
- QueryEngine is no-op for event mappings (mappings using queryEngine will get empty results)
- `addToCounterTarget` operation stays as deploy-time closure (called from EventMapper Lambda, not Counter Lambda)

### Step 8 complete

All component types now have bundled Lambda handler variants:
- Aggregate (Single, PerAggregate, Micro)
- ReadModel (Single, PerReadModel)
- AutomationSlice, StateViewSlice, OutboundTranslationSlice
- ExtensionPoint, PluginExtensionPoint
- Admin EventCollector (PluginRuntime)
- SideEffectHandler
- Task (PerBucket)
- Counter

### Step 9: Clean up ✅

- [x] Remove `CallbackFunction` usage — **N/A**: All remaining usages are intentional (bindings, non-bundled backward compat path, type aliases, AWS SDK bindings). No framework code creates `CallbackFunction` for new handlers.
- [x] Update analysis doc with resolution — Added "Resolution" section to `docs/analysis/pulumi-effect-serialization.md`
- [x] Consider deprecating `CallbackFunction` bindings — **Decision: Keep.** Bindings are still used by the non-bundled runtime path (backward compat), type aliases for Lambda event handler signatures, and AWS SDK bindings (SQS/S3/DynamoDB/Cognito event subscriptions).
- [x] Remove test stack (`examples/online-shop-hybrid/bundled-test-aws/`) — Removed.

## Key Files

| File | Status | Purpose |
|------|--------|---------|
| `reventless-aws/.../AggregateRuntime_Builder_Single_Bundled.res` | ✅ | Bundled runtime builder — collects descriptors, generates entry points |
| `reventless-aws/.../BundledAggregateHandlerFactory.mjs` | ✅ | Lambda cold-start handler chain reconstruction |
| `reventless-aws/.../Aggregate_Builder_Single_Bundled.res` | ✅ | AWS builder functor with BundledConfig |
| `reventless-aws/.../Util_EntryPoint.mjs` | ✅ | Entry point JS code generator |
| `reventless-aws/.../Util_EntryPoint.res` | ✅ | Types + FFI bindings |
| `reventless-aws/.../Util_PulumiShim.res` | ✅ | Fake Pulumi Outputs (ReScript) |
| `reventless-aws/.../Util_Bundle.mjs` | ✅ | esbuild bundler (JS) |
| `reventless-aws/.../Util_Bundle.res` | ✅ | ReScript bindings |
| `reventless-aws/.../Util_DeadLetterQueue.res` | ✅ | Converted to bundled Lambda |
| `reventless-aws/src/Platform.res` | ✅ | Added `Aggregate.MakeBundled`, `MakeBundledPerAggregate`, `MakeBundledMicro`, `ReadModel.MakeBundled` |
| `reventless-aws/.../BundledCommandGeneratorHandlerFactory.mjs` | ✅ | CommandGenerator handler chain reconstruction |
| `reventless-aws/.../BundledEventMapperHandlerFactory.mjs` | ✅ | EventMapper handler chain reconstruction |
| `reventless-aws/.../AggregateRuntime_Builder_Micro_Bundled.res` | ✅ | Micro bundled runtime builder (3 Lambdas per aggregate) |
| `reventless-aws/.../Aggregate_Builder_Micro_Bundled.res` | ✅ | Micro AWS builder functor with BundledConfig |
| `reventless-aws/.../AggregateRuntime_Builder_PerAggregate_Bundled.res` | ✅ | Per-aggregate bundled runtime builder |
| `reventless-aws/.../Aggregate_Builder_PerAggregate_Bundled.res` | ✅ | AWS builder functor with BundledConfig |
| `reventless-aws/.../BundledReadModelHandlerFactory.mjs` | ✅ | ReadModel handler chain reconstruction |
| `reventless-aws/.../EventCollectorRuntime_Builder_Single_Bundled.res` | ✅ | EventCollector bundled runtime builder |
| `reventless-aws/.../ReadModel_Builder_Single_Bundled.res` | ✅ | ReadModel AWS builder with BundledConfig |
| `reventless-aws/.../EventCollectorRuntime_Builder_PerEventCollector_Bundled.res` | ✅ | Per-EventCollector bundled runtime builder |
| `reventless-aws/.../ReadModel_Builder_PerReadModel_Bundled.res` | ✅ | ReadModel PerReadModel AWS builder with BundledConfig |
| `reventless-aws/.../ClonerRunner_Fargate.res` | ✅ | Converted to bundled Lambda.Function |
| `reventless-core/.../Runtime.res` | ✅ | `handlerRef`, `BundledEnvironment` types |
| `reventless-core/.../RuntimeEnvironment_Lambda.res` | ✅ | `makeBundled`, `makeBundledFromEntryPoint` |
| `reventless-aws/.../BundledPluginExtensionPointHandlerFactory.mjs` | ✅ | Plugin EP handler chain reconstruction with queryEngine + scheduler |
| `reventless-aws/.../PluginExtensionPointRuntime_Builder_Bundled.res` | ✅ | Plugin EP bundled runtime builder |
| `reventless-aws/src/core/Plugin_ExtensionPoint_Builder.res` | ✅ | Switched to bundled runtime builder |
| `reventless-aws/.../BundledAdminEventCollectorHandlerFactory.mjs` | ✅ | Full Admin EventCollector handler chain reconstruction |
| `reventless-aws/.../PluginRuntime_Builder_Bundled.res` | ✅ | Bundled Admin runtime builder (replaces PluginRuntime_Builder_Micro) |
| `reventless-aws/.../BundledSideEffectHandlerFactory.mjs` | ✅ | SideEffectHandler handler chain reconstruction |
| `reventless-aws/.../SideEffectHandlerRuntime_Builder_Single_Bundled.res` | ✅ | SideEffectHandler bundled runtime builder |
| `reventless-aws/.../SideEffectHandler_Single_Bundled.res` | ✅ | SideEffectHandler AWS builder with BundledConfig |
| `reventless-aws/.../BundledTaskHandlerFactory.mjs` | ✅ | Task bucket handler chain reconstruction |
| `reventless-aws/.../TaskRuntime_Builder_PerBucket_Bundled.res` | ✅ | Task per-bucket bundled runtime builder |
| `reventless-aws/.../Task_Builder_PerBucket_Bundled.res` | ✅ | Task AWS builder with BundledConfig |
| `reventless-aws/.../BundledCounterHandlerFactory.mjs` | ✅ | Counter handler chain reconstruction (deepest closure chain) |
| `reventless-aws/.../CounterHandler_DynamoDbStream_Bundled.res` | ✅ | Counter bundled handler (replaces CounterHandler_DynamoDbStream) |
| `reventless-aws/.../Counter_Builder_Bundled.res` | ✅ | Counter AWS builder with BundledConfig |

## Risk Assessment

- **esbuild at deploy time**: Adds ~0.5s per handler during `pulumi up`. Acceptable.
- **Lambda Layer**: Bundled handlers are self-contained (all deps bundled except `@aws-sdk/*`). Layer is still attached but only needed for shared native modules.
- **ESM**: Lambda nodejs22.x + esbuild ESM output + `.res.mjs` all work together. Verified.
- **Handler type API change**: Bundled builder uses `BundledConfig` functor param (specModulePath, behaviorModulePath). Non-breaking — existing Micro/Single builders unchanged.
- **Id module runtime gap**: `module Id = Id.String` doesn't produce a runtime value. Factory patches it. Works for `Id.String`; other Id types need the Id module path in config (TODO).

## Dependencies

- `esbuild` npm package (added to `reventless-aws` dependencies) ✅
- `@pulumi/aws` Function resource (bindings added) ✅
- `@pulumi/pulumi` Asset/Archive (bindings added) ✅
