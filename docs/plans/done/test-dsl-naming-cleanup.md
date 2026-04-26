# Test-DSL Naming Cleanup (Plan 01 — Spec-First series)

## Executive Summary

Align GWT test-DSL module names with **what they test** (the implementation kind: `Behavior`, `Projection`, `Automation`, `Translation`) instead of **which component type** the spec lives under (`StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `InboundTranslationSlice`, `OutboundTranslationSlice`). The current names mix the two conventions: `Behavior_GWT` and `Projection_GWT` already exist (named by implementation kind), while every slice DSL is named by component type. This plan converges the slice DSLs onto the implementation-kind convention.

This is the first plan in the Spec-First implementation series. It ships **before** Plan 02 (Spec-First slice split) because:
- It touches naming only, not functor shapes — no breaking changes to existing test code.
- Plan 02 needs the new names in place when it consolidates merged slice files into split (Spec, Implementation) pairs.
- The work is mechanical and low risk: new aliases + PPX updates + test-file migrations + deprecation shims.

**Scope is narrower than the analysis suggested.** Code inspection (see *Reality Check* below) revealed three constraints:
1. `StateChangeSlice_GWT` cannot simply be renamed to `Behavior_GWT` because they have *different functor signatures* — `Behavior_GWT.Make(Spec, Behavior)` takes two modules, `StateChangeSlice_GWT.Make(SliceSpec)` takes one merged module. They converge only after Plan 02 splits slices.
2. `StateViewSlice_GWT` cannot be renamed to `Projection_GWT` because `Projection_GWT` already exists with a totally different shape (multi-source ReadModel projections with `sourceEvent` / `targetState` parameters). They are not interchangeable.
3. `InboundTranslationSlice_GWT` and `OutboundTranslationSlice_GWT` cannot be unified into a single `Translation_GWT` — Inbound's DSL exposes a synchronous `translate` from external input; Outbound's DSL exposes `collect` + an async mock-based translate phase. The shapes diverge by design.

Plan 01 therefore lands the safe parts now and defers the rest — `StateChangeSlice_GWT` and `StateViewSlice_GWT` consolidations land in Plan 02 (when the underlying merged-vs-split shape question is settled). Translation stays as two distinct DSLs, just renamed.

**Breaking change:** No. Old names remain as aliases for one minor release, then are removed.

---

## Background

This is the first concrete step of a longer Spec-First implementation series. The naming convention proposed below was originally drafted as part of that series' design analysis; this plan is the first place the convention lands as code in this repo.

### Naming convention

The DSL name should match the *implementation function set* it exercises:

| Implementation kind | Function(s) tested        | DSL name             |
|---------------------|---------------------------|----------------------|
| Behavior            | `decide`, `evolve`        | `Behavior_GWT`       |
| Projection          | `project`                 | `Projection_GWT`     |
| Automation          | `collect`/`resolve`/`process` | `Automation_GWT` |
| Translation (in)    | `translate` (sync, from external input) | `InboundTranslation_GWT` |
| Translation (out)   | `collect` + mocked async `translate` | `OutboundTranslation_GWT` |

This aligns with the implementation-file naming convention coming in Plan 02 (`X_Behavior.res`, `X_Projection.res`, `X_Automation.res`, `X_Translation.res`).

---

## Reality Check: Existing Module Inventory

Before describing the rename, here is what `reventless/reventless-gwt/src/` actually contains today and what each module's functor shape looks like.

| File | Functor signature | Notes |
|------|-------------------|-------|
| [`Behavior_GWT.res`](../../reventless/reventless-gwt/src/Behavior_GWT.res) | `Make(Spec: BehaviorSpec, Behavior: Behavior.T) → T` | Two-arg. Used by Aggregates today (Spec is a thin schema, Behavior is the impl). |
| [`StateChangeSlice_GWT.res`](../../reventless/reventless-gwt/src/StateChangeSlice_GWT.res) | `Make(Spec: SliceSpec) → T` | One-arg. Spec is *fat* — bundles types + decide/evolve/initialState. Used by merged StateChangeSlice files. |
| [`StateViewSlice_GWT.res`](../../reventless/reventless-gwt/src/StateViewSlice_GWT.res) | `Make(Spec: SliceSpec) → T` | One-arg. Fat spec with `state`, `project`, `subIdConfig`. |
| [`Projection_GWT.res`](../../reventless/reventless-gwt/src/Projection_GWT.res) | `Make({sourceEvent, targetState, ...}) → T` | Multi-source ReadModel DSL. `sourceEvent`/`targetState` as separate type parameters; store-based outcomes. **Not the same shape as `StateViewSlice_GWT`.** |
| [`Mapping_GWT.res`](../../reventless/reventless-gwt/src/Mapping_GWT.res) | `Make(Source, Target, Mapping)` | Cross-pattern mapping (Aggr↔Aggr, Aggr↔DCB, etc.). |
| [`AutomationSlice_GWT.res`](../../reventless/reventless-gwt/src/AutomationSlice_GWT.res) | `Make(Spec: SliceSpec) → T` | One-arg. Tests `collect`/`resolve`/`process`. |
| [`InboundTranslationSlice_GWT.res`](../../reventless/reventless-gwt/src/InboundTranslationSlice_GWT.res) | `Make(Spec: SliceSpec) → T` | Sync `translate: externalInput → result<array<(string, command)>, string>`. |
| [`OutboundTranslationSlice_GWT.res`](../../reventless/reventless-gwt/src/OutboundTranslationSlice_GWT.res) | `Make(Spec: SliceSpec) → T` | Different surface — `collect` + async `whenTranslateMocked` phase + retry assertions. |
| [`Query_GWT.res`](../../reventless/reventless-gwt/src/Query_GWT.res) | — | Out of scope for this plan. |
| [`EventMapping_GWT.res`](../../reventless/reventless-gwt/src/EventMapping_GWT.res) | — | Predecessor to `Mapping_GWT`; out of scope. |

### What this means for the rename

| Old name | Analysis target | Reality | Plan 01 outcome |
|----------|-----------------|---------|-----------------|
| `StateChangeSlice_GWT` | `Behavior_GWT` | Different shape (one-arg vs two-arg). Real consolidation requires the slice-split Plan 02. | **Defer to Plan 02.** Add a `_Slice` deprecation note pointing to Plan 02; keep the module name unchanged. |
| `StateViewSlice_GWT` | `Projection_GWT` | `Projection_GWT` already exists for ReadModels with a different shape. | **Defer to Plan 02.** Same reasoning. |
| `AutomationSlice_GWT` | `Automation_GWT` | Shape-preserving alias is safe today. | **Rename now (alias + deprecation).** |
| `InboundTranslationSlice_GWT` | `Translation_GWT` (unified) | Cannot unify with Outbound — fundamentally different shapes. | **Rename to `InboundTranslation_GWT`.** Keep distinct from Outbound. |
| `OutboundTranslationSlice_GWT` | `Translation_GWT` (unified) | Cannot unify with Inbound. | **Rename to `OutboundTranslation_GWT`.** |

### Convergence target after Plan 02

After Plan 02 splits slices into `(Spec, X_Behavior)` / `(Spec, X_Projection)` pairs, the two-arg `Behavior_GWT.Make(Spec, X_Behavior)` shape becomes the canonical form for both Aggregates and StateChangeSlices, and the rename `StateChangeSlice_GWT` → `Behavior_GWT` becomes mechanical. Same for `StateViewSlice_GWT` → `Projection_GWT`, modulo the multi-source ReadModel design question that Plan 02 settles. Plan 01 deliberately stops short of touching these two modules so that Plan 02 has a clean canvas.

---

## Scope

### In scope (Plan 01)

1. **Add three new alias modules** in `reventless/reventless-gwt/src/`, each a one-line module alias of an existing one:
   - `Automation_GWT.res` → `module Make = AutomationSlice_GWT.Make` (plus type-aliasing the `T` and `SliceSpec` module types).
   - `InboundTranslation_GWT.res` → aliases `InboundTranslationSlice_GWT`.
   - `OutboundTranslation_GWT.res` → aliases `OutboundTranslationSlice_GWT`.
2. **Update PPX folder/filename inference** ([`packages/reventless-ppx/src/ppx/Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml) and [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml)) so that:
   - Folders/filenames containing `Automation`, `InboundTranslation`, `OutboundTranslation` (without the `Slice` suffix) classify as the same kinds as today's `*Slice` segments.
   - The emitted `<Kind>_GWT.Make` reference uses the new short kind name (e.g., `Automation_GWT.Make` instead of `AutomationSlice_GWT.Make`).
