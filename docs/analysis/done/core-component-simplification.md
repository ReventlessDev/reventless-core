# Core Component Simplification Analysis

## Problem Statement

The Core component is scattered across multiple modules (`reventless-infra`, `reventless-core`, `reventless-aws`, `reventless-in-memory`) and carries parameters that should not be user-facing. After the recent internalization of scheduler/Core creation into `Platform.makePlatform`, Core's content (aggregates, readModels, extensionPoints, dcbSpec) is still passed as top-level `makePlatform` parameters — but conceptually these belong to a single Core definition, not to the platform call site.

The goal: **one Core component per platform, defined in one simple place, with `makePlatform` receiving only a list of plugin modules.**

## Current State

### What Core Contains Today

Core is a management instance hosting platform-level components:

| Component | Purpose |
|-----------|---------|
| Aggregates | Platform-level aggregates (not domain plugins) |
| ReadModels | Platform-level read models |
| ExtensionPoints | Intra-Core extension points |
| DCB slices | Optional DCB infrastructure (StateChange, StateView, Automation, Translation) |
| Cloner | Point-in-time recovery/branching |
| EventCollector | Routes Core-generated events to extension points |
| API (CoreApi) | Administrative schema: Clone mutation, Plugin lifecycle (Activate/Deactivate), plugin queries |

### Current `makePlatform` Signature

```rescript
let makePlatform: (
  ~version: string,
  ~plugins: array<module(PluginMaker)>,
  ~extensionPoints: array<module(extensionPointT)>=?,     // Core content leaked here
  ~aggregates: array<module(aggregateT with ...)>=?,       // Core content leaked here
  ~readModels: array<module(readModelT with ...)>=?,       // Core content leaked here
  ~dcbSpec: module(dcbSpec)=?,                             // Core content leaked here
) => unit
```

### Current `Core.T` Module Type

```rescript
module type T = {
  let make: (
    ~version: string,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,     // Platform-internal
    ~dcbSpec: module(Plugin.DcbSpec)=?,
  ) => component
}
```

### Current `Core_Builder.make` (Actual Implementation)

```rescript
let make = (
  ~version,
  ~extensionPoints,
  ~aggregates,
  ~readModels,
  ~scheduler,
  ~api: ClonerRunner.api,             // Platform-internal (unit or AppSync)
  ~apiRole: 'role,                    // Platform-internal (unit or AppSync role)
  ~resourceNaming,                    // Platform-internal
  ~apiComponent: option<Api.component>=?,  // Platform-internal
  ~dcbSpec: option<module(Plugin.DcbSpec)>=?,
) => Core.component
```

There is a gap between `Core.T` (which hides api/apiRole/resourceNaming) and `Core_Builder.make` (which requires them). The Platform implementations bridge this gap by wrapping `Core_Builder.make` in a `Core` module that hardcodes the platform-specific values.

### Where "Core" Modules Exist

| Location | Role |
|----------|------|
| `reventless-core/src/core/Core/Core.res` | Type definitions (`outputs`, `component`, `module type T`) |
| `reventless-core/src/core/Core/Core_Builder.res` | Generic builder (functor over adapters) |
| `reventless-core/src/core/Core/Core_Callback.res` | EventCollector handler |
| `reventless-core/src/core/Core/Core_Helpers.res` | Builder helper functions |
| `reventless-core/src/core/API/CoreApi.res` | GraphQL schema fragment |
| `reventless-infra/src/types/Platform.res` | `Core.T` referenced in `Platform.T` |
| `reventless-aws/src/core/Core_Builder.res` | AWS adapter wiring (13 lines) |
| `reventless-in-memory/src/components/Core_Builder.res` | In-memory adapter wiring (18 lines) |
| `reventless-in-memory/src/Platform.res` | `module Core` wrapping CoreMaker + full `makePlatform` |
| `reventless-aws/src/Platform.res` | `module Core` wrapping CoreMaker + full `makePlatform` |

## Issues

### 1. Core Content Leaks Into `makePlatform`

After internalization, `makePlatform` still accepts `~extensionPoints`, `~aggregates`, `~readModels`, `~dcbSpec` as optional parameters. These are Core's content definition — they should not be spread across the platform call site. In practice, most applications pass nothing for these (defaulting to `[]`), making them noise.

