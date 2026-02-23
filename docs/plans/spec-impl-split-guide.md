# Package Split Guide: reventless-spec vs reventless

> **Status (2026-02-22):** Platform-to-reventless-spec Phases 1–4 are complete. The current
> state described in the sections below supersedes earlier content. The historical sections
> are kept for reference but mark the state prior to Phase 1.

## Current State (Post Phase 4)

The split is **complete**. Application developers now depend **only on `reventless-spec`** for all
plugin assembly, including `Platform.T`.

### Dependency model

```
reventless-spec    — specs, behaviors, mappings, Platform.T, component T types, output types
     ↑
reventless         — component builders (Aggregate_Builder, ReadModel_Builder, …)
                     Projection.Mapping.Make, Projection.Mappings.Make, NoEventMappings.Make
     ↑
reventless-aws     — AWS-wired concrete Platform.Make(Config), Plugin.make
     ↑
application
  ├── domain/          ← depends on reventless-spec only
  │   ├── MySpec.res
  │   ├── MyBehavior.res
  │   └── MyMappings.res
  ├── plugin/          ← depends on reventless-spec only
  │   ├── MyProjection.res  (uses Reventless.Projection.Mapping.Make)
  │   └── MyPlugin.res      (module Make = (Platform: ReventlessSpec.Platform.T) => {...})
  └── index.res        ← composition root; the ONLY file that imports reventless-aws
```

### Naming convention (current)

Component specs and module types are consolidated into **single files per component** in
`reventless-spec/src/components/`:

| reventless-spec path | What it contains |
|---|---|
| `components/Aggregate.res` | `module type Spec` + output types + `module type T` |
| `components/ReadModel.res` | `module type Spec` + config types + output types + `module type T` |
| `components/DcbEventLog.res` | `module type Spec` + output types + `module type T` |
| `components/StateChangeSlice.res` | `module type Spec` + output types + `module type T` |
| `components/StateViewSlice.res` | `module type Spec` + output types + `module type T` |
| `components/Task.res` | `module type Spec` + config/output types + `module type T` |
| `components/Plugin.res` | plugin definition types + output types + `module type DcbSpec` + `module type T` |
| `components/Counter.res` | output types + `module type T` |
| `components/ExtensionPoint.res` | `module type Spec` + output types + `module type T` |
| `components/Extension.res` | output types + `module type T` |
| `components/EventMapper.res` | output types + `module type Mappings` |
| `Platform.res` | `module type T` — factory interface for platform-agnostic assembly |

**No `_Spec.res` suffix files exist anymore.** The old `ReadModel_Spec.T` is now `ReadModel.Spec`,
`StateChangeSlice_Spec.T` is `StateChangeSlice.Spec`, etc.

### Key module paths (quick reference)

| Old path (pre-Phase 1) | Current path |
|---|---|
| `ReventlessSpec.ReadModel_Spec.T` | `ReventlessSpec.ReadModel.Spec` |
| `ReventlessSpec.ReadModel_Spec.config` / `open ReadModel_Spec; config()` | `ReventlessSpec.ReadModel.config()` |
| `ReventlessSpec.Projection.Spec.Set/Delete/…` | `ReventlessSpec.Projection.Set/Delete/…` |
| `ReventlessSpec.StateChangeSlice_Spec.T` | `ReventlessSpec.StateChangeSlice.Spec` |
| `ReventlessSpec.StateViewSlice_Spec.T` | `ReventlessSpec.StateViewSlice.Spec` |
| `ReventlessSpec.DcbEventLog_Spec.T` | `ReventlessSpec.DcbEventLog.Spec` |
| `Reventless.Platform.T` | `ReventlessSpec.Platform.T` |
| `Reventless.EventMapper.Mappings` | `ReventlessSpec.EventMapper.Mappings` |
| `Reventless.Plugin.DcbSpec` | `ReventlessSpec.Plugin.DcbSpec` |
| `Reventless.StateChangeSlice.T` | `ReventlessSpec.StateChangeSlice.T` |
| `Reventless.StateViewSlice.T` | `ReventlessSpec.StateViewSlice.T` |

### What remains in reventless (intentionally)

These types are internal builder concerns and must stay in reventless:
- `Projection.Mapping.Make` / `Projection.Mappings.Make` — functor implementations
- `NoEventMappings.Make` — utility functor
- `Aggregate_Builder.*`, `ReadModel_Builder.*`, etc. — component builders
- `AggregateRuntime_Builder.T`, `EventCollectorRuntime_Builder.T` — internal adapter types

---

## Goal

Split component definitions so that:
- **reventless-spec** — all types and module types needed by application developers (the public contract)
- **reventless** — implementation details only (builders, callbacks, internal types)

This guide uses `StateViewSlice` as the reference example. Apply the same pattern to other components.

---

## When to Split a Component

Move a module type to reventless-spec when application developers need to:
- Implement it themselves (e.g., define a `Spec` module for a component)
- Reference it in their Plugin/DcbSpec definitions

Keep in reventless when types reference:
- Internal reventless types (`Component.t`, `EventCollector`, `QueryDb.outputs`, etc.)
- Pulumi infrastructure types in functor signatures
- Runtime implementation types

---

## Naming Convention (Historical — Pre Phase 1)

> **Note:** This naming convention was used before Phase 1. The current convention consolidates
> spec and output types into a single file per component (no `_Spec` suffix). See "Current State"
> above for the current naming convention.