3. **Migrate in-repo test files** to use the new names:
   - `reventless/reventless-gwt/tests/AutomationSliceGwtTest.res` → `reventless/reventless-gwt/tests/AutomationGwtTest.res` (filename change is optional but consistent).
   - Same for `InboundTranslationSliceGwtTest.res` and `OutboundTranslationSliceGwtTest.res`.
   - Any explicit `include ReventlessGwt.<Old>.Make(...)` lines in `examples/` switch to the new names. (Most tests rely on the PPX to emit the include line, so the filename/folder rename is sufficient.)
4. **Deprecation shims**: keep the old `*Slice_GWT` module files as one-line aliases of the new ones, with a `@deprecated` attribute that surfaces in the LSP. Old names remain functional for one minor release.
5. **Documentation**:
   - Add a short note in `reventless/reventless-gwt/README.md` (or `docs/guides/`) describing the naming convention.

### Out of scope (deferred to Plan 02)

- Renaming `StateChangeSlice_GWT` → `Behavior_GWT`. Requires the slice-split that converges the two functor signatures into the two-arg `(Spec, X_Behavior)` shape. Plan 02 handles this naturally as part of moving slice tests to `Behavior_GWT.Make(Spec, X_Behavior)`.
- Renaming `StateViewSlice_GWT` → `Projection_GWT`. Requires either (a) unifying with the existing multi-source `Projection_GWT` shape, or (b) renaming the existing `Projection_GWT` to something more specific (e.g., `MultiSourceProjection_GWT`) first. This is a Plan 02 design decision because it interacts with how multi-source ReadModels are represented under Spec-First (see analysis section *Multi-Source ReadModels and StateViewSlices*).

