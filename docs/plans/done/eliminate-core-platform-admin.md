# Eliminate Core Component — Replace With Platform_Admin [DONE]

## Context

See analysis: `docs/analysis/core-component-simplification.md` (Option D).

The Core component is an unnecessary abstraction layer that duplicates Plugin's builder pattern, scatters its modules across 5 packages, and leaks platform-internal parameters. Its only real responsibilities — Plugin lifecycle management and an opt-in Cloner — belong directly in the platform.

There are no existing deployments, so no Pulumi state migration is needed.

## Goal

1. Delete the Core component entirely (8 files, ~350 lines)
2. Create `Platform_Admin` in `reventless-core` as the single central place defining what every platform contains
3. Unify platform config (`silent`, `splitApi`, `cloner`) into `Platform_Admin.Config`
4. Simplify `Platform.T` — remove `module Core`, simplify `makePlatform` to `(~version, ~plugins)`
5. Update both platform implementations (in-memory, AWS) to use `Platform_Admin`
6. Rename `CoreApi` → `AdminApi` and eliminate the `core/` folder

## Target API

```rescript
// Main.res — unchanged from today
module Platform = ReventlessInMemory.Platform.Make()
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
)
```

`makePlatform` internally calls `Admin.construct(~scheduler, ~api, ~apiRole, ~resourceNaming)` which creates all built-in platform components (Plugin aggregate, Plugin read model, Plugin extension point) and optionally the Cloner.

## File Reorganization

Eliminate `src/core/` entirely. Move surviving files into `src/admin/` as a flat structure:

```
src/admin/
├── Platform_Admin.res                    # NEW — main admin module
├── AdminApi.res                          # RENAMED from core/API/CoreApi.res
├── PluginBaseFragment.res                # MOVED from core/API/
├── PluginBehavior.res                    # MOVED from core/Aggregates/Plugin/
├── PluginSpec.res                        # MOVED from core/Aggregates/Plugin/
├── PluginExtensionPoint_Builder.res      # MOVED from core/ExtensionPoints/Plugin/
├── PluginExtensionPoint_Plugin.res       # MOVED from core/ExtensionPoints/Plugin/
├── PluginConnectExtension_Builder.res    # MOVED from core/Extensions/Connect/
├── PluginProjection.res                  # MOVED from core/ReadModels/Plugin/
└── PluginReadModelSpec.res               # MOVED from core/ReadModels/Plugin/
```

Files deleted (not moved):
- `core/Core/Core.res`
- `core/Core/Core_Builder.res`
- `core/Core/Core_Callback.res`
- `core/Core/Core_Helpers.res`

## Platform_Admin Design

```rescript
// reventless-core/src/admin/Platform_Admin.res

module type Config = {
  let silent: bool
  let splitApi: bool
  let cloner: bool
}

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner,
  RuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
  Config: Config,
) => {
  let construct = (~scheduler, ~api, ~apiRole, ~resourceNaming) => {
    // Built-in components (same for every provider)
    let aggregates = [module(PluginAggregate)]
    let readModels = [module(PluginReadModel)]
    let extensionPoints = [module(PluginExtensionPoint)]

    // Build components using Builder_Helpers
    let aggregateOutputs = aggregates->createAggregatesWithoutEventMappers(~api, ...)
    let readModelOutputs = readModels->createReadModels(~api, ~apiRole, ...)
    let extensionPointOutputs = extensionPoints->createExtensionPoints(...)
    // EventCollector wiring for platform extension points

    // Cloner (opt-in)
    let clonerOutputs = if Config.cloner {
      module C = Cloner.Make(ClonerRunner)
      Some(C.make(~api, ~opts={}))
    } else { None }

    // Admin schema — composed from actual config
    let mutationEntries = Array.concat(
      PluginBaseFragment.mutationEntries,
      if Config.cloner { [cloneMutationEntry] } else { [] },
    )
    let queryEntries = PluginBaseFragment.queryEntries

    { aggregates, readModels, extensionPoints, clonerOutputs, adminFragment }
  }
}
```

## Steps

### Step 1: Audit Plugin_Builder dependency on localCoreOutputs

Examine `Plugin_Builder.construct` to map exactly which fields from `Plugin_Helpers.localCoreOutputs` it reads and what it uses them for. Determine what Platform_Admin needs to provide instead.

**Files:**
- `reventless-core/src/components/Plugin/Plugin_Builder.res`
- `reventless-core/src/components/Plugin/Plugin_Helpers.res`

**Outcome:** List of fields Plugin_Builder needs from the platform, and how to provide them without a Core component.

### Step 2: Reorganize files — move `core/` contents to `admin/`

Move all surviving files from `src/core/` into a flat `src/admin/` folder. Rename `CoreApi.res` → `AdminApi.res`.

Moves (using `git mv`):
- `src/core/API/CoreApi.res` → `src/admin/AdminApi.res`
- `src/core/API/PluginBaseFragment.res` → `src/admin/PluginBaseFragment.res`
- `src/core/Aggregates/Plugin/PluginBehavior.res` → `src/admin/PluginBehavior.res`
- `src/core/Aggregates/Plugin/PluginSpec.res` → `src/admin/PluginSpec.res`
- `src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Builder.res` → `src/admin/PluginExtensionPoint_Builder.res`
- `src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res` → `src/admin/PluginExtensionPoint_Plugin.res`
- `src/core/Extensions/Connect/PluginConnectExtension_Builder.res` → `src/admin/PluginConnectExtension_Builder.res`
- `src/core/ReadModels/Plugin/PluginProjection.res` → `src/admin/PluginProjection.res`
- `src/core/ReadModels/Plugin/PluginReadModelSpec.res` → `src/admin/PluginReadModelSpec.res`

Update all references from `CoreApi` to `AdminApi` across the codebase.