### 2. No Single Place to Define Core Content

If a platform needs Core-level aggregates or DCB slices, they're specified at the `makePlatform` call site in `Main.res`, not in a dedicated Core definition module. This mixes assembly concerns (which plugins to load) with Core content definition.

### 3. Core.T Has Hidden Platform Parameters

`Core.T` omits `api`, `apiRole`, `resourceNaming`, `apiComponent` — but `Core_Builder.make` requires them. Each platform bridges this by hardcoding values in a wrapper module. This creates unnecessary indirection and means `Core.T` does not accurately represent the actual constructor.

### 4. Plugin and Core Have Parallel But Divergent Structures

Both Plugin and Core:
- Accept aggregates, readModels, extensionPoints, dcbSpec
- Use the same builder helpers (`createAggregatesWithoutEventMappers`, `createReadModels`, etc.)
- Register schema fragments
- Create EventCollectors

But they have different module types, different builder patterns, and different parameter passing. Core is essentially a special Plugin with extras (Cloner, administrative API).

### 5. CoreApi Is Tightly Coupled

`CoreApi` hardcodes the Clone mutation and Plugin lifecycle queries. If Core gains or loses capabilities, `CoreApi` must change. The schema generation could be derived from the Core's actual content rather than being a separate static definition.

## Proposal: Streamlined Core

### Principle

**Core content should be defined in one place using the same patterns as plugins. `makePlatform` should only receive a version and a list of plugin modules.**

### New `makePlatform` Signature

```rescript
let makePlatform: (
  ~version: string,
  ~plugins: array<module(PluginMaker)>,
) => unit
```

All Core content parameters (`~extensionPoints`, `~aggregates`, `~readModels`, `~dcbSpec`) are removed.

### Option A: Core Spec Module

Define a `CoreSpec` module type analogous to how plugins define their content, but simpler:

```rescript
module type CoreSpec = {
  let aggregates: (module Platform.T) => array<module(Aggregate.T)>
  let readModels: (module Platform.T) => array<module(ReadModel.T)>
  let extensionPoints: (module Platform.T) => array<module(ExtensionPoint.T)>
  let dcbSpec: option<(module Platform.T) => module(Plugin.DcbSpec)>
}
```

Usage in `Main.res`:
```rescript
module MyCoreSpec = {
  let aggregates = _ => []
  let readModels = _ => []
  let extensionPoints = _ => []
  let dcbSpec = None
}

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
  ~coreSpec=module(MyCoreSpec),  // Optional — defaults to empty
)
```

**Pros:** Explicit, composable, follows existing patterns.
**Cons:** Still requires a parameter on `makePlatform`; boilerplate for the common empty case.

### Option B: Core as a Special Plugin (Recommended)

Merge Core and Plugin concepts. Core becomes a built-in plugin with special capabilities (Cloner, administrative API) that are automatically added by the platform. The `makePlatform` signature becomes:

```rescript
let makePlatform: (
  ~version: string,
  ~plugins: array<module(PluginMaker)>,
) => unit
```

If platform-level aggregates/DCB slices are needed, they're defined as a regular plugin:

```rescript
module CorePlugin = {
  module Make = (Platform: ReventlessInfra.Platform.T) => {
    module MyAggregate = Platform.Aggregate.Make(MySpec, MyBehavior, NoMappings)

    let make = (~scheduler, ~api, ~apiRole) =>
      Platform.Plugin.make(
        ~name="Core",
        ~version="1.0.0",
        ~heartbeatInterval=60,
        ~aggregates=[module(MyAggregate)],
        ~api, ~apiRole, ~scheduler,
      )
  }
}

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(CorePlugin.Make), module(Catalog), module(Ordering)],
)
```

The platform automatically adds Cloner and administrative API regardless. The "Core" name is reserved for the first plugin or for the platform's own administrative components.

**Pros:** No new concepts, no special module types, plugins and Core use identical patterns, `makePlatform` is minimal.
**Cons:** Requires marking one plugin as "Core" or handling the Cloner/admin API attachment differently.

### Option C: Internalize Core Completely

Core becomes fully internal to the platform. It provides only administrative capabilities (Clone, Plugin lifecycle) and has no user-facing content. If platform-level aggregates or DCB slices are needed, they're just another plugin.

