---
name: platform-hooks-record-refactor
description: Replace PlatformHooks module type with a platformHooks record with optional fields; eliminate the two mutable ref fields by restructuring their call sites
type: plan
status: complete
---

# Plan: Platform Hooks Record Refactor

**Status:** Backlog
**Prerequisite:** schema-generation-cleanup Step 8 (done — `PlatformHooks` module type now in place)
**Related:** `docs/plans/done/schema-generation-cleanup.md`

## Goal

Step 8 replaced global mutable refs with a `PlatformHooks` **module type** where every field is still a `ref<option<fn>>`. This plan completes the cleanup by:

1. Eliminating the two fields that needed to be mutable refs (`onAdminComponentsCreated`, `localAdminExtensionPoints`) by restructuring their call sites.
2. Replacing the `PlatformHooks` module type with a `platformHooks` **record type** with optional fields — so platforms just write a record literal and `.contents` disappears everywhere.

## Why

With `ref<option<fn>>` in a module type, builders still read `Hooks.xxx.contents` and platforms still do `Hooks.xxx.contents = Some(...)`. The module boundary is explicit but the mutable-ref pattern is unchanged. A record with optional fields:

- Eliminates all `.contents` reads/writes — values are set once, at record creation
- Removes the `module Hooks` definition from both platforms — replaced by a plain `let hooks = { ... }` record literal
- Removes `NoopHooks` module — replaced by `Plugin_Helpers.noHooks` (a `let` binding equal to `{}`)
- Makes the "no hooks needed" case trivial: AWS aggregate builders just use `{ let hooks = {} }`

## Prerequisite analysis: why are two fields currently refs?

### `onAdminComponentsCreated`

Set inside AWS `deployPlatform` because the hook closure captures `pluginRmTableNameRef`, a local variable defined in that function. But `Admin.construct()` already returns an `outputs` record containing `aggregatesOutputs` and `readModelsOutputs`. The hook exists only to intercept those values mid-flight rather than using the return value. Eliminating the hook means using `admin.aggregatesOutputs` and `admin.readModelsOutputs` directly after the `Admin.construct()` call.

### `localAdminExtensionPoints`

Set by `Platform_Admin.construct()` so that `Plugin_Builder.construct()` can find the admin extension points for local (in-memory) wiring instead of going via Interstack. The ref bridges the time gap between:
1. `Plugin_Builder.Make` functor application (captures Hooks, but admin not built yet)
2. `Admin.construct()` (sets the ref)
3. `P.make()` call (reads the ref)

Eliminating it requires passing admin extension points explicitly. The cleanest path: add `~adminExtensionPoints` as an optional parameter to `Plugin.T.make`. After `Admin.construct()` returns, the Platform extracts `admin.extensionPointsOutputs` and passes it to each plugin's `make` call.

## Steps

### Step 1 — Eliminate `onAdminComponentsCreated` in AWS Platform

In `reventless-aws/src/Platform.res`, `deployPlatform` currently sets the hook before calling `Admin.construct()`, then reads the captured `pluginRmTableNameRef` afterward. Restructure to use `admin` directly:

```rescript
// After Admin.construct() returns:
let admin = Admin.construct(...)

// Extract Plugin aggregate CommandTopic queue URL
let publishToAggregatesQueueUrls = Dict.make()
switch admin.aggregatesOutputs->Dict.get("Plugin") {
| Some(pluginAgg) =>
  let queueUrl = pluginAgg.commandTopic->Pulumi.Output.flatMap(ct =>
    switch ct.resources->Array.get(0) {
    | Some(r) => r.id
    | None => Pulumi.Output.make("")
    }
  )
  publishToAggregatesQueueUrls->Dict.set("Plugin", queueUrl)
| None => ()
}

// Extract Plugin read model table name
let pluginReadModelTableName = switch admin.readModelsOutputs->Dict.get("Plugin") {
| Some(pluginRm) => pluginRm.queryDb.resources->Array.get(0)->Option.map(r => r.name)
| None => None
}

PluginExtensionPointRuntime_Builder.registerPluginExtensionPoint(
  ~publishToAggregatesQueueUrls,
  ~pluginReadModelTableName?,
  (),
)
PluginRuntime_Builder.registerConfig(
  ~appSyncApiId,
  ~pluginReadModelTableName?,
  ~clonerEnabled=Config.cloner,
  (),
)
switch pluginReadModelTableName {
| Some(name) => Pulumi.Pulumi.export("pluginRmTableName", name)
| None => ()
}
```

