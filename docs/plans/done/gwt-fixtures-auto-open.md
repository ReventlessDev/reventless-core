# Plan: `@@reventless.gwt` auto-opens the `<Stem>_Fixtures` companion module

**Status:** Completed (2026-04-24)
**Related:**
- `packages/reventless-ppx/src/ppx/GwtInference.ml` — the transformation this plan extends
- `packages/reventless-ppx/src/ppx/ModuleUrl.ml` — existing filesystem I/O in the PPX (package-scope lookup), the precedent for the filesystem check proposed here
- `docs/plans/done/gwt-external-spec-module.md` — the sibling plan that made `@@reventless.gwt` infer Kind and Spec from the path

---

## Goal

When a GWT test file `<Stem>_GWT.res` has a sibling `<Stem>_Fixtures.res` on disk, `@@reventless.gwt` auto-opens that fixtures module in the test body — in addition to the already-injected `open <Spec>`. When no sibling exists, the PPX behaves exactly as it does today.

```rescript
// tests/StateChange/AddCategory_GWT.res
@@reventless.gwt

describe("AddCategory StateChangeSlice", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(addCategoryElectronics)              // from AddCategory_Fixtures
    ->thenEvent((electronicsCategoryAdded :> event))  // from AddCategory_Fixtures
  )
})
```

The author writes no `open` in the test body. The existing `AddCategory_Fixtures.res` sibling is found on disk and auto-opened. Fixtures that `include` a shared-primitives module transitively expose their primitives through the same open.

---

## Current state

### What `@@reventless.gwt` injects today

`GwtInference.ml:transform` resolves `spec_name` from payload or filename stem, then assembles:

```
[open <Spec>; include <Kind>_GWT.Make(<Spec>)]
```

It anchors after the local `Pstr_module` binding for the spec when one exists, otherwise prepends at the top of the structure. It dedups the `open <Spec>` via `Util.has_open spec_name body` so author-written opens don't duplicate.

### Why a companion `_Fixtures` module is the missing piece

GWT tests for non-trivial specs accumulate repeated identity strings, event/command payloads, and expected state records. The natural extraction is a sibling `<Stem>_Fixtures.res` that opens the spec module, constructs qualified command/event/state fixture values, and re-exports shared primitives via `include`. Each GWT test then `open`s that companion to use the fixtures unqualified.

That `open <Stem>_Fixtures` is deterministic from the file's path — the PPX already knows `spec_name` (≡ the filename stem minus `_GWT`), so the companion name is mechanically derivable. Authors currently write it by hand in every GWT test file. The PPX should inject it.

### Precedent for filesystem I/O in the PPX

`ModuleUrl.find_package_for loc` walks the directory tree from `loc.pos_fname` looking for `package.json`, and `GwtInference.is_in_gwt_package` uses that to decide whether to prefix with the `ReventlessGwt` namespace. The PPX is already comfortable reading the filesystem during transformation — a sibling-file `Sys.file_exists` check fits the existing shape.

---

## Target behaviour

For a file at `<dir>/<stem>_GWT.res` (with `<stem>` the portion before the final `_GWT`):

1. Compute `fixtures_name = <stem> ^ "_Fixtures"` — e.g. `AddCategory_GWT` → `AddCategory_Fixtures`.
2. Check whether `<dir>/<fixtures_name>.res` exists.
3. If it exists **and** the test body does not already contain `open <fixtures_name>` (dedup via `Util.has_open`), emit `open <fixtures_name>` immediately after `open <Spec>` in `injection_items`.
4. If it does not exist, no change from today.

The emission order becomes:

```
[open <Spec>; open <Stem>_Fixtures; include <Kind>_GWT.Make(<Spec>)]
```

`<Stem>_Fixtures` is opened **after** `<Spec>`, so any binding defined in the fixtures module shadows a same-named binding from the spec module. This is the right order: authors write fixtures specifically to name things at call sites, and should be able to shadow spec-level identifiers without surprise.

### Resolution details

- **`<stem>` derivation.** For `Empty` / `One` / `Two` payload cases, `<stem>` is the filename stem of `attr_loc.loc_start.pos_fname` with a trailing `_GWT` / `GwtTest` / `Gwt` suffix stripped (the same logic that feeds `Util.spec_name_from_gwt_filename`). This keeps the fixtures-companion rule path-driven, independent of whether the Spec is resolved from the local structure or from an explicit payload.
- **Behavior DSL.** For the two-module form (`@@reventless.gwt(Spec, Behavior)`), the fixtures companion is still `<Stem>_Fixtures` — the filename stem, not the Spec module name. Consistent with the single-module rule.
- **Explicit-payload external Spec.** When the author writes `@@reventless.gwt(OtherModuleName)`, the spec is resolved externally but the fixtures companion is still derived from the filename stem. Rationale: the companion lives next to the test file, not next to the external spec.