| reventless-spec file | Module type name | Full access path |
|---|---|---|
| `src/components/Foo_Spec.res` | `module type T = {...}` | `ReventlessSpec.Foo_Spec.T` |

Use `T` for the module type name — consistent with `ReadModel_Spec.T` pattern.

The `_Spec` suffix in the filename makes the spec file recognizable without nesting into another module.

---

## Step-by-Step Split Pattern

### Step 1 — Identify dependencies

Check what `module type Spec` in reventless references:
- Types from reventless-spec → fine (already there)
- Simple module types from other reventless components → those need to move too (prerequisites)
- Internal reventless types → those cannot move (keep `module type T` in reventless)

### Step 2 — Move prerequisites first

If `ComponentA.Spec` depends on `ComponentB.Spec`, move `ComponentB` first.

Example: `StateViewSlice_Spec.T` required `DcbEventLog.Spec` → create `DcbEventLog_Spec.T` first.

### Step 3 — Create the `_Spec.res` file in reventless-spec

```rescript
// packages/reventless-spec/src/components/Foo_Spec.res

module type T = {
  let name: string
  // ... other developer-facing fields
}
```

### Step 4 — Remove the inline `module type Spec` from reventless; reference ReventlessSpec directly in `module type T`

```rescript
// packages/reventless/src/components/Foo/Foo.res

// Before:
module type Spec = {
  let name: string
  // ...
}

module type T = {
  module Spec: Spec
  // ...
}

// After (no alias, direct reference):
module type T = {
  module Spec: ReventlessSpec.Foo_Spec.T
  // ...
}
```

### Step 5 — Update Builder, Callback, and any other files that referenced `Foo.Spec`

All files that constrain a functor argument or module type using `Foo.Spec` must be updated to reference `ReventlessSpec.Foo_Spec.T` directly:

```rescript
// Before:
module Make = (Spec: Foo.Spec): (...) => { ... }

// After:
module Make = (Spec: ReventlessSpec.Foo_Spec.T): (...) => { ... }
```

---

## On `.resi` Files

A `.resi` file defines the public interface of a `.res` file within the same package. It:
- **Cannot** move types to a different package (wrong tool for cross-package split)
- **Can** hide internal types (`type t`, `componentType`, etc.) from reventless module surfaces

Use `.resi` optionally in reventless to hide implementation noise after the spec split, but it is not required for the split itself.

---

## Reference: StateViewSlice Split

**Files created in reventless-spec:**
- `packages/reventless-spec/src/components/DcbEventLog_Spec.res` — `module type T = { @schema type event }`
- `packages/reventless-spec/src/components/StateViewSlice_Spec.res` — `module type T = { name, DcbEventLogSpec, event, state, project }`

**Files modified in reventless** (inline `module type Spec` removed; `module type T` and all consumers updated to reference ReventlessSpec directly):
- `packages/reventless/src/components/DcbEventLog/DcbEventLog.res` — `module type T` uses `module Spec: ReventlessSpec.DcbEventLog_Spec.T`
- `packages/reventless/src/components/DcbEventLog/DcbEventLog_Builder.res` — functor arg `Spec: ReventlessSpec.DcbEventLog_Spec.T`
- `packages/reventless/src/components/DcbEventLog/DcbEventLog_Operations.res` — all `Spec` constraints → `ReventlessSpec.DcbEventLog_Spec.T`
- `packages/reventless/src/components/StateViewSlice/StateViewSlice.res` — `module type T` uses `module Spec: ReventlessSpec.StateViewSlice_Spec.T`
- `packages/reventless/src/components/StateViewSlice/StateViewSlice_Builder.res` — functor arg `Spec: ReventlessSpec.StateViewSlice_Spec.T`
- `packages/reventless/src/components/StateViewSlice/StateViewSlice_Callback.res` — all `Spec` constraints → `ReventlessSpec.StateViewSlice_Spec.T`
- `packages/reventless/src/components/StateChangeSlice/StateChangeSlice.res` — `DcbEventLogSpec: ReventlessSpec.DcbEventLog_Spec.T`

---

## Verification Checklist

1. `cd packages/reventless-spec && npm run build` — spec package compiles
2. `cd packages/reventless && npm run build` — reventless compiles with aliases
3. `cd packages/reventless && npm test` — tests pass
4. Confirm new module type accessible: `ReventlessSpec.Foo_Spec.T`
5. Confirm no remaining `Foo.Spec` references in reventless (alias removed)

---

## Components Eligible for Split (Candidates)

Apply this pattern to other components that have developer-facing `module type Spec`:

| Component | Current location | Status |
|---|---|---|
| `DcbEventLog.Spec` | `DcbEventLog.res` | Prerequisite for StateViewSlice |
| `StateViewSlice.Spec` | `StateViewSlice.res` | Reference implementation |
| `StateChangeSlice.Spec` | `StateChangeSlice.res` | Candidate |
| `ReadModel_Spec.T` | already in reventless-spec | Done |
| `Aggregate.Spec` | `reventless-spec/components/Aggregate.res` | Already there |
| `EventLog.Spec` | `EventLog.res` | Candidate |
| `ExtensionPoint.Spec` | `reventless-spec/components/ExtensionPoint.res` | Already there |

---

# Extended Analysis: What Goes Where