```rescript
// Main.res — simplest possible
Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
)
```

The platform:
1. Creates Core internally (Cloner + admin API only — no user aggregates/readModels)
2. Creates each plugin from the array
3. Wires everything

If you need platform-level aggregates, make a plugin for them:
```rescript
module PlatformExtras = {
  module Make = (Platform: ReventlessInfra.Platform.T) => {
    module AdminAggregate = Platform.Aggregate.Make(...)
    let make = (~scheduler, ~api, ~apiRole) =>
      Platform.Plugin.make(~name="PlatformAdmin", ...)
  }
}

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(PlatformExtras.Make), module(Catalog), module(Ordering)],
)
```

**Pros:** Cleanest `makePlatform`, no Core-specific concepts exposed to users, eliminates `Core.T` from `Platform.T` entirely.
**Cons:** Core aggregates/readModels would live in a separate EventCollector and Plugin infrastructure rather than in the Core component. May need a way to distinguish "admin" plugins from domain plugins for schema routing.

## Impact on CoreApi

Regardless of option chosen, CoreApi should be simplified:

**Current**: Static `baseFragment` with hardcoded Clone + Plugin lifecycle schema, plus `generateFragment` for DCB entries.

**Proposed**: CoreApi generates its schema from the Core's actual content:
- Clone mutation: always present (provided by Cloner)
- Plugin queries: always present (provided by Plugin read model)
- DCB entries: only present if Core has a dcbSpec
- Plugin Activate/Deactivate: always present

If Core becomes purely internal (Option C), CoreApi only has Clone + Plugin lifecycle — no user-defined entries. DCB entries would be part of the plugin's own schema fragment.

## Impact on Platform.T

### Current Platform.T Exposes

```rescript
module Core: Core.T with type api = api and type role = role
```

### With Option B or C

`Core` is removed from `Platform.T` — it's an internal implementation detail:

```rescript
module type T = {
  type api
  type role
  module Aggregate: { ... }
  module ReadModel: { ... }
  module Plugin: Plugin.T with type api = api and type role = role
  // No more: module Core: Core.T
  let makePlatform: (~version: string, ~plugins: array<module(PluginMaker)>) => unit
}
```

## Impact on Platform Implementations

### In-Memory Platform Changes

1. Remove `module Core` from the exposed modules
2. Remove `~extensionPoints`, `~aggregates`, `~readModels`, `~dcbSpec` from `makePlatform`
3. Create Core internally with empty arrays (Option C) or derive from a designated plugin (Option B)
4. Core creation code in `makePlatform` simplifies to:
   ```rescript
   let _core = Core.make(
     ~version,
     ~extensionPoints=[],
     ~aggregates=[],
     ~readModels=[],
     ~scheduler,
     ~api=(),
     ~apiRole=(),
     ~resourceNaming=InMemory_PluginSpec.resourceNaming,
   )
   ```

### AWS Platform Changes

