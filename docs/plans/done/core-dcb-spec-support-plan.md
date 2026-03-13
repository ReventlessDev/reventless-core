# Plan: Optional DCB Spec Support for Core Module

**Status:** All phases complete.
**Analysis:** `docs/analysis/core-dcb-spec-support.md`

## Goal

Add optional `~dcbSpec` support to the Core module (matching the existing Plugin capability), extract shared DCB construction logic into a reusable `Dcb_Builder`, consolidate existing builder duplication, and properly wire Core in the in-memory platform to eliminate the `connectWithoutCore` code path.

## Phases

### Phase 1 — Consolidate Existing Builder Duplication (no behavior change)

#### Step 1 — Create `Builder_Helpers.res` ✅

File: `reventless/reventless-core/src/components/Builder_Helpers.res`

Extract shared builder functions that are currently duplicated or aliased between `Plugin_Helpers` and `Core_Helpers`:

- `createResolvers` — currently identical 4-line function in both modules (`Plugin_Helpers.res:435–439`, `Core_Helpers.res:10–14`)
- Component-creation helpers currently re-exported from `Plugin_Helpers` via `Core_Helpers` aliases: `addEventMapperFns`, `aggregateResources`, `publishToAggregates`, `createAggregatesWithoutEventMappers`, `addEventMappers`, `createReadModels`, `createExtensionPoints`

**Files changed:**
- `reventless-core/src/components/Builder_Helpers.res` — New
- `Plugin_Helpers.res` — Remove functions moved to `Builder_Helpers`, import from `Builder_Helpers` instead
- `Core_Helpers.res` — Remove re-export aliases, import from `Builder_Helpers` instead
- `Plugin_Builder.res` — Update imports
- `Core_Builder.res` — Update imports

#### Step 2 — Verify all existing tests pass ✅

94 suites, 783 tests pass. No behavior change — pure refactor.

---

### Phase 2 — Extract DCB Construction Logic (no behavior change)

#### Step 3 — Create `Dcb_Builder.res` ✅

File: `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res`

Extract DCB construction logic from `Plugin_Builder.res` (lines 55–324, 346–468) into a standalone module:

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
  ): dcbResult => { ... }
}
```

The module should:
- Accept the 3 DCB adapters + RuntimeBuilder as functor arguments
- Accept `~name`, `~dcbSpec`, `~opts` as `construct` arguments
- Return a result record containing outputs, runtime setup closure, and API schema entries
- Call the existing `Plugin_Helpers` hooks (they're platform-level, not plugin-specific)

**Files changed:**
- `reventless-core/src/components/Dcb/Dcb_Builder.res` — New

#### Step 4 — Update `Plugin_Builder.res` to use `Dcb_Builder` ✅

Replace inline DCB construction in `Plugin_Builder.res` with:

```rescript
module DcbBuilder = Dcb_Builder.Make(
  { module DcbEventLogStorage = DcbEventLogStorage; ... },
  PluginRuntimeBuilder,
)
let dcbResult = DcbBuilder.construct(~name, ~dcbSpec, ~opts)
```

Consume `dcbResult` fields where the existing code uses the 7-tuple values.

**Files changed:**
- `Plugin_Builder.res` — Replace inline DCB logic with `Dcb_Builder` call

#### Step 5 — Verify all existing tests pass ✅

94 suites, 783 tests pass. No behavior change.

---

### Phase 3 — Wire Core Properly in In-Memory Platform (eliminate `connectWithoutCore`)

#### Step 6 — Introduce local Core reference mechanism ✅

Core_Builder.construct() now stores its outputs in `Plugin_Helpers.localCoreOutputs` during construction. Plugin_Builder reads this ref when `Interstack.coreStackReference` is `None` (e.g. in-memory), extracts the PluginExtensionPoint, converts to resolved format via `ExtensionPoint.toResolvedOutputs`, and creates a local RemoteChannel. This gives the in-memory platform the same Core→Plugin connection path as AWS.

Key changes:
- `Plugin_Helpers.localCoreOutputs: ref<option<Core.outputs>>` — set by Core_Builder during construction
- Plugin_Builder derives `localCoreResolvedEP` from local Core outputs as Interstack fallback
- `connect` unified to handle both with-Core and without-Core cases via optional parameters

**Files changed:**
- `Plugin_Helpers.res` — Add `localCoreOutputs` ref, unify `connect` with optional Core params, remove `connectWithoutCore`
- `Plugin_Builder.res` — Add `localCoreResolvedEP` computation, use as fallback when Interstack is None
- `Core_Builder.res` — Set `Plugin_Helpers.localCoreOutputs` during construction

#### Step 7 — Wire in-memory `makePlatform` to pass Core outputs to plugins (skipped)

Not needed — Core_Builder.construct() sets `localCoreOutputs` directly during construction, before Plugin_Builder runs. No changes needed in Platform.res makePlatform for the Core→Plugin connection.

#### Step 8 — Remove `connectWithoutCore` ✅

- Removed `connectWithoutCore` from `Plugin_Helpers.MakeEventCollectorHelper` (72 lines)
- Unified `connect` to handle both cases via optional `~corePluginExtensionPointUnwrapped`, `~connectPluginExtensionIncomingEventHandler`, and `~connectPluginExtensionOutputs` parameters
- Manual Core schema/query/mutation registration in `makePlatform` retained — it's platform-specific (in-memory GraphQL server) and cannot move to Core_Builder

**Files changed:**
- `Plugin_Helpers.res` — Remove `connectWithoutCore`, unify `connect`

#### Step 9 — Verify all existing tests pass ✅

94 suites, 783 tests pass. In-memory plugins now use the same `connect` path with local Core outputs.

---

### Phase 4 — Add Core DCB Support (new capability)

#### Step 10 — Move `DcbSpec` to shared location (skipped)

DcbSpec already exists in both `ReventlessInfra.Plugin.DcbSpec` (reventless-infra) and `ReventlessCore.Plugin.DcbSpec` (reventless-core). Both Core.T and Plugin.T reference DcbSpec from their respective packages. No move needed — the `Obj.magic` bridge handles the nominal type path difference at the Platform boundary.

#### Step 11 — Add DCB adapter modules to `Core_Builder.Make` ✅

Add the 3 DCB adapter modules to Core_Builder's functor signature:

```rescript
module Make = (
  // ...existing adapters...
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
) => { ... }
```

Add `~dcbSpec: option<module(DcbSpec)>=?` to `construct` and `make`.

Call `Dcb_Builder.Make(...)`.construct(...) and wire results:
- Merge DCB event topics into `allEventTopics`
- Wire `dcbRuntimeSetup` closure

**Files changed:**
- `Core_Builder.res` — Add DCB functor args, call Dcb_Builder

#### Step 12 — Update `Core.res` outputs type ✅

Add DCB-related optional fields to `Core.outputs`:

```rescript
dcbEventLog?: DcbEventLog.outputs,
stateChangeSlices?: dict<StateChangeSlice.outputs>,
stateViewSlices?: dict<StateViewSlice.outputs>,
automationSlices?: dict<AutomationSlice.outputs>,
outboundTranslationSlices?: dict<OutboundTranslationSlice.outputs>,
inboundTranslationSlices?: dict<InboundTranslationSlice.outputs>,
```

Add `~dcbSpec` to the `T` module type's `make` signature.

**Files changed:**
- `Core.res` — Add DCB output fields and `~dcbSpec` to module type

#### Step 13 — Wire DCB entries into CoreApi ✅

Update `CoreApi.res` to accept and merge DCB mutation/query/eventLog entries into the Core API fragment:

```rescript
CoreApi.generate(~dcbMutationEntries, ~dcbQueryEntries, ~dcbEventLogEntries) =>
  let mutationEntries = PluginBaseFragment.mutationEntries
    ++ dcbMutationEntries
    ++ [Clone]
  let queryEntries = PluginBaseFragment.queryEntries
    ++ dcbQueryEntries
  GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
