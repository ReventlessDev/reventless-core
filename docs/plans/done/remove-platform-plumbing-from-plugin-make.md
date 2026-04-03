# Remove Platform Plumbing from Plugin.make

## Status: Phase 1 DONE — Phase 2 pending

**Prerequisite**: ~~platform-plugin-core-extension~~ — completed (see `docs/plans/done/platform-plugin-core-extension.md`).

## Goal

Eliminate the `(~scheduler, ~api, ~apiRole)` parameters from the `PluginMaker.make` interface. App developers should not have to thread platform-internal values through their plugin `make` functions.

**Before** (every app plugin):
```rescript
let make = (~scheduler, ~api, ~apiRole) =>
  Platform.Plugin.make(~name="Catalog", ~scheduler, ~api, ~apiRole, ~aggregates=[...], ...)
```

**After**:
```rescript
let make = () =>
  Platform.Plugin.make(~name="Catalog", ~aggregates=[...], ...)
```

---

## Problem

Every app plugin's `make` function must accept and forward three platform-internal parameters (`~scheduler`, `~api`, `~apiRole`) that the app developer never chooses or inspects. This is pure boilerplate — `makePlatform`/`deployPlugin` create these values internally and pass them straight through.

Additionally, several builder functors (`Counter_Builder`, `StateViewSlice_Builder`, `AutomationSlice_Builder`, `OutboundTranslationSlice_Builder`, `InboundTranslationSlice_Builder`) take `(Api: {let api; let apiRole})` as a functor argument, even though these values are already available in the Platform scope. This is the same problem at a different layer.

---

## Current Flow

```
makePlatform()
  ├─ scheduler = makeScheduler()
  ├─ api/apiRole = appSyncApi/appSyncApiRole  (already module-level)
  └─ P.make(~scheduler, ~api, ~apiRole)       ← app plugin receives + forwards
       └─ Plugin.make(~scheduler, ~api, ~apiRole, ~name, ...)
            └─ construct(~scheduler, ~api, ~apiRole, ...)
                 ├─ createAggregatesWithoutEventMappers(~api, ...)
                 ├─ createReadModels(~api, ~apiRole, ...)
                 └─ scheduler → tasks, extension points
```

All three params originate inside the Platform and are consumed inside `Plugin_Builder.construct`. The app plugin is just a pass-through.

---

## Design

### Approach: Platform-scoped refs

Use mutable refs inside the Platform module scope (populated by `makePlatform`/`deployPlugin` before building plugins). `Plugin_Builder.make` reads from the platform hooks/refs instead of taking explicit params.

```rescript
// In Plugin_Helpers or Platform hooks:
type platformContext<'api, 'role> = {
  scheduler: Pulumi.Output.t<Scheduler.operations>,
  api: 'api,
  apiRole: 'role,
}

// In Platform.MakeWithConfig:
let platformContextRef: ref<option<platformContext<api, role>>> = ref(None)

// In makePlatform/deployPlugin:
let scheduler = makeScheduler()
platformContextRef := Some({scheduler, api: appSyncApi, apiRole: appSyncApiRole})
// ... then build plugins
```

This is the same pattern already used by `apiConfigRef` (Platform.res:122), `Plugin_Helpers.onPluginBuiltHook`, and `Spec.hooks.adminExtensionPoints` — all are ref-based context injection within the Platform scope.

### Why not functor injection?

`scheduler` is created per-call to `makePlatform`/`deployPlugin` (not at module-definition time), so it can't be a functor argument. A ref is the natural fit — it's populated right before plugins are built, in the same function scope.

### Why not keep scheduler and only remove api/apiRole?

Half-measures leave the app developer with `let make = (~scheduler) => ...` which is still unexplained plumbing. All three params should go together.

---

## Steps

### Phase 1: Add platformContext to Plugin_Builder

**Goal**: `Plugin_Builder.make` reads scheduler/api/apiRole from platform context instead of params.

#### 1.1 Add context type and ref to platform hooks

**File**: `reventless-core/src/components/Plugin/Plugin_Helpers.res`

Add to `platformHooks`:
```rescript
platformContext: ref<option<{
  scheduler: Pulumi.Output.t<Scheduler.operations>,
  api: 'api,  // needs to be typed via functor
  apiRole: 'role,
}>>
```

Or add a dedicated ref alongside the existing hooks pattern.

#### 1.2 Update Plugin_Builder.make to read from context

**File**: `reventless-core/src/components/Plugin/Plugin_Builder.res`

- Remove `~api`, `~apiRole`, `~scheduler` from `make` and `construct` signatures
- Read them from the hooks/ref inside `construct`
- Update `Plugin.T` module type accordingly

#### 1.3 Update Plugin.T module type (reventless-infra)

**File**: `reventless-infra/src/types/Plugin.res`

Remove `~api`, `~apiRole`, `~scheduler` from `make`:
```rescript
// Before:
let make: (~name, ~heartbeatInterval, ..., ~api: api, ~apiRole: role, ~scheduler, ...) => component

// After:
let make: (~name, ~heartbeatInterval, ...) => component
```

#### 1.4 Update PluginMaker module type

**File**: `reventless-infra/src/types/Platform.res`

```rescript
// Before:
module type PluginMaker = {
  let make: (
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~api: api,
    ~apiRole: role,
  ) => Plugin.component
}

// After:
module type PluginMaker = {
  let make: unit => Plugin.component
}
```

#### 1.5 Update Platform implementations

**Files**:
- `reventless-aws/src/Platform.res` — populate context ref in `makePlatform`/`deployPlugin` before building plugins; simplify `P.make()` calls
- `reventless-in-memory/src/Platform.res` — same

