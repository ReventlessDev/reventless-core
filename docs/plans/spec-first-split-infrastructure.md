# Spec-First Split Infrastructure + Migration (Plan 02)

## Executive Summary

Convert every merged DCB slice file (`StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `InboundTranslationSlice`, `OutboundTranslationSlice`) into the **two-file Spec / Implementation pattern** that Aggregates and ReadModels already use. After this plan:

- `X.res` is the **Spec** (types, annotations, configuration constants) — `@@reventless.spec`.
- `X_<Kind>.res` is the **Implementation** (pure decision/projection/automation/translation functions) — one of `@@reventless.behavior` / `@@reventless.projection` / `@@reventless.automation` / `@@reventless.translation`.
- The PPX, generator, framework builders, GWT DSLs, and example apps all understand the split.
- Plan 01's deferred renames (`StateChangeSlice_GWT` → `Behavior_GWT`, `StateViewSlice_GWT` → `Projection_GWT`) land here naturally because the functor shapes converge.

This is the **foundation for the rest of the Spec-First series** (Plans 03–05). The forward codegen pipeline, the roundtrip reverse pass, and the AI synthesis CLI all assume Spec and Implementation live in separate files with stable boundaries.

**Breaking change:** Yes — every example app and downstream plugin needs migration. An auto-split script and a deprecation period soften the impact.

**Estimated size:** L (multi-PR work, several weeks).

---

## Reality Check: Current State

Before describing the work, here is what exists today.

### Component types using the merged convention

Five component types currently bundle Spec + Implementation in one file:

| Component               | Folder pattern                                                                 | Example file |
|-------------------------|--------------------------------------------------------------------------------|--------------|
| StateChangeSlice        | `src/<Entity>/StateChangeSlice/<Cmd>.res`                                      | [`examples/online-shop-dcb/catalog/src/Category/StateChangeSlice/ArchiveCategory.res`](../../examples/online-shop-dcb/catalog/src/Category/StateChangeSlice/ArchiveCategory.res) |
| StateViewSlice          | `src/<Entity>/StateViewSlice/<View>.res`                                       | [`examples/online-shop-dcb/catalog/src/Category/StateViewSlice/CategoriesView.res`](../../examples/online-shop-dcb/catalog/src/Category/StateViewSlice/CategoriesView.res) |
| AutomationSlice         | `src/<Entity>/AutomationSlice/<Auto>.res`                                      | `examples/online-shop-dcb/ordering/src/Order/AutomationSlice/AutoShipOrder.res` |
| InboundTranslationSlice | `src/<Entity>/InboundTranslationSlice/<Tr>.res`                                | `examples/online-shop-dcb/catalog/src/Product/InboundTranslationSlice/ImportProduct.res` |
| OutboundTranslationSlice| `src/<Entity>/OutboundTranslationSlice/<Tr>.res`                               | `examples/online-shop-dcb/ordering/src/Order/OutboundTranslationSlice/PublishOrderShipped.res` |

### Component types already split

Two component types already use the two-file convention — Plan 02 leaves them alone:

| Component | Spec file       | Implementation file  | PPX |
|-----------|-----------------|----------------------|-----|
| Aggregate | `Foo.res`       | `FooBehavior.res`    | `@@reventless.spec` + `@@reventless.behavior(Foo)` |
| ReadModel | `FooReadModel.res` | `FooProjections.res` | `@@reventless.spec` + (no annotation on the projections file today; multiple `Mapping.Make` modules instead) |

Note the ReadModel projections file does **not** carry a PPX annotation today — it's just a regular `.res` file containing one or more `Mapping.Make({...})` calls. Plan 02 leaves this alone for ReadModels (it is multi-source by design) but introduces `@@reventless.projection` for the single-source StateViewSlice case.

### The annotations that exist today

[`packages/reventless-ppx/src/ppx/ReventlessPpx.ml`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml) currently understands two annotations:

- `@@reventless.spec` — the spec mode (most files use this).
- `@@reventless.behavior` (with optional spec name) — the implementation half of an Aggregate. Auto-injects `open Spec; module Spec = Spec`.

After Plan 02 there will be **four** implementation annotations (plus the spec annotation), one per implementation kind.

### Slice-spec module type

Today's [`reventless/reventless-spec/src/components/StateChangeSlice.res`](../../reventless/reventless-spec/src/components/StateChangeSlice.res) defines a single fat `Spec` module type bundling:
- Identity & metadata: `name`, `moduleUrl`, `Id`
- Types: `state`, `consumedEvent`, `command`, `error`, `event` (all `@schema`)
- Initial state: `initialState`
- Functions: `evolve`, `decide`
- Schema: `commandSchema`

Plan 02 splits this into `Spec` + `Behavior`. The remaining four merged slice types follow the same shape (one fat `Spec` containing types + functions); each gets the same split treatment.

### Pairing logic today

[`reventless/reventless-spec/src/generator/Pairing.res`](../../reventless/reventless-spec/src/generator/Pairing.res) already pairs:
- Aggregates: `Foo` + `FooBehavior` (line 154–170).
- ReadModels: `FooReadModel` + `FooProjections` (line 172–193, with `extractMappingModules` reading the projections file).

The five slice types are currently classified as single-stem entries (each push to its respective `*Slices` array, no pairing). Plan 02 adds pairing for each.

---

## Naming Convention

The annotation, file name, and DSL name all describe the same thing. The bare stem is the spec; underscore-suffixed names are derived artifacts.

| Implementation file        | PPX annotation              | GWT DSL (after Plan 02)         | Component types using it                |
|----------------------------|-----------------------------|----------------------------------|-----------------------------------------|
| `X_Behavior.res`           | `@@reventless.behavior`     | `Behavior_GWT`                   | Aggregate, StateChangeSlice             |
| `X_Projection.res`         | `@@reventless.projection`   | `Projection_GWT` (see below)     | StateViewSlice                          |
| `X_Automation.res`         | `@@reventless.automation`   | `Automation_GWT` (Plan 01)       | AutomationSlice                         |
| `X_Translation.res`        | `@@reventless.translation`  | `InboundTranslation_GWT` / `OutboundTranslation_GWT` (Plan 01) | InboundTranslationSlice, OutboundTranslationSlice |

ReadModel `FooProjections.res` files keep their existing name (they predate the convention and contain multi-source `Mapping.Make` calls — different shape from a single-source projection). Plan 02 does not migrate them; the pairing rule stays as-is.

---

## Scope

### In scope

1. **PPX annotations.** Add `@@reventless.projection`, `@@reventless.automation`, `@@reventless.translation`. Each:
   - Auto-injects `open <Spec>; module Spec = <Spec>`.
   - Auto-injects type annotations on recognized functions to disambiguate constructor shadowing (see *Type Shadowing* below).
   - Validates that the implementation file contains the expected functions for the kind.
2. **Slice-spec module types.** Split each of the five fat `Spec` module types into `Spec` (types + identity + schema) and `Behavior`/`Projection`/`Automation`/`Translation` (functions + initialState).
3. **Slice builders.** Update `StateChangeSlice_Builder`, `StateViewSlice_Builder`, `AutomationSlice_Builder`, `InboundTranslationSlice_Builder`, `OutboundTranslationSlice_Builder` to take two module arguments (`Spec`, `Implementation`) instead of one merged module — same pattern as `Aggregate_Builder.Make` today.
4. **Pairing & code generation.** Extend [`Pairing.resolve`](../../reventless/reventless-spec/src/generator/Pairing.res) so each slice type pairs `X.res` with `X_<Kind>.res`. Update [`Codegen.res`](../../reventless/reventless-spec/src/generator/Codegen.res) to emit the two-module `Make(Spec, X_<Kind>)` form when generating `Plugin.res`.
5. **GWT DSL convergence.** Update `Behavior_GWT.Make(Spec, X_Behavior)` so Aggregates *and* StateChangeSlices both use it. Add `Projection_GWT` for the single-source StateViewSlice shape (see *Open Question: Projection_GWT shape* below for the design choice). Folder-to-DSL inference in [`packages/reventless-ppx/src/ppx/Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml) returns the implementation-kind name (e.g., `"Behavior"` for `StateChangeSlice/`).
6. **Auto-migration script.** A standalone script that splits every existing merged slice file in `examples/` and any downstream plugin into the new two-file form. See *Auto-Migration Strategy* below.
7. **Example migration.** Run the script over all examples (`online-shop-dcb`, `online-shop-hybrid`, `online-shop-aggregates`); rebuild and run all test suites green.
8. **Deprecation shim.** A merged-file fallback path: if the PPX sees `@@reventless.spec` in a slice folder *with* `evolve`/`decide`/`project`/etc. defined alongside the types, it emits a deprecation warning and synthesizes the split-form modules in place. One minor release of overlap, then the merged path is removed.
9. **Plan 01 follow-ups.** The two GWT renames deferred from Plan 01 land here:
   - `StateChangeSlice_GWT` → deprecated alias for `Behavior_GWT`.
   - `StateViewSlice_GWT` → deprecated alias for `Projection_GWT` (after the multi-source design is settled).