## Current State Summary

### Already in reventless-spec (Public API - Developer-facing)

**Root level types:**
- `Message.res` — schema types for meta, context, event', command', commandJson
- `Id.res` — module type `T` and `String` implementation
- `Schedule.res` — schedule types and operations
- `QueryEngine.res` — query/scan types and operations
- `Projection_Spec.res` — Source/Target module types and action types
- `Projection.res` — Mapping module types
- `ResourceNaming.res` — resource naming operations
- `SideEffect.res` — side effect types
- `EventMapping.res` — event mapping types

**Adapter:**
- `Adapter.res` — resource type definition

**Components:**
- `Aggregate.res` — `module type Spec` (Id, name, command, event, error)
- `Counter.res` — counterId, reference, counterTarget types
- `ExtensionPoint.res` — `module type Spec` (name, command, event, callCommand)
- `Plugin.res` — pluginDefinition schema types
- `QueryDb.res` — storageError variant types
- `ReadModel/ReadModel_Spec.res` — `module type T`
- `DcbEventLog_Spec.res` — `module type T`
- `StateViewSlice_Spec.res` — `module type T`
- `PluginExtensionPointSpec.res` — Core.Plugin extension point types

**Mapping (in root):**
- `ExtensionMapping.res` — Spec/Impl module types, action types
- `ExtensionPointMapping.res` — Spec/Impl module types, action types

### Currently in reventless (Implementation - Internal)

**Root level:**
- `Message.res` — full Message module with encode/decode functions, handlers, uuid generation
- `ExtensionMapping.res` — full functor implementation with message encoding/decoding
- `ExtensionPointMapping.res` — full functor implementation
- `Projection.res` — full projection logic with action handling
- `Mapper.res`, `Mapper1toN.res`, `MapperNto1.res` — mapping implementations
- `Component.res`, `ComponentType.res` — component framework
- `Config.res`, `Env.res` — configuration

**Components:** All component implementations with Builder, Callback, Operations files

**Core:** Core framework implementation

---

# Recommendations for Improvements

## 1. Move Additional Component Specs to reventless-spec

### EventLog.Spec
**Current:** Inline in `EventLog.res` in reventless
**Should move:** `module type Spec` with event type definition
**Reason:** Application developers need to define event types for event logs

### StateChangeSlice.Spec
**Current:** Inline in `StateChangeSlice.res` in reventless
**Should move:** `module type T` similar to StateViewSlice
**Reason:** Part of the DCB pattern, developers need to define state change slices

### EventMapper.Spec
**Current:** Inline in `EventMapper.res` in reventless
**Should move:** `module type Spec` with event mapping definitions
**Reason:** Developers define how events map to commands

### CommandGenerator.Spec
**Current:** Inline in `CommandGenerator.res` in reventless
**Should move:** `module type Spec` 
**Reason:** Developers define command generation logic

### CommandTopic.Spec
**Current:** Inline in `CommandTopic.res` in reventless
**Should move:** `module type Spec`
**Reason:** Part of component definition

### ReadModel.Spec
**Current:** Already in reventless-spec as `ReadModel_Spec.T`
**Status:** ✅ Done

---

## 2. Consider Splitting Root-Level Modules

### Current: Message.res
**reventless-spec portion:**
- Schema types: `service`, `meta`, `context`, `event'`, `command'`, `commandJson`, `statusChange`
- `invalidEvent` function

**reventless portion:**
- Full encode/decode functions
- `uuid()`, `now()`, `nowAsISOString()` functions
- Message handlers types and implementations
- Meta generation functions

**Recommendation:** Keep as-is (well split already)

### Current: Projection.res
**reventless-spec portion:**
- `Projection_Spec.res` with Source/Target module types
- Action types

**reventless portion:**
- Full projection logic, action handling, optimization

**Recommendation:** Keep as-is (well split already)

---

## 3. Move More Framework Primitives to reventless-spec

### Add: Core Component Types
```rescript
// packages/reventless-spec/src/Component.res
module type T = {
  type t
  type outputs
  type operations
  type component<'ops> = ...
}
```

This would allow developers to reference components generically.

### Add: Handler Types
```rescript
// packages/reventless-spec/src/Handler.res
type commandHandler<'id, 'command> = ...
type eventsHandler<'id, 'event> = ...
type errorHandler<'error, 'command, 'event> = ...
```

Currently these are in reventless's Message.res but could be in spec.

---

## 4. Consider Moving Core Plugin/Extension Types

### Current Structure Issue
The core plugin extension point types are in `reventless-spec/src/core/plugin/PluginExtensionPointSpec.res`, but the actual implementations are split across:
- `packages/reventless/src/core/ExtensionPoints/Plugin/`
- `packages/reventless/src/core/Aggregates/Plugin/`
- `packages/reventless/src/core/ReadModels/Plugin/`

### Recommendation
Ensure all "Spec" module types for core framework extensions are in reventless-spec so developers can:
1. Define custom plugin extension points
2. Define custom aggregate plugins
3. Define custom read model plugins

---

## 5. Mapping Module Improvements

### Current Issue
`ExtensionMapping.res` and `ExtensionPointMapping.res` have both:
- Action types in reventless-spec (good - developers reference these)
- Spec/Impl module types in reventless-spec (good)
- Functor implementations in reventless (correct)

However, there's duplication - the action types appear in both spec AND implementation files.