```

**Files changed:**
- `CoreApi.res` — Accept DCB entries as parameters

#### Step 14 — Update platform implementations ✅

Each platform must supply the 3 new DCB adapter modules to Core:
- **reventless-aws**: Reuse existing `DcbEventLogStorage`, `DcbEventTopicPublisher`, `DcbCommandTopicChannel` (already provided for plugins)
- **reventless-in-memory**: Same — already provides these for plugins

**Files changed:**
- `reventless-aws/` — Pass DCB adapters to Core_Builder
- `reventless-in-memory/src/Platform.res` — Pass DCB adapters to Core_Builder

#### Step 15 — Add tests for Core with DCB spec

Add E2E tests in `reventless-in-memory` that create a Core component with a `~dcbSpec` and verify:
- DCB components are created (StateChangeSlice, StateViewSlice, etc.)
- DCB mutations and queries appear in Core API schema
- DCB event flow works end-to-end through Core

**Files changed:**
- `reventless-in-memory/tests/` — New Core DCB E2E test files

## Naming Conventions

- Core DCB components use `"Core"` as the name prefix
- DcbEventLog topic: `"CoreDcbEventLog"` (pattern: `name ++ "DcbEventLog"`)
- DCB CommandTopic: `"Core-dcb-command-topic"` (simplified from plugin pattern which adds component type suffix)
- API field names: `Core_AddProduct` (mutation), `Core_ProductsView` / `Core_ProductsViews` (queries) — uses `Api_Naming` with `"Core"` prefix

## Risks

| Risk | Mitigation |
|------|------------|
| Regression in Plugin_Builder during extraction | Extract as pure refactor first (Phase 2), verify all plugin tests pass before adding Core support |
| Hook conflicts (Plugin + Core both calling same hooks) | Hooks are additive (register more resolvers/types); no conflict |
| Naming collisions (Core DCB names vs Plugin DCB names) | Different `name` prefix ensures unique keys in all registries |
| Core_Builder functor becomes complex | DCB logic is encapsulated in Dcb_Builder; Core_Builder just calls it |
| CoreApi static fragment no longer works | Pass DCB entries as parameters or build fragment in Core_Builder |
| In-memory Core wiring changes break existing tests | Phase 3 is a separate step with its own test verification |
