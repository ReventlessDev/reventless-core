# Platform Extension: Plugin, Core, and Full-Platform Deployment

## Goal

Extend `Platform.T` (the abstract factory interface in `reventless-infra`) so that application code can:

1. Create **Plugin** deployment units via `Platform.Plugin.make(...)` — without knowing the underlying infrastructure provider.
2. Create the **Core** — the single management instance that registers all plugins — via `Platform.Core.make(...)`.
3. Deploy a **full platform** (one Core + multiple Plugins) in one shot via `Platform.makePlatform(...)`, which wires all cross-cutting concerns (Scheduler, Api schema stitching, stack exports) automatically.

Currently `Platform.T` only exposes primitive component factories: `Aggregate.Make`, `ReadModel.Make`, `ExtensionPoint.Make`, `Extension.Make`, `Task.Make`, `Counter`, `StateChangeSlice.Make`, `StateViewSlice.Make`, `DcbEventLog.Make`.

The Plugin and Core builders (`Plugin_Builder`, `Core_Builder`) already exist in `reventless-core` / `reventless-aws`, but are not exposed through the `Platform.T` abstraction.

**Dependency**: This plan must be coordinated with `docs/plans/api-component-graphql.md`. Several phases below depend on types and components introduced by that plan. The sequencing is noted per phase.

---

## Architecture Background

### Plugin

`Plugin.T` (`reventless-core/src/components/Plugin/Plugin.res`) is a module type with:
- `type api` — the API gateway type (e.g. AppSync API reference)
- `type role` — the IAM role type
- `make(~name, ~version, ~heartbeatInterval, ~aggregates, ~readModels, ~extensionPoints, ~extensions, ~tasks, ~api, ~apiRole, ~scheduler, ~dcbSpec?)` → `Plugin.component`

The concrete AWS builder (`Plugin_Builder.Make`) takes ~20 infrastructure adapter modules. The Platform must pre-bind all of these so callers only specify application-level arguments.

The `~api` and `~apiRole` values passed to `Plugin.make` are the AppSync API resource reference and the IAM role reference. With the api-graphql plan implemented, these are **output values from the `Api` component** (created via `Platform.Api.Make`), not configuration passed into the Platform constructor.

### Core

`Core.T` (`reventless-core/src/core/Core/Core.res`) is a module type with:
- `make(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler)` → `Core.component`

The AWS `Core_Builder` (in `reventless-aws/src/core/Core_Builder.res`) uses `include ReventlessCore.Core_Builder.Make(...)` and adds `~api`, `~apiRole`, `~resourceNaming` parameters. So the current `Core.T` is **incomplete** relative to the actual builder.

Per the api-graphql plan (Phase 8), `Core_Builder.Make` will gain `~api: Api.component` — replacing the raw `~api`/`~apiRole` value parameters. The `Api.component` gives Core both the AppSync resource reference AND the `updateSchema` operation needed to stitch plugin GraphQL schemas on plugin connect/disconnect. `Core.T` must be updated accordingly.

There is exactly **one Core** per platform. Uniqueness is enforced by convention in the composition root (only one call to `Platform.Core.make`).

### Api Component (from api-graphql plan)

The `Api` component (`reventless-infra/src/components/Api.res`, to be created by api-graphql plan) encapsulates:
- The AppSync GraphQL API resource (AWS) or the graphql-yoga server (in-memory)
- `operations.updateSchema(fragments)` — stitches all plugin GraphQL schema fragments and pushes the result to the API

The Api component is created via `Platform.Api.Make(Config: {let baseFragment})`. Its outputs include the concrete `api` (AppSync API reference) and `role` (IAM role) values that Plugin.make and Core.make need. This replaces the current pattern where the AWS Platform constructor takes `api`/`apiRole` as external config.

### Scheduler

Both `Plugin.make` and `Core.make` require `~scheduler: Pulumi.Output.t<Scheduler.operations>`. Currently the scheduler is created by the user in the deployment entry point. For a full-platform deployment, the Platform exposes `makeScheduler()` as a helper and `makePlatform` owns the scheduler lifecycle.

### Cross-Stack Wiring

Plugins connect to Core via a Pulumi StackReference — they read Core's exported `extensionPoints` output to find the Plugin extension point's command topic. This is currently handled inside `Plugin_Builder` via `Interstack.coreStackReference`. In the full-platform model (single stack), this cross-stack reference becomes a direct in-process value.

