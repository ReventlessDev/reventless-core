# Plan: `@@reventless.gwt` in `{SpecModule}_GWT.res` infers everything from the path

**Status:** Completed (2026-04-24)
**Related:**
- `packages/reventless-ppx/src/ppx/GwtInference.ml` — the transformation this plan changes
- `packages/reventless-ppx/src/ppx/Util.ml` — existing path vocabulary shared with `@@reventless.spec`
- `packages/reventless-ppx/src/ppx/ReventlessPpx.ml` — how `@@reventless.spec` classifies paths / derives spec names today
- `docs/guides/given-when-then.md` — guide section to update

---

## Goal

Let a bare `@@reventless.gwt` in `tests/<SliceFolder>/<SpecModule>_GWT.res` resolve Kind **and** Spec automatically, the way `@@reventless.spec` already resolves its side of the story for production slice files. Zero payload. Zero local module bindings. Zero explicit kinds.

```rescript
// tests/StateChange/AddCategory_GWT.res
@@reventless.gwt

describe("AddCategory StateChangeSlice", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"})))
})
```

The PPX resolves all three things from the path:

| What | How |
|---|---|
| **Kind** | Folder segment "StateChange" ∈ `Util.known_slice_bases` → `StateChangeSlice`. (Also matches the existing `*Slice`-suffixed long form like `StateChangeSlices`.) |
| **Spec module** | Filename stem `AddCategory_GWT` with `_GWT` stripped → `AddCategory`. Treated as an external module reference. |
| **Constructors in scope** | PPX injects `open AddCategory` before the `include`, so `AddCategory(...)` / `CategoryAdded(...)` / `initialState` / state field names read unqualified. |

---

## Current state

### What `@@reventless.gwt` does today

`GwtInference.ml` is self-contained and naive:

1. Kind is a substring match of the filename or any folder segment against a hard-coded list of **full** kind names:
   ```ocaml
   let kinds_longest_first = [
     "OutboundTranslationSlice"; "InboundTranslationSlice";
     "StateChangeSlice"; "AutomationSlice"; "StateViewSlice";
     "Projection"; "Behavior";
   ]
   ```
   Substring-matches `StateChangeSlice` but **not** `StateChange`, so `src/StateChange/` is invisible to this check.
2. Spec resolution: with empty payload, the first top-level `Pstr_module` in the file becomes the Spec. With `One` payload, the PPX calls `find_module_index` on the local structure and **fails** if the named module isn't a local binding. External-module references are rejected with `"spec module X not found at top level"`.
3. No `open` is emitted. Inline tests get away with unqualified constructors because ReScript resolves them off the expected type of `whenCmd` / `thenEvent`. State record field names and `Spec.initialState` still read qualified.

### What `@@reventless.spec` already does right (and GWT should reuse)

`Util.ml` has a much richer path vocabulary that GWT should adopt:

```ocaml
let known_slice_bases = [
  "StateChange"; "StateView"; "Automation";
  "InboundTranslation"; "OutboundTranslation"
]

let ends_with_slice part =
  len >= 5 && String.sub part (len - 5) 5 = "Slice"

let is_slice_folder_segment part =
  ends_with_slice part || List.mem part known_slice_bases
```

And `filename_to_name` in the same file already strips slice/view/spec/etc. suffixes to derive a clean entity name from a filename. `@@reventless.spec` uses this to infer its `let name = "AddCategory"` binding from the source file path.

The asymmetry is the whole problem: production code lives at `src/StateChange/AddCategory.res` and `@@reventless.spec` understands that path; the matching test at `tests/StateChange/AddCategory_GWT.res` exists on the same axis but `@@reventless.gwt` can't read it.

---

## Target behaviour

| Form | Emits |
|---|---|
| `@@reventless.gwt` at top of `{SpecModule}_GWT.res` in a slice folder | Kind + Spec derived from path; `open <Spec>` + `include <Kind>_GWT.Make(<Spec>)` injected at the attribute's position |
| `@@reventless.gwt` in a file that has a local spec module | Existing behaviour: first top-level module is the Spec; `open` + include after it |
| `@@reventless.gwt(ExplicitSpec)` | Kind from path; Spec from payload; PPX does **not** require `ExplicitSpec` to be a local binding — compiler resolves it |
| `@@reventless.gwt(Spec, Behavior)` in a `Behavior` folder | Unchanged (two-module Behavior DSL) |

Resolution order at the PPX:

1. Derive Kind from path (new vocabulary — see Stage 1).
2. If payload carries a Spec name, use it directly.
3. Else if there's a local `Pstr_module` at the top level, use its name as the Spec.
4. Else derive Spec from the filename (strip `_GWT` / `GwtTest` / `Gwt` suffix → the remainder).
5. Emit `open <Spec>` immediately before the generated `include`.

No explicit-Kind payload form is needed. The existing path-driven approach handles every real case once the vocabulary matches `@@reventless.spec`.

---

## Stage 1 — Share the path vocabulary with `@@reventless.spec`

Move the Kind-from-path helper into `Util.ml` alongside `known_slice_bases`, and call it from `GwtInference.ml`.

New helper in `Util.ml`:

```ocaml
(* Full Kind name for a given folder segment, or None if the segment
   doesn't correspond to any DSL kind. *)
let dsl_kind_of_folder_segment part : string option =
  (* Short slice-base form ("StateChange" → "StateChangeSlice") *)
  if List.mem part known_slice_bases then Some (part ^ "Slice")
  (* Long slice form ends with "Slice" or "Slices" *)
  else if ends_with_slice part then Some part
  else if ends_with_slice_plural part then Some (strip_trailing_s part)
  (* Non-slice kinds *)
  else if contains_substring part "Projection" then Some "Projection"
  else if contains_substring part "Behavior" then Some "Behavior"
  else None

let derive_gwt_kind fname : string option =
  let dir_parts = String.split_on_char '/' (Filename.dirname fname) in
  let file_stem = basename_without_ext fname in
  (* Scan folder segments innermost-first (closest-to-file wins), so a
     path like `tests/StateChange/Migrations/StateView/X_GWT.res` classifies
     as StateView rather than StateChange. The immediate folder is a
     better signal of what a test is about than an outer organisational
     ancestor. Falls back to the filename stem only when no folder
     segment matches. *)
  let from_folder =
    List.find_map dsl_kind_of_folder_segment (List.rev dir_parts)
  in
  match from_folder with
  | Some _ as k -> k
  | None -> dsl_kind_of_folder_segment file_stem
```

Every folder segment in the full path is considered, not just the immediate parent — so a deeply nested test like `reventless/platform-inspector/tests/StateChange/Categories/AddCategory_GWT.res` resolves as long as any segment (here `StateChange`) matches the vocabulary.

**Ambiguity policy — innermost wins.** When multiple segments of the path match slice-base names (e.g. `tests/StateChange/Migrations/StateView/X_GWT.res` contains both `StateChange` and `StateView`), the closer-to-file segment is chosen. Rationale: the test's immediate folder is a more specific signal of the test's subject than an outer organisational ancestor, and this matches how developers intuitively read the path ("this test is in the StateView folder, so it's a StateView test"). The rare case where the heuristic gets it wrong is handled by the explicit `@@reventless.gwt(Spec)` payload — pass the Spec whose Kind the path doesn't imply, and combine with a payload-aware Kind override if the explicit form proves insufficient in practice (Stage 6 escape hatch, not shipped initially).

`GwtInference.ml`:

- Delete `kinds_longest_first` and the inline substring loop; call `Util.derive_gwt_kind` instead.
- Error message on failure lists both forms ("folder `StateChange` / `StateChangeSlice` / `StateChangeSlices`, or a filename containing one of those").

Kind inference is now identical whether the file is `tests/StateChange/X_GWT.res`, `tests/StateChangeSlices/X_GWT.res`, or `tests/StateChangeSliceGwtTest.res`.

---

## Stage 2 — Infer Spec from the filename when there's no local binding

`GwtInference.ml`: when payload is `Empty` and no local `Pstr_module` exists, derive the Spec name from the filename.

Add to `Util.ml`:

```ocaml
let gwt_test_suffixes = ["_GWT"; "GwtTest"; "Gwt"]

(* Strip one of the GWT-test suffixes from the filename stem; result is
   the external Spec module name the PPX should reference. *)
let spec_name_from_gwt_filename fname : string option =
  let stem = basename_without_ext fname in
  let rec try_suffixes = function
    | [] -> None
    | s :: rest ->
      let stripped = strip_suffix stem s in
      if not (String.equal stripped stem) && String.length stripped > 0
      then Some stripped
      else try_suffixes rest
  in
  try_suffixes gwt_test_suffixes
```

`GwtInference.transform`:

```ocaml
let (spec_name, behavior_name_opt, spec_is_external) =
  match payload, kind, find_first_top_modules 2 body with
  | Two (s, b), "Behavior", _ -> (s, Some b, false)
  | Two _, _, _ -> error "two-module payload only for Behavior"
  | One s, "Behavior", _ -> error "Behavior DSL needs (Spec, Behavior)"
  | One s, _, _ ->
    (* External Spec — do NOT require local binding. *)
    (s, None, true)
  | Empty, "Behavior", [s; b] -> (s, Some b, false)
  | Empty, "Behavior", _ -> error "Behavior DSL needs two top-level modules"
  | Empty, _, [s] -> (s, None, false)
  | Empty, _, _ ->
    (* No local module; derive from filename. *)
    (match Util.spec_name_from_gwt_filename fname with
     | Some name -> (name, None, true)
     | None -> error "no local module and cannot derive Spec name from filename")
```

Injection point:

- **Local Spec** (`spec_is_external = false`): keep existing behaviour — insert `open` + `include` directly after the local spec module (or after Behavior, for Behavior DSLs).
- **External Spec** (`spec_is_external = true`): insert `open` + `include` at the attribute's position in the stripped structure (i.e., the very top, since `@@...` attributes live at file top by convention).

The compiler validates the module reference at the emitted `include` site. Failure surfaces as a standard "Unbound module X" error, which is more actionable than a PPX-specific string.

Drop the three `Location.raise_errorf` messages that exist only to enforce the old local-binding rule.

---

## Stage 3 — Auto-inject `open Spec`

Before the `include`, emit:

```ocaml
Pstr_open { popen_expr = Pmod_ident { txt = Lident spec_name; loc };
            popen_override = Fresh; popen_loc = loc; popen_attributes = [] }
```

Applies to all forms (Empty / One / Two — in the Two case we `open Spec`, not `open Behavior`, to avoid shadowing `decide`/`evolve` with Behavior's versions).

Inline tests that already work today keep working: opening the spec module a second time doesn't shadow local bindings inside `describe`/`test` bodies, and the Spec module's top-level values are the same ones the test already used qualified.

---

## Stage 4 — Update `docs/guides/given-when-then.md`

Revise:

- **§ 2 "Getting set up"** — show the canonical consumer pattern as the *default*: `@@reventless.gwt` at the top of `{SpecModule}_GWT.res` in a slice folder, no payload, no alias. Move the explicit-payload forms to an "advanced" subsection. Drop the `#Kind` form from earlier drafts — it is no longer needed.
- **New § 4.10 "Testing external slice modules (the consumer pattern)"** — worked example: one `_GWT.res` per production slice; path + filename do the work. Call out that `open` is auto-injected so constructors/fields/`initialState` are unqualified.
- **§ 10 "Migration tips"** — add a step: "Delete inline copies of production slices; rename the test file to `{ProductionModule}_GWT.res` in the matching slice folder; the PPX now resolves everything from the path."

Cross-repo note: the `feedback_plans_in_repo.md` convention (plans in `docs/plans/`, analyses in `docs/analysis/`) applies in core too. This plan belongs here; downstream consumer repos that adopt the new form land their rollout in their own `docs/plans/`.

---

## Stage 5 — Verification

Inside this repo:

- Add a GWT test in `reventless-gwt` (or a test-only sub-package that avoids circular deps) that uses `@@reventless.gwt` with zero payload against an external slice module. Confirms the end-to-end external path.
- Leave the existing inline worked-example tests as-is. They still exercise the Empty-payload / local-Spec branch and document each DSL.
- `pnpm exec reventless-gwt run reventless/reventless-gwt/tests/` stays green.

Downstream consumers can then rename their existing `*Test.res` files for slice-shaped tests to `{SpecModule}_GWT.res` and drop the old `include ReventlessGwt.<Kind>_GWT.Make(Spec)` line.

---

## Risks + rollback

- **Filename conventions beyond `_GWT` / `GwtTest` / `Gwt`** — anything else won't auto-infer the Spec. The PPX error explicitly names the three accepted suffixes; users with a different convention either rename or pass `@@reventless.gwt(SpecModule)` explicitly.
- **`open Spec` shadowing.** The Spec's top-level names (variants, fields of the state record, `initialState`, `evolve`, `decide`) enter the test-file scope. If a test body defines a local `let initialState = …` it will shadow the spec's — which is typically the intended thing. Document in the guide.
- **External-module resolution errors.** A typo in the Spec name surfaces as "Unbound module X" at the generated `include` line rather than a PPX-specific message. Clear, source-located — accept.

Rollback is additive: every change is a widening of what the PPX accepts. Reverting the `Util.ml` additions and the `GwtInference.ml` simplifications restores exactly today's behaviour.