### Out of scope

- **Aggregate / ReadModel restructuring.** Both already use the two-file form and stay unchanged. The ReadModel `Foo + FooProjections` pairing keeps its existing rule (multi-source by design — does not match the `X_<Kind>.res` convention).
- **Forward codegen pipeline (Plan 03).** Plan 02 just makes the split possible; it does not generate Spec or GWT files from a model.
- **Roundtrip reverse pass (Plan 04).** Out of scope.
- **AI synthesis CLI (Plan 05).** Out of scope.

---

## Type Shadowing in Split Files

Splitting a slice creates a constructor-shadowing problem that did not exist in the merged form: `consumedEvent` and `event` often share constructor names (e.g., `CategoryArchived` payload-less in `consumedEvent`, with payload in `event`). The merged file disambiguates by **declaration order** — `consumedEvent` is defined first, `evolve` consumes it, then `event` is defined and shadows the earlier constructor, then `decide` consumes the new one.

After splitting, both type definitions live in the same Spec file with no function definitions between them. The implementation file does `open Spec`, which brings both types into scope; the later definition shadows the earlier. The order trick stops working.

### Resolution: PPX-injected type annotations

The PPX (the new `@@reventless.behavior` / `@@reventless.projection` / etc. annotation) injects type annotations on recognized functions. With explicit annotations, the compiler resolves constructors from the annotation context, not from declaration order.