### Recommendation
Clean up imports so implementations in reventless properly import from reventless-spec rather than defining local duplicates.

---

## 6. Add Missing Spec Dependencies

### QueryDb Operations
Currently `QueryEngine.operations` is in reventless-spec, but the actual `QueryDb.operations` (save, load, delete, etc.) is in reventless.

**Consider:** Moving more of QueryDb operations interface to reventless-spec so developers can:
- Understand what's available for read models
- Create custom components that query the database

### EventCollector Operations
Similar situation - the operations interface could be more visible in spec.

---

## 7. Consider a Clearer Separation: "Application Developer" vs "Framework Contributor" Views

### Application Developer (uses reventless-spec)
- Defines component specs (Aggregate, ReadModel, ExtensionPoint, etc.)
- Defines mappings between components
- Defines projections
- Uses builders to instantiate components
- Does NOT see: Pulumi infrastructure, internal runtime types, adapter implementations

### Framework Contributor (uses reventless)
- Implements component builders
- Creates infrastructure adapters (SNS, SQS, DynamoDB)
- Works with runtime execution models
- Works with Pulumi resource types

### Implementation
Currently both packages expose too much "framework internals" to application developers. Consider:
1. Hiding more reventless modules behind `.resi` files with limited exports
2. Creating a simplified "App" module that re-exports only what developers need
3. Documenting which modules are "public API" vs "internal"

---

## 8. Infrastructure Directory

**Current:** `packages/reventless/src/infrastructure/` is mostly empty (just a TODO)

**Recommendation:** This could be used for:
- AWS-specific infrastructure helpers that don't belong in core framework
- Pulumi utility functions for common patterns
- OR remove this directory if not needed

---

## Priority Order for Implementation

### Phase 1: Complete Current Pattern (High Priority)

All component specs that need to be moved from `reventless` to `reventless-spec`:

| # | Component | Current Location | Spec Definition | Move to | Status |
|---|-----------|-----------------|-----------------|---------|--------|
| 1 | DcbEventLog | `DcbEventLog.res` | `module type Spec` | `DcbEventLog_Spec.T` | ✅ Done |
| 2 | StateViewSlice | `StateViewSlice.res` | `module type Spec` | `StateViewSlice_Spec.T` | ✅ Done |
| 3 | StateChangeSlice | `StateChangeSlice.res` | `module type Spec` | `StateChangeSlice_Spec.T` | ✅ Done (Phase 1) |
| 4 | EventLog | `EventLog.res` | `module type Spec` | `EventLog_Spec.T` | ✅ Done (Phase 1) |
| 5 | EventTopic | `EventTopic.res` | `module type Spec` | `EventTopic_Spec.T` | ✅ Done (Phase 1) |
| 6 | CommandTopic | `CommandTopic.res` | `module type Spec` | `CommandTopic_Spec.T` | ✅ Done (Phase 1) |
| 7 | StateTopic | `StateTopic.res` | `module type Spec` | `StateTopic_Spec.T` | ✅ Done (Phase 1) |
| 8 | Task | `Task.res` | `module type Spec` | `Task_Spec.T` | ✅ Done (Phase 1, simplified) |
| 9 | Counter | `Counter.res` | No Spec | `Counter_Spec.T` (if needed) | Not started |
| 10 | Heartbeat | `Heartbeat.res` | No Spec | N/A (builder-only) | Not started |
| 11 | Scheduler | `Scheduler.res` | No Spec | N/A (builder-only) | Not started |
| 12 | EventCollector | `EventCollector.res` | No Spec | N/A (runtime) | Not started |
| 13 | EventMapper | `EventMapper.res` | Uses ExtensionMapping | N/A (uses existing spec) | Not started |
| 14 | Extension | `Extension.res` | No Spec | N/A (uses ExtensionMapping) | Not started |
| 15 | Plugin.DcbSpec | `Plugin.res` | `module type DcbSpec` | `Plugin_DcbSpec.T` | Deferred (depends on component T types) |

#### Phase 1 Completed Items:

**1. DcbEventLog_Spec.T** ✅ DONE
- Already in reventless-spec: `components/DcbEventLog_Spec.res`
- Status: Complete

**2. StateViewSlice_Spec.T** ✅ DONE
- Already in reventless-spec: `components/StateViewSlice_Spec.res`
- Status: Complete

**3. StateChangeSlice_Spec.T** ✅ DONE
- Created: `packages/reventless-spec/src/components/StateChangeSlice_Spec.res`
- Updated reventless files to use `ReventlessSpec.StateChangeSlice_Spec.T`
- Status: Complete

**4. EventLog_Spec.T** ✅ DONE
- Created: `packages/reventless-spec/src/components/EventLog_Spec.res`
- Updated reventless files to use `ReventlessSpec.EventLog_Spec.T`
- Status: Complete

**5. EventTopic_Spec.T** ✅ DONE
- Created: `packages/reventless-spec/src/components/EventTopic_Spec.res`
- Updated reventless files to use `ReventlessSpec.EventTopic_Spec.T`
- Status: Complete

**6. CommandTopic_Spec.T** ✅ DONE
- Created: `packages/reventless-spec/src/components/CommandTopic_Spec.res`
- Updated reventless files to use `ReventlessSpec.CommandTopic_Spec.T`
- Status: Complete

