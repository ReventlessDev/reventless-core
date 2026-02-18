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