Remove `Hooks.onAdminComponentsCreated.contents = Some(...)` and `pluginRmTableNameRef` entirely.

**Files changed:** `reventless-aws/src/Platform.res`

### Step 2 — Add `~adminExtensionPoints` to `Plugin.T.make` and eliminate `localAdminExtensionPoints`

#### 2a — Extend `Plugin.T`

In `reventless-infra/src/components/Plugin.res`, add an optional labeled argument:

```rescript
module type T = {
  type api
  type role
  type component
  let make: (
    ~name: string,
    ~heartbeatInterval: int,
    // ...existing params...
    ~adminExtensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

#### 2b — Thread through Plugin_Builder

In `Plugin_Builder.Make.make` and `construct`, accept `~adminExtensionPoints=?` and use it directly in the place where `Hooks.localAdminExtensionPoints.contents` is currently read:

```rescript
// Was: switch Hooks.localAdminExtensionPoints.contents { ... }
// Becomes: adminExtensionPoints passed as parameter to construct
let localAdminResolvedEP = switch adminExtensionPoints {
| Some(adminEPs) => adminEPs->Pulumi.Output.flatMap(eps =>
    switch eps->Dict.get(PluginExtensionPointSpec.name) {
    | Some(ep) => ep->ExtensionPoint.toResolvedOutputs->Pulumi.Output.apply(r => Some(r))
    | None => Pulumi.Output.make(None)
    }
  )
| None => Pulumi.Output.make(None)
}
```

#### 2c — Update Platform_Admin

Remove the `Hooks.localAdminExtensionPoints := Some(...)` write at the end of `Platform_Admin.construct()`. `Platform_Admin` no longer needs to coordinate with Plugin_Builder via shared state — it just returns its outputs.

#### 2d — Update Platform implementations

**In-memory Platform** (`makePlatform`):
```rescript
let admin = Admin.construct(...)
let adminExtensionPoints =
  admin.extensionPointsOutputs->Pulumi.Output.apply(eps =>
    eps->Array.map(ep => (ep.name, ep))->Dict.fromArray
  )

let plugins = plugins->Array.map(plugin => {
  module P = unpack(plugin)
  P.make(~scheduler, ~api=(), ~apiRole=(), ~adminExtensionPoints)
})
```

**AWS Platform** (`deployPlatform`):
```rescript
let admin = Admin.construct(...)
let adminExtensionPoints =
  admin.extensionPointsOutputs->Pulumi.Output.apply(eps =>
    eps->Array.map(ep => (ep.name, ep))->Dict.fromArray
  )

let pluginComponents = plugins->Array.map(plugin => {
  module P = unpack(plugin)
  P.make(~scheduler, ~api=appSyncApi, ~apiRole=appSyncApiRole, ~adminExtensionPoints)
})
```

**Files changed:** `reventless-infra/src/components/Plugin.res`, `reventless-core/src/components/Plugin/Plugin_Builder.res`, `reventless-core/src/admin/Platform_Admin.res`, `reventless-in-memory/src/Platform.res`, `reventless-aws/src/Platform.res`

### Step 3 — Replace `PlatformHooks` module type with `platformHooks` record

After Steps 1 and 2, all remaining hooks are statically known at Platform module-application time. None need lazy assignment.

#### 3a — Redefine in `Plugin_Helpers.res`

Remove the `PlatformHooks` module type and `NoopHooks` module. Add:

```rescript
type platformHooks = {
  // ── In-memory GraphQL ──────────────────────────────────────────────────
  mutationResolverHook?: (~kind: mutationKind, ~fields: array<string>, ~commandSchema: S.t<unknown>) => unit,
  mutationBindHook?: (~field: string, ~generateCommand: CommandGenerator.commandGenerator) => unit,
  inboundMutationResolverHook?: (~fieldName: string, ~externalInputSchema: S.t<unknown>) => unit,
  inboundMutationBindReceiveHook?: (~fieldName: string, ~receive: JSON.t => promise<result<string, string>>) => unit,
  schemaTypeRegistrationHook?: array<string> => unit,
  mcpSchemaRegistrationHook?: mcpRegistrationParams => unit,
  // ── AWS AppSync ────────────────────────────────────────────────────────
  preResolversSchemaHook?: (~name: string, Reventless.Plugin.apiSchemaFragment) => Pulumi.Output.t<unit>,
  inboundAppSyncResolverHook?: inboundAppSyncResolverParams => unit,
  dcbAppSyncResolverHook?: dcbAppSyncResolverParams => unit,
  // ── AWS lifecycle ──────────────────────────────────────────────────────
  onDcbEventLogCreated?: unknown => unit,
  onDcbCommandTopicCreated?: unknown => unit,
  onDcbSlicesCreated?: unknown => unit,
  onHeartbeatEpChannelAvailable?: unknown => unit,
}