#### 1.6 Update all app plugins

**Files** (examples):
- `examples/online-shop-hybrid/catalog/src/Plugin/CatalogPlugin.res`
- `examples/online-shop-hybrid/ordering/src/Plugin/OrderingPlugin.res`
- `examples/online-shop-aggregates/catalog/src/CatalogPlugin.res`
- `examples/online-shop-aggregates/ordering/src/OrderingPlugin.res`
- `examples/online-shop-dcb/catalog/src/Plugin/CatalogPlugin.res`
- `examples/online-shop-dcb/ordering/src/Plugin/OrderingPlugin.res`

Change from:
```rescript
let make = (~scheduler, ~api, ~apiRole) =>
  Platform.Plugin.make(~name="Catalog", ~scheduler, ~api, ~apiRole, ...)
```
To:
```rescript
let make = () => Platform.Plugin.make(~name="Catalog", ...)
```


### Phase 2: Remove Api functor arg from slice builders

**Goal**: Since `api`/`apiRole` are now in the platform context (not passed through Plugin.make), the builder functors that take `(Api: {let api; let apiRole})` can also be simplified.

#### 2.1 Core builders — remove Api functor param

For each of these builders, remove the `Api` functor parameter and instead accept `~api`/`~apiRole` at `make()` time (matching the existing `QueryDb_Builder` pattern):

| Core builder | File |
|-------------|------|
| Counter_Builder | `reventless-core/src/components/Counter/Counter_Builder.res` |
| StateViewSlice_Builder | `reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` |
| AutomationSlice_Builder | `reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res` |

Pattern for each:
```rescript
// Before:
module Make = (QueryDbStorage, Api: { let api; let apiRole }, Handler) => {
  let make = (~name, ...) => ...
  // uses Api.api, Api.apiRole in construct
}

// After:
module Make = (QueryDbStorage, Handler) => {
  let make = (~name, ~api: QueryDbStorage.api, ~apiRole: QueryDbStorage.role, ...) => ...
  // uses ~api, ~apiRole directly
}
```

#### 2.2 AWS builders — remove Api functor param, pass through

| AWS builder | File |
|------------|------|
| Counter_Builder | `reventless-aws/src/components/Counter_Builder.res` |
| StateViewSlice_Builder | `reventless-aws/src/components/StateViewSlice_Builder.res` |
| StateViewSlice_Builder_Bundled | `reventless-aws/src/components/StateViewSlice_Builder_Bundled.res` |
| AutomationSlice_Builder | `reventless-aws/src/components/AutomationSlice_Builder.res` |
| AutomationSlice_Builder_Bundled | `reventless-aws/src/components/AutomationSlice_Builder_Bundled.res` |
| OutboundTranslationSlice_Builder | `reventless-aws/src/components/OutboundTranslationSlice_Builder.res` |
| OutboundTranslationSlice_Builder_Bundled | `reventless-aws/src/components/OutboundTranslationSlice_Builder_Bundled.res` |
| InboundTranslationSlice_Builder | `reventless-aws/src/components/InboundTranslationSlice_Builder.res` |

#### 2.3 In-memory builders — remove dummy Api module

| In-memory builder | File |
|-------------------|------|
| Counter_Builder | `reventless-in-memory/src/components/Counter_Builder.res` |
| StateViewSlice_Builder | `reventless-in-memory/src/components/StateViewSlice_Builder.res` |
| AutomationSlice_Builder | `reventless-in-memory/src/components/AutomationSlice_Builder.res` |

Remove the `module Api = { let api = (); let apiRole = () }` pattern. Pass `~api=()` / `~apiRole=()` at `make()` call sites instead.

#### 2.4 Platform.res — remove ApiConfig from builder instantiation

**Files**: `reventless-aws/src/Platform.res`, `reventless-in-memory/src/Platform.res`

```rescript
// Before:
module Counter = Counter_Builder.Make(ApiConfig, { ... })
module StateViewSlice = { include StateViewSlice_Builder.Make(ApiConfig) }

// After:
module Counter = Counter_Builder.Make({ ... })
module StateViewSlice = { include StateViewSlice_Builder.Make() }
// api/apiRole passed at make() time inside Plugin_Builder.construct
```

#### 2.5 Update module types (reventless-infra)

- `Counter.T` (`reventless-infra/src/components/Counter.res`) — no change needed if Counter.make stays internal (called by Plugin_Builder, not by app devs)
- `StateViewSlice.T` — same consideration

#### 2.6 Update in-memory component tests

Tests that call builder `make()` functions directly will need to pass `~api=()` / `~apiRole=()`. Check:
- `reventless-in-memory/tests/components/`
- `reventless-in-memory/tests/e2e/`

---

## Sequencing

1. **Phase 1 first** — simplifies the app developer interface (the user-facing win)
2. **Phase 2 second** — internal cleanup, no app-level impact
3. Build check after each step within a phase

Phase 1 is a **breaking change** for `PluginMaker` — all app plugins must be updated together (or use a compatibility shim temporarily).

Phase 2 is internal to the framework — no app-level impact.

---

## Risk

- **Breaking change**: `PluginMaker` interface changes. All example projects need updating.
- **Ref timing**: Platform context must be populated before any plugin `make()` runs. `makePlatform`/`deployPlugin` already do this sequentially, so this is safe.
- **Low risk**: The ref pattern is already established (`apiConfigRef`, `onPluginBuiltHook`, `adminExtensionPoints`).

## Previously Completed

### ~~Remove `(Api: ...)` from AWS `Platform.Make`~~ — DONE

`Platform.Make` is already a parameterless functor (line 865 of `Platform.res`).
