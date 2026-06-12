# Plan: PPX Component Suffix Stripping Fix

**Analysis:** `docs/analysis/ppx-component-suffix-stripping.md` *(in the downstream consumer repo)*

**Problem:** `filename_to_name` in `Util.ml` strips all `component_suffixes` unconditionally. Inside slice folders, suffixes like `Plugin` and `Aggregate` are part of user-defined entity names, not framework type labels. E.g. `StateChange/SyncPlugin.res` → entity `"Sync"` (wrong, should be `"SyncPlugin"`).

**Fix:** Split `component_suffixes` into two lists and apply the right one based on whether the file is inside a slice folder.

---

## Step 1 — Split suffix lists in `Util.ml`

File: `packages/reventless-ppx/src/ppx/Util.ml`

Replace the single `component_suffixes` list (line 84) with two lists:

```ocaml
(* Slice-layer suffixes: describe the category of a slice.
   Stripped everywhere, including inside slice folders. *)
let slice_layer_suffixes = [
  "View"; "Slice"; "Spec"
]

(* Framework component suffixes: describe top-level architectural types.
   Only stripped when the file is NOT inside a slice folder.
   Inside a slice folder these can be part of the entity name (e.g. SyncPlugin). *)
let top_level_only_suffixes = [
  "ExtensionPointMapping";
  "ExtensionPoint";
  "ReadModel";
  "Behavior";
  "Projections";
  "Projection";
  "Aggregate";
  "Plugin";
]
```

Update `strip_component_suffix` to accept the suffix list as a parameter (or inline in `filename_to_name`).

Update `filename_to_name` (currently line 125):

```ocaml
let filename_to_name fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let suffixes =
    if is_in_slice_folder fname then slice_layer_suffixes
    else slice_layer_suffixes @ top_level_only_suffixes
  in
  let rec try_suffixes name = function
    | [] -> name
    | suffix :: rest ->
      let stripped = strip_suffix name suffix in
      if not (String.equal stripped name) then stripped
      else try_suffixes name rest
  in
  try_suffixes without_ext suffixes
```

Note: `is_in_slice_folder` is already defined above `filename_to_name` (moved in the prior commit `5471b3f2`), so no further reordering is needed.

---

## Step 2 — Add test cases in `test/run.sh`

Add a new fixture file inside the existing `StateChangeSlice/` fixture directory:

```bash
# Slice file whose name ends in a top-level-only suffix (Plugin)
# Entity name must retain the suffix
cat > "$DCB/src/StateChangeSlice/SyncPlugin.res" <<'EOF'
@@reventless.spec

@schema
type command = Sync
@schema
type event = Synced
@schema
type error = unit
EOF
```

Add a test assertion after the `TransferItems` test block:

```bash
echo ""
echo "=== Test: slice folder — top-level-only suffix NOT stripped (Plugin retained) ==="
JS="$DCB/src/StateChangeSlice/SyncPlugin.res.mjs"
assert_js_contains "$JS" 'let name = "SyncPlugin"'  "Plugin suffix retained inside slice folder"
```

Also add a fixture in the plugin package for a `StateView/` slice to confirm `View` is still stripped:

```bash
mkdir -p "$PLUGIN/src/StateView"
cat > "$PLUGIN/src/StateView/ProductsView.res" <<'EOF'
@@reventless.spec

@schema
type state = { count: int }
EOF
```

```bash
echo ""
echo "=== Test: slice folder — slice-layer suffix View still stripped ==="
JS="$PLUGIN/src/StateView/ProductsView.res.mjs"
assert_js_contains "$JS" 'let name = "Products"'  "View suffix still stripped inside slice folder"
```

---

## Step 3 — Rebuild the binary

```bash
cd packages/reventless-ppx
npm run build:ppx
cp src/_build/default/bin/bin.exe ppx-osx-x64.exe
# Also update ppx-linux.exe if building on Linux CI
```

---

## Step 4 — Run tests

```bash
cd packages/reventless-ppx
npm test
```

All existing tests must pass. The two new assertions in Step 2 must pass.

---

## Behaviour Table (after fix)

| File | In slice folder? | Result |
|------|-----------------|--------|
| `OrderReadModel.res` | No | `Order` |
| `CartAggregate.res` | No | `Cart` |
| `CatalogPlugin.res` | No | `Catalog` |
| `StateChange/SyncPlugin.res` | Yes | `SyncPlugin` ✓ |
| `StateView/ProductsView.res` | Yes | `Products` ✓ |
| `StateView/ProductDemandView.res` | Yes | `ProductDemand` ✓ |
| `StateView/PlatformOverview.res` | Yes | `PlatformOverview` ✓ |
| `InboundTranslation/ImportSlice.res` | Yes | `Import` ✓ |