### Explicitly **not** changed

- `Behavior_GWT` — already correctly named.
- `Mapping_GWT`, `Query_GWT`, `EventMapping_GWT` — out of scope; these test cross-pattern mappings, queries, and legacy event mappings respectively.
- The `@@reventless.gwt` PPX attribute name itself — unchanged.
- Any framework runtime code (Aggregate_Builder, slice builders) — unchanged.

---

## Implementation Steps

The work breaks into four sequential PRs (each independently testable):

### Step 1 — Add new alias modules (rescript-gwt package)

Files to add:
- `reventless/reventless-gwt/src/Automation_GWT.res`
- `reventless/reventless-gwt/src/InboundTranslation_GWT.res`
- `reventless/reventless-gwt/src/OutboundTranslation_GWT.res`

Each is a thin re-export of its `*Slice_GWT` counterpart — module type `T` and module type `SliceSpec` re-aliased, `Make` re-exported. Pattern:

```rescript
// Automation_GWT.res — alias of AutomationSlice_GWT introduced in
// docs/plans/test-dsl-naming-cleanup.md (Plan 01).
module type SliceSpec = AutomationSlice_GWT.SliceSpec
module type T = AutomationSlice_GWT.T

module Make = AutomationSlice_GWT.Make
```

Verify `bun run build` in the `reventless-gwt` package succeeds and the new module appears in the generated `ReventlessGwt` namespace.

### Step 2 — Update PPX inference

Two changes in `packages/reventless-ppx/src/ppx/Util.ml`:

1. Extend `dsl_kind_of_segment` so that segments containing `Automation`, `InboundTranslation`, or `OutboundTranslation` (without the `Slice` suffix) return the *short* kind name — e.g., `"Automation"` instead of `"AutomationSlice"`.
2. Keep the existing `*Slice` segment recognition working — it should now also return the short kind name (so `AutomationSlice/` and `Automation/` both produce kind `"Automation"`).

