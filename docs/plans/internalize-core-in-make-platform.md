# Internalize Core and Scheduler in Platform.makePlatform ✅

## Context

Currently, users must manually create a scheduler, pass it to each plugin's `make`, create a `Core.component`, and pass everything to `Platform.makePlatform`. This is unnecessary boilerplate because:
1. `~core` is **completely ignored** in both in-memory and AWS `makePlatform` implementations (`~core as _`)
2. `~api` (apiComponent) is also **completely ignored** (`~api as _`)
3. Core.make requires platform-internal knowledge (`~api`, `~apiRole`, `~resourceNaming`) that leaks into user code
4. The scheduler is a platform-internal singleton — every plugin's `make` has the same `(~scheduler, ~api, ~apiRole)` signature
5. Core-level components (extensionPoints, aggregates, readModels) are empty in all examples — rarely used

The goal is to move scheduler creation, Core creation, and plugin assembly all inside `makePlatform`.

## Current API (identical boilerplate in all 3 examples)

```rescript
module Platform = ReventlessInMemory.Platform.Make()
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

let scheduler = Platform.makeScheduler()
let catalogPlugin = Catalog.make(~scheduler, ~api=(), ~apiRole=())
let orderingPlugin = Ordering.make(~scheduler, ~api=(), ~apiRole=())

let core = Platform.Core.make(
  ~version="1.0.0",
  ~extensionPoints=[],
  ~aggregates=[],
  ~readModels=[],
  ~scheduler,
  ~api=(),
  ~apiRole=(),
  ~resourceNaming=ReventlessInMemory.InMemory_PluginSpec.resourceNaming,
)

Platform.makePlatform(~api=Obj.magic(), ~core, ~plugins=[catalogPlugin, orderingPlugin])
```

## Target API

```rescript
module Platform = ReventlessInMemory.Platform.Make()
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
)
```

`makePlatform` internally:
1. Creates the scheduler via `makeScheduler()`
2. Calls each plugin's `make(~scheduler, ~api, ~apiRole)` using platform-known `api`/`apiRole` values
3. Creates Core with platform-known `api`, `apiRole`, `resourceNaming`
4. Wires everything together (same as today)

## PluginMaker module type

Every plugin's `Make` functor already produces a uniform `make` signature:

```rescript
let make: (
  ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
  ~api: Platform.api,
  ~apiRole: Platform.role,
) => Plugin.component
```

Define a new module type in `Platform.T` (or `Plugin.res`) that `makePlatform` can use to call each plugin:

```rescript
module type PluginMaker = {
  let make: (
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~api: api,
    ~apiRole: role,
  ) => Plugin.component
}
```

`makePlatform` then takes `~plugins: array<module(PluginMaker)>` instead of `array<Plugin.component>`.

## Files to Modify

### Step 1: Add PluginMaker type and update Platform.T interface

**File:** `reventless/reventless-infra/src/types/Platform.res`

- Add `module type PluginMaker` inside `Platform.T`
- Remove `makeScheduler` from Platform.T (no longer user-facing)
- Change `makePlatform` signature:

```rescript
module type PluginMaker = {
  let make: (
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~api: api,
    ~apiRole: role,
  ) => Plugin.component
}

let makePlatform: (
  ~version: string,
  ~plugins: array<module(PluginMaker)>,
  ~extensionPoints: array<module(ExtensionPoint.T)>=?,
  ~aggregates: array<module(Aggregate.T with type api = api)>=?,
  ~readModels: array<module(ReadModel.T with type api = api and type role = role)>=?,
  ~dcbSpec: module(Plugin.DcbSpec)=?,
) => unit
```

### Step 2: Update In-Memory Platform implementation

**File:** `reventless/reventless-in-memory/src/Platform.res`

In `makePlatform`:
1. Accept new params — `~version`, `~plugins: array<module(PluginMaker)>`, plus optional core-component arrays
2. Internally create scheduler via existing `makeScheduler()` logic
3. Iterate `plugins`, calling each `PluginMaker.make(~scheduler, ~api=(), ~apiRole=())`
4. Internally call `Core.make(...)` with platform-known values
5. Continue with existing wiring logic using the built plugin components

`makeScheduler` stays as an internal function (no longer exposed on Platform.T).

### Step 3: Update AWS Platform implementation

**File:** `reventless/reventless-aws/src/Platform.res`

Same pattern — create scheduler internally, call each PluginMaker.make with AWS-specific `api`/`apiRole`, create Core internally.

### Step 4: Update all example Main.res files

**Files:**
- `examples/online-shop-aggregates/online-shop-aggregates/src/Main.res`
- `examples/online-shop-dcb/online-shop-dcb/src/Main.res`
- `examples/online-shop-hybrid/online-shop-hybrid/src/Main.res`

Remove scheduler creation, plugin make calls, and Core.make. Simplify to:

```rescript
let _ = ReventlessInMemory.TestRunner.setup()

module Platform = ReventlessInMemory.Platform.Make()  // or MakeWithConfig
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
)
```

### Step 5: Update documentation

**Files:**

- `docs/guides/platform-and-plugin-guide.md`
  - Lines 660-696: Full in-memory platform assembly example (scheduler, Core.make, makePlatform)
  - Lines 780-790: Split API mode example (`makePlatform(~api=Obj.magic(), ~core, ~plugins=[...])`)
  - Lines 1370-1398: Hybrid composition example (repeat of full assembly pattern)

- `docs/guides/graphql-schema-debugging.md`
  - Lines 220-249: Integration example showing `makeScheduler()`, plugin `make(~scheduler, ~api, ~apiRole)`, and platform wiring

- `packages/doc/docs-providers/aws/get-started.md`
  - Line 68: `let core = Core.make()` pseudocode

- `packages/doc/docs-providers/aws/index.md`
  - Line 426: `let core = Reventless.Core.make(~adapter, ...)` pseudocode

Update all platform assembly examples in these docs to reflect the simplified API.

## Design Decisions

1. **`makeScheduler` becomes internal** — No longer exposed on `Platform.T`. Created inside `makePlatform` and passed to plugins/Core automatically.

2. **`PluginMaker` module type** — Matches the existing uniform plugin `make` signature. First-class modules (`module(Catalog)`) passed in an array.

3. **Keep `Core` and `Plugin` modules on `Platform.T`** — Still needed internally. `Core` is used by `makePlatform`; `Plugin` is used by `PluginMaker.make` which calls `Platform.Plugin.make(...)`.

4. **Optional core-level component params** — `~extensionPoints`, `~aggregates`, `~readModels`, `~dcbSpec` default to empty/none on `makePlatform`. Covers the common case while supporting the rare case.

5. **`~apiComponent` omitted** — Currently optional on Core.make and unused in both platforms. Can be added later if needed.

## Verification

1. `npm run build` from root — all packages compile with zero warnings
2. Run each example: `cd examples/online-shop-dcb/online-shop-dcb && npx tsx src/Main.res.mjs`
3. Run tests: `npm test` from root
4. Verify GraphQL server starts and responds to queries in examples
