# Package Split Guide: reventless-spec vs reventless

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

## Naming Convention

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
1. Move handler types to spec
2. Ensure all core plugin spec types are accessible
3. Document the public API surface

### Phase 3: Cleanup (Lower Priority)
1. Clean up duplicate type definitions between spec and impl
2. Add .resi files to hide internal types
3. Create simplified app-level exports

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