---

## Design Decisions

### Decision 1: `type api` and `type role` in `Platform.T` are output types from the Api component

The `Plugin.T` module type has abstract `type api` and `type role`. When Platform exposes a `Plugin` module, these types must be concrete so callers can provide `~api` and `~apiRole` values.

With the api-graphql plan, the AppSync API is **created by** the `Api` component — it is no longer passed into the Platform constructor. `type api` and `type role` in `Platform.T` therefore represent the *output* types produced by the platform's Api component:
- AWS: `type api = PulumiAws.AppSync.GraphQLApi.t`, `type role = PulumiAws.IAM.Role.t`
- In-memory: `type api = unit`, `type role = unit`

Each concrete Platform implementation fixes these types. Callers that need to pass `~api`/`~apiRole` to `Plugin.make` obtain the values from `(Platform.Api.Make(...)).make(...)->Component.outputs`.

**Consequence**: The AWS `Platform.Make` functor no longer takes `(Api: {let api; let apiRole})` as input. It becomes `module Make = (): ReventlessInfra.Platform.T`. This is a breaking change, but both Platform implementations are in this repo.

### Decision 2: Scheduler owned by `makePlatform`; `makeScheduler` is the helper

For users creating components individually, `Platform.makeScheduler()` creates and returns a scheduler. For the full-platform path, `makePlatform` creates the scheduler internally and threads it to Core and Plugins via callbacks (see Phase 4).

`Core.T` and `Plugin.T` keep `~scheduler` in their `make` signatures — no interface change needed for the scheduler.

### Decision 3: `Core.T` gains `~api: Api.component`

Per the api-graphql plan (Phase 8), `Core_Builder.Make` gains `~api: Api.component` parameter. `Core.T` must be extended to match:
- Remove raw `~api: api` + `~apiRole: role` value params from `Core.T`
- Add `~api: Api.component` — Core uses this to call `updateSchema` on plugin connect/disconnect and to get the AppSync API reference for its own data sources

**Dependency**: Requires `Api.component` type from api-graphql Phase 2.

### Decision 4: `makePlatform` handles the single-stack scenario

When running Core and Plugins in the same Pulumi stack, there is no StackReference — Core's outputs are available directly. `Platform.makePlatform` wires this by:
1. Creating the Scheduler.
2. Passing the Api component to Core.make.
3. Creating each Plugin component with api/role values extracted from the Api component, and threading the Core's plugin extension point outputs directly (bypassing StackReference).
4. Calling `Api.operations.updateSchema` with all plugin schema fragments after assembly.
5. Exporting all required Pulumi stack outputs.

The separate multi-stack scenario (existing use case) is unchanged — Plugins still use `Interstack.coreStackReference`.

### Decision 5: `Plugin.make` still receives `~api`/`~apiRole` as values (not the full Api component)

The api-graphql plan does not change `Plugin.T`. Plugin only needs the AppSync API resource reference and IAM role for data sources, not the full schema management capability. The values are extracted from `Api.component.outputs` and passed explicitly to `Plugin.make`. This keeps `Plugin.T`'s interface stable and Plugin.make usable independently of makePlatform.

---

## Files Affected

| File | Change |
|------|--------|
| `reventless-infra/src/types/Platform.res` | Add `type api`, `type role`, `module Api`, `module Plugin`, `module Core`, `let makeScheduler`, `let makePlatform` |
| `reventless-core/src/core/Core/Core.res` | Update `Core.T`: add `~api: Api.component`, remove `~api: api` + `~apiRole: role` raw params |
| `reventless-aws/src/Platform.res` | Remove `(Api: {let api; let apiRole})` constructor param; implement `Api`, `Plugin`, `Core`, `makeScheduler`, `makePlatform` |
| `reventless-in-memory/src/Platform.res` | Implement `Api`, `Plugin`, `Core`, `makeScheduler`, `makePlatform`; remove bare `GraphQL_Server.start()` (moved into Api component per api-graphql plan) |
| `reventless-in-memory/src/Plugin_Builder.res` | Create — in-memory plugin builder |
| `reventless-in-memory/src/Core_Builder.res` | Create — in-memory core builder |

