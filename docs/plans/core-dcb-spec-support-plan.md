# Plan: Optional DCB Spec Support for Core Module

**Status:** Not started
**Analysis:** `docs/analysis/core-dcb-spec-support.md`

## Goal

Add optional `~dcbSpec` support to the Core module (matching the existing Plugin capability), extract shared DCB construction logic into a reusable `Dcb_Builder`, consolidate existing builder duplication, and properly wire Core in the in-memory platform to eliminate the `connectWithoutCore` code path.

## Phases

### Phase 1 — Consolidate Existing Builder Duplication (no behavior change)

#### Step 1 — Create `Builder_Helpers.res`

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

#### Step 2 — Verify all existing tests pass

Run full test suite. No behavior change expected — pure refactor.

---

### Phase 2 — Extract DCB Construction Logic (no behavior change)

#### Step 3 — Create `Dcb_Builder.res`

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

#### Step 4 — Update `Plugin_Builder.res` to use `Dcb_Builder`

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

#### Step 5 — Verify all existing tests pass

Run full test suite. No behavior change expected — pure extraction refactor.

---

### Phase 3 — Wire Core Properly in In-Memory Platform (eliminate `connectWithoutCore`)

#### Step 6 — Introduce local Core reference mechanism

The in-memory platform currently creates a Core module but never wires plugins to it (`makePlatform` receives `~core` and ignores it). Introduce a mechanism for Plugin_Builder to accept local Core outputs (specifically PluginExtensionPoint outputs) as an alternative to `Interstack.coreStackReference`.

Key changes:
- Plugin_Builder `connect` path should accept either local Core outputs or cross-stack interop outputs
- In-memory platform passes Core's outputs directly to Plugin_Builder

**Files changed:**
- `Plugin_Builder.res` — Accept local Core reference
- `Plugin_Helpers.res` — Update `connect` to handle local Core outputs

#### Step 7 — Wire in-memory `makePlatform` to pass Core outputs to plugins

Update the in-memory platform to pass Core's outputs to plugins instead of ignoring the `~core` parameter.

**Files changed:**
- `reventless-in-memory/src/Platform.res` — Wire `~core` to plugin construction

#### Step 8 — Remove `connectWithoutCore` and manual Core registration

- Remove `connectWithoutCore` from `Plugin_Helpers` (54 lines)
- Remove manual Core schema/query/mutation registration from in-memory `makePlatform` (lines 490–547)
- Both Plugin and Core use the same `connect` path in AWS and in-memory

**Files changed:**
- `Plugin_Helpers.res` — Remove `connectWithoutCore`
- `Core_Helpers.res` — Remove simplified `MakeEventCollectorHelper` if no longer needed
- `reventless-in-memory/src/Platform.res` — Remove manual Core registration

#### Step 9 — Verify all existing tests pass

Run full test suite. Behavior should be identical but exercising more production code paths in-memory.

---

### Phase 4 — Add Core DCB Support (new capability)

#### Step 10 — Move `DcbSpec` to shared location

Move `DcbSpec` module type from `Plugin.res` to a shared location:

```
reventless/reventless-core/src/components/Dcb/DcbSpec.res
```

Add backward-compatible alias in `Plugin.res`: `module DcbSpec = DcbSpec`.

**Files changed:**
- `reventless-core/src/components/Dcb/DcbSpec.res` — New (moved from Plugin.res)
- `Plugin.res` — Replace inline DcbSpec with alias

#### Step 11 — Add DCB adapter modules to `Core_Builder.Make`

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

#### Step 12 — Update `Core.res` outputs type

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

#### Step 13 — Wire DCB entries into CoreApi

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

#### Step 14 — Update platform implementations

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