| Annotation                    | Function       | Injected signature |
|-------------------------------|----------------|--------------------|
| `@@reventless.behavior`       | `initialState` | `: state` |
| `@@reventless.behavior`       | `evolve`       | `(state: state, event: consumedEvent): state` |
| `@@reventless.behavior`       | `decide`       | `(state: state, command: command): result<array<event>, error>` |
| `@@reventless.projection`     | `project`      | `(event: consumedEvent): array<Reventless.Projection.action<string, state>>` |
| `@@reventless.automation`     | `collect`      | `(event: consumedEvent): array<(string, todoItem)>` |
| `@@reventless.automation`     | `resolve`      | `(event: consumedEvent): option<string>` |
| `@@reventless.automation`     | `process`      | `(id: string, item: todoItem): option<(string, command)>` |
| `@@reventless.translation`    | `translate`    | `(input: externalInput): result<array<(string, command)>, string>` (inbound) |
| `@@reventless.translation`    | `translate`    | `(item: outboundItem): promise<result<option<(string, inboundCommand)>, string>>` (outbound) |

The PPX only injects when the developer hasn't supplied an explicit annotation — manual annotations remain the escape hatch. Inbound vs. outbound translation are distinguished by the slice folder.

---

## Implementation Phases

The work splits into seven phases. Phases 1–3 land the framework changes; Phase 4 ships the auto-migration; Phase 5 migrates examples; Phase 6 handles the GWT DSL convergence; Phase 7 schedules deprecation removal.

### Phase 1 — Slice spec module types: split into (Spec, Implementation) ✅ DONE

**Status:** Completed 2026-04-26.

Per D2, each of the five slice spec files in [`reventless/reventless-spec/src/components/`](../../reventless/reventless-spec/src/components/) now exposes three module types:

| File | Lean `Spec` (carrier) | Implementation kind |
|------|-----------------------|---------------------|
| `StateChangeSlice.res` | name, moduleUrl, Id, command, event, error, consumedEvent, commandSchema | `Behavior` — state, initialState, evolve, decide |
| `StateViewSlice.res`   | name, moduleUrl, state, stateSchema, consumedEvent, config, subIdConfig | `Projection` — project |
| `AutomationSlice.res`  | name, moduleUrl, consumedEvent, todoItem, command, maxRetries, heartbeatInterval, targetName | `Automation` — collect, resolve, process |
| `InboundTranslationSlice.res` | name, moduleUrl, externalInput, command, targetName | `Translation` — translate |
| `OutboundTranslationSlice.res` | name, moduleUrl, consumedEvent, outboundItem, inboundCommand, maxRetries, heartbeatInterval, targetName | `Translation` — collect, translate (async) |

State placement follows D2: ephemeral state (StateChangeSlice) lives in `Behavior`; persisted state (StateView/Automation/OutboundTranslation) lives in `Spec`.

**Transitional `MergedSpec`.** Each slice file also exports a `MergedSpec` module type — the legacy combined shape — used by slice builders/callbacks/Platform interfaces while Phase 2 hasn't switched them to `(Spec, Impl)` yet. `MergedSpec` is removed in Phase 6 once nothing references it.

**Downstream renames.** 35 `<Slice>_Builder.res` / `<Slice>_Callback.res` / `<Slice>.res` (T module type) / `Platform.res` files in `reventless-core`, `reventless-aws`, `reventless-in-memory`, and `reventless-infra` were updated to reference `Reventless.<Slice>.MergedSpec` instead of `Reventless.<Slice>.Spec`. One exception: `Query_GWT.FromStateViewSlice` already only touches lean-Spec fields (`name`, `state`, `stateSchema`, `config`, `subIdConfig`), so it stays on the new lean `Spec`.

**Verification:** Full repo build clean (no warnings, no errors). All 1110 tests across 124 suites pass.

### Phase 2 — Slice builders: take two module arguments ✅ DONE

**Status:** Completed 2026-04-26.

Each of the five framework slice `_Builder.Make` and `_Callback.Make` functors now takes two module arguments — the lean `Spec` and the kind-specific implementation module:

| Slice                       | Functor signature                                                                          |
|-----------------------------|--------------------------------------------------------------------------------------------|
| `StateChangeSlice_Builder`  | `Make(Spec, Behavior: Behavior with module Spec := Spec)` → `StateChangeSlice.T`           |
| `StateViewSlice_Builder`    | `Make(Spec, Projection: Projection with module Spec := Spec)` → `StateViewSlice.T`         |
| `AutomationSlice_Builder`   | `Make(Spec, Automation: Automation with module Spec := Spec)` → `AutomationSlice.T`        |
| `InboundTranslationSlice_Builder`  | `Make(Spec, Translation: Translation with module Spec := Spec)` → `InboundTranslationSlice.T`  |
| `OutboundTranslationSlice_Builder` | `Make(Spec, Translation: Translation with module Spec := Spec)` → `OutboundTranslationSlice.T` |

Internal references inside `_Callback.res` and `_Builder.res` switched from `Spec.evolve` / `Spec.project` / `Spec.collect` / `Spec.translate` / `Spec.process` / `Spec.resolve` / `Spec.initialState` to `Behavior.X` / `Projection.X` / `Automation.X` / `Translation.X` (all unqualified within the implementation half).