*Files created by the api-graphql plan (prerequisite, not modified here): `reventless-infra/src/components/Api.res`, `reventless-infra/src/components/Api_Adapter.res`, `reventless-core/src/components/Api/Api_Builder.res`.*

---

## Implementation Plan

### Phase 1: Reconcile `Core.T` with the AWS builder and api-graphql plan

**Dependency**: Requires `Api.component` type to be defined (api-graphql Phase 2). Can be drafted before that, but the type ascription test requires it.

**Problem**: `Core.T` currently specifies `make(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler)`. The actual AWS `Core_Builder` takes additional `~api`, `~apiRole`, `~resourceNaming` parameters. The api-graphql plan (Phase 8) changes this further: `Core_Builder.Make` gains `~api: Api.component`, replacing the raw api/apiRole.

**Steps**:

1. **Read `Core.T` and `Core_Builder.Make` signatures** to confirm the exact parameter mismatch.

2. **Update `Core.T`** to reflect both sets of requirements:
   ```rescript
   module type T = {
     type api
     type role
     let make: (
       ~version: string,
       ~extensionPoints: array<module(ExtensionPoint.T)>,
       ~aggregates: array<module(Aggregate.T with type api = api)>,
       ~readModels: array<module(ReadModel.T with type api = api and type role = role)>,
       ~scheduler: Pulumi.Output.t<Scheduler.operations>,
       ~api: Api.component,  // Full Api component (per api-graphql Phase 8)
     ) => component
   }
   ```
   Notes:
   - `~apiRole` is removed — Core obtains it from `Api.component.outputs`
   - `~resourceNaming` is an infrastructure detail — stays internal to the builder, not exposed in `Core.T`
   - `type api` and `type role` on `Core.T` are kept for aggregate/readModel type constraints

3. **Update `Core_Builder.Make`** (once api-graphql Phase 8 is implemented) to accept `~api: Api.component` and use `api->Component.outputs.api` / `api->Component.outputs.role` internally.

4. **Verify AWS `Core_Builder.Make` satisfies the updated `Core.T`** (add a type ascription test).

5. **Build and fix any type errors** in packages that use `Core.T`.

---

### Phase 2: Add `type api`, `type role`, `module Api`, `module Plugin`, and `module Core` to `Platform.T`

**Dependency**: Requires `Api.T` type from api-graphql Phase 2, and `Plugin.T`/updated `Core.T` from this plan Phase 1.

**Steps**:

1. **Update `reventless-infra/src/types/Platform.res`** to add:
   ```rescript
   module type T = {
     type api  // Output type of the platform's Api component (e.g. AppSync API ref)
     type role // Output type of the platform's Api component (e.g. IAM role ref)

     // ... existing Aggregate, ReadModel, etc. factories ...

     /** Factory for the API component (GraphQL schema management). Per api-graphql plan. */
     module Api: {
       module Make: (Config: {let baseFragment: ReventlessInfra.Api.schemaFragment}) => ReventlessInfra.Api.T
         with type api = api and type role = role
     }

     /** Factory for plugin deployment units. */
     module Plugin: Plugin.T with type api = api and type role = role

     /** Factory for the Core management instance. */
     module Core: Core.T with type api = api and type role = role
   }
   ```

2. **Update `reventless-aws/src/Platform.res`**:
   - Remove `(Api: {let api; let apiRole})` from `module Make` — Platform now takes no config params: `module Make = (): ReventlessInfra.Platform.T`
   - Add `type api = PulumiAws.AppSync.GraphQLApi.t`
   - Add `type role = PulumiAws.IAM.Role.t`
   - Add `module Api` — wraps `Api_Builder.Make(AppSync_Adapter.Make())` (from api-graphql Phase 5)
   - Add `module Plugin` — wraps the existing `Plugin_Builder.Make(...)` with all infrastructure adapters pre-bound
   - Add `module Core` — wraps `ReventlessAws.Core_Builder` with platform adapters pre-bound

3. **Update `reventless-in-memory/src/Platform.res`**:
   - Add `type api = unit`
   - Add `type role = unit`
   - Add `module Api` — wraps `Api_Builder.Make(GraphQL_InMemory_Adapter.Make())` (from api-graphql Phase 9); **this replaces the bare `GraphQL_Server.start()` call** — the server is now started by `makeApiResource` inside the Api component
   - Add `module Plugin` — in-memory plugin builder (see Phase 3)
   - Add `module Core` — in-memory core builder (see Phase 3)