---

## Implementation sketch

`GwtInference.ml` gains one helper and a couple of lines in `transform`:

```ocaml
(** Detect a companion [<Stem>_Fixtures.res] next to the GWT file.
    Returns the module name if the sibling file exists, else [None]. *)
let companion_fixtures_module (fname : string) : string option =
  match Util.spec_stem_from_gwt_filename fname with
  | None -> None
  | Some stem ->
    let dir = Filename.dirname fname in
    let candidate_module = stem ^ "_Fixtures" in
    let candidate_file = Filename.concat dir (candidate_module ^ ".res") in
    if Sys.file_exists candidate_file then Some candidate_module else None
```

(`Util.spec_stem_from_gwt_filename` likely already exists as the helper underlying `spec_name_from_gwt_filename`; if not, extract it.)

In `transform`, after the existing `open_item = gen_open ~loc:attr_loc spec_name`:

```ocaml
let fixtures_open =
  match companion_fixtures_module fname with
  | Some name when not (Util.has_open name body) ->
    [gen_open ~loc:attr_loc name]
  | _ -> []
in
let injection_items =
  (if Util.has_open spec_name body then [] else [open_item])
  @ fixtures_open
  @ [include_item]
in
```

Order matters: `open <Spec>` first, then `open <Stem>_Fixtures`, then the `include`. This preserves the current semantics (Spec visible) and adds fixture-module bindings that can shadow Spec-level names when authors intend it.

---

## Tests

Add snapshot tests to `packages/reventless-ppx/tests` parallel to the existing GWT inference tests:

1. **Companion present, no manual open.** Fixture directory contains `<Stem>_GWT.res` with `@@reventless.gwt` and a sibling `<Stem>_Fixtures.res`. Expected output: injection includes `open <Stem>; open <Stem>_Fixtures; include …`.
2. **Companion present, manual open.** Test body already contains `open <Stem>_Fixtures`. Expected output: no duplicate — the manual open stays, the PPX skips.
3. **Companion absent.** No sibling fixtures file. Expected output: unchanged from today (`open <Stem>; include …`).
4. **Explicit one-module payload with companion.** `@@reventless.gwt(OtherSpec)` on `AddCategory_GWT.res` with a sibling `AddCategory_Fixtures.res`. Expected output: `open OtherSpec; open AddCategory_Fixtures; include …`.
5. **Behavior DSL with companion.** `@@reventless.gwt(Spec, Behavior)` on a file with a companion fixtures module. Expected output: `open Spec; open <Stem>_Fixtures; include Behavior_GWT.Make(Spec)(Behavior)`.

The snapshot fixtures need real files on disk (the PPX does `Sys.file_exists`), so the test runner must stage them in a temp dir or a checked-in `tests/fixtures/gwt-fixtures-auto-open/` tree.

---

## Guide updates

- `docs/guides/given-when-then.md` — document the companion-fixtures convention: "If a sibling `<Stem>_Fixtures.res` exists next to `<Stem>_GWT.res`, the PPX opens it automatically. The convention lets fixture-heavy suites collapse to a single `@@reventless.gwt` line with no manual opens."
- Mention that a shared-primitives module (e.g. a test-wide `TestFixtures.res` used across specs) can be surfaced through the auto-open by having each `<Stem>_Fixtures.res` `include` it.

---

## Migration / backward compatibility

Fully additive. Existing GWT files without a companion fixtures file see no behavioural change. Existing GWT files that already write `open <Stem>_Fixtures` manually get deduped by the same `Util.has_open` check that already handles the spec open — their source remains valid and produces identical output.

No changes to attribute syntax, no payload additions, no new kinds.

---

## Out of scope

- **Re-export of `open DeploymentTypes` / other spec-adjacent modules.** GWT tests that reference variant constructors from modules beyond the Spec (e.g. a shared types module) still need an explicit `open` in the test body. The auto-open is scoped to the companion fixtures module.
- **Auto-opening companions named other than `_Fixtures`** (e.g. `_Helpers`, `_Builders`). A single companion naming rule keeps the PPX's filesystem behaviour minimal; other shapes can be revisited if demand emerges.