Mirror the in-memory changes. The AWS `Core_Builder` adapter module stays as-is (it's just adapter wiring).

### Option D: Eliminate Core — Replace With Platform_Admin

Remove the Core component entirely. Its responsibilities split into two places:
- **Platform_Admin** — a shared module in `reventless-core` that is the single central place for platform-level components (aggregates, read models, extension points, DCB slices) and administrative features (Plugin lifecycle, opt-in Cloner).
- **Platform.makePlatform** — calls Platform_Admin and handles platform-specific wiring (GraphQL/AppSync, MCP, servers).

There is no `Core.res`, no `Core_Builder.res`, no `Core.T` module type, and no Pulumi `ComponentResource` for Core.

#### What Core Does Today (Inventory)

| # | Responsibility | Where It Lives Today | Where It Moves |
|---|----------------|---------------------|----------------|
| 1 | **Cloner** — point-in-time restore | `Core_Builder.construct` | Platform_Admin (opt-in) |
| 2 | **Plugin read model** — Plugin/Plugins queries | `PluginReadModelSpec` + `makePlatform` | Platform_Admin (always-on) |
| 3 | **Plugin lifecycle mutations** — Activate/Deactivate | `PluginBaseFragment` + `makePlatform` | Platform_Admin (always-on) |
| 4 | **Clone mutation** — triggers Cloner | `CoreApi.mutationEntries` | Platform_Admin (only when Cloner enabled) |
| 5 | **EventCollector** — routes platform events to EPs | `Core_Helpers.MakeEventCollectorHelper` | Platform_Admin (only when platform has EPs or aggregates) |
| 6 | **Platform aggregates** | `Core_Builder` (always `[]` today) | Platform_Admin (optional) |
| 7 | **Platform read models** | `Core_Builder` (always `[]` today) | Platform_Admin (optional) |
| 8 | **Platform extension points** | `Core_Builder` (always `[]` today) | Platform_Admin (optional) |
| 9 | **Platform DCB slices** | `Core_Builder` (never used today) | Platform_Admin (optional) |
| 10 | **Schema registration** | `Plugin_Helpers` hooks + `makePlatform` | Platform_Admin (generates fragment) |
| 11 | **`localCoreOutputs`** | `Plugin_Helpers` ref | Platform_Admin outputs ref (simplified) |

#### Platform_Admin Design

`Platform_Admin` is a functor in `reventless-core` that both AWS and in-memory platforms call. It is the **single central place** where all platform-level components and administrative features are defined.

All platform configuration — currently scattered across separate `Config` functor parameters in each platform — is unified into a single `Platform_Admin.Config`:

```rescript
// reventless-core/src/core/Platform_Admin.res

module type Config = {
  /** Suppress diagnostic warnings (useful in tests). */
  let silent: bool
  /** Serve admin and plugin APIs on separate endpoints. */
  let splitApi: bool
  /** Include the Cloner component for point-in-time restore. Opt-in. */
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
  // ── Built-in platform components (same for every provider) ──
  //
  // These are always created by construct — they define what
  // "being a Reventless platform" means. No provider-specific
  // code should duplicate this list.

  // Plugin aggregate — tracks plugin lifecycle (Activate/Deactivate)
  // Plugin read model — exposes Plugin/Plugins queries
  // Plugin extension point — allows cross-plugin wiring
  //
  // These are the built-in components that every platform gets.
  // Additional aggregates, read models, EPs, and DCB slices can
  // be passed in via the optional parameters below.

  // ── Opt-in Cloner ─────────────────────────────────────────

  // Clone mutation entry — only present when Cloner is enabled
  let clonerMutationEntries = if Config.cloner {
    [{
      fieldNames: [Api_Naming.coreField(~name="Clone")],
      commandSchema: CoreApi.cloneArgsSchema->S.castToUnknown,
      description: "Clone the system to a specific point in time",
    }]
  } else {
    []
  }

  // ── construct ─────────────────────────────────────────────

  /** Construct all platform-level components. Called by each
      provider's makePlatform. This is the ONE place that defines
      what every platform contains — no parameters for additional
      components. If the platform needs new built-in components,
      they are added here. */
  let construct = (
    ~scheduler,
    ~api,
    ~apiRole,
    ~resourceNaming,
  ) => {
    // ── Built-in components (provider-agnostic) ──────────────
    // This is the canonical definition of what every Reventless
    // platform contains. Adding a new platform-level component
    // means adding it here — once — and all providers get it.

    let aggregates = [module(PluginAggregate)]
    let readModels = [module(PluginReadModel)]
    let extensionPoints = [module(PluginExtensionPoint)]

    // Build aggregates (same helpers as Plugin_Builder)
    let aggregateOutputs = aggregates->createAggregatesWithoutEventMappers(~api, ...)
    let allEventTopics = Aggregate.allEventTopics(aggregateOutputs)

    // Build read models subscribing to all platform event topics
    let readModelOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, ...)

    // Build extension points + EventCollector
    let extensionPointOutputs = extensionPoints->createExtensionPoints(...)
    // ... EventCollector wiring same as current Core_Builder

    // Build Cloner (opt-in)
    let clonerOutputs = if Config.cloner {
      module C = Cloner.Make(ClonerRunner)
      Some(C.make(~api, ~opts={}))
    } else {
      None
    }

    // ── Generate admin schema fragment ───────────────────────
    // Composed from actual content — no static constant that
    // can drift from reality.

    let allMutationEntries = Array.concat(
      PluginBaseFragment.mutationEntries,   // Activate, Deactivate (always)
      clonerMutationEntries,                // Clone (only if cloner=true)
    )
    let allQueryEntries =
      PluginBaseFragment.queryEntries        // Plugin, Plugins (always)

    {
      aggregates: aggregateOutputs,
      readModels: readModelOutputs,
      extensionPoints: extensionPointOutputs,
      dcbResult,
      clonerOutputs,
      adminFragment: GraphQL_FragmentGenerator.generate(
        ~mutationEntries=allMutationEntries,
        ~queryEntries=allQueryEntries,
      ),
    }
  }
}
```

#### Usage in Platform Implementations

Both AWS and in-memory platforms wire Platform_Admin with their adapters and call `construct` inside `makePlatform`:

Today `silent` and `splitApi` are passed as a separate `Config` functor to `Platform.MakeWithConfig`, while the proposed `cloner` would live in `Platform_Admin.Config`. Unifying them means there is one config surface for all platform behavior — no more hunting across two functor parameters.

The in-memory `Platform.Make()` default becomes `{ silent: false, splitApi: true, cloner: false }`. The AWS `Platform.Make(Api)` default becomes `{ silent: false, splitApi: false, cloner: false }`. Users override via `MakeWithConfig`.

```rescript
// In-memory Platform (conceptual)
module Admin = Platform_Admin.Make(
  RuntimeEnvironment_InMemory,
  EventCollectorChannel_InMemory.Make(Bus),
  QueryEngine_InMemory.Make(Bus),
  ClonerRunner_InMemory,
  PluginRuntime_Builder_Micro.Make(...),
  { let silent = false; let splitApi = true; let cloner = false },
)

let makePlatform = (~version, ~plugins) => {
  let scheduler = makeScheduler()

  // Platform-level components — defined inside Platform_Admin
  let adminOutputs = Admin.construct(
    ~scheduler,
    ~api=(),
    ~apiRole=(),
    ~resourceNaming=InMemory_PluginSpec.resourceNaming,
  )

  // Build plugins
  let plugins = plugins->Array.map(plugin => {
    module P = unpack(plugin)
    P.make(~scheduler, ~api=(), ~apiRole=())
  })

  // Register admin schema, seed plugin QueryDb, start servers...
  registerAdminSchema(adminOutputs.adminFragment)
  seedPluginQueryDb(plugins)
  startServers()
}
```

```rescript
// AWS Platform (conceptual)
module Admin = Platform_Admin.Make(
  RuntimeEnvironment.Lambda,
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
  PluginRuntime_Builder_Micro.Make(...),
  { let silent = false; let splitApi = false; let cloner = true },
)

let makePlatform = (~version, ~plugins) => {
  let scheduler = makeScheduler()

  let adminOutputs = Admin.construct(
    ~scheduler,
    ~api=appSyncApi,
    ~apiRole=appSyncApiRole,
    ~resourceNaming=Util_ResourceNaming.operations,
  )

  // Build plugins, push schema to AppSync...
}
```

#### Avoiding Duplication Between Platforms

The key concern is addressed by the layered split:

**Shared in `Platform_Admin` (reventless-core) — written once:**
- **Built-in components** (Plugin aggregate, Plugin read model, Plugin extension point) — defined and created here, same for every provider
- Cloner opt-in logic
- Admin schema fragment generation (Plugin queries + Activate/Deactivate + conditional Clone)
- EventCollector wiring for platform extension points
- Reuses `Builder_Helpers` (same helpers that Plugin_Builder uses — no duplication)

**Platform-specific (stays in each Platform.res):**
- Adapter selection (which functors to pass to `Platform_Admin.Make`)
- Config defaults (`silent`, `splitApi`, `cloner` — each platform sets sensible defaults, users override via `MakeWithConfig`)
- Plugin QueryDb seeding (Bus store vs DynamoDB)
- Schema registration target (GraphQL_Server vs AppSync)
- MCP registration (in-memory only)
- Server startup

This is the same boundary that exists today between `Core_Builder.Make(adapters)` (shared) and each platform's `makePlatform` (specific). The difference is that Platform_Admin replaces Core_Builder without being a Pulumi ComponentResource — it's just a construction helper.

#### `makePlatform` Signature

```rescript
let makePlatform: (
  ~version: string,
  ~plugins: array<module(PluginMaker)>,
) => unit
```

Platform-level components (aggregates, read models, EPs, DCB) are **not** passed as `makePlatform` parameters. They are defined inside the platform implementation's call to `Admin.construct`. This is deliberate: platform-level components are an infrastructure concern, not an application assembly concern. Application code only sees `~plugins`.

If a specific deployment needs platform-level aggregates, the platform module (or a config module passed to `Platform.MakeWithConfig`) defines them — not the `Main.res` call site.

#### Advantages

1. **Eliminates the Core abstraction layer**: No `Core.res`, `Core.T`, `Core_Builder.res`, `Core_Callback.res`, `Core_Helpers.res`, plus adapter `Core_Builder.res` in AWS and in-memory — 8 files and ~350 lines removed.

2. **No more Core/Plugin parallel structure**: Today Core duplicates Plugin's builder pattern with subtle differences. Platform_Admin reuses `Builder_Helpers` directly without wrapping it in a ComponentResource.

3. **`Platform.T` becomes simpler**: No `module Core: Core.T` — one less concept for users.

4. **`makePlatform` signature is minimal**: `(~version, ~plugins)` only.

5. **Cloner is opt-in**: Most deployments (especially local dev/testing) don't need point-in-time restore. The Cloner is only created when explicitly enabled via `Config.cloner = true`. This avoids provisioning unnecessary infrastructure (Fargate cluster, ECS task definitions, Lambda) in production stacks that don't use it.

6. **Platform-level components have a clear home**: `Admin.construct` is the one central place. Built-in components (Plugin aggregate, read model, extension point) are defined once — no provider duplication.

7. **Admin schema is generated from actual content**: The fragment is built from what's actually configured — Cloner mutations only appear if Cloner is enabled. No static `baseFragment` that might drift from reality.

8. **No more `localCoreOutputs` ref**: `Plugin_Helpers.localCoreOutputs` is replaced by `Admin.construct` returning its outputs directly. The platform passes what plugins need explicitly, rather than through a hidden mutable ref.

#### Consequences and Considerations

**1. Pulumi ComponentResource hierarchy changes**

Today: `Stack → Core (ComponentResource) → [Cloner, EventCollector, ...]`

After: Platform-level components are direct children of the stack (or of a lightweight "Platform" ComponentResource if grouping is desired).

**Impact:** Existing AWS deployments need a Pulumi state migration. Since Cloner is now opt-in, most deployments that didn't actively use Cloner can simply remove it.

**Mitigation:** For in-memory, this is a non-issue. For AWS, the migration can be scripted. If Cloner was provisioned but unused, the migration just removes the old Core + Cloner resources.

**2. Plugin_Builder wiring**

`Plugin_Builder.construct` reads `Plugin_Helpers.localCoreOutputs` for cross-plugin extension point wiring. This changes:

- Platform extension point outputs from `Admin.construct` are stored in a simpler ref (e.g., `Platform_Helpers.platformExtensionPoints`) that Plugin_Builder reads.
- Or Platform_Admin returns the data and makePlatform passes it to each plugin's construction context.

**Action needed:** Audit `Plugin_Builder.construct` to map exactly which fields from `localCoreOutputs` it uses, and provide them through a cleaner mechanism.

**3. EventCollector for platform components**

Platform_Admin creates an EventCollector to route events from the built-in Plugin aggregate to the built-in Plugin extension point. This uses the same `MakeEventCollectorHelper` and `Core_Callback` patterns — they move into Platform_Admin.

**4. Builder_Helpers shared state**

`Builder_Helpers` maintains mutable dictionaries populated during aggregate/readModel construction. Platform_Admin's `construct` populates these before plugin construction begins, just as Core_Builder does today. The order is preserved: platform components first, then plugins.

**5. Admin schema composition**

The admin schema fragment is composed from:
- Plugin lifecycle entries (always)
- Cloner entries (only if `Config.cloner = true`)

This is more correct than today's approach where `CoreApi.baseFragment` always includes Clone whether or not Cloner is deployed.

**6. Split API mode**

Unchanged. The admin fragment (whatever it contains) goes to the core API endpoint in split mode. `makePlatform` already handles split API routing today.

**7. Where platform-level components are defined**

Two patterns depending on the use case:

Platform_Admin defines what every platform contains. If a future requirement needs additional platform-level components (e.g., an audit aggregate), they are added to `Platform_Admin.construct` — once — and all providers get them automatically. Application-specific domain components belong in plugins, not in the platform.

#### Files Affected

| File | Action |
|------|--------|
| `reventless-core/src/core/Core/Core.res` | Delete |
| `reventless-core/src/core/Core/Core_Builder.res` | Delete (logic moves to Platform_Admin) |
| `reventless-core/src/core/Core/Core_Callback.res` | Move into Platform_Admin (used when platform has EPs) |
| `reventless-core/src/core/Core/Core_Helpers.res` | Move into Platform_Admin |
| `reventless-core/src/core/API/CoreApi.res` | Simplify to just `cloneArgsSchema`; fragment generation moves to Platform_Admin |
| `reventless-infra/src/types/Platform.res` | Remove `module Core: Core.T`, simplify `makePlatform` signature |
| `reventless-aws/src/core/Core_Builder.res` | Delete (adapter selection moves to Platform.res) |
| `reventless-in-memory/src/components/Core_Builder.res` | Delete (adapter selection moves to Platform.res) |
| `reventless-in-memory/src/Platform.res` | Replace `Core.make(...)` with `Admin.construct(...)` |
| `reventless-aws/src/Platform.res` | Replace `Core.make(...)` with `Admin.construct(...)` |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | Replace `localCoreOutputs` with simpler platform outputs ref |
| `reventless-core/src/components/Builder_Helpers.res` | No changes |
| New: `reventless-core/src/core/Platform_Admin.res` | Central shared module for platform-level components |

#### Comparison: Option C vs Option D

| Aspect | Option C (Internalize) | Option D (Eliminate + Platform_Admin) |
|--------|----------------------|---------------------|
| Core component exists? | Yes — thin, internal | No |
| Platform-level components? | Not supported (always empty) | Built-in (defined in Platform_Admin) |
| Cloner | Always created | Opt-in via `Config.cloner` |
| Pulumi resource tree | Core still appears as ComponentResource | No Core resource |
| AWS migration needed? | No | Yes — Pulumi state migration |
| Files removed | 0 (simplified) | 6 deleted, 2 moved into Platform_Admin |
| Code duplication | Core_Builder duplicates Plugin builder | Platform_Admin reuses Builder_Helpers directly |
| `localCoreOutputs` | Still needed | Replaced with explicit return value |
| Admin schema | Static (may include unused Clone entry) | Reflects actual config (Clone only if enabled) |
| Shared logic location | `Core_Builder` (existing) | `Platform_Admin` (new, cleaner) |
| User-facing concepts | Core exists but hidden | No Core concept at all |

## Recommendation

**Option D (Eliminate + Platform_Admin)** is the recommended approach:

1. **Cleanest architecture**: No Core concept, no parallel Core/Plugin structures, no hidden mutable refs.
2. **Opt-in Cloner**: Avoids unnecessary infrastructure in most deployments.
3. **Platform-level components supported**: `Admin.construct` is the single central place — aggregates, read models, EPs, and DCB slices all go here.
4. **No duplication**: Platform_Admin in reventless-core is shared; platform-specific concerns stay in each Platform.res.
5. **Minimal user-facing API**: `makePlatform(~version, ~plugins)` — nothing else.
6. **Admin schema reflects reality**: Generated from actual config, not a static constant.

### Migration Path

1. Create `Platform_Admin` module with unified `Config` (`silent`, `splitApi`, `cloner`) and `construct` with built-in components
2. Update in-memory Platform to use `Admin.construct` instead of `Core.make`
3. Update AWS Platform to use `Admin.construct` instead of `Core.make`
4. Remove `module Core: Core.T` from `Platform.T`, simplify `makePlatform` signature
5. Delete Core files (`Core.res`, `Core_Builder.res`, `Core_Callback.res`, `Core_Helpers.res`)
6. Delete adapter `Core_Builder` files (AWS, in-memory)
7. Replace `localCoreOutputs` in Plugin_Helpers with explicit Platform_Admin outputs
8. Simplify CoreApi (keep only `cloneArgsSchema`; remove `baseFragment` and `generateFragment`)
9. Script Pulumi state migration for existing AWS deployments
10. Update documentation and platform-and-plugin guide