// Convenience binding — identical to {}, but named for readability.
let noHooks: platformHooks = {}
```

Add a `HooksConfig` module type for use as a functor parameter:

```rescript
module type HooksConfig = {
  let hooks: platformHooks
}
```

#### 3b — Merge hooks into `Plugin_Builder.Make`'s `Spec`

`Plugin_Builder.Make` already has a `Spec` module parameter with `runtimeOps`, `resourceNaming`, and `environment`. Add `hooks` to it:

```rescript
module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
  let environment: string
  let hooks: Plugin_Helpers.platformHooks
}
```

Remove the standalone `Hooks: Plugin_Helpers.PlatformHooks` parameter. Inside `Plugin_Builder.Make`, access hooks as `Spec.hooks.mutationResolverHook` (using `->Option.forEach` or `switch`). Since fields are optional, no `.contents` needed:

```rescript
// Was:  switch Hooks.mutationResolverHook.contents { | Some(fn) => fn(...) | None => () }
// Now:  Spec.hooks.mutationResolverHook->Option.forEach(fn => fn(...))
```

Pass a `HooksConfig` anonymous module to `Dcb_Builder.Make`:
```rescript
module DcbBuilder = Dcb_Builder.Make(
  DcbEventLogStorage,
  DcbEventTopicPublisher,
  DcbCommandTopicChannel,
  PluginRuntimeBuilder,
  Spec,  // Spec satisfies HooksConfig since it has `let hooks`
)
```

#### 3c — Update `Dcb_Builder.Make`

Replace `Hooks: Plugin_Helpers.PlatformHooks` with `HooksConfig: Plugin_Helpers.HooksConfig`. Access as `HooksConfig.hooks.mutationResolverHook->Option.forEach(...)` etc.

#### 3d — Update `Aggregate_Builder.Make`

Replace `Hooks: Plugin_Helpers.PlatformHooks` with `HooksConfig: Plugin_Helpers.HooksConfig`. Access as `HooksConfig.hooks.mutationBindHook->Option.forEach(...)`.

#### 3e — Update `Platform_Admin.Make`

Replace `Hooks: Plugin_Helpers.PlatformHooks` with `HooksConfig: Plugin_Helpers.HooksConfig`. Access as `HooksConfig.hooks.schemaTypeRegistrationHook->Option.forEach(...)` etc. Pass `HooksConfig` (or an anonymous wrapper) to `Dcb_Builder.Make`.

**Files changed:** `reventless-core/src/components/Plugin/Plugin_Helpers.res`, `reventless-core/src/components/Plugin/Plugin_Builder.res`, `reventless-core/src/components/Dcb/Dcb_Builder.res`, `reventless-core/src/components/Aggregate/Aggregate_Builder.res`, `reventless-core/src/admin/Platform_Admin.res`

### Step 4 — Update in-memory Platform

Remove `module Hooks` and all `Hooks.xxx.contents = Some(...)` assignments. Define a single `hooks` record literal. Pass it to builders via the `Spec` and anonymous `HooksConfig` modules:

```rescript
let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
  mutationResolverHook: Some(
    (~kind, ~fields, ~commandSchema) =>
      switch kind {
      | ReventlessCore.Plugin_Helpers.Aggregate =>
        CommandGeneratorResolvers_GraphQL.register(~fields, ~commandSchema)
      | Dcb =>
        fields->Array.forEach(field =>
          CommandGeneratorResolvers_GraphQL.registerDcb(~fieldName=field, ~commandSchema)
        )
      },
  ),
  mutationBindHook: Some(CommandGeneratorResolvers_GraphQL.bindHandler),
  inboundMutationResolverHook: Some(InboundTranslationResolvers_GraphQL.register),
  inboundMutationBindReceiveHook: Some(InboundTranslationResolvers_GraphQL.bindReceive),
  schemaTypeRegistrationHook: Some(sdlTypes => GraphQL_Server.registerTypes(~sdlTypes)),
  mcpSchemaRegistrationHook: Some(mcpFn),  // complex inline fn, same as before
}