**7. StateTopic_Spec.T** ✅ DONE
- Created: `packages/reventless-spec/src/components/StateTopic_Spec.res`
- Updated reventless files to use `ReventlessSpec.StateTopic_Spec.T`
- Status: Complete

**8. Task_Spec.T** ✅ DONE (simplified)
- Created: `packages/reventless-spec/src/components/Task_Spec.res`
- Note: Original `setup` type references Pulumi types, so only `name` field moved to spec
- Status: Complete (simplified version)

---

#### Verification (Phase 1):

- ✅ `cd packages/reventless-spec && npm run build` — compiles successfully
- ✅ `cd packages/reventless && npm run build` — compiles with 162 modules
- ✅ `cd packages/reventless && npm test` — 103 tests passed

---

#### Deferred Items:

**Plugin.DcbSpec** - Deferred
- Depends on component T types (StateChangeSlice.T, StateViewSlice.T) which are still in reventless
- Requires moving those component types first before this can be implemented**
  ```rescript
  module type Spec = {
    module Id: ReventlessSpec.Id.T
    let name: string
    @schema type event
  }
  ```
- **Dependencies:** Id.T (already in reventless-spec)
- **Move to:** `packages/reventless-spec/src/components/EventLog_Spec.res`
- **New module name:** `module type T`

**5. EventTopic_Spec.T**
- **Source:** `packages/reventless/src/components/EventTopic/EventTopic.res`
- **Spec definition:**
  ```rescript
  module type Spec = {
    module Id: ReventlessSpec.Id.T
    @schema type event
  }
  ```
- **Dependencies:** Id.T
- **Move to:** `packages/reventless-spec/src/components/EventTopic_Spec.res`

**6. CommandTopic_Spec.T**
- **Source:** `packages/reventless/src/components/CommandTopic/CommandTopic.res`
- **Spec definition:**
  ```rescript
  module type Spec = {
    module Id: ReventlessSpec.Id.T
    @schema type command
  }
  ```
- **Dependencies:** Id.T
- **Move to:** `packages/reventless-spec/src/components/CommandTopic_Spec.res`

**7. StateTopic_Spec.T**
- **Source:** `packages/reventless/src/components/StateTopic.res`
- **Spec definition:**
  ```rescript
  module type Spec = {
    module Id: ReventlessSpec.Id.T
    let name: string
    @schema type state
  }
  ```
- **Dependencies:** Id.T
- **Move to:** `packages/reventless-spec/src/components/StateTopic_Spec.res`

**8. Task_Spec.T**
- **Source:** `packages/reventless/src/components/Task/Task.res`
- **Spec definition:**
  ```rescript
  module type Spec = {
    let name: string
    let setup: setup  // setup type needs to be evaluated
  }
  ```
- **Dependencies:** QueryEngine.operations (in spec)
- **Move to:** `packages/reventless-spec/src/components/Task_Spec.res`
- **Note:** The `setup` type references QueryEngine.operations - ensure that stays accessible

**9. Plugin_DcbSpec.T**
- **Source:** `packages/reventless/src/components/Plugin/Plugin.res`
- **Spec definition:**
  ```rescript
  module type DcbSpec = {
    @schema type event
    let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
    let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
  }
  ```
- **Dependencies:** StateChangeSlice_Spec.T, StateViewSlice_Spec.T (both done)
- **Move to:** `packages/reventless-spec/src/components/Plugin_DcbSpec.res`
- **Note:** Must be moved AFTER StateChangeSlice_Spec is complete

### Phase 1 Files to Create:

1. `packages/reventless-spec/src/components/StateChangeSlice_Spec.res`
2. `packages/reventless-spec/src/components/EventLog_Spec.res`
3. `packages/reventless-spec/src/components/EventTopic_Spec.res`
4. `packages/reventless-spec/src/components/CommandTopic_Spec.res`
5. `packages/reventless-spec/src/components/StateTopic_Spec.res`
6. `packages/reventless-spec/src/components/Task_Spec.res`
7. `packages/reventless-spec/src/components/Plugin_DcbSpec.res`

### Phase 1 Files to Update in reventless:

All component files that reference the moved specs must be updated to use `ReventlessSpec.Foo_Spec.T` instead of local `Spec` definitions.

### Phase 2: Framework Primitives (Medium Priority)
1. Move handler types to spec ✅ DONE
   - Created: `packages/reventless-spec/src/Handler.res`
   - Contains: `handler`, `commandHandler`, `commandsHandler`, `eventsHandler`, `errorHandler` types
   - Accessible via: `ReventlessSpec.Handler.T` (module type) or individual type aliases
2. Ensure all core plugin spec types are accessible ✅ DONE
   - Plugin types already in reventless-spec: `Plugin.res`, `PluginExtensionPointSpec.res`
3. Move `Behavior.T` to reventless-spec ✅ DONE
   - Created: `packages/reventless-spec/src/Behavior.res`
   - Contains `resolverConfig` type and `module type T` for aggregate business logic
   - All type dependencies (`Message.context`, `Handler.errorHandler`, `S.t`) are spec-level
   - Structurally compatible with `Reventless.Behavior.T` (identical underlying types)
4. Create `Platform.T` in reventless ✅ DONE (see Corrected Option B below)
5. Document the public API surface - Pending