The framework `T` module types were updated to expose **two** modules — `module Spec` (lean) and `module <ImplKind>` (the implementation half). Same change in [`reventless-infra/src/components/<Slice>.res`](../../reventless/reventless-infra/src/components/) for the deploy-time-facing `T`. Plugin_Structure / Dcb_Builder consumers only ever read `<Slice>.Spec.{name, eventSchema, consumedEventSchema, commandSchema, moduleUrl}`, all of which live in the lean Spec — no consumer change needed.

**Backwards-compat shim at the AWS / in-memory adapter layer.** Each `Platform.<Slice>.Make` still accepts a legacy `MergedSpec`. Inside the wrapper the merged module is spliced into a `LeanSpec` + `<ImplKind>Impl` pair using inline submodule definitions, then handed to the new two-arg framework `Make`. The wrapper re-binds `module Spec = Spec` (the original input MergedSpec) and `module <ImplKind> = <ImplKind>Impl` so the result satisfies `T with module Spec = Spec`. This means **example apps and the codegen are unchanged in Phase 2** — they keep calling `Platform.StateChangeSlice.Make(SpecModule)` exactly as before. Phase 5 will switch examples to native split form, after which the wrappers shed the `MergedSpec` adapter and take `(Spec, Impl)` directly.

Files touched:
- Framework: `_Builder.res`, `_Callback.res`, `<Slice>.res` for all five slices (~15 files in `reventless-core`).
- Infra: `<Slice>.res` for all five slices in `reventless-infra/src/components/`.
- AWS adapters: `<Slice>_Builder.res` (and `StateViewSlice_Builder_Stream.res`) in `reventless-aws/src/components/` (6 files).
- In-memory adapters: `<Slice>_Builder.res` in `reventless-in-memory/src/components/` (5 files).
- Tests: `tests/dcb/DcbStateChangeSliceTest.res` and `tests/plugin/PluginStructureTest.res` in `reventless-core` plus three callback tests in `reventless-in-memory/tests/components/` updated to splice MergedSpec → (Spec, Impl) when calling the framework callbacks directly.

**Note on framework Projection module shadowing.** Inside `StateViewSlice_Callback.res` and `StateViewSlice_Builder.res`, the new `Projection` functor argument shadows the framework's local `Projection` module (`reventless-core/src/Projection.res`, which provides `handleAction`/`handleActions`). Both files now alias the framework module as `module FrameworkProjection = Projection` at the top of the file, before the functor argument shadows the name. Same shadowing mitigation pattern will apply if a similar `Behavior` or `Translation` framework module is ever introduced.

**Verification:** Full clean repo rebuild (`pnpm exec rescript clean && pnpm exec rescript build`) compiles 836 modules with zero warnings and zero errors. All 1110 tests across 124 suites pass.

### Phase 3 — PPX annotations and inference

Phase 3 is split into two sub-phases. **Phase 3a** is additive: new annotations land alongside the existing `@@reventless.behavior` / `@@reventless.spec` without breaking anything, so it can ship before example migrations. **Phase 3b** contains the breaking GWT-inference changes that have to land in lockstep with Phase 5 (example migration) and Phase 6 (DSL convergence).

#### Phase 3a — New annotations (additive) ✅ DONE

**Status:** Completed 2026-04-26.

In [`packages/reventless-ppx/src/ppx/ReventlessPpx.ml`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml):

1. The `mode` ADT now has a unified `Implementation of impl_kind * string option` variant. `impl_kind` is `Behavior | Projection | Automation | Translation` — one variant per implementation file kind. The old `Behavior of string option` was folded into `Implementation (Behavior, _)`.
2. `detect_mode` and `strip_ppx_attrs` recognise the new annotation names (`reventless.projection`, `reventless.automation`, `reventless.translation`) alongside `reventless.behavior`. Each accepts an optional Spec module name in the same `(SpecModule)` payload form Behavior already supports.
3. The Implementation transform branch:
   - Injects `open <Spec>` and `module Spec = <Spec>` (same as Behavior).
   - For `Projection` only, also injects `open Reventless.Projection` so the `Set` / `Update` / `UpdateWithDefault` / `Delete` action constructors are in scope without an explicit user `open`. This mirrors the auto-open the Spec branch already does for `is_stateview_filename` files in the merged form.
   - Adds the `moduleUrl` suffix.
4. Spec-name derivation (`derive_impl_spec_name`) handles both filename conventions:
   - `X_<Kind>.res` (slice convention, e.g. `ArchiveCategory_Behavior.res` → `ArchiveCategory`).
   - `X<Kind>.res` (Aggregate convention, e.g. `ProductBehavior.res` → `Product`).
   - For `Behavior` outside slice folders, the legacy `Util.filename_to_name` derivation is preserved so existing Aggregate filenames keep resolving correctly.

PPX integration tests added in [`packages/reventless-ppx/test/run.sh`](../../packages/reventless-ppx/test/run.sh) cover:
- `@@reventless.projection` on `StateViewSlice/SplitView_Projection.res` (paired with `SplitView.res`) compiles with auto-injected `open` / `module Spec` / `open Reventless.Projection`.
- `@@reventless.projection(AltView)` explicit-Spec form.
- `@@reventless.automation` on `AutomationSlice/Sweep_Automation.res`.
- `@@reventless.translation` on both `InboundTranslationSlice/Hook_Translation.res` (sync) and `OutboundTranslationSlice/Notify_Translation.res` (sync collect + async translate).

