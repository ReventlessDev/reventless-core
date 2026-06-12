# Plan: Component Visibility Annotations ✅ DONE

Implements the design in a downstream consumer analysis (`analysis/component-visibility-and-metadata-annotations.md`).

**Goal.** Add a file-level `@@reventless.visibility(...)` PPX attribute to ReadModel and StateViewSlice specs that controls whether the component appears in the AutoUI manifest. Ship as a variant from day one (not a bool) to keep future cases backwards-compatible.

**v1 scope.** Two cases — `Public` (default) and `Internal` (hidden from the AutoUI manifest only). GraphQL exposure, `pluginStructure.queryableDef`, authorization, and resolver provisioning are all left untouched.

**Predecessor.** Field-level pipeline established in [done/autoui-schema-annotations.md](done/autoui-schema-annotations.md). This plan reuses the same PPX → metadata → `x-reventless-*` extension property pattern, but extends it to component-level filtering inside `makeAutoUIManifest` instead of just field-level rendering hints.

**Outcome.** Shipped all 4 phases. PPX integration test count went from 184 → 194 (+10 tests covering default Public, explicit Internal, attribute stripping, error on wrong file kind, JSON-Schema metadata threading). Jest test count went from 1092 → 1097 (+5 in new `ManifestVisibilityTest.res`). Full reventless-core SuryToJsonSchema suite went from 18 → 20 tests. Zero warnings. Linux PPX rebuilt via Docker.

---

## Architectural choices (fixed before implementation)

| Question | Decision | Rationale |
|---|---|---|
| Bool or variant? | **Variant `Public \| Internal`** | Migration to `bool → variant` later is breaking; variant→more-cases is additive. Detailed in the analysis doc. |
| Where does the metadata live? | On `ReadModel.config` and `StateViewSlice.Spec` as `visibility: visibility` | Same shape as the existing `authorization` field; PPX-injected with a default. |
| Where does the new type live? | `Reventless.Visibility` in `reventless-spec/src/components/Visibility.res` | New module; mirrors `Reventless.Authorization`. Keeps the type, encoder, and stringifier together. |
| Where is the filter applied? | `Plugin_Builder.makeAutoUIManifest` (lines 751-794) | Single chokepoint; the components themselves are still built, still have resolvers, still appear in GraphQL. |
| Does the JSON Schema carry `x-reventless-visibility`? | **Yes**, even though AutoUI uses the config field directly | Lets external consumers (host shell, docs generators, dashboards) see the flag without re-running ReScript codegen. Consistent with the field-level pipeline. |
| Does the attribute also work on Aggregates? | **No in v1.** Leave the type general enough to adopt. | Scope discipline — prove the read-model case first. |

---

## Phase 1 — Add `Reventless.Visibility` type and PPX recognition ✅ DONE

**Goal.** Establish the type and authoring surface. No filtering yet — components carry the flag through to the manifest, but the manifest still ignores it.

### 1.1 Define the type

**New file:** `reventless/reventless-spec/src/components/Visibility.res`

```rescript
@@reventless.spec    // no — this is a framework type, not a spec; skip the attribute

@schema
type visibility =
  | Public
  | Internal

let toString = (v: visibility) => switch v {
  | Public => "Public"
  | Internal => "Internal"
}

let default = Public
```

`@schema` is required so the value can be encoded into the JSON Schema metadata pipeline alongside other annotations.

### 1.2 Add `visibility` field to ReadModel.config and StateViewSlice.Spec

**File:** `reventless/reventless-spec/src/components/ReadModel.res`

Add to the `config<...>` record (next to `authorization`):

```rescript
visibility: Visibility.visibility,
```

Update the `config()` constructor (factory) to default-inject `Visibility.default` (= `Public`).

**File:** `reventless/reventless-spec/src/components/StateViewSlice.res`

Same change. Mirror in `StateViewSliceStream.res`.

### 1.3 PPX recognition

**File:** `packages/reventless-ppx/src/ppx/VisibilityInjection.ml` (new) — mirrors `AuthorizationInjection.ml`.