#### Deferred Items:
- **Plugin.DcbSpec** - Deferred
  - Requires simplified T types for StateChangeSlice.T and StateViewSlice.T
  - These component T types have internal reventless dependencies (DcbEventLog.component, etc.)
  - Cannot move until simplified T types are created in reventless-spec

### Phase 3: Cleanup (Lower Priority)
1. Clean up duplicate type definitions between spec and impl
2. Add .resi files to hide internal types
3. Create simplified app-level exports

#### Phase 3 Status: Investigated
- **Handler types** exist in both `reventless-spec/src/Handler.res` and `reventless/src/Message.res`
  - Kept current structure - Handler.res serves as API reference, Message.res has implementation types
  - Module resolution complexity prevents simple consolidation
- **.resi files**: Found existing examples (Component.resi). Adding more is a larger refactoring task, deferred.
- **App-level exports**: Would require more design work, deferred.
- **Verification**: ✅ All builds pass, 103 tests pass

---

## Summary Table: Recommended Moves

| From (reventless) | To (reventless-spec) | Rationale |
|---|---|---|
| `EventLog.res` (Spec) | `components/EventLog_Spec.res` | Developer-defined events |
| `StateChangeSlice.res` (Spec) | `components/StateChangeSlice_Spec.res` | DCB pattern |
| `EventMapper.res` (Spec) | `components/EventMapper_Spec.res` | Developer defines mapping |
| `CommandGenerator.res` (Spec) | `components/CommandGenerator_Spec.res` | Command generation |
| `CommandTopic.res` (Spec) | `components/CommandTopic_Spec.res` | Topic definitions |
| Handler types from Message.res | `Handler.res` | Common interface types |

---

## Files to Review for Future Splits

Run this to find remaining inline specs:
```bash
grep -r "module type Spec" packages/reventless/src/components/*/
```

Each found should be evaluated for moving to reventless-spec following this guide's pattern.

---

# Application Dependencies and the Platform Coupling Problem

## The Question

Applications use component builders from `reventless` or `reventless-aws` to create components. This means they have direct dependencies on implementation packages. Does this make the spec/impl split pointless?

**No — but the split's value needs to be understood correctly, and there are concrete improvements available.**

---

## What the Split Already Achieves

Domain code — `Spec`, `Behavior`, `EventMappings` — only imports from `reventless-spec`. These modules:
- Compile and test without AWS SDK, DynamoDB, Lambda, or any infrastructure
- Are portable to alternative platform implementations
- Version independently from the implementation

The split is working. The remaining coupling is in the **wiring/assembly code** — the code that calls builders to compose components. This is known as the **Composition Root** and it is *legitimately* coupled to the platform. That's its job.

---

## Current Layering (Observed)

```
reventless-spec   — types and module types (public contract, no infra)
     ↑
reventless        — generic builders, framework logic (depends on Pulumi types)
     ↑
reventless-aws    — pre-configured builders (DynamoDB, SQS, SNS, Lambda pre-wired)
     ↑
application       — domain code + ONE wiring file that calls builders
```

`reventless-aws` already dramatically reduces the coupling surface. `Aggregate_Builder_Micro.Make` takes only `(Config, Spec, Behavior, EventMappings)` — the four things the application defines. All AWS adapter wiring (DynamoDB, SQS_FIFO, DynamoDB streams, Lambda runtime) is internal to `reventless-aws`.

---

## Options for Reducing Application Coupling

### Option A — Composition Root Convention (zero code changes) ★ Recommended now

Establish and enforce the rule: **only the Composition Root file may import from `reventless-aws`**.

```
app/
├── domain/
│   ├── MySpec.res        ← imports reventless-spec only
│   ├── MyBehavior.res    ← imports reventless-spec only
│   └── MyMappings.res    ← imports reventless-spec only
└── index.res             ← Composition Root: imports reventless-aws here
```

`index.res` is the Pulumi stack entry point. It is *allowed* to know about the platform. All domain and business logic is isolated.

This requires no code changes. It is the minimum viable answer and is already achievable with the current design.

### Option B — Platform Module Type in reventless-spec (recommended next step)

Add an abstract `Platform.T` module type to `reventless-spec` that captures the factory surface applications need. Applications can then write their plugin assembly as a functor over the platform rather than importing a concrete platform package.

```rescript
// reventless-spec/src/Platform.res
module type T = {
  module Aggregate: {
    module Make: (
      Spec: Aggregate.Spec,
      Behavior: Behavior.T,
      Mappings: EventMapper.Mappings,
    ) => Aggregate.T
  }
  module ReadModel: {
    module Make: (
      Spec: ReadModel_Spec.T,
      Mappings: Projection.Mappings,
    ) => ReadModel.T
  }
  // Plugin, Task, etc.
}
```

Application plugin assembly becomes a functor over the platform:

```rescript
// app/MyPlugin.res — only imports reventless-spec
module Make = (Platform: ReventlessSpec.Platform.T) => {
  module MyAggregate = Platform.Aggregate.Make(MySpec, MyBehavior, MyMappings)
  module MyReadModel = Platform.ReadModel.Make(MyRmSpec, MyMappings)
  // ...
}

// index.res — only place that imports reventless-aws
module App = MyPlugin.Make(ReventlessAws.Platform)
```

`reventless-aws` would expose a concrete `Platform` module satisfying `Platform.T` — the pre-configured AWS builders already exist; they just need to be assembled under a common namespace.