**Verification:** All 129 PPX integration tests pass (10 new + 119 existing). Full repo rebuild compiles 836 modules with zero warnings; all 1110 tests across 124 suites pass. Both `ppx-osx-x64.exe` and `ppx-linux.exe` binaries committed.

**Deferred to Phase 3b** (would break existing tests; needs coordination with Phases 5 & 6):
- Type-annotation injection on recognised function bindings to resolve `consumedEvent` / `event` constructor shadowing in split slice files.
- Folder-to-DSL inference change: `Util.dsl_kind_of_segment` returning the implementation-kind name for `StateChangeSlice/` / `StateViewSlice/` (currently still returns the slice-typed name).
- `GwtInference` update so the `Projection` kind also uses `gen_include_two` (today only `Behavior` does).

#### Phase 3b — Breaking GWT inference changes (deferred)

These three items land alongside Phase 5 (auto-migrated examples) and Phase 6 (Behavior_GWT / Projection_GWT convergence). Doing them earlier would break every existing slice test in the example apps because:
- Today's `StateChangeSlice/` test folders contain a single merged-spec module; flipping the inference to `Behavior_GWT.Make(Spec, X_Behavior)` requires the split-form layout to already exist.
- Today's `StateViewSlice/` test folders use `StateViewSlice_GWT` as a single-source DSL; Plan 02's `Projection_GWT` rename (D1) needs the new DSL in place before the inference flips.

When Phase 3b lands:

1. Update folder-to-DSL inference in [`Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml):
   - `dsl_kind_of_segment` returns the implementation-kind name for slice folders (`"Behavior"` for `StateChangeSlice/`, `"Projection"` for `StateViewSlice/`).
2. Update [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml) so `Behavior` and `Projection` kinds always use `gen_include_two` (two-arg form).
3. Add type-annotation injection on recognised function bindings (table from *Type Shadowing* section): a slice with shared `consumedEvent` / `event` constructor names must compile correctly without manual annotations; manual annotations are preserved (no double annotation).

### Phase 4 — Auto-migration script

A standalone tool — placed in `scripts/spec-first-migrate/` or as a subcommand of an existing CLI — that walks a source tree and splits every merged slice file:

```
Input:  src/Category/StateChangeSlice/ArchiveCategory.res    (merged)
Output: src/Category/StateChangeSlice/ArchiveCategory.res    (Spec only)
        src/Category/StateChangeSlice/ArchiveCategory_Behavior.res  (Implementation only)
```

Algorithm:
1. **Parse the file** as ReScript via the standard parser. Reuse the same parser the PPX uses (Ppxlib AST).
2. **Classify each top-level item** as Spec content or Implementation content:
   - Type declarations (`type state`, `type consumedEvent`, `type command`, `type error`, `type event`, `type todoItem`, `type externalInput`, `type outboundItem`, `type inboundCommand`) → Spec.
   - Configuration constants (`let targetName`, `let maxRetries`, `let heartbeatInterval`, `let subIdConfig`) → Spec.
   - Implementation functions (`let initialState`, `let evolve`, `let decide`, `let project`, `let collect`, `let resolve`, `let process`, `let translate`) → Implementation.
   - Comments preceding a binding follow the binding.
   - Everything else (helper functions, local types) → Implementation, unless explicitly annotated `@spec` (a marker for tooling).
3. **Determine the implementation kind** from the slice folder name (`StateChangeSlice` → `Behavior`, etc.).
4. **Write the Spec file**: original path, contents = original `@@reventless.spec` attribute + Spec items + nothing else.
5. **Write the Implementation file**: same directory, name = `<stem>_<Kind>.res`, contents = `@@reventless.<kind>` attribute + Implementation items.
6. **Verify by re-parsing**: round-trip the two files through the PPX, compile against the new framework, run the original tests.

The script must be idempotent: running it on already-split files is a no-op.

A dry-run mode prints the planned splits without writing files.

### Phase 5 — Migrate examples and validate

Run the auto-migration script over:
- `examples/online-shop-dcb/` (catalog, ordering plugins)
- `examples/online-shop-hybrid/` (catalog, ordering plugins — only the slice folders; aggregates stay as-is)
- `examples/online-shop-aggregates/` (only the slice folders if any; mostly aggregates)

For each migrated app:
1. `bun run build` succeeds.
2. `bun run test` passes — both unit tests (Jest, runtime, plugin) and any GWT suites.
3. The generated `src/Plugin.res` matches the expected new-form (`Make(Spec, X_<Kind>)`).
4. `pulumi preview` (or equivalent platform-aware build step) succeeds for any app that ships infrastructure.

### Phase 6 — GWT DSL convergence (Plan 01 follow-up)

In [`reventless/reventless-gwt/src/`](../../reventless/reventless-gwt/src/):

1. **Behavior_GWT** — the existing `Make(Spec: BehaviorSpec, Behavior: Behavior.T)` shape stays, but `BehaviorSpec` is generalized to also satisfy the new `StateChangeSlice.Spec`. The two are unified — both Aggregate and StateChangeSlice tests use `Behavior_GWT.Make(Spec, X_Behavior)`.
2. **Projection_GWT** — settle the multi-source vs. single-source design (see *Open Questions* below). Either:
   - Rename the existing multi-source DSL to `MultiSourceProjection_GWT` (or `MappingProjection_GWT`) and use `Projection_GWT` for the new single-source StateViewSlice shape; **or**
   - Generalize `Projection_GWT` so it accepts both shapes via a polymorphic spec type.
3. **`StateChangeSlice_GWT` and `StateViewSlice_GWT`** — convert to deprecated one-line aliases, scheduled for removal in the same release Plan 02 ships fully. Plan 01's `@deprecated` shim machinery is reused.
4. PPX folder-to-DSL inference (already updated in Phase 3) now resolves slice folders to `Behavior_GWT` / `Projection_GWT` directly. Test files no longer need explicit `include` lines.

Acceptance: every example test file under `tests/.../StateChangeSlice/` and `tests/.../StateViewSlice/` passes without explicit `include ReventlessGwt.<Old>_GWT.Make(...)` lines.

### Phase 7 — Schedule deprecation removal

`RELEASE.md` entry: list every deprecation introduced by Plans 01 + 02 (`AutomationSlice_GWT`, `InboundTranslationSlice_GWT`, `OutboundTranslationSlice_GWT`, `StateChangeSlice_GWT`, `StateViewSlice_GWT`, the merged-file slice fallback path). Schedule removal in the next minor.

A grep CI gate (existing repo convention if any, or a new `scripts/deprecation-gate.sh`) prevents new uses of the deprecated names landing on `main`.

---

## Auto-Migration Strategy

The migration script is the single biggest risk in Plan 02 — if it produces incorrect output for even a few files, the example apps break and confidence in the migration drops sharply. Mitigations:

1. **Use the real ReScript parser** (Ppxlib, same one the PPX uses). Do not write a string-based or regex-based splitter — comments, multi-line bindings, embedded JSX, and PPX attributes are all parser-level concerns.
2. **Run on a representative corpus first**: the slice files under `reventless/reventless-gwt/tests/StateChange/` (the test fixtures used by the GWT DSL itself) are small and exhaustive over the patterns. Migrate those first as a smoke test.
3. **Idempotence test**: round-trip every migrated file (split → re-merge → re-split) and assert the output is byte-stable up to formatting.
4. **Comment preservation**: doc comments above type/function declarations move with the declaration. Section header comments (e.g., `// -- Implementation --`) are migrated based on what follows them.
5. **Manual review for edge cases**: any file the script flags as ambiguous (e.g., a top-level helper function that could be Spec or Implementation depending on intent) is left untouched and listed in a report. Migrator opens manual PRs for those.

The script should produce a structured report after running (`migrated.json` or similar): for each input file, list the output files, classification of each top-level item, and any warnings.

---

## Verification

After each phase:
- `bun run build` succeeds at the repo root and inside every package.
- `bun run test` passes — unit, integration, GWT, e2e (where applicable).
- The PPX test suite covers the new annotations and the type-annotation injection.
- The generator's snapshot tests for `Plugin.res` reflect the new two-module `Make(Spec, X_<Kind>)` form.
- LSP shows the expected `@deprecated` warnings on old names; no warnings on new names.

End-to-end smoke test: pick `examples/online-shop-dcb/`, run the full local-mode e2e flow (start in-memory mode, exercise commands, verify projections). Repeat for `online-shop-hybrid`.

---

## Effort Estimate

| Phase | Files affected (approx.) | Effort |
|-------|--------------------------|--------|
| 1. Spec module type splits | 5 files in `reventless-spec` | M |
| 2. Slice builders | 5 builder + 5 callback files in `reventless-core`; AWS counterparts | M |
| 3. PPX annotations & type-annotation injection | `ReventlessPpx.ml`, `Util.ml`, `GwtInference.ml`; PPX tests | M–L |
| 4. Auto-migration script | New script + tests + dry-run mode | M |
| 5. Migrate examples & validate | Hundreds of `.res` files via the script; manual review of warnings | M |
| 6. GWT DSL convergence | 2–4 files in `reventless-gwt`; PPX inference already done in Phase 3 | S |
| 7. Schedule deprecation removal | `RELEASE.md`; optional CI grep gate | XS |

**Total: L** (estimated 3–5 weeks of focused work, depending on edge cases discovered during example migration).

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Auto-migration produces incorrect splits for hand-written edge-case files. | Parser-based migration, idempotence tests, ambiguous-file report, dry-run mode. |
| Type-annotation injection creates compile errors for files that already have manual annotations on the same bindings. | Detect existing annotations and skip injection; PPX tests cover this. |
| Constructor shadowing manifests differently in the wild than expected (e.g., across more than two types). | The injected annotations resolve any number of shadowed constructors per binding. Add a test case with three shadowed types. |
| Deprecation shim (merged-file fallback in PPX) has subtle differences from the split-form output. | Keep the shim minimal — emit a warning and refer the user to the migration script rather than trying to be invisible. The shim exists to keep old plugins compiling for one minor cycle, not to support indefinite use. |
| AWS adapter and platform layers (Pulumi side) miss a slice-builder signature change. | Build all packages in CI, including `reventless-aws`, before merging Phase 2. |
| Multi-source ReadModel projections regress. | Plan 02 explicitly excludes ReadModel restructuring. The existing `Foo + FooProjections` pairing rule remains untouched. |
| Plan 01's GWT renames clash with Plan 02's PPX inference change. | Coordinate the merge: Plan 01's PPX update accepts the short forms (`Automation/`, `InboundTranslation/`, etc.); Plan 02's update extends the same logic to slice-folder names returning the implementation-kind name. The two changes are additive. |

---

## Resolved Decisions

The five Open Questions on the original draft have been settled by code inspection (see decision rationale below) and decided on 2026-04-26.

### D1 — Projection_GWT shape: two DSLs, rename

**Decision: Option (a)** — two DSLs with the existing one renamed.

- `Projection_GWT` (in [`reventless/reventless-gwt/src/Projection_GWT.res`](../../reventless/reventless-gwt/src/Projection_GWT.res)) is renamed to `MultiSourceProjection_GWT`. It keeps its existing functor signature `Make(Projection: Reventless.Projection.Mapping)` and is used by ReadModels with their multi-source `FooProjections.res` files.
- A new `Projection_GWT` is introduced for the single-source post-Plan-02 StateViewSlice shape. It is essentially today's `StateViewSlice_GWT` renamed (single `consumedEvent` union, single `state`, single `project` function).

**Rationale.** A side-by-side read of `Projection_GWT.res` (multi-source, 316 lines) and `StateViewSlice_GWT.res` (single-source, 293 lines) shows nearly identical surfaces (`store`, `givenEvents`, `whenEvent[s]`, `thenStates`, `thenAllStates`, …). The only material difference is whether the source is described by a multi-source `Mapping` interface or a single-source `SliceSpec`. ReadModel multi-source projections remain a deliberate framework feature that survives Plan 02 unchanged, so surfacing the distinction in the DSL name is honest. Generalising into one polymorphic DSL (option b) trades a clean module signature for module-type-machinery in user code; deferring (option c) carries a known inconsistency forward into Plan 03 codegen.

### D2 — `state` type placement: match the existing convention per slice

**Decision:** state placement follows the convention for the corresponding non-slice component, not a blanket rule.

| Slice                       | State carrier        | Goes in                  | Rationale (mirrors)                       |
|-----------------------------|----------------------|--------------------------|-------------------------------------------|
| StateChangeSlice            | `state`/`initialState` | Implementation (`X_Behavior.res`) | Aggregate puts `state`/`initialState` in `Behavior.T`, not in `Aggregate.Spec` ([reventless-spec/src/types/Behavior.res](../../reventless/reventless-spec/src/types/Behavior.res)). Slice state is ephemeral, rebuilt from events for the decide loop — pure implementation detail. |
| StateViewSlice              | `state` + `stateSchema` | Spec (`X.res`)         | ReadModel puts `state`/`stateSchema` in `ReadModel.Spec` ([reventless-spec/src/components/ReadModel.res:164](../../reventless/reventless-spec/src/components/ReadModel.res#L164)). View state is persisted, schema-visible to GraphQL resolvers — part of the externally-observable contract. |
| AutomationSlice             | `todoItem` + `todoItemSchema` | Spec (`X.res`)   | Persisted TODO state with schema, queried for sweeps. Same axis as ReadModel state. |
| OutboundTranslationSlice    | `outboundItem` + `outboundItemSchema` | Spec (`X.res`) | Same as Automation. |
| InboundTranslationSlice     | (no state)           | —                        | Translation is a pure function of external input. |

**Why this overrides the original "state stays in Spec" recommendation.** The blanket rule was motivated by Plan 03/04 codegen-roundtrip, but codegen is a structural concern: any consistent split is roundtrippable as long as the parser uses the file the generator emitted. The deciding axis is *what's already true for non-slice components*. StateChangeSlice ↔ Aggregate parity dictates state-in-implementation; StateViewSlice ↔ ReadModel parity dictates state-in-spec. Mixing conventions inside the slice family is the cost of accurately mirroring the existing Aggregate/ReadModel asymmetry.

### D3 — OutboundTranslationSlice: both `collect` and `translate` in `X_Translation.res`

**Decision:** Confirmed. Both functions live in the implementation file, with type signatures injected by the PPX:

- `collect: consumedEvent => array<(string, outboundItem)>` (sync; what tests observe via `whenCollect`)
- `translate: (string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>` (async; mocked in tests via `whenTranslateMocked`, exercised for real in runtime tests)

Inbound vs. Outbound is distinguished by **folder name** at PPX time (`OutboundTranslationSlice/` vs `InboundTranslationSlice/`); each folder selects a different `translate` signature. Inbound has no `collect`; Outbound has both. The annotation `@@reventless.translation` is shared.

### D4 — No deprecation cycle (matches Plan 01)

**Decision:** Plan 02 ships clean renames and removals — no deprecation shims, no `@deprecated` aliases, no fallback paths in the PPX.

- Slice spec module types: split cleanly. Old fat `Spec` is removed in the same PR.
- Slice builders: change to two-arg `Make(Spec, Impl)` cleanly. Old one-arg signature is removed.
- GWT renames (`StateChangeSlice_GWT` → `Behavior_GWT`, `StateViewSlice_GWT` → `Projection_GWT`, plus the `Projection_GWT` → `MultiSourceProjection_GWT` rename from D1): clean rename with `git mv`, no aliases.
- The PPX merged-file fallback path described in the original Phase 8 is dropped entirely.

**Rationale.** The codebase is in alpha (`0.x-alpha.N`), and the established philosophy from Plan 01 was clean renames over deprecation shims (the user explicitly chose "no deprecation shims" for the AutomationSlice/InboundTranslation/OutboundTranslation rename). The auto-migration script in Phase 4 is the safety net for in-repo examples; downstream plugins do a one-shot grep-and-replace.

This collapses the original Phase 7 ("schedule deprecation removal") to a single sentence: there is nothing to schedule.

### D5 — `examples/online-shop-aggregates/` has no slices

**Decision:** Confirmed by `find examples/online-shop-aggregates -type d -name '*Slice'` (excluding `node_modules` and `lib/`): no source-level slice folders exist. Phase 5 migrates only:

- `examples/online-shop-dcb/catalog/` — StateChangeSlice, StateViewSlice, InboundTranslationSlice
- `examples/online-shop-dcb/ordering/` — StateChangeSlice, StateViewSlice, AutomationSlice, OutboundTranslationSlice
- `examples/online-shop-hybrid/catalog/` — StateChangeSlice, InboundTranslationSlice
- `examples/online-shop-hybrid/ordering/` — StateChangeSlice, StateViewSlice, AutomationSlice, OutboundTranslationSlice

`examples/online-shop-aggregates/` is unchanged — it stays a pure-Aggregate example.

---

## Plan Adjustments Implied by the Decisions

The decisions above tighten Phases 1, 3, 6, and 7. Specific deltas:

1. **Phase 1 (spec module type splits).** Don't move `state`/`initialState` uniformly — follow the D2 table per-slice. Drop the "old fat `Spec` remains as a deprecated alias" step (D4). Each slice ends up with a clean `Spec` + `<ImplKind>` pair and the old fat type is gone.

2. **Phase 3 (PPX annotations).** The injected type signatures for `evolve`/`decide`/`initialState` reference `state` from the implementation file's local scope (StateChangeSlice case). For `project`/`collect`/`resolve`/`process`, `state`/`todoItem`/`outboundItem` come from `Spec.<type>` because those types live in the Spec file. The Type Shadowing table in the original draft already used `state` as a bare identifier — that remains valid for the StateChangeSlice case (state is local) but the Projection/Automation/Translation rows should read `Spec.state` / `Spec.todoItem` / `Spec.outboundItem`.

3. **Phase 6 (GWT DSL convergence).** Add a step **6a** before the existing steps: rename `Projection_GWT` → `MultiSourceProjection_GWT` (`git mv` + update the few in-repo references in `MappingGwtTest`/`StateViewSliceGwtTest`/etc.). Then promote `StateViewSlice_GWT`'s body to be the new `Projection_GWT`. Step **6b** converges `Behavior_GWT` to accept both Aggregate and StateChangeSlice. Step **6c** removes `StateChangeSlice_GWT` and `StateViewSlice_GWT` entirely (no aliases — D4). PPX inference (Phase 3) emits `Behavior_GWT.Make(Spec, X_Behavior)` and `Projection_GWT.Make(Spec, X_Projection)` for the slice folders accordingly.

4. **Phase 7 (deprecation removal).** Replace with: "No deprecation cycle. The CHANGELOG entry produced by the conventional-commit message is the sole user-visible record of the breaking change."

---

## Dependency Map

```
Plan 01 (Test-DSL Naming Cleanup)
   │
   └──►  Plan 02 (this plan)  ──►  Plan 03 (Forward Codegen)
                                      │
                                      ├──►  Plan 04 (Roundtrip)
                                      │
                                      └──►  Plan 05 (Synthesis CLI)
```

Plan 02 depends on Plan 01 only for the in-place naming convention (Plan 01's `Automation_GWT` / `InboundTranslation_GWT` / `OutboundTranslation_GWT` aliases are the targets Plan 02's PPX inference now resolves to). It does not require Plan 01's deprecation cycle to complete.

---

## Acceptance Criteria

- [ ] `@@reventless.projection`, `@@reventless.automation`, `@@reventless.translation` are recognized PPX annotations alongside the existing `@@reventless.spec` and `@@reventless.behavior`.
- [ ] Each new annotation auto-injects `open Spec; module Spec = Spec` and the canonical type annotations on recognized functions.
- [ ] Slice spec module types in `reventless-spec` are split into `Spec` + `<ImplKind>`; old fat module types remain as deprecated aliases.
- [ ] Slice builders in `reventless-core` (and AWS counterparts) take two module arguments.
- [ ] `Pairing.resolve` pairs every slice type by stem (`X.res` ↔ `X_<Kind>.res`).
- [ ] `Codegen.res` emits the two-module `Make(Spec, X_<Kind>)` form in `Plugin.res`.
- [ ] Auto-migration script splits every merged slice file in `examples/` into the new form; idempotent on already-split files; produces a structured report.
- [ ] All examples build and test green after migration.
- [ ] PPX folder/filename inference resolves slice folders to implementation-kind names (`StateChangeSlice/` → `Behavior_GWT`, etc.).
- [ ] `Behavior_GWT` accepts both Aggregate and StateChangeSlice spec shapes.
- [ ] `Projection_GWT` (or `StateViewProjection_GWT`, depending on the design choice in Open Question 1) is in place for StateViewSlice tests.
- [ ] `StateChangeSlice_GWT` and `StateViewSlice_GWT` are deprecated aliases.
- [ ] `RELEASE.md` lists all deprecations and their planned removal.
- [ ] LSP warnings appear on every deprecated name.
- [ ] No reference to a deprecated name remains in any non-shim source file.
