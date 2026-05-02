# Plan: Close PPX Coverage Gaps & Unify Example File Naming

## Summary

Two intertwined goals tackled together because they touch the same files:

1. **Close PPX gaps** — eliminate hand-rolled boilerplate that has no PPX coverage today (multi-source `_Mappings` wrappers across ReadModel / AutomationSlice / Aggregate EventMappings; hand-rolled DCB Source modules; Extension files; Task files).
2. **Unify file naming** — every spec file is `<Name>.res` (kind comes from the folder); every body file is `<Name>_<Kind>.res` with an underscore separator. Today the convention is mixed (`CategoryBehavior.res` no underscore, `PlaceOrder_Behavior.res` with underscore, `CategoriesProjections.res` plural-no-underscore-no-stem-match, `Order_EventMappings.res` with extra `Event` prefix, `OrdersView.res` fused suffix, etc.).

The two land together because the new PPXes infer kind from filename suffix, and consistent suffixes make inference unambiguous.

---

## Resolved decisions

These were the open questions; all resolved before plan execution:

1. **ReadModel spec name** — drop the `ReadModel` suffix entirely. `CategoriesReadModel.res` → `Categories.res`. Matches the precedent across all other slice kinds (kind in folder, not filename).
2. **EventMappings folder** — restructure `online-shop-aggregates` to per-entity folder layout (matching DCB and hybrid examples). The top-level `EventMappings/` folder disappears; files move to `<Entity>/Aggregate/<Entity>_Mappings.res`, sibling to `<Entity>_Behavior.res`.
3. **Extension folder** — no folder rename. File rename only: `<Name>Extension.res` → `<Name>_Extension.res`.
4. **DCB Source modules** — no dedicated PPX attribute. The file-level kind PPXes (`@@reventless.mappings`, `@@reventless.automation`) scan inner modules and apply Source transforms (inject `module Id = Reventless.Id.String`, run dcbTags) when a module looks like a Source (has both `let name = "..."` and `@schema type event`). Detection is unambiguous.
5. **`@reventless.projections` removal** — hard cutover. The attribute only appears in auto-generated `Plugin.res`; codegen update + PPX removal land together. No deprecation period.
6. **StateViewSlice spec name** — drop the `View` suffix. `OrdersView.res` → `Orders.res`. Same reasoning as #1. Convention rule: spec stems must be unique within a plugin (codegen lints this in Phase 4).

---

## Target conventions

### File naming (all examples)

| Folder | Spec file | Body file(s) |
|---|---|---|
| `Aggregate/` | `<Entity>.res` | `<Entity>_Behavior.res`, `<Entity>_Mappings.res`† |
| `StateChangeSlice/` | `<Slice>.res` | `<Slice>_Behavior.res` |
| `StateViewSlice/` | `<Name>.res` | `<Name>_Projection.res` |
| `ReadModel/` | `<Plural>.res` | `<Plural>_Projections.res` |
| `AutomationSlice/` | `<Slice>.res` | `<Slice>_Automation.res` (process + per-source mappings inline) |
| `InboundTranslationSlice/` | `<Slice>.res` | `<Slice>_Translation.res` |
| `OutboundTranslationSlice/` | `<Slice>.res` | `<Slice>_Translation.res` |
| `Extension/` | — | `<Name>_Extension.res` |
| `ExtensionPoint/` | `<Name>_ExtensionPoint.res` | `<Name>_ExtensionPointMapping.res` |
| `Task/` | `<Name>.res` | — |

† only when EventMappings exist for that aggregate.

**Rules:**
- Spec filename never carries the kind suffix; folder name supplies the kind.
- Body filename is always `<SpecStem>_<KindWord>.res` with an underscore separator.
- Body file uses singular `_Projection` for single-source (StateViewSlice) and plural `_Projections` for multi-source (ReadModel) — the s/no-s distinction is meaningful (one function vs. a list of mappings).
- Within a plugin, every spec stem is unique across folders (Codegen enforces in Phase 4).

### PPX coverage

