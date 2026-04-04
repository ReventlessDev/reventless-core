# Reventless PPX

## Status: IN PROGRESS (phases 0–9 done; remaining: CI verification, docs site)

## Goal

Build a custom ReScript PPX that eliminates repetitive boilerplate from Reventless application code. Written in OCaml with ppxlib (same stack as sury-ppx), distributed as pre-compiled binaries via npm.

**Analysis:** [docs/analysis/reventless-ppx-analysis.md](../../analysis/reventless-ppx-analysis.md), [docs/analysis/eliminate-moduleurl-raw-javascript.md](../../analysis/eliminate-moduleurl-raw-javascript.md)

---

## Phase 0: Project Scaffold

### 0.1 — Create reventless-ppx package

- [x] Create `packages/reventless-ppx/` with OCaml/dune project structure:
  ```
  packages/reventless-ppx/
  ├── src/bin/bin.ml                # Entry: Ppxlib.Driver.run_as_ppx_rewriter()
  ├── src/ppx/ReventlessPpx.ml     # Main mapper (register transformations)
  ├── src/ppx/ModuleUrl.ml         # package.json walk + specifier computation
  ├── src/ppx/DcbTagInference.ml   # Auto-annotate *Id fields
  ├── src/ppx/Util.ml              # Shared helpers
  ├── src/dune-project
  ├── src/reventless-ppx.opam
  ├── bin                          # Shell script dispatcher
  ├── bin.cmd                      # Windows dispatcher
  ├── install.cjs                  # Post-install hook (copy sury-ppx pattern)
  └── package.json
  ```
- [x] Set up dune build: `(kind ppx_rewriter)`, depend on `ppxlib`, `yojson`
- [x] Verify binary builds on local machine
- [x] Add `"ppx-flags": ["reventless-ppx/bin", "sury-ppx/bin"]` to one example package's rescript.json (PPX ordering: reventless first, then sury)
- [x] Verify PPX compiles examples without errors (all example packages migrated and passing)

### 0.2 — CI cross-compilation

- [x] Create `.github/workflows/build-ppx.yml` — builds on 5 platforms (macOS ARM, macOS x64, Linux x64, Linux ARM, Windows x64)
- [x] Test job runs `test/run.sh` after build
- [x] Assemble job collects all binaries into a single artifact on push to main/beta/alpha
- [ ] Verify workflow runs successfully on first push
- [ ] Integrate with release workflow to publish binaries to npm

### 0.3 — Test infrastructure

- [x] Create `packages/reventless-ppx/test/run.sh` — integration test that creates temp ReScript packages, compiles through PPX, and verifies JS output
- [x] Tests cover: spec name derivation, behavior injection, ReadModel suffix stripping, explicit name, dotted name from *Spec namespace, module Id skip
- [x] Add `"test": "./test/run.sh"` to package.json
- [x] 25 assertions, all passing (spec, behavior, namespace, DCB tags, ReadModel defaults, projections, delegate, EP mapping open, slice folder auto-dcbTags, *Ids array annotation)

---

## Phase 1: `moduleUrl` Auto-Injection

**Impact: 298 `%raw` declarations eliminated**

### 1.1 — Implement `@@reventless.spec` moduleUrl injection

- [x] In `ReventlessPpx.ml`: register a structure mapper that detects `@@reventless.spec`
- [x] Removed `@@reventless.specModule` — superseded by `@@reventless.spec` (Phase 4)
- [x] In `ModuleUrl.ml`: implement `find_package_name`:
  - Read `pos_fname` from the AST location to get the source file path
  - Walk up directory tree, `stat` for `package.json` at each level
  - Parse JSON, extract `"name"` field
  - Cache results keyed by directory (avoid repeated filesystem walks)
- [x] Compute npm specifier: `packageName + "/" + relativePath` with `.res` → `.res.mjs` suffix
- [x] Inject `let moduleUrl: string = "computed-specifier"` into the AST
- [x] Handle edge cases: relative `pos_fname` (prepend `cwd`), Windows path separators, symlinks

### 1.2 — Snapshot tests for moduleUrl

- [x] Covered in Phase 0.3 test suite: moduleUrl specifier verified for plugin and spec packages

### 1.3 — Migrate one example package