Critical: the kind name returned by `dsl_kind_of_segment` is what `GwtInference.gen_include_one` uses to build `<Kind>_GWT.Make` references. After the change, every `@@reventless.gwt` test under an `Automation/`, `AutomationSlice/`, or `Automations/` folder will emit `Automation_GWT.Make(...)` — pointing at the new alias module added in Step 1.

For `StateChangeSlice` and `StateViewSlice`: leave them returning the long kind name today. Plan 02 changes both segments to return `"Behavior"` and `"Projection"` respectively, after the underlying functor shapes converge.

Update the inline error message in `GwtInference.ml` (`kinds_list_for_error`) to mention the new short forms alongside the slice-suffixed forms.

Add tests in `packages/reventless-ppx/tests/` covering: short folder name, long folder name, plural folder name, filename-fallback path. Run `bun run test` in the PPX package.

### Step 3 — Migrate in-repo tests

In `reventless/reventless-gwt/tests/`:
- Rename `AutomationSliceGwtTest.res` → `AutomationGwtTest.res` (folder structure already classifies via filename stem).
- Rename `InboundTranslationSliceGwtTest.res` → `InboundTranslationGwtTest.res`.
- Rename `OutboundTranslationSliceGwtTest.res` → `OutboundTranslationGwtTest.res`.
- The `.res.mjs` companions are compiler output — let `bun run build` regenerate them.

In `examples/` (Aggregate-style and DCB):
- For any test file whose folder is `*Slice/` and contains an automation or translation slice, no change is needed — the PPX inference handles it.
- If any test file uses an explicit `include ReventlessGwt.AutomationSlice_GWT.Make(...)` line, switch it to the new name. Search:
  ```bash
  grep -rn "AutomationSlice_GWT\|InboundTranslationSlice_GWT\|OutboundTranslationSlice_GWT" examples/ reventless/
  ```
- Run `bun run test` at the repo root to confirm everything still passes.

### Step 4 — Deprecation shims and docs