| Attribute | Target | Generates |
|---|---|---|
| `@@reventless.mappings` (NEW) | `*_Mappings.res`, `*_Projections.res` | `open <Domain>` (where `<Domain>` is `Reventless.Projection` for `ReadModel/`, `Reventless.EventMapping` for `Aggregate/`); `module M = <Domain>.Mappings.Make(Spec)`; `module type Mapping = M.Mapping`; `let moduleUrl`. **Also** scans inner modules and applies Source transforms (inject `module Id`, run dcbTags) on those that look like a DCB source. |
| `@@reventless.automation` (EXTENDED) | `*_Automation.res` | Existing injections + the same Mappings wrapper from above (since the merged file holds both `process` and per-source `Mapping.Make` modules) + the same Source-module scan. |
| `@@reventless.extension` (NEW) | `*_Extension.res` | Injects `open ReventlessInfra.ExtensionMapping`; applies the existing Delegate auto-transform inside the file's `Mapping` module (same as ExtensionPointMapping files). |
| `@@reventless.task` (NEW) | `Task/*.res` | Injects `let name` (from filename), `let moduleUrl`, `open Reventless`. |

After the migration, `@reventless.projections` (the Plugin-functor module attribute) is **removed** entirely.

---

## Prerequisites

- All current example/test suites green on `alpha`.
- `generate-plugin` is rerun locally to regenerate `src/Plugin.res` after each rename phase (it's a `prebuild` step, so this happens automatically on `pnpm run build`).
- Both `ppx-osx-x64.exe` and `ppx-linux.exe` get rebuilt for every PPX change (per memory: rebuild `ppx-linux.exe` via Docker after PPX edits).

---

## Phase 1 — PPX scaffolding (additive, no example changes yet)

Add the new PPX surfaces in `packages/reventless-ppx/src/ppx/`. Each one is additive: existing examples keep compiling against today's hand-rolled boilerplate. Migration of examples is Phase 3.

### 1.1 — `@@reventless.mappings`

- Add `Mappings` to the `impl_kind` enum in `ReventlessPpx.ml`.
- Implement `transform` branch:
  - Infer `Spec` module from filename stem (strip `_Mappings` or `_Projections` suffix).
  - Infer `domain` from folder path (`ReadModel/` → `Reventless.Projection`, `Aggregate/` → `Reventless.EventMapping`). Reject on no match.
  - Inject the `open <Domain>` (and `open Reventless.Message` for projections), the `Mappings.Make(Spec)` module, the `module type Mapping = M.Mapping`, the `let moduleUrl`.
  - Scan inner modules: for any `module X = { ... }` containing both `let name = "..."` AND `@schema type event`, inject `module Id = Reventless.Id.String` (if absent) and apply the existing dcbTags transform on the event type.
  - Leave the user-written `let mappings: array<module(Mapping)> = [...]` and the per-source `Mapping.Make` modules untouched.
- Add unit tests in `packages/reventless-ppx/test/` covering both domain folders and Source detection.

### 1.2 — Extend `@@reventless.automation` to handle Mappings + Source modules

- The merged `_Automation.res` will hold per-source `Mapping.Make` modules in addition to `process`. The PPX additionally emits the `Reventless.AutomationSlice.Mappings.Make(Spec)` wrapper and applies the same Source-module scan as 1.1.
- The user writes `let mappings: array<module(Mapping)> = [...]` in the same file.
- Tests cover both shapes (with and without per-source mappings) and Source-module detection.

### 1.3 — `@@reventless.extension`

- File-level attribute on `*_Extension.res`.
- Inject `open ReventlessInfra.ExtensionMapping`.
- Apply the existing Delegate auto-transform inside the inner `Mapping` module (the same one ExtensionPointMapping files get).
- Test covers an OrdersExtension-shaped file.

### 1.4 — `@@reventless.task`

- File-level attribute on Task files.
- Inject `let name = "<Filename>"` from the filename stem if absent.
- Inject `let moduleUrl` if absent.
- Inject `open Reventless` if absent.
- Test covers an ImportProducts-shaped file.

### 1.5 — Rebuild PPX binaries

- Run `pnpm run build:ppx` on macOS to refresh `ppx-osx-x64.exe`.
- Run the Docker build to refresh `ppx-linux.exe`.
- Commit both.

**Phase verification:** existing examples still build with zero warnings; new PPX unit tests pass.

---

## Phase 2 — Framework adjustment for AutomationSlice 2-file shape

The merged `_Automation.res` (process + mappings) replaces the current 3-file shape. Plugin assembly drops to 2 args.

- `reventless/reventless-infra/src/types/Platform.res` — change `AutomationSlice.Make` signature from `(Spec, Automation, Mappings)` to `(Spec, Automation)` where `Automation` exposes both the `process` binding and the `mappings` array.
- `reventless/reventless/src/components/AutomationSlice/AutomationSlice_Builder.res` — adapt to read mappings from the Automation module.
- `reventless/reventless-aws/src/components/AutomationSlice/AutomationSlice_Builder.res` — same.
- `reventless/reventless-in-memory/src/components/AutomationSlice/AutomationSlice_Builder.res` — same.

**Phase verification:** the 2-arg form must still work for current `_Automation.res` + `_Mappings.res` separation (because the user can re-export `mappings` from `_Automation.res` via `let mappings = AutoShipOrder_Mappings.mappings`). Existing examples temporarily get this one-line bridge; Phase 3 deletes the `_Mappings.res` files.

---

## Phase 3 — Example migration (per example, sweep)

Apply the file renames and PPX adoption across all three example domains: `online-shop-aggregates`, `online-shop-dcb`, `online-shop-hybrid`. Each domain has `catalog/`, `ordering/`, plus `*-spec/` and `*-aws/` packages.

### 3.0 — Restructure `online-shop-aggregates` to per-entity folder layout — ✅ DONE (PR2)

Before any renames, migrate `online-shop-aggregates/{catalog,ordering}/src/` from flat folders (`Aggregate/`, `EventMappings/`, `ReadModel/`, `Extension/`, `ExtensionPoint/`, `Task/`) to per-entity folders matching DCB and hybrid (`<Entity>/Aggregate/`, `<Entity>/ReadModel/`, etc.).

- `git mv` files into per-entity directories (e.g., `Aggregate/Order.res` → `Order/Aggregate/Order.res`; `EventMappings/Order_EventMappings.res` → `Order/Aggregate/Order_EventMappings.res`; `ReadModel/OrdersProjections.res` → `Order/ReadModel/OrdersProjections.res`).
- The top-level `EventMappings/` folder is deleted entirely (its contents merge into the per-entity `Aggregate/` folders).
- Update Plugin.res via `generate-plugin` (it should already handle per-entity layout).

**Verification:** all aggregates-example tests pass before proceeding to renames.

**Codegen tweaks needed for per-entity layout (also landed in PR2):**
- `Pairing.findEventMappings` was a flat-folder scan over `srcDir/EventMappings/`; rewrote it to recursively walk `srcDir` (skipping `Plugin/`, `tests/`, `lib/`) so it finds `<Entity>/Aggregate/<Agg>_EventMappings.res` too.
- `Discovery.isSkipped` was extended to skip `*_EventMappings.res` so the per-entity Aggregate folder doesn't double-pick those files as Aggregate specs (which would hunt for a non-existent `*_EventMappingsBehavior`).
- Catalog and ordering tests moved to `tests/<Entity>/` to mirror the hybrid layout.
- The `SideEffect/` folder (ordering-only) moved under `Order/SideEffect/` for entity locality.

### 3.1 — Aggregate behaviors

`git mv` for every rename:

- `<Entity>Behavior.res` → `<Entity>_Behavior.res` (across all three example domains).
- Update any references in tests, plugin generator output, etc.

Affected entities: `Category`, `Customer`, `Order`, `Product`, `CatalogProduct`, plus any `*Behavior` test files.

**aggregates done in PR3** — dcb + hybrid still use `<Entity>Behavior.res` for their aggregate behaviors. Pairing now tries `<Spec>_Behavior` first, falls back to `<Spec>Behavior`, so both shapes work during the migration.

### 3.2 — Aggregate event mappings — ✅ DONE for aggregates (PR3)

- `<Entity>_EventMappings.res` → `<Entity>_Mappings.res` (drop the `Event` prefix; PPX recognises `_Mappings.res` in `Aggregate/` folder).
- Replace the hand-rolled wrapper with `@@reventless.mappings` at the top. Resulting file body shrinks to: per-source `Mapping.Make` modules + `let mappings = [module(...)]` + (if needed) `let counter = None`.

**aggregates done in PR3** (only `Order_Mappings.res`). dcb + hybrid only have AutomationSlice `_Mappings.res` siblings (handled by Phase 3.5). `Pairing.findEventMappings` now walks the tree and matches both `_Mappings.res` (in `Aggregate/`) and legacy `_EventMappings.res`.

### 3.3 — ReadModel files — ✅ DONE for aggregates (PR3)

- `<Plural>ReadModel.res` → `<Plural>.res` (drop `ReadModel` suffix from spec).
- `<Plural>Projections.res` → `<Plural>_Projections.res` (add underscore).
- Replace hand-rolled `open Reventless.Message`, `open Reventless.Projection` headers in `_Projections.res` with `@@reventless.mappings`.
- Update Plugin generator: stop emitting the `@reventless.projections` wrapper module; instead reference `<Plural>_Projections` directly: `Platform.ReadModel.Make(<Plural>, <Plural>_Projections)`.

**aggregates done in PR3.** Codegen now flags ReadModel pairs where the projections file is the new `_Projections` form and emits the direct shape; legacy `Projections` form still gets the `@reventless.projections` wrapper. Wrapping module name in Plugin.res appends `ReadModel` (e.g., `module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)`) to keep the LHS distinct from the bare-named spec.

**Spec stem collision encountered:** catalog had both an `Aggregate/ProductDemand.res` and a `ReadModel/ProductDemand.res` (post-rename). Renamed the read model to `ProductDemands.res` (plural per the convention) — this is exactly the case the Phase-4 lint is meant to catch automatically.

**PPX update:** `Util.is_readmodel_filename` is now folder-aware (returns true for any file inside a `ReadModel/` folder) so the @@reventless.spec auto-injection of `config` + `subIdConfig` still fires for the bare-plural spec files.

### 3.4 — StateViewSlice files

- `<Name>View.res` → `<Name>.res` (drop `View` suffix).
- `<Name>View_Projection.res` → `<Name>_Projection.res`.
- Update all references across the plugin and Plugin.res.

Affected: `OrdersView`, `ProductsView`, `ProductDemandView`, `AvailableProductsView`, etc.

### 3.5 — AutomationSlice merge

For each `*_Automation.res` + `*_Mappings.res` pair:

1. Move the per-source `Mapping.Make` modules and `let mappings = [...]` from `_Mappings.res` into `_Automation.res`.
2. Move any `module XSource` declarations along with them. The PPX now auto-injects `module Id` and runs dcbTags on these — remove the hand-rolled lines.
3. `git rm` the now-empty `_Mappings.res`.
4. Update Plugin to use the new 2-arg `Platform.AutomationSlice.Make(Spec, Automation)`.

Affected: `AutoShipOrder` in `online-shop-dcb/ordering/` and `online-shop-hybrid/ordering/`.

### 3.6 — Extension files — ✅ DONE for aggregates (PR3)

- `<Name>Extension.res` → `<Name>_Extension.res`.
- Add `@@reventless.extension` at the top; remove the now-redundant `open ReventlessInfra.ExtensionMapping`.
- Verify the Delegate transform applies (DCB extensions only — Aggregate-style extensions don't have a Delegate).

**aggregates done in PR3** (catalog `Orders_Extension.res`, ordering `Products_Extension.res`). The Aggregate-style extensions reference real Aggregate modules as `module Delegate = ProductDemand` etc., so the Delegate auto-transform skips them harmlessly (the transform only fires on inline `Pmod_structure` modules).

### 3.7 — ExtensionPoint files — ✅ DONE for aggregates (PR3)

- `<Name>ExtensionPoint.res` → `<Name>_ExtensionPoint.res` (in `*-spec/` packages).
- `<Name>ExtensionPointMapping.res` → `<Name>_ExtensionPointMapping.res` (in plugin packages).
- Update all references (Plugin.res, Extension files referencing the EP).

**aggregates done in PR3.** `Util.top_level_only_suffixes` extended with underscored variants (`_ExtensionPoint`, `_ExtensionPointMapping`, `_ReadModel`, `_Extension`, `_Aggregate`, `_Plugin`) tried before the bare versions, so `filename_to_name` strips the underscore cleanly.

### 3.8 — DCB Source modules in projection files

For every `module XDcbSource = { ... }` block inside `_Projections.res` files (e.g., `CatalogActivityProjections.res`), the new `@@reventless.mappings` PPX scan now handles the transforms. Remove the hand-rolled `module Id = Reventless.Id.String` and ensure event fields rely on dcbTag auto-injection.

### 3.9 — Task files — ✅ DONE for aggregates (PR3)

- Add `@@reventless.task` to each `Task/*.res`.
- Remove the hand-rolled `let name`, `open Reventless`, etc. that the PPX now injects.

**aggregates done in PR3** (catalog `ImportProducts.res`, ordering `OrderNotifications.res`).

### 3.10 — Per-example verification

After each example sweep:

1. `pnpm run build` from the example platform package — compiles without warnings.
2. `pnpm test` — all tests green.
3. E2E tests under `tests/E2E/` — green.
4. `git status` reveals no missed references.

**Per memory:** `git mv` only stages the rename; also `git add <new-path>` to capture any unstaged edits (status shows `RM`).

---

## Phase 4 — Update plugin generator

`packages/reventless-codegen/` (or wherever `generate-plugin` lives) must:

- Recognise the new file naming: scan for `*_Behavior.res`, `*_Projections.res`, `*_Projection.res`, `*_Extension.res`, `*_ExtensionPoint.res`, `*_ExtensionPointMapping.res`, `*_Automation.res`, `*_Translation.res`, `*_Mappings.res`.
- Treat the spec file as `<Name>.res` regardless of folder (no fused suffix anymore).
- Stop emitting the `@reventless.projections` wrapper modules in `Plugin.res` — reference the slice-local `_Projections` modules directly.
- Emit the 2-arg `Platform.AutomationSlice.Make(Spec, Automation)` form.
- **New lint:** error on duplicate spec stems across the plugin tree (e.g., `Order/StateViewSlice/Orders.res` + `Order/ReadModel/Orders.res` both producing module `Orders`). Fail with a clear message naming both files.
- Update generator unit tests against the new fixture shape.

---

## Phase 5 — Documentation & convention sweep

- Update `.claude/rules/conventions.md` and `.claude/rules/app-developer.md` with the new file naming table and the new PPX inventory. Add the spec-stem-uniqueness rule.
- Update `docs/guides/platform-and-plugin-guide.md` (the canonical reference per memory) — every code listing, every snippet, every folder-tree illustration.
- Update `packages/doc/docs/reventless-components/*.md` — file paths and PPX usage in every component doc.
- Search for stale references: `grep -rn "Behavior\.res\|Projections\.res\|ExtensionPoint\.res\|View\.res\|ReadModel\.res\|EventMappings" docs/ packages/doc/` — fix all hits.

---

## Phase 6 — Retire deprecated PPX surfaces

- Remove `@reventless.projections` handling from `ReventlessPpx.ml`. Add a clear error message if a user still applies it: "use `@@reventless.mappings` in the slice-local `_Projections.res` file instead".
- Rebuild PPX binaries (osx + linux).
- Update CHANGELOG with breaking-change notes for any user who hand-edited their Plugin.res.

**Phase verification:** full repo build (`pnpm run build` at root) clean; all examples and codegen golden tests pass; zero warnings.

---

## Risk register

- **Renames are high-churn**: every example, every test, every doc snippet. Sweep one example end-to-end, verify, then propagate. Don't half-rename.
- **Module name collisions**: dropping `View` and `ReadModel` suffixes simultaneously creates collision potential within mixed plugins. The Phase 4 codegen lint catches these at build time. Examples don't have any collisions today (verified during planning).
- **PPX binary drift**: skipping the Linux rebuild means CI breaks. Always rebuild both binaries in the PPX-touching commits.
- **`pnpm-workspace.yaml` overlay**: per memory, sibling `reventless-ui` work requires `pnpm link:on`. Confirm release-mode (symlink to base) before all phases here, or this plan's edits won't be visible to UI consumers.
- **Codegen golden tests** under `examples/codegen/` will need fixture updates simultaneously with Phase 4.
- **External user code** (private app repos using Reventless) needs a migration note in CHANGELOG with mechanical sed/grep patterns for each rename.
- **Restructuring online-shop-aggregates (Phase 3.0)** is the largest individual move. Treat it as its own commit before any renames touch the same files.

---

## Estimated sequencing

| Phase | Why now | Roughly |
|---|---|---|
| Phase 1 (PPX scaffolding) | Foundation; additive; lowest risk | First |
| Phase 2 (AutomationSlice framework) | Required before Phase 3.5 example merge | After 1 |
| Phase 3.0 (aggregates restructure) | Must precede renames in that example | Before 3.1 |
| Phase 3.1–3.9 (example sweep) | One example at a time; commit per example | After 2 + 3.0 |
| Phase 4 (codegen) | Must follow Phase 3 file conventions | After 3 |
| Phase 5 (docs) | After all code changes are stable | After 3+4 |
| Phase 6 (retire deprecated PPX) | Cleanup; only after all examples migrated | Last |

Reasonable PR boundaries:

- **PR 1**: Phases 1 + 2 (PPX surface + framework adjustment). No example changes.
- **PR 2**: Phase 3.0 (aggregates restructure to per-entity layout).
- **PR 3, 4, 5**: Phase 3.1–3.9 applied per example domain (one PR each: aggregates, dcb, hybrid).
- **PR 6**: Phases 4 + 5 + 6 (codegen + docs + PPX retirement) together.