- Recognise file-level `@@reventless.visibility(Public)` and `@@reventless.visibility(Internal)`.
- On QueryCarrier-kind files (ReadModel, StateViewSlice, StateViewSliceStream), splice the visibility into the auto-injected `let config = config(...)` call.
- Default when no attribute present: `Public`.
- Error if the attribute appears on a non-QueryCarrier file (Aggregate, Slice, Extension, etc.) with a clear message: "@@reventless.visibility is only supported on ReadModel and StateViewSlice files".

**Wire-up:** Add to `ReventlessPpx.ml` after the existing `AuthorizationInjection` pass.

### 1.4 Tests

**PPX integration test** (`packages/reventless-ppx/test/run.sh`):
- `VisibilityPublicReadModel.res` — no attribute → compiled output contains `visibility: Visibility.Public`.
- `VisibilityInternalReadModel.res` — `@@reventless.visibility(Internal)` → compiled output contains `visibility: Visibility.Internal`.
- `VisibilityInternalStateViewSlice.res` — same on a StateViewSlice.
- `VisibilityOnAggregate.res` — negative test, expects compile error.

**Unit test** (new in `reventless/reventless-core/tests/`):
- `VisibilityTest.res` — `toString` mapping, `default` value.

**Definition of done:**
- New `.res.mjs` files in compiled output show `visibility: Visibility.Internal` for annotated files.
- All existing ReadModel/StateViewSlice files compile unchanged (default = Public).
- Zero new warnings.

---

## Phase 2 — Filter the AutoUI manifest ✅ DONE

**Depends on:** Phase 1 (the field exists and is reachable via `R.Spec.visibility`).

**Goal.** Skip ReadModels and StateViewSlices marked `Internal` when assembling the manifest's panels and pages.

