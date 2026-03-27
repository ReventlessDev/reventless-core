# Analysis: Optional DCB Spec for Core Module

## Context

Plugins support an optional `~dcbSpec` parameter that wires up a full DCB infrastructure: `DcbEventLog`, `StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `OutboundTranslationSlice`, and `InboundTranslationSlice`. The Core module currently has no DCB support — it only manages aggregates, read models, extension points, and the cloner.

This analysis explores adding the same optional DCB capability to Core, and whether the ~270 lines of DCB construction logic in `Plugin_Builder.construct()` (lines 55–324) can be shared rather than duplicated.

## Existing Shared Logic Between Core and Plugin

Before examining DCB, it's worth noting the current sharing pattern between Core_Builder and Plugin_Builder — because it reveals existing duplication that a broader refactor could address.

### What Core_Helpers Already Re-exports from Plugin_Helpers

`Core_Helpers.res` lines 1–8 are pure aliases:
```rescript
let addEventMapperFns = Plugin_Helpers.addEventMapperFns
let aggregateResources = Plugin_Helpers.aggregateResources
let publishToAggregates = Plugin_Helpers.publishToAggregates
let createAggregatesWithoutEventMappers = Plugin_Helpers.createAggregatesWithoutEventMappers
let addEventMappers = Plugin_Helpers.addEventMappers
let createReadModels = Plugin_Helpers.createReadModels
let createExtensionPoints = Plugin_Helpers.createExtensionPoints
```

Core already depends on Plugin_Helpers for its fundamental component-creation functions. The naming is misleading — these are **shared builder helpers**, not plugin-specific.

### Already-Duplicated Code

**`createResolvers`** — identical 4-line function in both modules:
- `Plugin_Helpers.res:435–439`
- `Core_Helpers.res:10–14`

This should be a single shared function (trivial fix).

**`MakeEventCollectorHelper`** — duplicated functor with different complexity:
- `Plugin_Helpers.res:441–624` (185 lines) — full version with `connect` (Core-stack wiring) and `connectWithoutCore` (standalone)
- `Core_Helpers.res:16–69` (54 lines) — simplified version: `make` returns 2-tuple (no `eventCollectorUrn`), `connect` uses `Core_Callback` with a fake pluginDefinition and only handles extensionPoints (no extensions, no Core-stack setup)

The Core version is a stripped-down subset. The `make` functions differ only in whether `eventCollectorUrn` is returned. The `connect` functions differ substantially because Core's EventCollector doesn't handle extensions or cross-stack wiring.

### Implication

`Plugin_Helpers` is misnamed — it's already the de facto shared builder module. When adding DCB support to Core, the cleanest approach is to either:
1. Rename `Plugin_Helpers` → `Builder_Helpers` (or similar) and consolidate all shared logic there
2. Extract a new `Builder_Helpers.res` with the truly shared parts, leaving Plugin-specific logic in `Plugin_Helpers`

Option 2 is lower-risk since it doesn't rename an existing module. The `createResolvers` duplication and the re-export aliases would move to `Builder_Helpers`, and DCB construction would live there too.

## Current State

### Plugin DCB Flow (Plugin_Builder.res lines 55–324)

When `~dcbSpec` is `Some(module(DcbSpec))`, Plugin_Builder:

1. **Creates DcbEventLog** — `DcbEventLog_Builder.Make(DcbEventLogSpec, Storage, Publisher)`
2. **Creates shared CommandTopic** — single JSON-typed CommandTopic for all StateChangeSlices
3. **Creates StateChangeSlices** — each gets `dcbEventLog` + `publishJsons`
4. **Registers mutation hooks** — `dcbMutationResolverHook`, `inboundMutationResolverHook`, `inboundMutationBindReceiveHook`
5. **Populates query field name registries** — for StateViewSlices, AutomationSlices, OutboundTranslationSlices, InboundTranslationSlices
6. **Creates StateViewSlices, AutomationSlices, OutboundTranslationSlices, InboundTranslationSlices**
7. **Builds composite DCB handler** — merges SQS command handling with InboundTranslation direct invocations
8. **Captures `dcbRuntimeSetup` closure** — called later to wire the DCB CommandTopic Lambda

### What Plugin_Builder Produces from DCB

A 7-tuple:
```rescript
(
  option<DcbEventLog.outputs>,           // dcbEventLogOutputs
  dict<StateChangeSlice.outputs>,        // stateChangeSlicesOutputs
  dict<StateViewSlice.outputs>,          // stateViewSlicesOutputs
  dict<AutomationSlice.outputs>,         // automationSlicesOutputs
  dict<OutboundTranslationSlice.outputs>,// outboundTranslationSlicesOutputs
  dict<InboundTranslationSlice.outputs>, // inboundTranslationSlicesOutputs
  option<unit => unit>,                  // dcbRuntimeSetup
)
```

### Core_Builder Today (Core_Builder.res)

The Core Make functor takes 5 adapter modules:
- `RuntimeEnvironment`
- `EventCollectorChannel`
- `QueryEngineAdapter`
- `ClonerRunner`
- `CoreRuntimeBuilder`

It does **not** take the 3 DCB adapter modules that Plugin_Builder requires:
- `DcbEventLogStorage`
- `DcbEventTopicPublisher`
- `DcbCommandTopicChannel`

### Core API (CoreApi.res)

Core's API schema is built from `PluginBaseFragment.mutationEntries` (Activate/Deactivate) plus a `Clone` mutation. There is no DCB mutation/query integration.

## Proposed Design

### Option A: Extract a Shared `Dcb_Builder` Helper Module

Extract the DCB construction logic from Plugin_Builder into a standalone helper that both Plugin_Builder and Core_Builder can call.

#### New Module: `Dcb_Builder.res`

```rescript
module type Adapters = {
  module DcbEventLogStorage: DcbEventLog_Adapter.Storage
  module DcbEventTopicPublisher: EventTopic_Adapter.Publisher
  module DcbCommandTopicChannel: CommandTopic_Adapter.Channel
}