4. **Build the monorepo** and fix type errors.

---

### Phase 3: Create in-memory `Plugin_Builder` and `Core_Builder`

**Dependency**: The in-memory `Plugin_Builder` interacts with the Api component for schema fragment generation. If api-graphql Phase 9 (`GraphQL_InMemory_Adapter`) is not yet implemented, use a no-op fragment generator stub and mark for replacement.

The in-memory platform currently has no Plugin or Core builder. These must be created.

**`reventless-in-memory/src/Plugin_Builder.res`**:
- Takes `Bus` as a shared in-memory message bus
- Implements `Plugin.T with type api = unit and type role = unit`
- Wires aggregates, read models, extension points, extensions, tasks, DCB components using the existing in-memory builders
- For the core plugin extension point connection: in-memory mode runs a single stack — connect directly via the Bus (no StackReference)
- Schema fragment generation: delegates to `GraphQL_FragmentGenerator` (from api-graphql Phase 3) via the in-memory Api adapter, or no-op stub if api-graphql is not yet implemented
- Heartbeat: dispatches real Bus message to Core's plugin extension point channel (to exercise Core's read model in integration tests)

**`reventless-in-memory/src/Core_Builder.res`**:
- Takes `Bus` as a shared in-memory message bus
- Implements `Core.T with type api = unit and type role = unit`
- Wires core's aggregates, read models, extension points using existing in-memory builders
- Plugin extension point (where plugins send heartbeats) backed by in-memory bus channel
- `~api: Api.component` parameter: in-memory core uses `api->Component.operations->TestRunner.resolve` pattern to access `updateSchema` for integration tests

**Steps**:

1. Read existing in-memory builders (`Aggregate_Builder.res`, `ReadModel_Builder.res`, `ExtensionPoint_Builder.res`) to understand the `Bus`-based pattern.
2. Create `Plugin_Builder.res` in-memory implementation.
3. Create `Core_Builder.res` in-memory implementation.
4. Wire them into `Platform.res` (in-memory).
5. Build and run existing tests — confirm no regressions.

---

### Phase 4: Add `makePlatform` to `Platform.T`

**Dependency**: Requires api-graphql plan Phase 4 (`Api.operations.updateSchema`) and Phase 6 (`Plugin_Builder` generating `apiSchemaFragment`). Without these, `makePlatform` cannot perform schema stitching but can still handle Scheduler and stack exports.

**Purpose**: Deploy a complete platform (one Api + one Core + N Plugins) in one Pulumi stack:
- Single shared Scheduler created internally
- Direct Core→Plugin wiring (no StackReference)
- GraphQL schema stitching across all plugins
- All Pulumi stack exports set

**Type in `Platform.T`**:
```rescript
type platformOutputs = {
  api: Api.component,
  core: Core.component,
  plugins: array<Plugin.component>,
}

let makePlatform: (
  ~api: Api.component,
  ~core: Api.component => Core.component,
  ~plugins: array<Api.component => Plugin.component>,
) => platformOutputs
```

The callback pattern (`~core: Api.component => Core.component`) lets `makePlatform` thread the Api component and Scheduler into user-supplied factory calls. This avoids requiring users to manually extract api/role from the Api component when using the full-platform path.

**Simpler alternative** (if callbacks feel too heavy): receive pre-built components and just handle exports + schema stitching:
```rescript
let makePlatform: (
  ~api: Api.component,
  ~core: Core.component,
  ~plugins: array<Plugin.component>,
) => platformOutputs
```

The simpler form requires the user to extract api/role manually. **Use this form initially** and upgrade to callbacks if the ergonomics prove awkward.

**`makePlatform` responsibilities**:
1. Creates the shared Scheduler (or accepts one via optional `~scheduler` param).
2. Collects all plugin schema fragments (from `Plugin.outputs.apiSchemaFragment` — per api-graphql Phase 6).
3. Calls `Api.operations.updateSchema(allPluginFragments)` to stitch the full GraphQL schema.
4. On AWS: exports Pulumi stack outputs (`core`, `extensionPoints`, `eventMappers`, `resolvers`) so other stacks can reference them via StackReference.
5. On in-memory: returns components for test assertion access; triggers `GraphQL_Server.rebuildSchema` via the `updateSchema` operation.

**Steps**:

1. Define `type platformOutputs` in `Platform.T`.
2. Add `let makePlatform` to `Platform.T`.
3. Implement in AWS Platform:
   - Create scheduler via EventBridge
   - Collect plugin fragments from outputs
   - Call `updateSchema`
   - Set Pulumi stack exports (version, core outputs, plugin outputs, resolvers, eventMappers)
4. Implement in in-memory Platform:
   - Create no-op scheduler
   - Call `updateSchema` (triggers `GraphQL_Server.rebuildSchema`)
   - Return components for test access
5. Update examples to demonstrate the new API.

---

### Phase 5: Add `makeScheduler` helper to `Platform.T`

For users who create components individually (outside of `makePlatform`), the Scheduler is infrastructure-specific (EventBridge on AWS, no-op on in-memory). The Platform exposes a factory:

```rescript
let makeScheduler: unit => Pulumi.Output.t<Scheduler.operations>
```

This allows the composition root to create a shared scheduler and pass it to Core and Plugin individually:

```rescript
// index.res — used when NOT using makePlatform
let scheduler = Platform.makeScheduler()
let core = Platform.Core.make(~version, ~api=myApi, ~aggregates, ~readModels, ~scheduler)
let plugin = Platform.Plugin.make(~name, ~version, ~heartbeatInterval, ~aggregates, ~readModels, ~api, ~apiRole, ~scheduler)
```

---

## Final Platform.T Shape

After all phases, `Platform.T` will look like:

```rescript
module type T = {
  // Platform-level types
  type api   // AppSync API ref (AWS) or unit (in-memory)
  type role  // IAM role ref (AWS) or unit (in-memory)

  // Existing primitive component factories (unchanged)
  module Aggregate: { module Make: (...) => Aggregate.T }
  module ReadModel: { module Make: (...) => ReadModel.T with module Spec = Spec }
  module ExtensionPoint: { module Make: (...) => ExtensionPoint.T }
  module Extension: { module Make: (...) => Extension.T }
  module Task: { module Make: (...) => Task.T with module Spec = Spec }
  module Counter: Counter.T
  module StateChangeSlice: { module Make: (...) => StateChangeSlice.T }
  module StateViewSlice: { module Make: (...) => StateViewSlice.T }
  module DcbEventLog: { module Make: (...) => DcbEventLog.T }

  // NEW: GraphQL API component (from api-graphql plan)
  module Api: {
    module Make: (Config: {let baseFragment: Api.schemaFragment}) => Api.T
      with type api = api and type role = role
  }

  // NEW: Deployment unit factories
  module Plugin: Plugin.T with type api = api and type role = role
  module Core: Core.T with type api = api and type role = role

  // NEW: Scheduler helper
  let makeScheduler: unit => Pulumi.Output.t<Scheduler.operations>

  // NEW: Full-platform deployment
  type platformOutputs = {
    api: Api.component,
    core: Core.component,
    plugins: array<Plugin.component>,
  }
  let makePlatform: (
    ~api: Api.component,
    ~core: Core.component,
    ~plugins: array<Plugin.component>,
  ) => platformOutputs
}
```

---

## Usage Pattern (After Implementation)

```rescript
// index.res — the only file that imports reventless-aws

module Platform = ReventlessAws.Platform.Make()  // No api/apiRole config needed

// Create the shared Api component (creates the AppSync API + base schema)
module MyApiMaker = Platform.Api.Make({let baseFragment = coreBaseSchema})
let myApi = MyApiMaker.make(~name="MyPlatform")

// Extract api/role values for Plugin.make
let apiRef = myApi->Component.outputs |> _.api     // Pulumi.Output.t<AppSync.api>
let roleRef = myApi->Component.outputs |> _.role   // Pulumi.Output.t<IAM.role>

// Create the shared scheduler
let scheduler = Platform.makeScheduler()

// Assemble the Core (with full Api component for schema management)
module PluginAggregate = Platform.Aggregate.Make(PluginSpec, PluginBehavior, NoEventMappings)
let core = Platform.Core.make(
  ~version="1.0.0",
  ~api=myApi,
  ~extensionPoints=[module(PluginExtensionPoint)],
  ~aggregates=[module(PluginAggregate)],
  ~readModels=[],
  ~scheduler,
)

// Assemble a Plugin (with api/role values extracted from Api component)
module ProductAggregate = Platform.Aggregate.Make(ProductSpec, ProductBehavior, NoEventMappings)
module ProductsReadModel = Platform.ReadModel.Make(ProductsRMSpec, ProductsMappings)
let catalogPlugin = Platform.Plugin.make(
  ~name="Catalog",
  ~version="1.0.0",
  ~heartbeatInterval=30,
  ~aggregates=[module(ProductAggregate)],
  ~readModels=[module(ProductsReadModel)],
  ~api=apiRef,
  ~apiRole=roleRef,
  ~scheduler,
)

// Deploy the full platform (stitches schema, sets stack exports)
let _platform = Platform.makePlatform(
  ~api=myApi,
  ~core,
  ~plugins=[catalogPlugin],
)
```

