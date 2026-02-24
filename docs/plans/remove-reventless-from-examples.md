# Plan: Remove `reventless` Dependency from Examples

**Status: COMPLETED** ✓

## Goal

Make all 4 example packages (`example-aggregate-catalog`, `example-aggregate-ordering`, `example-dcb-catalog`, `example-dcb-ordering`) depend only on `@reventlessdev/reventless-spec` and `@reventlessdev/reventless-in-memory`, eliminating the direct `@reventlessdev/reventless` dependency (which pulls in Pulumi, AWS SDKs, SSH2, and other heavy infrastructure).

## Steps Taken

### Step 1: Add `encode`/`decode` to `reventless-spec/src/Message.res` ✓

Added pure serialization functions to spec so examples don't need `Reventless.Message.encode`:

```rescript
let decode = (json, schema: S.t<'a>) => json->S.parseJsonOrThrow(schema)
let encode = (value, schema: S.t<'a>) => value->S.reverseConvertToJsonOrThrow(schema)
exception InvalidEvent(JSON.t)
```

Removed the now-duplicate declarations from `reventless/src/Message.res` (they come via `include ReventlessSpec.Message`).

### Step 2: Add `Mapping.Make` / `Mappings.Make` to `reventless-spec/src/Projection.res` ✓

Moved the two pure functors from `reventless/src/Projection.res` into spec. The `reventless` version now re-exports them (kept `MakeGenericSource` which uses reventless-specific types).

### Step 3: Delete `DcbTag.res` re-export in reventless ✓

`reventless/src/components/DcbEventLog/DcbTag.res` contained only `include ReventlessSpec.DcbTag` — deleted it. Updated all internal usages:
- `CommandTopic_Helpers.res`, `DcbEventLog_Adapter.res`, `DcbEventLog_Operations.res`, `DcbEventLog_Builder.res`, `StateChangeSlice_Callback.res`
- Tests: `DcbFixtures.res`, `DcbTagTest.res`, `DcbEventLogOperationsTest.res`, `DcbStateChangeSliceTest.res`
- `reventless-in-memory/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res`
- `PluginProjection.res` (changed to `ReventlessSpec.Projection.Mapping.Make` and `Mappings.Make`)

All `DcbTag.` → `ReventlessSpec.DcbTag.`.

### Step 4: Add test helper modules to `reventless-in-memory/src/` ✓

Created new files:
- `AsyncTest.res` — Jest async test bindings (direct copy from `reventless/test-helper/AsyncTest.res`)
- `BehaviorTest.res` — uses `ReventlessSpec.Behavior.T` in functor signature (not `Reventless.Behavior.T`) to avoid requiring reventless in example scope
- `ProjectionTest.res` — copy with `open Reventless` inside functor body
- `NoEventMappings.res` — returns `ReventlessSpec.EventMapper.Mappings` (spec type)
- `CommandTopic.res` — `include Reventless.CommandTopic`
- `Component.res` — `include Reventless.Component`

### Step 5: Update all example `.res` files ✓

Mechanical replacements across all 4 example packages:
- `open Reventless.Projection` removed (functor now in `ReventlessSpec.Projection`)
- `Reventless.Message.encode/decode/InvalidEvent` → `ReventlessSpec.Message.*`
- `Reventless.DcbTag.` → `ReventlessSpec.DcbTag.`
- `Reventless.AsyncTest.*` → `ReventlessInMemory.AsyncTest.*`
- `Reventless.BehaviorTest.Make` → `ReventlessInMemory.BehaviorTest.Make`
- `Reventless.ProjectionTest.Make` → `ReventlessInMemory.ProjectionTest.Make`
- `Reventless.NoEventMappings.Make` → `ReventlessInMemory.NoEventMappings.Make`
- `Reventless.CommandTopic.getHandlers` → `ReventlessInMemory.CommandTopic.getHandlers`
- `Reventless.Component.operations` → `<SpecificMaker>.operations` (see step 6)
- `Mappings.Make(...)` → `Projection.Mappings.Make(...)` where not using `open Projection`