type dcbResult = {
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
  stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  automationSlicesOutputs: dict<AutomationSlice.outputs>,
  outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
  dcbRuntimeSetup: option<unit => unit>,
  mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
}

module Make = (Adapters: Adapters, RuntimeBuilder: PluginRuntime_Builder.T) => {
  let construct = (
    ~name: string,
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
    ~opts: Pulumi.ComponentResource.options,
  ): dcbResult => {
    // Move the existing ~270 lines from Plugin_Builder here
  }
}
```

**Plugin_Builder** would become:
```rescript
module DcbBuilder = Dcb_Builder.Make(
  { module DcbEventLogStorage = DcbEventLogStorage; ... },
  PluginRuntimeBuilder,
)
let dcbResult = DcbBuilder.construct(~name, ~dcbSpec, ~opts)
```

**Core_Builder** would add the 3 DCB adapter modules to its functor signature:
```rescript
module Make = (
  // ...existing adapters...
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
) => {
  // ...
  module DcbBuilder = Dcb_Builder.Make(
    { module DcbEventLogStorage = DcbEventLogStorage; ... },
    CoreRuntimeBuilder,
  )
  let dcbResult = DcbBuilder.construct(~name="Core", ~dcbSpec, ~opts)
}
```

#### Advantages
- Single source of truth for DCB construction logic
- Both Plugin and Core use identical infrastructure wiring
- Easy to add DCB to future component types (if any)

#### Considerations
- The naming convention (`name` parameter) differs: plugins use the plugin name, Core would use `"Core"`
- Hook registrations (`dcbMutationResolverHook`, etc.) are global refs in `Plugin_Helpers` — they work for both Plugin and Core since they're platform-level (set once by the platform before any component is built)
- `queryFieldNamesRegistry` and `aggregateMutationFieldsRegistry` are also global — Core DCB entries would coexist with plugin entries, which is correct (query field names are keyed by component Spec.name, not by plugin/core)
- API schema integration: the extracted module should return `mutationEntries`, `queryEntries`, and `eventLogEntries` so the caller (Plugin_Builder or Core_Builder) can merge them into its own API fragment generation

### Option B: Share Only the DcbSpec Type, Duplicate Construction

Keep `DcbSpec` as a shared module type (move from `Plugin.res` to a shared location) but duplicate the construction logic in `Core_Builder`.

#### Advantages
- No risk of regression in Plugin_Builder
- Simpler refactor

#### Disadvantages
- ~270 lines of duplicated logic that must stay in sync
- Bug fixes need to be applied in two places
- Future slice types require changes in two places

### Option C: Properly Wire Core in In-Memory, Eliminate `connectWithoutCore`

The in-memory platform currently creates a Core module (`Platform.res:396–402`) but never wires plugins to it:
- `makePlatform` receives `~core` and **ignores it** (`~core as _`, line 414)
- `Interstack.coreStackReference` is `None` (no Pulumi "core" stack config in-memory)
- Plugin_Builder falls into the `connectWithoutCore` path — skipping ConnectPluginExtension, heartbeat-to-Core wiring, and Core PluginExtensionPoint resources
- `makePlatform` then manually registers Core's schemas, queries, and mutation stubs in GraphQL_Server (lines 490–547) instead of letting the Core component handle it

This means the in-memory platform doesn't exercise the same code paths as AWS, weakening test coverage. The `connectWithoutCore` function (54 lines) only exists because the in-memory platform doesn't provide a local Core reference.

#### What Would Change

Instead of `Interstack.coreStackReference` (a Pulumi cross-stack reference), introduce a local Core reference mechanism:
- The in-memory platform would pass Core's outputs (specifically the PluginExtensionPoint outputs) directly to Plugin_Builder, avoiding the need for cross-stack deserialization
- Plugin_Builder would use the same `connect` path in both AWS and in-memory, just with different sources for the Core extension point data
- `connectWithoutCore` could be removed entirely

#### Advantages
- In-memory tests exercise the same plugin↔Core wiring as production
- Eliminates `connectWithoutCore` (54 lines of near-duplicate code)
- Core's extension points, heartbeat, and ConnectPluginExtension work in-memory
- Manual Core schema registration in `makePlatform` (lines 490–547) could be replaced by proper Core component integration

#### Considerations
- The current `connect` path expects `ReventlessInterop.ExtensionPoint.resolvedOutputs` — a serialized/deserialized cross-stack type. In-memory would need to produce this from local outputs, or the connect path needs to accept either local outputs or interop outputs
- Heartbeat wiring to Core may not be useful in-memory (no real keep-alive needed), but having it work is still better for coverage

### Recommendation: Option A + Option C Combined

The DCB construction logic is substantial (~270 lines), self-contained, and identical regardless of whether it runs inside a Plugin or Core context. The only differences are:
1. The `name` parameter (plugin name vs `"Core"`)
2. Where the results are consumed (Plugin outputs vs Core outputs)

Both are already parameterized — the `name` is a function argument, and the results are a returned tuple/record.

Combining Option A (extract shared `Dcb_Builder`) with Option C (properly wire Core in-memory) gives the cleanest result: a single connect path, a single DCB construction module, and in-memory tests that exercise production code paths.

## Changes Required

### 0. Consolidate Existing Shared Logic (Prerequisite)

Before adding DCB support, eliminate the existing duplication:

**Create `Builder_Helpers.res`** in `reventless/reventless-core/src/components/`:
- Move `createResolvers` here (currently duplicated in both Plugin_Helpers and Core_Helpers)
- Move the shared component-creation functions here: `createAggregatesWithoutEventMappers`, `addEventMappers`, `createReadModels`, `createExtensionPoints`, and supporting state (`addEventMapperFns`, `aggregateResources`, `publishToAggregates`, etc.)
- `Plugin_Helpers` keeps plugin-specific logic: `createExtensions`, `createConnectPluginExtension`, `createTasks`, `MakeEventCollectorHelper` (plugin version), hooks, registries, interop meta
- `Core_Helpers` becomes a thin wrapper: just `MakeEventCollectorHelper` (Core version) — the re-export aliases go away since both builders would `open Builder_Helpers` directly

Alternatively, simply rename `Plugin_Helpers` → `Builder_Helpers` if the churn is acceptable — all plugin-specific code stays in the same file, but the name reflects that Core uses it too.

### 1. Move `DcbSpec` to a Shared Location

Currently defined in `Plugin.res`. Move to a new shared file or to `reventless-spec`:

```
reventless/reventless-core/src/components/Dcb/DcbSpec.res
```

Both `Plugin.res` and `Core.res` would reference this shared type. `Plugin.DcbSpec` can become an alias for backward compatibility.

### 2. Create `Dcb_Builder.res`

Location: `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res`

Extract lines 55–324 and 346–468 from `Plugin_Builder.res`. The module should:
- Accept the 3 DCB adapters + RuntimeBuilder as functor arguments
- Accept `~name`, `~dcbSpec`, `~opts` as `construct` arguments
- Return a result record containing outputs, runtime setup closure, and API schema entries
- Call the same `Plugin_Helpers` hooks (they're platform-level, not plugin-specific)

### 3. Update `Plugin_Builder.res`

Replace inline DCB construction with a call to `Dcb_Builder.Make(...)`.construct(...).

### 4. Update `Core_Builder.res`

- Add `DcbEventLogStorage`, `DcbEventTopicPublisher`, `DcbCommandTopicChannel` to the Make functor signature
- Add `~dcbSpec: option<module(DcbSpec)>=?` to `construct` and `make`
- Call `Dcb_Builder.Make(...)`.construct(...)
- Merge DCB event topics into `allEventTopics` (same as Plugin_Builder line 508)
- Wire `dcbRuntimeSetup` (same as Plugin_Builder line 731)

### 5. Update `Core.res`

- Add DCB-related fields to `Core.outputs`:
  ```rescript
  dcbEventLog?: DcbEventLog.outputs,
  stateChangeSlices?: dict<StateChangeSlice.outputs>,
  stateViewSlices?: dict<StateViewSlice.outputs>,
  automationSlices?: dict<AutomationSlice.outputs>,
  outboundTranslationSlices?: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlices?: dict<InboundTranslationSlice.outputs>,
  ```
- Add `~dcbSpec` to the `T` module type's `make` signature

### 6. Update `CoreApi.res`

- Merge DCB mutation/query/eventLog entries into the Core API fragment
- The `Dcb_Builder` result record provides these entries, so CoreApi can consume them

### 7. Update Platform Implementations

Each platform that provides the Core functor arguments must supply the 3 new DCB adapter modules:
- **reventless-aws**: Already has `DcbEventLogStorage`, `DcbEventTopicPublisher`, `DcbCommandTopicChannel` for plugins — reuse the same modules for Core
- **reventless-in-memory**: Same — already provides these for plugins

### 8. Rename `Plugin_Helpers` Hooks (Optional)

The hooks in `Plugin_Helpers` (`dcbMutationResolverHook`, etc.) are not plugin-specific — they're platform-level. Consider either:
- Leaving them in `Plugin_Helpers` (simplest, they work fine as-is)
- Moving to a new `Platform_Hooks.res` module (cleaner naming, but more churn)

Recommendation: leave in `Plugin_Helpers` for now, rename in a future cleanup pass.

## API Schema Integration Detail

The CoreApi currently builds its fragment from hardcoded `PluginBaseFragment` entries + a `Clone` mutation. With DCB support, the flow becomes:

```
CoreApi.generate(~dcbMutationEntries, ~dcbQueryEntries, ~dcbEventLogEntries) =>
  let mutationEntries = PluginBaseFragment.mutationEntries
    ++ dcbMutationEntries
    ++ [Clone]
  let queryEntries = PluginBaseFragment.queryEntries
    ++ dcbQueryEntries
  GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