Update `rescript.json` source paths: replace `src/core` entry with `src/admin`.

**Files:**
- All files listed above (moves)
- `reventless-core/rescript.json` (source paths)
- All files referencing `CoreApi` (grep for usages)

### Step 3: Create Platform_Admin module

Create `reventless-core/src/admin/Platform_Admin.res` with:
- `Config` module type (`silent`, `splitApi`, `cloner`)
- `Make` functor accepting runtime adapters + Config
- `construct` function that:
  - Creates built-in components (Plugin aggregate, Plugin read model, Plugin extension point)
  - Creates EventCollector for platform event routing
  - Optionally creates Cloner
  - Generates admin schema fragment
  - Returns outputs

Move relevant logic from `Core_Builder.res`, `Core_Helpers.res`, and `Core_Callback.res` into this module.

**Files:**
- New: `reventless-core/src/admin/Platform_Admin.res`
- Read: `reventless-core/src/core/Core/Core_Builder.res` (source of logic)
- Read: `reventless-core/src/core/Core/Core_Helpers.res` (EventCollector helper)
- Read: `reventless-core/src/core/Core/Core_Callback.res` (event handler)

### Step 4: Simplify AdminApi

Remove `generateFragment` and `baseFragment`. Keep only `cloneArgsSchema` (used by Platform_Admin to conditionally add the Clone mutation entry). The admin fragment is now generated inside `Platform_Admin.construct`.

**Files:**
- `reventless-core/src/admin/AdminApi.res`

### Step 5: Update Platform.T

Remove from `Platform.T`:
- `module Core: Core.T with type api = api and type role = role`
- `~extensionPoints`, `~aggregates`, `~readModels`, `~dcbSpec` from `makePlatform`

Remove module type aliases that only existed for Core:
- `module type dcbSpec = Plugin.DcbSpec` (if no longer referenced)

New `makePlatform` signature:
```rescript
let makePlatform: (~version: string, ~plugins: array<module(PluginMaker)>) => unit
```

**Files:**
- `reventless-infra/src/types/Platform.res`

### Step 6: Update in-memory Platform

- Replace `module CoreMaker = Core_Builder.Make(Bus)` / `module Core` with `module Admin = Platform_Admin.Make(..., Config)`
- Remove the separate `Config` functor parameter from `MakeWithConfig` — use `Platform_Admin.Config` instead
- Replace `Core.make(...)` call in `makePlatform` with `Admin.construct(...)`
- Replace `localCoreOutputs`-based wiring with direct use of `Admin.construct` return value
- Plugin QueryDb seeding, admin schema registration, MCP registration, server startup remain in `makePlatform`

**Files:**
- `reventless-in-memory/src/Platform.res`

### Step 7: Update AWS Platform

Same changes as in-memory:
- Replace `module Core` with `module Admin = Platform_Admin.Make(..., Config)`
- Unify `Api` + `Config` functor parameters — Config now includes `silent`, `splitApi`, `cloner`
- Replace `Core.make(...)` with `Admin.construct(...)`
- Split API mode uses `Admin.construct` outputs instead of Core outputs

**Files:**
- `reventless-aws/src/Platform.res`

### Step 8: Update Plugin_Helpers

- Remove `localCoreOutputs: ref<option<Core.outputs>>`
- Replace with whatever mechanism Step 1 identified (e.g., simpler `platformExtensionPoints` ref, or direct parameter passing)

**Files:**
- `reventless-core/src/components/Plugin/Plugin_Helpers.res`

### Step 9: Delete Core files

Delete all Core-specific modules:
- `reventless-core/src/core/Core/Core.res`
- `reventless-core/src/core/Core/Core_Builder.res`
- `reventless-core/src/core/Core/Core_Callback.res`
- `reventless-core/src/core/Core/Core_Helpers.res`
- `reventless-aws/src/core/Core_Builder.res`
- `reventless-in-memory/src/components/Core_Builder.res`

Delete the now-empty `src/core/` directory tree.

Remove Core from `rescript.json` source lists if explicitly listed.

Remove `Core.res` type definitions from `reventless-infra` if they exist as a separate file (currently inline in `Platform.res` references).

**Files:** (deletions)
- `reventless-core/src/core/Core/Core.res`
- `reventless-core/src/core/Core/Core_Builder.res`
- `reventless-core/src/core/Core/Core_Callback.res`
- `reventless-core/src/core/Core/Core_Helpers.res`
- `reventless-aws/src/core/Core_Builder.res`
- `reventless-in-memory/src/components/Core_Builder.res`
- `reventless-core/src/core/` (entire directory, now empty)

### Step 10: Update examples

The example `Main.res` files should already work since they only call `makePlatform(~version, ~plugins)`. Verify they compile and tests pass.

If any example was passing `~extensionPoints`, `~aggregates`, `~readModels`, or `~dcbSpec` to `makePlatform`, remove those parameters.

**Files:**
- `examples/online-shop-aggregates/online-shop-aggregates/src/Main.res`
- `examples/online-shop-dcb/online-shop-dcb/src/Main.res`
- `examples/online-shop-hybrid/online-shop-hybrid/src/Main.res`

### Step 11: Build and test

- `npm run clean && npm run build` from root — zero warnings
- `npm test` — all tests pass
- Verify GraphQL server starts correctly (in-memory examples)
- Verify admin schema contains Plugin queries, Activate/Deactivate mutations, and Clone mutation only when `cloner=true`

### Step 12: Update documentation

- Update `docs/guides/platform-and-plugin-guide.md` — remove Core references, document Platform_Admin as internal
- Update `packages/doc/docs/reventless-components/` — remove or redirect Core component docs
- Update `packages/doc/docs/reventless-components-overview.md` — remove Core from component diagrams