- [x] Add `reventless-ppx` to `examples/online-shop-aggregates/catalog/rescript.json`
- [x] Replace all `let moduleUrl: string = %raw(...)` with `@@reventless.specModule` in catalog specs
- [x] Verify `npm run build` succeeds with zero warnings
- [x] Verify `npm run test` passes (26 catalog + 30 ordering = 56 tests)

### 1.4 — Migrate all example packages

- [x] Add PPX to all example packages (catalog, catalog-spec, ordering, ordering-spec, online-shop-aggregates)
- [x] Migrate ordering specs (3 aggregates, 3 read models) to `@@reventless.spec`
- [x] Migrate ordering behaviors (3 files) to `@@reventless.behavior`
- [x] Migrate ordering-spec EP to `@@reventless.specModule`
- [x] Migrate EventMappings and SideEffect files to `@@reventless.specModule`
- [x] Full build + test pass (all 56 example tests)
- Note: `OrderingPlugin.res` retains explicit `%raw` for top-level `moduleUrl` — inner functor modules reference it via `let moduleUrl = moduleUrl`. PPX can't inject before a functor that uses the value.

### 1.5 — Migrate framework packages

- [x] Add PPX to `reventless-core/rescript.json`
- [x] Migrate `PluginSpec.res` → `@@reventless.spec("Plugin")`
- [x] Migrate `PluginBehavior.res` → `@@reventless.behavior(PluginSpec)`
- [x] Migrate `PluginReadModelSpec.res` → `@@reventless.spec("Plugin")`
- [x] Full build + test pass (252 framework tests)
- 7 Builder files have `moduleUrl` inside functor inner modules — can't be migrated
- 48 framework test fixtures define specs inside inner modules — can't be migrated
- [x] Add PPX to `reventless-in-memory/rescript.json` (no file-level specs to migrate, but enables future use)

---

## Phase 2: Auto-Annotate DCB Entity ID Fields

**Impact: 126+ `@s.matches(DcbTag.string)` annotations eliminated**

### 2.1 — Implement `*Id` field detection

- [x] In `DcbTagInference.ml`: when processing a `@@reventless.specModule` file, scan all `@schema`-annotated variant types
- [x] For each inline record constructor field: if field name ends with `Id` (case-sensitive) and type is `string`, inject `@s.matches(DcbTag.string)` attribute on the type expression
- [x] Ensure this runs BEFORE sury-ppx processes the `@schema` attribute (guaranteed by ppx-flags ordering)
- [x] Do NOT annotate if `@s.matches(...)` is already present (explicit overrides implicit)

### 2.2 — Snapshot tests