Convert each old `*Slice_GWT.res` to a deprecation alias of the new module (the inverse of Step 1's aliasing direction):

```rescript
// AutomationSlice_GWT.res — DEPRECATED. Use Automation_GWT instead.
// Removal scheduled for the release after this one (see RELEASE.md).
@deprecated("Use Automation_GWT instead — see docs/plans/test-dsl-naming-cleanup.md")
module type SliceSpec = Automation_GWT.SliceSpec
@deprecated("Use Automation_GWT instead")
module type T = Automation_GWT.T
@deprecated("Use Automation_GWT instead")
module Make = Automation_GWT.Make
```

This *inverts* the alias direction from Step 1 — the new module is now the source of truth, the old module is a thin deprecated re-export. Step 1's direction was a bootstrapping convenience; Step 4 makes the new name canonical.

Add a one-paragraph naming-convention note to `reventless/reventless-gwt/README.md`.

### Step 5 — Schedule removal

Add an entry to `RELEASE.md` noting the deprecation and the planned removal in the next minor (e.g., "removed in 0.X+1"). Do not remove yet — give downstream consumers one cycle.

---

## Verification

After each step:
- `bun run build` succeeds in `reventless-gwt`, `reventless-ppx`, and at the repo root.
- `bun run test` passes in `reventless-gwt`, `reventless-ppx`, and the example apps that ship in this repo.
- LSP shows `@deprecated` warnings on old names but not on new names.
- A PPX-emitted include line for a fresh `tests/Foo/Automation/X_GWT.res` reads `include ReventlessGwt.Automation_GWT.Make(X)` — not `AutomationSlice_GWT.Make(X)`.

End-to-end smoke test: pick one example app (`examples/online-shop-dcb/`), regenerate plugins (`bun run codegen` if applicable), run the full test suite, confirm zero regressions.

---

## Effort

| Step | Files affected | Effort |
|------|----------------|--------|
| 1. Add new alias modules | 3 new `.res` files in `reventless-gwt/src/` | XS |
| 2. PPX inference update | `Util.ml`, `GwtInference.ml`, PPX tests | S |
| 3. Migrate in-repo tests | ~3–6 file renames; compile-only fallout | S |
| 4. Deprecation shims + docs | 3 existing `.res` files rewritten as aliases; README; analysis update | XS |
| 5. Schedule removal | `RELEASE.md` entry | XS |

Total: **S–M** (one short PR per step, or one combined PR if the reviewer prefers).

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Downstream test files break when `<Kind>_GWT.Make` resolves differently after the PPX update. | The deprecation shim in Step 4 keeps old module names live. The PPX update in Step 2 targets the *new* names, so downstream tests continue compiling against either old or new names. |
| Folder-name ambiguity: a path like `tests/MyAutomation/` could now classify as `Automation` kind, where it might not have before. | The existing matcher already uses substring matching for non-slice kinds (`Projection`, `Behavior`); extending the same pattern to `Automation`/`InboundTranslation`/`OutboundTranslation` is consistent. Add tests covering the edge cases. |
| Two modules (`Automation_GWT` and `AutomationSlice_GWT`) shipping with identical surfaces increases the search space for new contributors. | Document the convention in the README and use `@deprecated` to surface a hint in the LSP. After one release cycle, remove the old names. |
| Plan 02 turns out to need different DSL signatures than today's `Behavior_GWT`/`Projection_GWT`, invalidating the rationale for keeping `StateChangeSlice_GWT`/`StateViewSlice_GWT` deferred. | Acceptable: Plan 02 will be the place to settle this. Plan 01 deliberately avoids touching these modules so that Plan 02 has a clean canvas. |

---

## Open Questions

These are narrow enough to resolve during execution; none block writing or starting the plan.

1. **Filename casing for new alias files.** `Automation_GWT.res` matches the module-name convention. Confirm there are no path-length or case-sensitivity concerns on Windows builds (the repo already ships `Behavior_GWT.res` and `Projection_GWT.res`, so this is precedent — should be fine).

2. **Deprecation duration.** One minor release (the default) vs. two minor releases vs. a single minor cycle keyed to a specific Plan 02 milestone. Recommend one minor cycle, removal scheduled for the same release Plan 02 lands.

3. **Should the PPX warn when it sees an explicit `*Slice_GWT.Make` reference in user code?** Pure deprecation (compiler-side) is probably enough; an additional PPX-level warning would be redundant. Recommend: rely on `@deprecated`.

4. **`MappingGwtTest` / `EventMapping_GWT`.** Out of scope for this plan, but worth flagging: these names are less consistent with the new convention. Decide separately whether to rename.

---

## Dependency Map

```
[ none ]  ──►  Plan 01 (this plan)  ──►  Plan 02 (Spec-First slice split)
                                          │
                                          ├──►  StateChangeSlice_GWT → Behavior_GWT  (handled there)
                                          └──►  StateViewSlice_GWT → Projection_GWT  (handled there)
```

Plan 01 is independent — no upstream dependency. Plan 02 depends on Plan 01 only for the in-place naming convention; it does not require Plan 01's deprecation cycle to complete.

---

## Acceptance Criteria

- [ ] `Automation_GWT`, `InboundTranslation_GWT`, `OutboundTranslation_GWT` exist as canonical modules in `reventless-gwt`.
- [ ] `AutomationSlice_GWT`, `InboundTranslationSlice_GWT`, `OutboundTranslationSlice_GWT` are deprecated aliases.
- [ ] `@@reventless.gwt` in a folder named `Automation/`, `Automations/`, or `AutomationSlice/` produces `Automation_GWT.Make(...)`. Same for the two translation kinds.
- [ ] All in-repo example tests pass without modification (or with mechanical filename changes only).
- [ ] PPX test suite covers all four folder-naming variants (`Automation`, `Automations`, `AutomationSlice`, `AutomationSlices`).
- [ ] `RELEASE.md` mentions the deprecation and the planned removal.
- [ ] LSP warnings appear on old names; do not appear on new names.
