# Platform Extension: Plugin, Core, and Full-Platform Deployment

## Status: COMPLETED

Implementation completed 2026-03-03. Pragmatic additive approach — keeps AWS `Platform.Make` taking `Api` config as-is; adds Plugin, Core, makeScheduler, makePlatform alongside existing modules.

---

## What Was Implemented

### 1. `Core.T` module type in `reventless-infra`

**File created**: `reventless-infra/src/components/Core.res`

Mirrors how `Plugin.T` is already split — module type in `reventless-infra`, builder in `reventless-core`. Signature matches the actual `Core_Builder.Make` output (with `~api`, `~apiRole`, `~resourceNaming`, `~apiComponent` parameters).

### 2. Extended `Platform.T`

**File modified**: `reventless-infra/src/types/Platform.res`

Added to `module type T`:
- `type api` and `type role` — platform-specific types (AWS: `Types.AppSync.api/role`, in-memory: `unit`)
- `module Plugin: Plugin.T with type api = api and type role = role`
- `module Core: Core.T with type api = api and type role = role`
- `let makeScheduler: unit => Pulumi.Output.t<Scheduler.operations>`
- `let makePlatform: (~api: apiComponent, ~core: Core.component, ~plugins: array<Plugin.component>) => unit`

Note: `type apiComponent = Api.component` alias defined before `module type T` to avoid shadowing by the nested `module Api`.

### 3. In-memory adapter stubs

New files created in `reventless-in-memory/src/adapter/`:
- `CommandTopic/CommandTopicRemoteChannel_InMemory.res` — dispatches to Bus
- `Runtime/PluginRuntime_Builder_InMemory.res` — wraps `PluginRuntime_Builder_Micro`
- `Cloner/ClonerRunner_InMemory.res` — no-op cloner using `Cloner.Adapter.noRunner`
- `InMemory_PluginSpec.res` — no-op runtime ops, identity resource naming

### 4. In-memory Plugin_Builder and Core_Builder

New files in `reventless-in-memory/src/components/`:
- `Plugin_Builder.res` — `Make(Bus)` functor using `include ReventlessCore.Plugin_Builder.Make(...)`
- `Core_Builder.res` — `Make(Bus)` functor using `include ReventlessCore.Core_Builder.Make(...)`

### 5. AWS Platform updated

**File modified**: `reventless-aws/src/Platform.res`

- Added return type annotation `(ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role)`
- Added `type api = Types.AppSync.api`, `type role = Types.AppSync.role`
- Added `module Plugin`, `module Core`, `let makeScheduler`, `let makePlatform`
- Kept existing `(Api: {let api; let apiRole})` constructor — not removed (deferred)

### 6. In-memory Platform updated

**File modified**: `reventless-in-memory/src/Platform.res`

- Added return type constraint, `type api = unit`, `type role = unit`
- Added `module Plugin`, `module Core`, `let makeScheduler`, `let makePlatform`
- Kept `GraphQL_Server.start()` at module init

### 7. Plugin_Builder refactored for no-Core-stack support

**File modified**: `reventless-core/src/components/Plugin/Plugin_Builder.res`

- Handles `Interstack.coreStackReference = None` gracefully (in-memory mode has no Core stack)
- Added conditional logic for `coreSetup` (None when running without Core stack reference)
- No-op heartbeat connect and no-op publishToCorePluginExtensionPoint when no Core stack

**File modified**: `reventless-core/src/components/Plugin/Plugin_Helpers.res`

- Added `connectWithoutCore` to `MakeEventCollectorHelper` functor — simplified connect without Core stack reference

---

## Key Technical Decisions

### `Obj.magic` for Plugin module sealing

`ReventlessCore.Plugin.T` and `ReventlessInfra.Plugin.T` have nominally different `DcbSpec` module types (same structure, different paths). ReScript's first-class module type matching is nominal, so `Plugin_Builder.make` can't directly satisfy `ReventlessInfra.Plugin.T.make`. Both Platform implementations use `Obj.magic(PluginBuilder.make)` — safe because the types are structurally identical at runtime.

Core doesn't need `Obj.magic` because its `make` signature uses explicitly-qualified `ReventlessInfra.*` types throughout and has no first-class module type path conflicts.

### Abstract `type component` exposure

`ReventlessCore.Plugin.T` (in `reventless-core`) does NOT include `type component` in `module type T`. `ReventlessInfra.Plugin.T` DOES. So `include Plugin_Builder.Make(...)` alone doesn't provide `type component`. Both Platforms explicitly define `type component = ReventlessCore.Plugin.component` in the sealed module wrapper. Same pattern for Core.

### `makePlatform` as no-op

Currently both AWS and in-memory `makePlatform` are no-ops (return `unit`). Schema stitching is handled by existing event-based mechanisms (ConnectPluginExtension). Stack exports are set by user entry-point code. Future work can add automatic schema stitching and export management.

---

## Files Changed/Created

| File | Action |
|------|--------|
| `reventless-infra/src/components/Core.res` | **Created** — Core module type T |
| `reventless-infra/src/types/Platform.res` | **Modified** — Added type api/role, Plugin, Core, makeScheduler, makePlatform |
| `reventless-core/src/components/Plugin/Plugin_Builder.res` | **Modified** — Handle None coreStackReference |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | **Modified** — Added connectWithoutCore |
| `reventless-in-memory/src/adapter/CommandTopic/CommandTopicRemoteChannel_InMemory.res` | **Created** |
| `reventless-in-memory/src/adapter/Runtime/PluginRuntime_Builder_InMemory.res` | **Created** |
| `reventless-in-memory/src/adapter/Cloner/ClonerRunner_InMemory.res` | **Created** |
| `reventless-in-memory/src/adapter/InMemory_PluginSpec.res` | **Created** |
| `reventless-in-memory/src/components/Plugin_Builder.res` | **Created** |
| `reventless-in-memory/src/components/Core_Builder.res` | **Created** |
| `reventless-aws/src/Platform.res` | **Modified** — Added Plugin, Core, makeScheduler, makePlatform |
| `reventless-in-memory/src/Platform.res` | **Modified** — Added Plugin, Core, makeScheduler, makePlatform |

---

## Verification

- `npm run build` — zero errors, zero warnings
- `npm test` — 653 tests pass (81 test suites)
- Both AWS and in-memory Platform.Make satisfy extended `Platform.T`

---

## Deferred Work

- **Remove Api config from Platform.Make**: See `docs/plans/Backlog/remove-api-config-from-platform-make.md`
- **Real `makePlatform` implementation**: Add automatic schema stitching and Pulumi stack export management
- **Nominal type alignment**: Align `ReventlessCore.Plugin.DcbSpec` / `ReventlessInfra.Plugin.DcbSpec` to eliminate `Obj.magic` need
- **Core.T signature alignment**: `ReventlessCore.Core.T` still has the old minimal signature; a future change could make it reference `ReventlessInfra.Core.T`