module AggregateMaker = Aggregate_Builder.Make(Bus, {let hooks = hooks})
// PluginMaker's Spec gains hooks:
// InMemory_PluginSpec gets `let hooks = hooks` added
module Admin = ReventlessCore.Platform_Admin.Make(..., Config, {let hooks = hooks})
```

Remove `NoopHooks` from `reventless-in-memory/src/components/Aggregate_Builder.res` — replace its usage in tests and examples with `{ let hooks = {} }` (empty record).

**Files changed:** `reventless-in-memory/src/Platform.res`, `reventless-in-memory/src/components/Aggregate_Builder.res`, `reventless-in-memory/src/components/Plugin_Builder.res`, `reventless-in-memory/InMemory_PluginSpec.res` (add `let hooks`)

### Step 5 — Update AWS Platform and builders

Define an `awsHooks` record in `MakeWithConfig` replacing the `module Hooks`. The complex lambda implementations move inline into the record literal (same code, just different packaging):

```rescript
let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
  inboundAppSyncResolverHook: Some(...),
  dcbAppSyncResolverHook: Some(...),
  preResolversSchemaHook: Some(...),
  onDcbEventLogCreated: Some(...),
  onDcbCommandTopicCreated: Some(...),
  onDcbSlicesCreated: Some(...),
  onHeartbeatEpChannelAvailable: Some(...),
  // All in-memory hooks absent — optional fields default to None
}

module PluginBuilderImpl = Plugin.Make({let hooks = hooks})
module Admin = ReventlessCore.Platform_Admin.Make(..., Config, {let hooks = hooks})
```

AWS aggregate builders use `{let hooks = {}}` (or `{let hooks = ReventlessCore.Plugin_Helpers.noHooks}`):

```rescript
// In Aggregate_Builder_Single.res, PerAggregate, Micro, NoResolver:
module Inner = ReventlessCore.Aggregate_Builder.Make(
  Spec, Behavior, EventMappings, RuntimeEnvironment,
  CommandGeneratorResolvers, CommandTopicChannel,
  EventLogStorage.DynamoDbStream, EventTopicPublisher.DynamoDbStream,
  EventCollectorChannel, AggregateRuntimeBuilder,
  {let hooks = ReventlessCore.Plugin_Helpers.noHooks},
)
```

**Files changed:** `reventless-aws/src/Platform.res`, `reventless-aws/src/components/Plugin.res`, `reventless-aws/src/components/Aggregate_Builder_Single/PerAggregate/Micro/NoResolver.res`

### Step 6 — Update examples and tests

Any test or example that constructs `Aggregate_Builder.Make(Bus, SomeHooks)` changes from passing the `NoopHooks` module to passing `{let hooks = {}}`:

```rescript
// Was:
module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus, ReventlessInMemory.Aggregate_Builder.NoopHooks)

// Becomes:
module AggregateMaker = ReventlessInMemory.Aggregate_Builder.Make(Bus, {let hooks = {}})
```

**Files changed:** `reventless-in-memory/tests/components/aggregate/AggregateFixtures.res`, `examples/online-shop-aggregates/**/E2E/*Test.res`

### Step 7 — Build and verify zero warnings

```bash
npx rescript clean && npm run build 2>&1 | grep -E "Warning|warning|error|Error|Bug"
npm test  # in reventless-in-memory
```

## Files changed summary

| Package | Files |
|---------|-------|
| `reventless-infra` | `Plugin.res` — add `~adminExtensionPoints` to `T.make` |
| `reventless-core` | `Plugin_Helpers.res`, `Plugin_Builder.res`, `Dcb_Builder.res`, `Aggregate_Builder.res`, `Platform_Admin.res` |
| `reventless-in-memory` | `Platform.res`, `components/Plugin_Builder.res`, `components/Aggregate_Builder.res`, `InMemory_PluginSpec.res` |
| `reventless-aws` | `Platform.res`, `components/Plugin.res`, `components/Aggregate_Builder_{Single,PerAggregate,Micro,NoResolver}.res` |
| `reventless-in-memory/tests` | `AggregateFixtures.res` |
| `examples/online-shop-aggregates` | `*E2ETest.res` (4 files) |

## Key before/after comparison

**Before (module type, refs):**
```rescript
// Platform defines:
module Hooks: PlatformHooks = {
  let mutationResolverHook = ref(None)
  ...
}
let () = Hooks.mutationResolverHook.contents = Some(fn)

// Builder reads:
switch Hooks.mutationResolverHook.contents {
| Some(fn) => fn(...) | None => ()
}
```

**After (record, optional fields):**
```rescript
// Platform defines:
let hooks: platformHooks = {
  mutationResolverHook: Some(fn),
  ...  // other fields absent = None
}

// Builder reads:
Spec.hooks.mutationResolverHook->Option.forEach(fn => fn(...))
```