**Benefits:**
- `MyPlugin.res` and all domain files only depend on `reventless-spec`
- The concrete platform (`ReventlessAws.Platform`) is injected at one point
- `MyPlugin.res` is portable and unit-testable with a mock platform

**What `reventless-aws` needs to add:**
```rescript
// reventless-aws/src/Platform.res
module Aggregate = {
  module Make = Aggregate_Builder.Make  // already exists
}
module ReadModel = {
  module Make = ReadModel_Builder.Make  // already exists
}
// ... etc.
```

This is an additive, non-breaking change.

### Option C — `reventless-aws-app` Package (more invasive)

Create a fifth package that wraps `reventless-aws` with a higher-level API and hides all builder details. Applications depend only on `reventless-spec` and `reventless-aws-app`.

```
reventless-spec → reventless-aws-app (simple assembly API)
                  └── reventless-aws (hidden)
                      └── reventless
                          └── reventless-spec
```

This is the most radical cut. Only warranted if Option B proves insufficient or if the goal is to provide a zero-boilerplate getting-started experience.

---

## Recommendation Summary

| Goal | Approach | Status |
|---|---|---|
| Isolate domain code from infrastructure now | Option A (Convention) — no code changes needed | ✅ Done |
| Make plugin assembly platform-portable | Option B (Platform.T in reventless — see deep dive below) | ✅ Done |
| Zero framework API surface for application developers | Option C (new package) | Not started |

**Option A** — The spec/impl split already achieves domain isolation. Document the Composition Root convention and enforce it via code review.

**Option B** — Implemented as `Reventless.Platform.T` (not `reventless-spec` — see deep dive below for the type-system constraints that prevent this). `ReventlessAws.Platform.Make(Config)` provides the concrete AWS implementation. Application plugin assembly code can now be written as a functor over `Reventless.Platform.T` without importing `reventless-aws`.

---

## Option B Deep Dive: Why Platform.T Cannot Live in reventless-spec

The Option B description above uses simplified pseudocode. After a detailed investigation of the actual type signatures, putting `Platform.T` in `reventless-spec` is **not feasible** without significantly restructuring the component type system. This section explains the specific blockers.

### The Three Type Categories in Platform.T

A `Platform.T.Aggregate.Make` functor has three parts:

```
module Make: (Input modules...) => Output module type
```

Each category has different constraints on where it can live.

---

### Category 1: Input Module Types — Partially Moveable

**`Aggregate.Spec`** — Already in `reventless-spec`. ✅

**`Behavior.T`** — Currently in `reventless/src/Behavior.res`. This type only references:
- `S.t<'command>` — sury schema, globally available
- `Message.context` — in `reventless-spec/src/Message.res`
- `Message.errorHandler` — defined in `reventless/src/Message.res` as `('error, 'command, ReventlessSpec.Message.context) => array<'event>`, itself only using spec types

`Behavior.T` **can be moved to `reventless-spec`**. All its type dependencies are spec-level.

**`EventMapper.Mappings`** — Currently in `reventless/src/components/EventMapper/EventMapper.res`:
```rescript
module type Mappings = {
  module Target: ReventlessSpec.EventMapping.Target
  module type Mapping = ReventlessSpec.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>   // ← BLOCKER
}
```

`Counter.T` is in `reventless` and has:
```rescript
module type T = {
  let make: (
    ~name: string,
    ~counterEventsHandler: counterEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,   // ← Pulumi type
  ) => component
}
```

`Pulumi.ComponentResource.options` cannot be in `reventless-spec`. A **simplified** `EventMapper_Spec.Mappings` without the `counter` field could be defined in spec, but it would be a different type from `EventMapper.Mappings` — see the compatibility problem below.

**`ExtensionPoint.Mappings`** — References `ExtensionPointMapping.T` (in reventless-spec ✅) but also cannot easily change signatures due to `counter` references in mapping logic.

---

### Category 2: Output Module Types — Cannot Move

The return type of each `Make` functor is the critical blocker.

**`Aggregate.T`** (in `reventless`):
```rescript
module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec
  module AggregateRuntimeBuilder: AggregateRuntime_Builder.T   // ← internal reventless type
  let make: (~opts: Pulumi.ComponentResource.options=?) => component  // ← Pulumi type
}
```

**`ReadModel.T`** (in `reventless`):
```rescript
module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T
  module EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T  // ← internal
  let make: (~allEventTopics: ..., ~opts: ...) => component
}
```

**`Plugin.T.make`** (in `reventless`):
```rescript
let make: (
  ~scheduler: Pulumi.Output.t<Scheduler.operations>,  // ← Pulumi type
  ~opts: Pulumi.ComponentResource.options=?,          // ← Pulumi type
  ...
) => component
```

These output types contain `Pulumi.*` types, internal adapter module types, and component infrastructure types — none of which can live in `reventless-spec` without pulling in the entire infrastructure dependency.

---

### Category 3: The Abstract Output Type Dead End

One might propose defining a **minimal abstract output type** in reventless-spec:

```rescript
// reventless-spec/src/Platform.res
module type AggregateOutput = {
  module Spec: Aggregate.Spec
  // minimal — no Pulumi, no internals
}

module type T = {
  module Aggregate: {
    module Make: (...) => AggregateOutput
  }
  module Plugin: {
    let make: (~aggregates: array<module(AggregateOutput)>=?, ...) => unit
  }
}
```