---

## Open Questions

1. **`resourceNaming`** — `Core_Builder` takes `~resourceNaming: ResourceNaming.operations`. Where does this come from — Platform config or always the same? Clarify before implementing Phase 1. Likely stays as an internal default in the builder.

2. **`apiRef` / `roleRef` are `Pulumi.Output.t` wrapped** — Plugin.T's `~api` and `~apiRole` params may be raw values, not `Output.t`. Confirm whether the Api component outputs are wrapped or direct resource references. If wrapped, `Plugin.make` signature may need to accept `Pulumi.Output.t<api>` or the Platform's `Plugin` wrapper needs to unwrap them via `Output.apply`.

3. **In-memory `Plugin_Builder` heartbeat** — Plugins send heartbeats to the Core's plugin extension point. In in-memory tests, should this be a real in-bus message or a no-op? **Recommend**: real Bus dispatch (exercises Core's read model in integration tests).

4. **Single-stack vs. multi-stack Core wiring** — When `makePlatform` is called, Plugins reference the Core's extension point directly (not via StackReference). Should the existing `Interstack.coreStackReference` path in `Plugin_Builder` be changed, or should a new "same-stack" builder variant be created? **Recommend**: new variant to avoid breaking existing multi-stack deployments.

5. **`makePlatform` Scheduler ownership** — If `Core.make` and `Plugin.make` are called before `makePlatform`, they already need a scheduler. `makePlatform` cannot retroactively thread it. **Resolution**: expose `makeScheduler()` (Phase 5) and have users create it first; `makePlatform` accepts an optional `~scheduler` override. Document the recommended usage order.

6. **api-graphql schema fragment availability in `Plugin.outputs`** — `makePlatform` needs to collect all plugin schema fragments to call `updateSchema`. This requires `Plugin.outputs` to expose `apiSchemaFragment`. Confirm this is part of api-graphql Phase 6 outputs (it appears to be embedded in `pluginDefinition`). If not in `Plugin.outputs` directly, `makePlatform` may need to call `updateSchema` via the Core's plugin connect handler instead.

7. **Backward compatibility for `AWS Platform.Make` callers** — The removal of `(Api: {let api; let apiRole})` from `Platform.Make` is breaking. Any existing composition root code must be updated to remove the config argument. Both implementations are in this repo, so this is manageable.

---

## Order of Work

1. Phase 1 — Fix `Core.T` (prerequisite for all others; can draft before api-graphql Phase 2 is merged but full implementation waits)
2. Phase 3 — In-memory Plugin/Core builders (enables testing before AWS implementation; use no-op Api stubs if api-graphql not yet merged)
3. Phase 2 — Add Api/Plugin/Core/api/role to `Platform.T` + AWS/in-memory implementations (waits for api-graphql Phases 2, 5, 9)
4. Phase 5 — Add `makeScheduler` helper (small, can be done alongside Phase 2)
5. Phase 4 — Add `makePlatform` function (waits for api-graphql Phase 6 for schema stitching; can implement without stitching first and add it after)

**Coordination with api-graphql plan:**
- api-graphql Phase 2 (Api.res / Api_Adapter.res types) must precede Phase 1 of this plan
- api-graphql Phase 4 (Api_Builder) must precede Phase 2 of this plan (AWS Platform.Api.Make)
- api-graphql Phase 5 (AppSync_Adapter) must precede Phase 2 (AWS)
- api-graphql Phase 9 (GraphQL_InMemory_Adapter) must precede Phase 2 (in-memory)
- api-graphql Phase 6 (Plugin_Builder fragment generation) must precede Phase 4's schema stitching step
