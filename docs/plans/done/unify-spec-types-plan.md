# Plan: Unify Spec Types — Remove Same-Name Duplicates, Minimize reventless-spec

**Status: DONE** (committed `f8ba26e8`)

## Goal

Eliminate naming confusion between same-named files in `reventless-spec` and `reventless`, remove pointless re-export files, and move framework-internal types out of the spec package.

---

## Phase 1: Fix re-exports and re-definitions ✅

### Step 1.1 — Delete `reventless/src/Platform.res` ✅
- Deleted `reventless/reventless/src/Platform.res`
- Was a pure `include ReventlessSpec.Platform` with no callers

### Step 1.2 — Replace `reventless/src/Behavior.res` ✅
- Replaced content with `include ReventlessSpec.Behavior` plus:
  - Named `module type Spec` (used by test helpers and `BehaviorTest.res`)
  - Standalone type aliases `init`, `apply`, `create`, `execute` (used by `PluginBehavior.res`, `Aggregate_Callback.res`, test helpers)
- The spec version only exports `resolverConfig` and an inline `module type T`; the extra aliases are still needed in reventless

### Step 1.3 — Move ComponentType from spec into reventless ✅
- Replaced `reventless/reventless/src/ComponentType.res` (was `include ReventlessSpec.ComponentType`) with full implementation
- Deleted `reventless/reventless-spec/src/components/ComponentType.res`
- No callers used `ReventlessSpec.ComponentType` directly (verified by grep)

---

## Phase 2: Move internal types out of spec ✅

### Step 2.1 — Move `PluginRuntimeOperations.res` ✅
- Moved: `reventless-spec/src/types/` → `reventless/src/PluginRuntimeOperations.res`
- Updated callers (change `ReventlessSpec.PluginRuntimeOperations` → `PluginRuntimeOperations`):
  - `reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Builder.res`
  - `reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res`
  - `reventless/src/core/Extensions/Connect/PluginConnectExtension_Builder.res`
  - `reventless/src/components/Plugin/Plugin_Builder.res`
  - `reventless-aws/src/util/PluginRuntimeOperations.res` (`Reventless.PluginRuntimeOperations`)

### Step 2.2 — Move `PluginExtensionPointSpec.res` ✅
- Moved: `reventless-spec/src/core/plugin/` → `reventless/src/core/plugin/PluginExtensionPointSpec.res`
- Changed `include Plugin` → `include ReventlessSpec.Plugin` (since `Plugin.res` in reventless is the component file, not the spec)
- Fixed `reventless-spec/src/types/ExtensionMapping.res`: replaced `PluginExtensionPointSpec.pluginDefinition` → `Plugin.pluginDefinition` (the type originates in `ReventlessSpec.Plugin`)
- Updated callers (change `ReventlessSpec.PluginExtensionPointSpec` → `PluginExtensionPointSpec`):
  - `reventless/src/ExtensionMapping.res`
  - `reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Builder.res`
  - `reventless/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res`
  - `reventless/src/core/Extensions/Connect/PluginConnectExtension_Builder.res`
  - `reventless/src/components/Extension/Extension_Operations.res`
  - `reventless/src/components/Plugin/Plugin_Builder.res`
  - `reventless/src/components/Heartbeat/Heartbeat_Callback.res` (found via grep, not in original plan)

### Step 2.3 — Move `StateTopic.res` (spec module type T) ✅
- Deleted `reventless-spec/src/components/StateTopic.res`
- Inlined the `module type T` body directly into `reventless/src/components/StateTopic.res`:
  - Replaced `module Spec: ReventlessSpec.StateTopic.T` with anonymous inline module type
  - Applied same inline type to the `Make` functor parameter

---

## Verification ✅

- `reventless-spec`: builds (52 modules)
- `reventless`: builds (186 modules)
- `reventless-aws`: builds (195 modules)
- `reventless-in-memory` tests: 76/76 pass

## Deferred (separate plans)

- `Component.res` / `Component.resi` / `Component.js` — hand-written `Component.js` creates restore-from-git risk
- `ResourceNaming.res` — referenced by `ExtensionPoint.res` and `Task.res` inside spec itself
- Component Specs (`CommandGenerator`, `CommandTopic`, `EventCollector`, `EventLog`, `EventTopic`, `Heartbeat`, `Scheduler`) — used by Platform module types; removal cascades into `Platform.T`