```

This requires CoreApi to accept the DCB entries as parameters rather than being a static module-level computation. Alternatively, Core_Builder could construct the full fragment itself (similar to Plugin_Builder lines 481–501) and pass it as an output.

## Naming Conventions

Core DCB components would use `"Core"` as the name prefix:
- DcbEventLog topic: `"CoreDcbEventLog"` (matching the pattern `name ++ "DcbEventLog"`)
- DCB CommandTopic: `"CoreCore-dcb-command-topic"` — this needs adjustment since Plugin_Builder uses `childName` which adds the component type suffix. For Core, the naming should be simplified to `"Core-dcb-command-topic"`.

The `Api_Naming` module would need to handle Core DCB field names. Currently `sliceMutationField(~plugin, ~slice)` uses the plugin name as prefix. For Core, the prefix would be `"Core"`:
- `Core_AddProduct` (mutation)
- `Core_ProductsView` / `Core_ProductsViews` (queries)

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Regression in Plugin_Builder during extraction | Extract as pure refactor first, verify all plugin tests pass before adding Core support |
| Hook conflicts (Plugin + Core both calling same hooks) | Hooks are additive (register more resolvers/types); no conflict |
| Naming collisions (Core DCB component names vs Plugin DCB names) | Different `name` prefix ensures unique keys in all registries |
| Core_Builder functor becomes complex | DCB logic is encapsulated in Dcb_Builder; Core_Builder just calls it |
| CoreApi static fragment no longer works | Pass DCB entries as parameters or build fragment in Core_Builder |

## Implementation Order

### Phase 1: Consolidate Existing Duplication (no behavior change)
1. Create `Builder_Helpers.res` with shared functions (`createResolvers`, component-creation helpers, supporting state)
2. Update `Plugin_Helpers.res` and `Core_Helpers.res` to use `Builder_Helpers` instead of duplicating/aliasing
3. Verify all existing tests pass

### Phase 2: Extract DCB Construction (no behavior change)
4. Create `Dcb_Builder.res` by extracting from `Plugin_Builder.res`
5. Update `Plugin_Builder.res` to use `Dcb_Builder` — verify all plugin tests pass

### Phase 3: Wire Core Properly in In-Memory (eliminate `connectWithoutCore`)
6. Introduce a local Core reference mechanism (alternative to `Interstack.coreStackReference`)
7. Update Plugin_Builder to accept local Core outputs alongside cross-stack interop outputs
8. Wire in-memory `makePlatform` to pass Core outputs to plugins
9. Remove `connectWithoutCore` from Plugin_Helpers
10. Remove manual Core schema/query/mutation registration from in-memory `makePlatform`
11. Verify all existing tests pass

### Phase 4: Add Core DCB Support (new capability)
12. Move `DcbSpec` to shared location, alias in `Plugin.res`
13. Add DCB adapter modules to `Core_Builder.Make` functor
14. Add `~dcbSpec` parameter to `Core_Builder.construct` and `Core_Builder.make`
15. Update `Core.res` outputs type
16. Wire DCB entries into CoreApi fragment generation
17. Update platform implementations (AWS, in-memory) to pass DCB adapters to Core
18. Add tests for Core with DCB spec in `reventless-in-memory`