- [x] Test: `itemId: string` → auto-injected `@s.matches(Reventless.DcbTag.string)` (verified via DcbTag in JS output)
- [x] Test: `name: string` → untouched (doesn't end in `Id`) — verified by DcbTag count = 3 (import + 2 *Id fields)
- [x] Covered in Phase 0.3 test suite (DCB fixture package with @@reventless.dcbTags)

### 2.3 — Migrate DCB examples

- [x] Changed PPX to inject `Reventless.DcbTag.string` (fully qualified) instead of `DcbTag.string` — removes need for `open Reventless` just for DCB tags
- [x] Add PPX to all 5 online-shop-dcb packages (catalog-spec, catalog, ordering-spec, ordering, online-shop-dcb)
- [x] Migrate 8 catalog StateChangeSlice files + 8 ordering StateChangeSlice files to `@@reventless.spec` + `@@reventless.dcbTags`
- [x] Migrate 6 StateViewSlice files to `@@reventless.spec`
- [x] Migrate ImportProduct (InboundTranslationSlice) and AutoShipOrder (AutomationSlice) — removed manual `@s.matches`
- [x] Migrate SendOrderConfirmation (OutboundTranslationSlice) and EP spec files
- [x] ExtensionPointMapping files retain manual `@s.matches` (inner Delegate modules — PPX can't reach)
- [x] Plugin files retain inline `%raw` `moduleUrl` (functor-body usage)
- [x] Full build + test pass (80 DCB tests: 40 catalog + 40 ordering)

---

## Phase 3: Implicit `module Id = Id.String`

**Impact: 195+ lines eliminated**

### 3.1 — Implement auto-injection

- [x] When `@@reventless.specModule` is present and no `module Id` declaration exists in the file, inject `module Id = Reventless.Id.String` into the AST
- [x] If `module Id = ...` is already declared, skip injection (explicit overrides implicit)

### 3.2 — Tests

- [x] Covered in Phase 0.3 test suite: plugin package spec compiles with injected module Id
- [x] Covered: spec package without reventless-spec dependency skips module Id injection

### 3.3 — Migrate all specs

- [x] All migrated example spec files (aggregates, DCB slices) have module Id removed — PPX auto-injects
- [x] Full build + test pass (388 tests total)

---

## Phase 4: `@@reventless.spec("Name")` Header Macro

**Impact: ~780 lines eliminated (4 lines × 195 files)**

### 4.1 — Implement spec header generation

- [x] `@@reventless.spec("Category")` expands to:
  ```rescript
  open Reventless
  let name = "Category"
  module Id = Reventless.Id.String
  let moduleUrl: string = "computed-specifier"
  ```
- [x] `@@reventless.spec` (no argument) derives name from filename: `Category.res` → `"Category"`
- [x] Replaces the separate `@@reventless.specModule` attribute (superset)

### 4.2 — Implement behavior header generation

- [x] `@@reventless.behavior(Product)` expands to:
  ```rescript
  open Product
  module Spec = Product
  let moduleUrl: string = "computed-specifier"
  ```

### 4.3 — Namespace-based name derivation and unified `@@reventless.spec`

**Goal:** Eliminate `@@reventless.specModule` entirely. All spec files use `@@reventless.spec` with fully automatic name derivation — including extension point specs in standalone packages.

**Approach:** The PPX reads `rescript.json` to get the namespace, then derives the extension point name from the namespace + filename:

1. Read `rescript.json` from the same directory walk used for `package.json` (cache both)
2. Extract `"namespace"` field → strip `Spec` or `Plugin` suffix → plugin name
3. If namespace ends in `Spec` (i.e., this is a spec package), derive name as `{pluginName}.{entityName}`
4. Otherwise, derive name as `{entityName}` (current behavior)

**Examples:**
- `ProductsExtensionPoint.res` + namespace `CatalogSpec` → strip `Spec` → `"Catalog"`, filename → `"Products"` → name = `"Catalog.Products"`
- `OrdersExtensionPoint.res` + namespace `OrderingSpec` → `"Ordering.Orders"`
- `Category.res` + namespace `CatalogPlugin` → name = `"Category"` (unchanged)

**Resolve `module Id` injection:** Use Option C — PPX reads `rescript.json` dependencies (already reading the file for namespace). If `reventless-spec` is not a dependency, skip `module Id` injection. Zero developer friction, and the rescript.json read is already cached.

**Implementation steps:**
- [x] Add `find_rescript_json` to `ModuleUrl.ml` — walk up to find `rescript.json`, parse with Yojson, cache
- [x] Extract namespace and dependencies from cached rescript.json
- [x] In `ReventlessPpx.ml` Spec mode: if namespace ends in `"Spec"`, prefix derived name with plugin name + `"."`
- [x] In `ReventlessPpx.ml` Spec mode: only inject `module Id` when `reventless-spec` is in dependencies
- [x] Remove `SpecModule` mode — `@@reventless.spec` handles all cases
- [x] Migrate `ProductsExtensionPoint.res` and `OrdersExtensionPoint.res` from `@@reventless.specModule` to `@@reventless.spec`
- [x] Migrate `Order_EventMappings.res` and `Order_EmailNotification.res` from `@@reventless.specModule` to `@@reventless.spec`
- [x] Full build + test pass (56 tests across catalog + ordering)

### 4.4 — Tests

- [x] All covered in Phase 0.3 test suite (14 assertions):
  - Spec with explicit name, filename-derived name, ReadModel suffix stripping
  - Dotted name from *Spec namespace
  - Module Id skip for lightweight packages
  - Behavior open + module Spec injection
  - DCB tag auto-injection composing with spec annotation

### 4.5 — Migrate all specs and behaviors

- [x] All aggregate example specs migrated (catalog + ordering, both aggregate and DCB variants)
- [x] All behavior files migrated
- [x] All DCB StateChangeSlice, StateViewSlice, AutomationSlice, InboundTranslation, OutboundTranslation migrated
- [x] Framework admin specs migrated (PluginSpec, PluginBehavior, PluginReadModelSpec)
- [x] Full build + test pass (388 tests: 252 framework + 56 aggregate examples + 80 DCB examples)

---

## Phase 5: Projection Mappings Macro

**Impact: 120 lines eliminated (5-line blocks × 24 instances)**

**Blocker:** Projection modules are defined inside functor bodies (`module Make = (Platform) => { ... }`). File-level PPX annotations cannot inject code into functor bodies. Two possible approaches:

**Approach A — Extract projections to separate files:**
Move each projection module to its own file (e.g., `ProductProjections.res`). The file would use `@@reventless.spec` to get `moduleUrl`, and define the `Mappings` module directly. The plugin composition root would just reference it: `Platform.ReadModel.Make(ProductsReadModel, ProductProjections)`.

- Pro: Works with existing file-level PPX, cleaner separation
- Con: Architectural change — more files, changes how plugins are structured
- Con: All existing plugins would need restructuring

**Approach B — PPX enhancement for module-level attributes:**
Extend the PPX to detect and expand `@reventless.projections` on module bindings inside functors.

- Pro: No architectural change, works in place
- Con: Significantly more complex PPX (needs to walk into functor bodies, handle module expressions)

**Decision:** Implement Approach B — extend PPX to handle module-level attributes inside functor bodies.

### 5.1 — Design

The current boilerplate inside a functor-body projection module:

```rescript
module XProjections: Projection.Mappings with module Target := XReadModel = {
  module M = Projection.Mappings.Make(XReadModel)      // ← boilerplate
  module type Mapping = M.Mapping                       // ← boilerplate
  let moduleUrl = moduleUrl                             // ← boilerplate (or %raw)
  let mappings: array<module(Mapping)> = [module(...)]  // ← developer-authored
}
```

With `@reventless.projections`:

```rescript
@reventless.projections
module XProjections: Projection.Mappings with module Target := XReadModel = {
  let mappings = [module(XProjections.XMapping)]
}
```

The PPX detects `@reventless.projections` on any module binding (at any nesting depth), reads the `Target` from the module constraint, and injects:
1. `module M = Projection.Mappings.Make(Target)` (or `Reventless.Projection.Mappings.Make`)
2. `module type Mapping = M.Mapping`
3. `let moduleUrl: string = "<computed-specifier>"` (same computation as file-level)

The `mappings` binding type annotation changes from `array<module(Mapping)>` to `array<module(M.Mapping)>` since `Mapping` is now auto-generated and the developer sees `M.Mapping`.

**Implementation approach:** Add a recursive structure mapper in `ReventlessPpx.ml` that walks into all module expressions (Pmod_structure, Pmod_functor) and transforms module bindings with the `@reventless.projections` attribute.

### 5.2 — Implement `@reventless.projections` transformation

- [x] In `ReventlessPpx.ml`: add `transform_projections` — a recursive structure mapper that:
  - Walks `Pstr_module` items looking for `@reventless.projections` attribute
  - Extracts the `Target` module name from the module constraint (`with module Target := X`)
  - Strips the `@reventless.projections` attribute
  - Injects `module M`, `module type Mapping`, and `let moduleUrl` into the module body
  - Recursively walks into `Pmod_structure` and `Pmod_functor` to handle any nesting depth
- [x] In `ReventlessPpx.ml`: integrate into `transform` — apply the recursive mapper to the structure after existing transformations
- [x] Handle both patterns: `Projection.Mappings` (with `open Reventless.Projection`) and `Reventless.Projection.Mappings` (fully qualified)

### 5.3 — Tests

- [x] Add test case to `packages/reventless-ppx/test/run.sh`: projection module inside functor body with `@reventless.projections`
- [x] Verify: `module M`, `module type Mapping`, and `let moduleUrl` are injected (compilation proves it)
- [x] Verify: existing `let mappings` is preserved
- [x] Fix pre-existing DCB test failure (commonjs suffix mismatch with ESM sury) — all fixtures now use ESM
- [x] 16 assertions, all passing

### 5.4 — Migrate example plugins

- [x] Migrate `CatalogPlugin.res` — replace 3 projection module boilerplate blocks with `@reventless.projections`
- [x] Migrate `OrderingPlugin.res` — replace 3 projection module boilerplate blocks
- [x] OrderingPlugin retains top-level `let moduleUrl = %raw(...)` for EP inline module (not a projection)
- [x] Full build + test pass (935 tests, 0 warnings)

---

## Phase 6: DCB Shim and ReadModel Defaults

**Impact: ~120 lines eliminated**

### 6.1 — DCB extension point delegate shim

Unblocked by Phase 5's module-level PPX support. Extend the PPX to handle `@reventless.delegate` on module bindings inside `ExtensionPointMapping` files.

- [x] Implement `transform_delegate_module` — detects `@reventless.delegate` on any `Pstr_module`, injects:
  - `module Id = Reventless.Id.String`
  - `@schema type command = unit` (sury generates `commandSchema` from this)
  - dcbTags inference on `@schema type event` fields
  - `@schema type error = unit`
  - `let moduleUrl`
- [x] Extend `walk_structure` to handle `@reventless.delegate` alongside `@reventless.projections`
- [x] Add test fixture and 3 assertions (21 total, all passing)
- [x] Migrate `ProductsExtensionPointMapping.res` and `OrdersExtensionPointMapping.res`
- [x] Full build + test pass (935 tests, 0 warnings)

**Phase 6.1 follow-up (completed):**

- [x] `@@reventless.spec` already present on all ExtensionPointMapping files; `module Delegate` auto-detected via `is_spec` flag in `walk_structure` (no `@reventless.delegate` needed)
- [x] Auto-inject `open ReventlessInfra.ExtensionPointMapping` for `*ExtensionPointMapping.res` files — detected by filename via `is_extensionpointmapping_filename`; skipped if already present
- [x] Remove `open ReventlessInfra.ExtensionPointMapping` from all 4 EP mapping files (dcb + hybrid, catalog + ordering)
- [x] Add test fixture `ItemExtensionPointMapping.res` that uses `PublishEvent` without manual open; 2 new assertions (25 total, all passing)
- [x] Full build + test pass, 0 warnings

### 6.2 — ReadModel spec defaults

- [x] When `@@reventless.spec` is present and filename contains `ReadModel`, file has `@schema type state`, and no `let config`, auto-inject:
  ```rescript
  open Reventless.ReadModel
  let config = config()
  let subIdConfig = None
  ```
- [x] Skip if `let config` is already declared (explicit overrides implicit)
- [x] Migrate 7 ReadModel spec files (6 online-shop-aggregates + PluginReadModelSpec)
- [x] 18 PPX test assertions, all passing; 935 full tests passing

---

## Phase 7: Documentation and Guide Updates

- [x] Update `docs/guides/platform-and-plugin-guide.md` with PPX-based examples (aggregate spec, behavior, read model, EP spec, DCB StateChangeSlice sections)
- [x] Update `.claude/rules/app-developer.md` with PPX annotation reference
- [x] Update component docs in `packages/doc/docs-app/` to show PPX syntax (aggregate-based-plugin, dcb-based-plugin guides)
- [x] Add PPX installation and configuration section to getting started guide

---

## Phase 8: Auto-detect DCB Slices — eliminate `@@reventless.dcbTags` ✅

**Impact: Removes the `@@reventless.dcbTags` annotation from all `*Slice.res` spec files (~16+ files)**

### Motivation

Files named `*Slice.res` are always DCB slices. Requiring an explicit `@@reventless.dcbTags` alongside `@@reventless.spec` is redundant — the PPX already auto-infers ReadModel defaults from filename, and `"Slice"` is already in `component_suffixes`.

### Design

The reliable signal is not the filename but the **parent folder name** — every file needing dcbTags lives inside a folder whose name ends with `Slice`:

```
StateChangeSlice/AddProduct.res         ← needs dcbTags
StateViewSlice/ProductsView.res         ← needs dcbTags
AutomationSlice/AutoShipOrder.res       ← needs dcbTags
InboundTranslationSlice/ImportProduct.res ← needs dcbTags
OutboundTranslationSlice/SendOrderConfirmation.res ← needs dcbTags
```

This means files keep clean names (`AddProduct.res`, not `AddProductSlice.res`) and the folder structure carries the slice type. Test files inside those folders (`CategoryDecisionTest.res`) are safe — dcbTags only touches `@schema` variant types, which test files don't define.

Implementation: check whether any path segment of `Filename.dirname(pos_fname)` either ends with `"Slice"` OR matches a known slice base name (without the suffix). This lets teams use either `StateChangeSlice/` or `StateChange/` as their folder name.

```ocaml
let known_slice_bases = [
  "StateChange"; "StateView"; "Automation";
  "InboundTranslation"; "OutboundTranslation"
]

let ends_with_slice part =
  let len = String.length part in
  len >= 5 && String.sub part (len - 5) 5 = "Slice"

let is_slice_folder_segment part =
  ends_with_slice part || List.mem part known_slice_bases

let is_in_slice_folder fname =
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  List.exists is_slice_folder_segment parts
```

In the `Spec` branch of `transform`:

```ocaml
let dcb_tags = has_dcb_tags_attr str
               || Util.is_in_slice_folder loc.loc_start.pos_fname in
```

- `@@reventless.dcbTags` continues to work as an explicit opt-in for edge cases
- Files inside any `*Slice/` folder with `@@reventless.spec` get dcbTags automatically

### Implementation steps

- [x] Add `is_in_slice_folder` to `Util.ml` — checks if any dirname path segment ends with `"Slice"`
- [x] In `ReventlessPpx.ml` `transform`: change `dcb_tags` derivation to also check `is_in_slice_folder`
- [x] Remove `@@reventless.dcbTags` from all slice spec files in the DCB example packages
- [x] Add PPX test assertion: file inside `StateChangeSlice/` gets dcbTags without explicit annotation
- [x] Update `@@reventless.dcbTags` entry in the PPX annotations API section
- [x] Full build + test pass

---

## Phase 9: `*Id(s): array<string>` DCB Tag Annotation ✅

**Impact: Eliminates the last remaining manual `@s.matches` annotations on array-of-ID fields**

### Motivation

`@@reventless.dcbTags` only handled `*Id: string` (singular scalar). Array-of-entity-IDs fields
must still be annotated manually. Two patterns need coverage:

- `*Ids: array<string>` — plural name, multi-value storage (e.g. `tagIds`, `itemIds`)
- `*Id: array<string>` — singular name, multi-clause cross-entity query (e.g. `productId: array<string>` in `PlaceOrder` queries events stored under `productId` key by `SyncCatalogProduct`)

### Design

Extend `DcbTagInference.ml` to detect both patterns and inject `@s.matches(Reventless.DcbTag.string)` on the **inner element type** of the array:

```rescript
// Before (manual):
tagIds: array<@s.matches(Reventless.DcbTag.string) string>
productId: array<@s.matches(Reventless.DcbTag.string) string>

// After (PPX-generated, both forms):
tagIds: array<string>      // *Ids — plural suffix
productId: array<string>   // *Id with array<string> type
```

**Singular `*Id: array<string>` vs `*Ids: array<string>`:**
The DcbTag key is the field name. `productId: array<string>` produces per-element query clauses
`{key: "productId", value: element}`, matching events stored with the `productId` tag
(e.g. `CatalogProductSynced` from `SyncCatalogProduct`). Using `productIds` would look for a
different tag key and miss those events. Field naming must match the stored event's tag key.

**Auto-tagging suppression:** The heuristic tags all `*Id: string` fields, including payload-only
fields like `customerId` that are not DCB query keys. Use `@s.matches(S.string)` to suppress:
`customerId: @s.matches(S.string) string`. See `docs/analysis/dcb-tag-auto-tagging-suppression.md`
for a full analysis of options including a cleaner `@dcb.skip` opt-out (Option B).

The same extension applies inside `@reventless.delegate` module transforms (Phase 6.1).

### Implementation steps

- [x] In `DcbTagInference.ml`: add `ends_with_ids` predicate (`*Ids` suffix)
- [x] Extend `transform_label_decl` — if name ends with `*Ids` OR (`*Id` AND type is `array<string>`), inject annotation on inner element type; skip if already annotated
- [x] Apply via shared `transform_structure` (covers both dcbTags mode and delegate transforms)
- [x] Add PPX test assertions: `*Ids: array<string>` and `*Id: array<string>` in `StateChangeSlice/` folder both annotated
- [x] Update `@@reventless.dcbTags` entry in the PPX annotations API section
- [x] Full build (0 warnings, 0 errors) + test pass (935 Jest tests, 25 PPX integration tests)

---

## Summary

| Phase | Feature | Status | Lines Eliminated |
|---|---|---|---|
| 0.1 | Project scaffold | ✅ Done | — |
| 0.2 | CI cross-compilation | 🔶 Workflow created, needs verification | — |
| 0.3 | Test infrastructure | ✅ Done (25 assertions) | — |
| 1 | `moduleUrl` auto-injection | ✅ Done | 298 |
| 2 | DCB `*Id` auto-annotation | ✅ Done | 126+ |
| 3 | Implicit `module Id` | ✅ Done | 195 |
| 4 | Spec/Behavior header macros | ✅ Done | 780 |
| 5 | Projection Mappings macro | ✅ Done | 120 |
| 6.1 | DCB delegate shim + EP mapping `open` | ✅ Done | ~18 (4 files × ~2 lines each) |
| 6.2 | ReadModel spec defaults | ✅ Done | 21 (7×3 lines) |
| 7 | Documentation | 🔶 Partial (guide + rules updated) | — |
| 8 | Auto-detect slice folder → drop `@@reventless.dcbTags` | ✅ Done | ~16 annotations |
| 9 | `*Id(s): array<string>` DCB tag annotation | ✅ Done | ~few manual annotations |
| **Total done** | | **Phases 0–9, 7 (partial)** | **~1,570+ lines** |
| **Remaining** | | **Phases 0.2, 7 (docs site completion)** | — |

### Known limitations (cannot be PPX-migrated)
- `moduleUrl` for ExtensionPoint inline modules inside functor bodies (OrderingPlugin.res, CatalogPlugin.res) — requires top-level `%raw` captured by closure
- `moduleUrl` inside Builder framework files — PPX appends at file end, but value needed inside functor
- Test fixture specs defined as inner modules (`module AggSpec = { ... }`) — file-level PPX cannot inject into inner module bodies

### PPX annotations (final API)
- `@@reventless.spec` — auto-injects `let name`, `module Id`, `let moduleUrl`. Derives name from filename (strips component suffixes). In `*Spec` namespaces, prefixes with plugin name for dotted names. For `*ReadModel*` files with `@schema type state` and no `let config`, also auto-injects `open Reventless.ReadModel; let config = config(); let subIdConfig = None`. For `*ExtensionPointMapping*` files, auto-injects `open ReventlessInfra.ExtensionPointMapping` (brings `PublishEvent`, `PublishCommand`, `PublishEventAsync`, `Call` into scope). In `@@reventless.spec`-annotated files, any module named `Delegate` is auto-transformed (injects `module Id`, `@schema type command = unit`, dcbTags on `*Id`/`*Ids` event fields, `@schema type error = unit`, `let moduleUrl`).
- `@@reventless.spec("ExplicitName")` — same, but uses the provided name instead of deriving
- `@@reventless.behavior` — auto-injects `open Spec`, `module Spec = Spec`, `let moduleUrl`. Derives spec name from filename.
- `@@reventless.behavior(SpecName)` — same, but uses the provided spec module name
- `@@reventless.dcbTags` — explicit opt-in for DCB tag annotation outside slice folders. Auto-injects `@s.matches(Reventless.DcbTag.string)` on: `*Id: string` scalar fields; element types of `*Id: array<string>` fields (singular with array type, for cross-entity queries); element types of `*Ids: array<string>` fields (plural, for multi-value storage). Implicit for files inside `*Slice/` folders (Phase 8). To suppress auto-tagging on a specific `*Id` payload field that is not a DCB query key, use `@s.matches(S.string)` on the type expression. See `docs/analysis/dcb-tag-auto-tagging-suppression.md`.
- `@reventless.projections` — on module bindings inside functor bodies. Auto-injects `module M = Reventless.Projection.Mappings.Make(Target)`, `module type Mapping = M.Mapping`, and `let moduleUrl`. Extracts `Target` from the module constraint (`with module Target := X`). Works at any nesting depth.
- `@reventless.delegate` — explicit opt-in for `Delegate`-style transforms outside `*ExtensionPointMapping*` files. In `@@reventless.spec`-annotated `*ExtensionPointMapping*` files, `module Delegate` is auto-transformed without this attribute.