This fails at the concrete implementation boundary. The concrete `Plugin.make` internally calls `Reventless.Plugin_Builder.make(~aggregates: array<module(Aggregate.T)>)`. But the application passed `array<module(AggregateOutput)>` (weaker type). `AggregateOutput` is a structural subtype of `Aggregate.T` — a module satisfying `Aggregate.T` also satisfies `AggregateOutput`, but **not vice versa**. The concrete plugin builder cannot safely use `array<module(AggregateOutput)>` where `array<module(Aggregate.T)>` is required.

Even with OCaml's abstract module types inside module type signatures (`module type AggregateT` inside `module type T`), the same problem applies: the concrete platform reveals `AggregateT = Reventless.Aggregate.T`, but the abstract view from `reventless-spec` loses this information, breaking the Plugin boundary.

---

### The Config Problem

`Aggregate_Builder_Micro.Make` and `ReadModel_Builder_Single.Make` take `Config: Config.T` as their first argument:

```rescript
// reventless-aws/src/components/Aggregate_Builder_Micro.res
module Make = (
  Config: Config.T,                         // ← AWS Config with Pulumi types
  Spec: ReventlessSpec.Aggregate.Spec,
  Behavior: Reventless.Behavior.T with module Spec := Spec,
  EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
): Reventless.Aggregate.T
```

`Config.T` in `reventless-aws` is:
```rescript
module type T = Reventless.Config.T
  with type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
  and type role = Pulumi.Output.t<PulumiAws.IAM.Role.t>
```

For `Platform.T.Aggregate.Make` to not include Config (so app code stays clean), Config must be **pre-applied** at the point the Platform is created. This means the concrete Platform itself is a **functor over Config**:

```rescript
// reventless-aws/src/Platform.res
module Make = (Config: Config.T): Reventless.Platform.T => { ... }
```

Application code would then do:
```rescript
// index.res (Composition Root — imports reventless-aws)
module Platform = ReventlessAws.Platform.Make(Config)
module App = MyPlugin.Make(Platform)
```

This design is clean, but it requires `Reventless.Platform.T` (not `ReventlessSpec.Platform.T`) because all the component output types are in `reventless`.

---

### Summary: What Can and Cannot Move to reventless-spec

> **Note:** This table reflects the state before Phase 1. After Phases 1–4, all items marked
> "❌ No" except `Config.T` have been moved to reventless-spec via the accessor function pattern
> (see Phase 4 results in platform-to-reventless-spec.md).

| Type | Can move? | Reason |
|---|---|---|
| `Behavior.T` | ✅ Yes | Only uses `Message.context`, `Handler.errorHandler`, `S.t` — all spec-compatible |
| `EventMapper.Mappings` | ✅ Yes — **done in Phase 2** | Moved to `ReventlessSpec.EventMapper.Mappings` |
| `Aggregate.T` (output) | ✅ Yes — **done in Phase 2** | Added via accessor function pattern; `AggregateRuntimeBuilder` stays in reventless |
| `ReadModel.T` (output) | ✅ Yes — **done in Phase 2** | Same pattern |
| `Plugin.T.make` + `DcbSpec` | ✅ Yes — **done in Phase 2** | Now in `ReventlessSpec.Plugin` |
| `Counter.T` | ✅ Yes — **done in Phase 2** | Now in `ReventlessSpec.Counter.T` |
| `Platform.T` | ✅ Yes — **done in Phase 3** | Now in `ReventlessSpec.Platform.T` |
| `Config.T` | ❌ No | AWS Pulumi resource types; stays in reventless-aws |

---

### Corrected Option B: Platform.T in `reventless-spec` (Final State)

After completing Phases 1–4 of the platform-to-reventless-spec plan, `Platform.T` now lives in
`reventless-spec` (not `reventless`). The original analysis that said this was impossible was
resolved by the **accessor function pattern** (Phase 4) which provides `outputs`, `operations`,
and `finish` functions on each spec-level T type, allowing `Plugin_Helpers.res` to work without
needing `AggregateRuntimeBuilder` directly.

```
Platform.T lives in reventless-spec
ReventlessAws.Platform.Make(Config) satisfies ReventlessSpec.Platform.T
```

The full dependency model:

```
app/MySpec.res        ← imports reventless-spec only
app/MyBehavior.res    ← imports reventless-spec only
app/MyMappings.res    ← imports reventless-spec only
app/MyProjection.res  ← imports reventless (for Projection.Mapping.Make)
app/MyPlugin.res      ← imports reventless-spec only (Platform.T is there)
index.res             ← Composition Root: imports reventless-aws, creates Platform.Make(Config)
```

### Implementation Status: ✅ DONE (Phases 1–4 of platform-to-reventless-spec)

**In `reventless-spec`:**
- `packages/reventless-spec/src/Behavior.res` ✅ — `resolverConfig` type and `module type T`
- `packages/reventless-spec/src/Platform.res` ✅ — `module type T` with builders for all component types
- `packages/reventless-spec/src/components/*.res` ✅ — all component output types + module type T

**In `reventless-aws`:**
- `packages/reventless-aws/src/Platform.res` ✅ — `module Make(ApiValues: {...}): ReventlessSpec.Platform.T`

**Verification:**
- ✅ Full monorepo build: 442 modules, 0 errors
- ✅ All tests pass