### 2.1 Update `makeAutoUIManifest`

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res`

At lines 751-794, before mapping `readModels` to `panelManifestEntry` / `pageManifestEntry`, filter:

```rescript
let visibleReadModels = readModels->Array.filter(module(R: ...) =>
  switch R.config.visibility {
  | Public => true
  | Internal => false
  }
)
```

Use `visibleReadModels` in the existing `Array.map` calls. Mirror for StateViewSlices wherever they enter the manifest.

### 2.2 Tests

**Integration test** (extend an existing builder test or add new):
- A test plugin with two ReadModels — one Public, one Internal.
- Assert the rendered manifest's `panels` array contains exactly one entry, matching the Public ReadModel's name.
- Assert `pages` array is also length 1.
- Assert the Internal ReadModel's resolver / GraphQL fragment / queryableDef entry **is still present** (sanity-check that we didn't over-filter).

**Definition of done:**
- Manifest excludes Internal components.
- All other plugin outputs (resolvers, GraphQL schema, event graph) are unaffected — verified by test assertions.
- Full reventless-core test suite green; zero warnings.

---

## Phase 3 — Emit `x-reventless-visibility` in JSON Schema ✅ DONE

**Depends on:** Phase 1.

**Goal.** Surface the flag in the generated JSON Schema so external consumers (host shell, docs generator, dashboards) can read it without re-running ReScript codegen.

### 3.1 Extend `StateAnnotations` metadata

**File:** `reventless/reventless-spec/src/components/StateAnnotations.res`

Add `visibility: string` (the result of `Visibility.toString`) to the `stateAnnotationSpec` record. Default `"Public"`.

### 3.2 Update PPX to write the metadata

**File:** `packages/reventless-ppx/src/ppx/StateAnnotations.ml`

When generating the `stateSchema->S.Metadata.set(...)` binding, read the visibility from the same file-level attribute as Phase 1 and include `~visibility:"Internal"` or `"Public"`. (Read from the AST, not from `R.config.visibility` — the PPX runs before module type-checking.)

### 3.3 Update `SuryToJsonSchema`

**File:** `reventless/reventless-core/src/components/Api/SuryToJsonSchema.res`

In `deriveObjectSchema`, emit a top-level `"x-reventless-visibility": "Internal"` on the schema object when the metadata's visibility ≠ `"Public"`. (Skip the property for the default case to keep schemas compact.)

### 3.4 Tests

**PPX integration test:** `VisibilityInternalReadModel.res` compiled output's metadata contains `visibility: "Internal"`.

**Unit test** (`reventless/reventless-core/tests/api/SuryToJsonSchemaTest.res`):
- Internal ReadModel → schema contains `"x-reventless-visibility": "Internal"`.
- Public ReadModel → schema **does not** contain the property (default omitted).

**Definition of done:**
- `x-reventless-visibility` appears in JSON Schema output for Internal components.
- Absent for Public (the default).
- Zero warnings.

---

## Phase 4 — Documentation and example adoption ✅ DONE

**Depends on:** Phases 1-3 shipped.

### 4.1 Update conventions doc

**File:** `.claude/rules/app-developer.md` — PPX Annotations / File-level section.

Add:

```
- `@@reventless.visibility(Public | Internal)` — controls whether the component appears in the AutoUI manifest. Default `Public`. `Internal` hides from the menu but leaves GraphQL exposure, authorization, and resolver provisioning untouched. Valid on ReadModel and StateViewSlice files only.
```

### 4.2 Update docusaurus docs

**File:** `packages/doc/docs/reventless-components/readmodel.md` (and `statevweslice.md`).

Add a short "Visibility" subsection with an example.

### 4.3 Convert at least one example to use `Internal`

Find a helper ReadModel in `examples/online-shop-aggregates/` or `examples/online-shop-dcb/` that exists purely for lookups (candidate: anything used as `@resolves` target but not user-facing). Add `@@reventless.visibility(Internal)`. Verify in the in-memory AutoUI that it disappears from the menu.

If no clear candidate exists, skip the example change and note in the plan.

### 4.4 Tests

GWT test for the converted example (if any) — assert the manifest output excludes that ReadModel.

**Definition of done:**
- Conventions doc updated.
- Docusaurus has a "Visibility" section per component.
- Example demonstrates real-world use (or noted as no good candidate).

---

## Out of scope (future work, do NOT do here)

- **Aggregate-level visibility.** Mechanism generalises; defer until ReadModel case proves out.
- **`UnlistedInAutoUI` / `InternalToPlatform` / `InternalToPlugin` / `Hidden` cases.** Variant is extensible — add when there's a concrete use case.
- **GraphQL schema filtering.** Internal components remain queryable; treat visibility as a UX hint, not a boundary.
- **Folder-level defaults in `plugin.json`.** Could halve the annotation count for StateViewSlice-heavy plugins, but needs its own design pass.
- **Other metadata annotations** (`@@reventless.title`, `@@reventless.description`, `@@reventless.deprecated`, `@@reventless.owner`). Each deserves its own plan once the visibility surface lands as precedent.

---

## Risks

| Risk | Mitigation |
|---|---|
| PPX binary rebuild required on macOS + Linux for both `ppx-darwin.exe` and `ppx-linux.exe` | Per [feedback_ppx_linux_rebuild.md](memory) — run macOS `pnpm run build:ppx` + Linux docker build; commit both binaries. |
| `@res.optional` field synthesis pitfalls when injecting `visibility` field | Per [feedback_ppx_optional_fields.md](memory) — use `Location.none` for pld/type/attr on synthesised fields. Visibility is non-optional with a default so this should not apply, but watch for it if we add an option-typed metadata field later. |
| Filter applied at wrong layer (e.g., breaking the GraphQL schema) | Tests in Phase 2 explicitly assert that GraphQL / resolvers / queryableDef are untouched. |
| Variant addition breaks existing pattern matches in user code | Visibility variant is internal framework type; users only reference constructors by name (`Public`, `Internal`). Adding cases later only breaks code that explicitly switches on visibility — unlikely in app code. |

---

## Execution order

1. Phase 1 — type + PPX + config field. Land first; everything else builds on this.
2. Phase 2 — manifest filter. Delivers user-visible value.
3. Phase 3 — JSON Schema export. Unblocks external consumers.
4. Phase 4 — docs + example adoption. Closes the loop.

Each phase is independently testable and shippable; review after each.

---

## Implementation notes

**Pivot 1: visibility lives on `Spec`, not on `config`.** The plan called for adding `visibility` to `ReadModel.config`. In practice the existing `authorization` field is a top-level binding on the `Spec` module type, not inside the `config` record. To stay consistent (and because `R.Spec.visibility` is the natural access pattern in `makeAutoUIManifest`), the field was added directly to `ReadModel.Spec` and `StateViewSlice.Spec` — mirroring `authorization` exactly. No `config` change.

**Pivot 2: file-level `@@reventless.visibility` is rejected on command-carrying files.** Originally planned as a warning; landed as a hard error via `Location.raise_errorf` (`[reventless-ppx] @@reventless.visibility is only supported on ReadModel and StateViewSlice spec files.`). OCaml `Format`-printer footgun: the literal `@@` in the error message renders as a single `@`, so the source uses `@@@@reventless.visibility` to produce `@@` in the output.

**Pivot 3: manual `let visibility` required for inline specs nested in function bodies.** The PPX `walk_inline_specs` is a single-level scan (mirrors the auth pattern). Five framework files had to add a manual `let visibility: Reventless.Visibility.t = Public` next to their existing manual `let authorization`:

- `reventless/reventless-core/src/components/Counter/Counter_Builder.res` (×2)
- `reventless/reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res`
- `reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res`
- `reventless/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res`
- `reventless/reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res`
- `reventless/reventless-in-memory/tests/adapter/QueryDbListResolverTest.res`

This is now documented in `.claude/rules/app-developer.md`.

**Pivot 4: visibility metadata co-located with `stateAnnotationSpec`.** Considered a separate sury metadata ID for visibility but reused the existing `stateAnnotationSpec` record (added `visibility: option<string>`). Same lineage as the field-level annotations and the `status: option<string>` component-level field already on the spec — single metadata channel, simpler downstream consumers.

**Pivot 5: JSON Schema emission at top level, not on a field.** `mergeAnnotations` operates per-field; visibility is component-level. Added the emission in `deriveObjectSchema` after `objectRefToJsonSchema` returns, patching the resulting JSON object. Default (`Public` → metadata `None`) is omitted entirely so unannotated schemas stay byte-for-byte compatible.

**Pivot 6: example adoption is `AvailableProducts` in `examples/online-shop-aggregates/ordering`.** It's a denormalised mirror of the Catalog's `Products` view kept inside Ordering for lookup performance — the user-facing list lives in Catalog. Cleanest "internal" semantics in the example set.

**ReScript incremental-build gotcha.** Rebuilding the PPX binary doesn't trigger downstream `.res` recompilation — ReScript only re-runs the PPX when the source file changes. Required a one-shot `find . -name lib -type d | xargs rm -rf` after the PPX update to force every consumer to re-run the new PPX. Worth documenting if the PPX surface keeps evolving.

**Follow-up fix: also filter `Plugin_Structure`.** Initial implementation only filtered `makeAutoUIManifest`. The local in-memory UI menu turned out to be driven by `Platform_UIDefinitions` → `pluginStructure.readModels` (via `RegisterFragments.res`'s `AutoUI.generateFragments`), **not** the `uiFragmentManifest` (which is only used to override federation entries). `AvailableProducts` still appeared in the dev console menu until the filter was also applied at `Plugin_Structure.readModelDefs` and `stateViewDefs`. Internal entries are now omitted from `pluginStructure` entirely — hiding them from the menu, drill-down pages, and the AutoUI event graph. GraphQL schema fragments are built independently of `pluginStructure` so cross-plugin queries to Internal targets still resolve. Three new assertions in `ManifestVisibilityTest.res` (`Plugin_Structure.make — visibility filter`) cover the regression: 1102 tests pass (was 1099).