### Step 6: Remove `@reventlessdev/reventless` from example dependencies ✓

All 4 `package.json` and `rescript.json` files updated.

### Additional fixes for type opacity (OCaml module system constraints)

Removing `reventless` from example scope caused type-unification failures for types that were transparent aliases in reventless. Fixed using the **`include` + re-shadow** pattern in `reventless-in-memory` builders:

**`Aggregate_Builder.res`** — Added `let operations: component => Pulumi.Output.t<ReventlessSpec.Aggregate.operations> = operations` (re-shadows with spec type). Also changed functor signature from `Reventless.Behavior.T`/`Reventless.EventMapper.Mappings` to `ReventlessSpec.Behavior.T`/`ReventlessSpec.EventMapper.Mappings`.

**`Platform.res`** — Same functor signature fix.

**`StateChangeSlice_Builder.res`** — `include Reventless.StateChangeSlice_Builder.Make(Spec)` + re-shadow `make` with spec-typed `publishJsons: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>`.

**`DcbEventLog_Builder.res`** — `include Reventless.DcbEventLog_Builder.Make(...)` + re-shadow `operations` with `Pulumi.Output.t<ReventlessSpec.DcbEventLog.operations<Spec.event>>`. DCB E2E tests updated to use `CatalogEventLogMaker.operations`/`OrderingEventLogMaker.operations` instead of `ReventlessInMemory.Component.operations` (which can't unify with the DcbEventLog component type opaquely).

**`NoEventMappings.res`** — Return type changed from `Reventless.EventMapper.Mappings` to `ReventlessSpec.EventMapper.Mappings`.

**`BehaviorTest.res`** — Removed `open Reventless` from functor body (it shadowed the `Behavior` functor parameter). Uses `Reventless.TestFixtures.context` directly instead.

### Additional fixes in `reventless-aws` (cascade from Steps 2 and 3)

Deleting `DcbTag.res` from reventless and moving `Mappings.Make` to spec also broke `reventless-aws`:

**`DcbEventLogStorage_DynamoDb_Runtime.res`** — 6 occurrences of `Reventless.DcbTag.*` → `ReventlessSpec.DcbTag.*` (type annotations for `tag`, `queryItem`, `query`, `appendCondition`).

**`Plugin_ReadModel_Builder.res`** — `Reventless.Projection.Mappings.Make` → `ReventlessSpec.Projection.Mappings.Make`.

**`SideEffectHandler_InMemory.res`** (reventless-in-memory) — Warning 44: `open Reventless` shadowed the `Component` identifier. Removed `open Reventless`; added explicit `Reventless.` qualifiers to `SideEffectHandler.*` and `ComponentType.*` references.

## Verification

All builds and tests pass:

```
examples/aggregate/catalog:  26 tests passed
examples/aggregate/ordering: 30 tests passed
examples/dcb/catalog:        44 tests passed
examples/dcb/ordering:       48 tests passed
reventless-in-memory:         9 tests passed
reventless:                 103 tests passed
reventless-aws:             builds cleanly
```

## Key Lessons Learned

1. **OCaml functor signatures must use types accessible to callers.** If a functor parameter type comes from package `A`, callers need `A` in their `rescript.json` dependencies to type-check the functor application.

2. **Type aliases are opaque to packages that don't have the aliased package in scope.** `Reventless.Aggregate.operations = ReventlessSpec.Aggregate.operations` is transparent inside `reventless`, but from examples (without `reventless` in scope), it's an opaque type — field access fails.

3. **The `include + re-shadow` pattern fixes opacity.** By including the concrete implementation and re-declaring specific values with explicit spec types, callers get the concrete types without needing the aliasing package in scope.

4. **Path-based type comparison.** Two values of type `Reventless.DcbEventLog.component<Reventless.DcbEventLog.operations<E.event>>` unify by PATH even without `reventless` in scope — the compiler compares paths. This is why `dcbEventLogComponent` matched `eventLog.component` without special handling.
