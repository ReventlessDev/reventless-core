# Analysis: Reventless PPX

## Overview

A custom Reventless PPX that eliminates repetitive boilerplate from application code. Written in OCaml using ppxlib (same approach as sury-ppx), distributed as pre-compiled binaries, configured via `"ppx-flags": ["reventless-ppx/bin"]` in `rescript.json`.

This document analyzes the `moduleUrl` elimination as the primary motivation, then catalogs other high-value opportunities a PPX unlocks.

---

## Part 1: Eliminating `moduleUrl`

### The Problem

Every spec, behavior, and mapping module declares:

```rescript
let moduleUrl: string = %raw(`import.meta.url`)
```

**298 identical declarations** across the codebase. The only `%raw` in application code.

### How a PPX Solves It

A PPX has access to the **source file path** via `Location.input_name` (the `pos_fname` field on every AST node's location). Combined with filesystem access to find the nearest `package.json`, the PPX can compute the npm specifier at compile time.

### Mechanism

1. PPX encounters a file-level attribute `@@reventless.specModule` (or detects a `let name = "..."` + `@schema type command` pattern)
2. Reads `pstr_loc.loc_start.pos_fname` — e.g., `/Users/dev/catalog/src/Aggregate/Category.res`
3. Walks up to find `package.json`, reads `name` field — e.g., `@reventlessdev/catalog`
4. Computes relative path — `src/Aggregate/Category.res`
5. Maps `.res` suffix to `.res.mjs` (the compiled output suffix)
6. Injects `let moduleUrl: string = "@reventlessdev/catalog/src/Aggregate/Category.res.mjs"` into the AST

The result is a **pure string literal** in the compiled output — no runtime `import.meta.url`, no `%raw`.

### Example

**Before:**

```rescript
let name = "Category"
module Id = Id.String
let moduleUrl: string = %raw(`import.meta.url`)

@schema type command = ...
```

**After (with PPX):**

```rescript
@@reventless.specModule

let name = "Category"
module Id = Id.String

@schema type command = ...
```

The PPX injects `let moduleUrl = "@reventlessdev/catalog/src/Aggregate/Category.res.mjs"` into the AST. Users never write it.

### PPX Implementation Sketch (OCaml)

```ocaml
(* Find nearest package.json and extract "name" field *)
let rec find_package_name dir =
  let pkg_path = Filename.concat dir "package.json" in
  if Sys.file_exists pkg_path then
    let ic = open_in pkg_path in
    let json = Yojson.Safe.from_channel ic in
    close_in ic;
    match Yojson.Safe.Util.member "name" json with
    | `String name -> Some (name, dir)
    | _ -> find_package_name (Filename.dirname dir)
  else if dir = "/" then None
  else find_package_name (Filename.dirname dir)

(* Compute npm specifier from source file path *)
let module_specifier loc =
  let source_file = loc.Location.loc_start.Lexing.pos_fname in
  let abs_path =
    if Filename.is_relative source_file
    then Filename.concat (Sys.getcwd ()) source_file
    else source_file
  in
  let dir = Filename.dirname abs_path in
  match find_package_name dir with
  | Some (pkg_name, pkg_root) ->
    let rel = make_relative ~base:pkg_root abs_path in
    let mjs = (Filename.chop_extension rel) ^ ".res.mjs" in
    pkg_name ^ "/" ^ mjs
  | None ->
    Location.raise_errorf ~loc
      "[reventless-ppx] No package.json found for %s" source_file

(* Inject: let moduleUrl: string = "computed-specifier" *)
let inject_module_url loc =
  let specifier = module_specifier loc in
  [%stri let moduleUrl : string = [%e Exp.constant (Const.string specifier)]]
```

### Caching

The `find_package_name` walk is done once per file (one `stat` per directory level). The PPX processes files sequentially, so a simple in-process cache (directory -> package name) avoids redundant filesystem access. In practice, all files in a package share the same package.json, so the cache hits on the first lookup after the initial miss.

### Edge Cases

| Scenario | Resolution |
|---|---|
| **Symlinked packages** (npm workspaces) | `pos_fname` resolves through symlinks — use `realpath` to normalize |
| **Root rescript.json builds sub-packages** | `pos_fname` still contains the source package's path, not the root |
| **Windows paths** | Normalize separators to `/` before constructing specifier |
| **Package name changes** | PPX re-reads package.json on each build (no cross-build cache) |
| **Source in nested workspace** | Walk up finds the nearest package.json, which is correct |

---

## Part 2: Other PPX Opportunities

### Opportunity 1: Auto-apply `@s.matches(DcbTag.string)` to Entity ID Fields

**Current (126+ annotations):**

```rescript
@schema
type command =
  | AddProduct({productId: @s.matches(DcbTag.string) string, name: string, price: float})
  | ChangePrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})
  | PriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
```

**With PPX:**

```rescript
@schema
type command =
  | AddProduct({productId: string, name: string, price: float})
  | ChangePrice({productId: string, price: float})

@schema
type event =
  | ProductAdded({productId: string, name: string, price: float})
  | PriceChanged({productId: string, price: float})
```

The PPX detects fields named `*Id: string` inside `@schema` types within a `@@reventless.specModule`-annotated file and automatically applies `@s.matches(DcbTag.string)`.

**How it works in the AST:** For each `Ptype_variant` constructor with inline record fields, scan field labels ending in `Id` with type `string`. Inject the `@s.matches(DcbTag.string)` attribute on the field's type expression before sury-ppx processes it.

**Ordering requirement:** reventless-ppx MUST run BEFORE sury-ppx in the `ppx-flags` array:

```json
"ppx-flags": ["reventless-ppx/bin", "sury-ppx/bin"]
```

PPX flags are applied left-to-right, so reventless-ppx transforms the AST first, then sury-ppx sees the `@s.matches` annotations and generates the correct schemas.

**Impact:** Eliminates 126+ inline annotations. Reduces visual noise in the most-read files.

### Opportunity 2: Implicit `module Id = Id.String`

**Current (195+ declarations):**

```rescript
module Id = Reventless.Id.String
```

**With PPX:** Omitted. The PPX injects `module Id = Reventless.Id.String` into every `@@reventless.specModule` file that doesn't already declare a `module Id`.

Every spec in the codebase uses `Id.String`. If a future spec needs a different Id module, it declares `module Id = ...` explicitly and the PPX skips injection.

**Impact:** 195+ lines removed. One less thing to forget when creating a new spec.

### Opportunity 3: Projection Mappings Macro

**Current (24 instances, 5 lines each = 120 lines):**

```rescript
module ProductProjections: Mappings with module Target := ProductsReadModel = {
  module M = Mappings.Make(ProductsReadModel)
  module type Mapping = M.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
}
```

**With PPX attribute:**

```rescript
@@reventless.projection(ProductProjections, ProductsReadModel, [
  ProductsProjections.ProductMapping,
])
```

The PPX expands this to the full 5-line block. The `moduleUrl` is auto-computed (same mechanism as Opportunity 1).

**Alternative — derive from ReadModel.Make call:** Instead of a separate declaration, annotate the ReadModel.Make call:

```rescript
module ProductReadModel = Platform.ReadModel.Make(
  ProductsReadModel,
  @reventless.projections([ProductsProjections.ProductMapping])
)
```

The PPX generates the Mappings wrapper inline.

**Impact:** 120 lines of mechanical boilerplate collapsed to single-line declarations.

### Opportunity 4: Spec File Header Generation

**Current pattern (every spec file):**

```rescript
open Reventless

let name = "Category"
module Id = Id.String
let moduleUrl: string = %raw(`import.meta.url`)
```

**With PPX:**

```rescript
@@reventless.spec("Category")

// That's it. PPX generates:
// open Reventless
// let name = "Category"
// module Id = Reventless.Id.String
// let moduleUrl = "computed-specifier"
```

Or derive the name from the file name:

```rescript
@@reventless.spec  // name derived from filename: Category.res → "Category"
```

**Impact:** 4 lines → 1 line, across 195+ spec files.

### Opportunity 5: Behavior File Header

**Current:**

```rescript
open Product
module Spec = Product

@schema
type state = { ... }

let moduleUrl: string = %raw(`import.meta.url`)
```

**With PPX:**

```rescript
@@reventless.behavior(Product)

@schema
type state = { ... }
```

PPX generates `open Product`, `module Spec = Product`, and `let moduleUrl`.

**Impact:** 3 lines → 1 line, across 24+ behavior files.

### Opportunity 6: ReadModel Footer

**Current (every ReadModel spec):**

```rescript
open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

**With PPX:** Injected automatically when `@@reventless.specModule` is present and the file satisfies `ReadModel.Spec` shape (has `@schema type state`).

Or: the framework changes `ReadModel.Spec` to make these optional with defaults. This might be better handled at the type level than the PPX level.

**Impact:** Low (18 lines total), but one less thing to forget.

### Opportunity 7: DCB Shim Module for Extension Points

**Current (DCB EP adapter pattern):**

```rescript
module Delegate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema type event = CatalogEventLog.event
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

**With PPX:**

```rescript
@@reventless.dcbDelegate(CatalogEventLog)
```

PPX generates the full shim module with `command = unit`, `error = unit`, `commandSchema = S.unit`, and event type from the referenced event log.

**Impact:** 8 lines → 1 line per DCB extension point mapping.

---

## Part 3: Implementation Plan

### Architecture

```
reventless-ppx/
├── bin                    # Shell script dispatcher
├── bin.cmd                # Windows dispatcher
├── ppx-osx.exe            # Pre-compiled Mac binary
├── ppx-linux.exe          # Pre-compiled Linux binary
├── ppx-linux-arm.exe      # Pre-compiled Linux ARM binary
├── ppx-windows.exe        # Pre-compiled Windows binary
├── install.cjs            # Post-install hook (same pattern as sury-ppx)
├── package.json
└── src/
    ├── bin/
    │   ├── dune
    │   └── bin.ml          # Entry: Ppxlib.Driver.run_as_ppx_rewriter()
    ├── ppx/
    │   ├── dune
    │   ├── ReventlessPpx.ml     # Main mapper (register transformations)
    │   ├── ModuleUrl.ml         # moduleUrl computation (find_package_name + specifier)
    │   ├── SpecModule.ml        # @@reventless.specModule handler
    │   ├── DcbTagInference.ml   # *Id field auto-annotation
    │   └── Util.ml              # Shared helpers
    ├── dune-project
    └── reventless-ppx.opam
```

### Build & Distribution

Same as sury-ppx:
- **Build:** `dune build` produces a native binary
- **CI:** Cross-compile for Mac (x64 + ARM), Linux (x64 + ARM), Windows
- **Distribute:** Publish to npm as `reventless-ppx` with platform-specific binaries
- **Install hook:** `install.cjs` copies the correct binary to `./bin`

### Configuration

```json
{
  "ppx-flags": ["reventless-ppx/bin", "sury-ppx/bin"],
  "bs-dependencies": ["sury", "@reventlessdev/reventless-spec"]
}
```

Ordering matters: reventless-ppx runs first (injects `moduleUrl`, annotates `*Id` fields), then sury-ppx runs (generates schemas from the annotated types).

### Phased Rollout

| Phase | Feature | Impact | Complexity |
|---|---|---|---|
| **1** | `moduleUrl` auto-injection via `@@reventless.specModule` | 298 `%raw` eliminated | Low |
| **2** | `@s.matches(DcbTag.string)` auto-annotation on `*Id` fields | 126+ annotations eliminated | Low |
| **3** | Implicit `module Id = Id.String` | 195+ lines eliminated | Trivial |
| **4** | `@@reventless.spec("Name")` header macro | 780+ lines (4 × 195) eliminated | Low |
| **5** | Projection Mappings macro | 120 lines eliminated | Medium |
| **6** | Behavior/DCB shim macros | 100+ lines eliminated | Medium |

### Testing Strategy

- **Snapshot tests:** Compare PPX output AST against expected .res files (same approach as sury-ppx's `e2e/` package)
- **Round-trip tests:** Compile PPX-transformed code with ReScript, verify it produces identical `.res.mjs` output as hand-written code
- **Integration tests:** Build the online-shop examples with the PPX enabled, run all 930 tests

---

## Part 4: Risk Assessment

### PPX Ordering with sury-ppx

reventless-ppx must run before sury-ppx. The `ppx-flags` array in rescript.json controls ordering (left to right). This is well-defined and used by other projects.

**Risk:** If a user reverses the order, `@s.matches` annotations injected by reventless-ppx won't be visible to sury-ppx. **Mitigation:** Document the ordering requirement. Optionally, reventless-ppx can detect sury-ppx attributes in the AST and emit a compile error if it runs after sury-ppx.

### Filesystem Access in PPX

PPXs reading the filesystem is non-standard but not prohibited. sury-ppx doesn't do this, but other PPXs in the OCaml ecosystem do (e.g., `ppx_blob` for embedding files). The `package.json` walk is fast (2-4 `stat` calls, cached) and deterministic.

**Risk:** Build caching. If `package.json` changes but the `.res` file doesn't, the PPX output may be stale. **Mitigation:** ReScript's build cache is based on source file hashes. A `package.json` name change is rare and warrants a `rescript clean`. This can be documented.

### OCaml Ecosystem Dependency

Building a PPX requires OCaml tooling (opam, dune, ppxlib). This is already a dependency for sury-ppx development. The build produces self-contained binaries — end users don't need OCaml installed.

**Risk:** Cross-compilation complexity. **Mitigation:** Use the same CI pipeline as sury-ppx (already building for 4 platforms).

### Attribute Namespace

Using `@@reventless.*` as the attribute prefix avoids collisions with sury's `@s.*` and ReScript's built-in `@as`, `@module`, etc.

---

## Part 5: What the End State Looks Like

### Aggregate Spec (Before)

```rescript
open Reventless

let name = "Category"
module Id = Id.String
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type command =
  | Add({categoryId: string, name: string})
  | Rename({categoryId: string, name: string})
  | Archive({categoryId: string})

@schema
type event =
  | Added({categoryId: string, name: string})
  | Renamed({categoryId: string, name: string})
  | Archived({categoryId: string})

@schema
type error = | AlreadyExists | NotFound
```

### Aggregate Spec (After)

```rescript
@@reventless.spec("Category")

@schema
type command =
  | Add({categoryId: string, name: string})
  | Rename({categoryId: string, name: string})
  | Archive({categoryId: string})

@schema
type event =
  | Added({categoryId: string, name: string})
  | Renamed({categoryId: string, name: string})
  | Archived({categoryId: string})

@schema
type error = | AlreadyExists | NotFound
```

4 lines of boilerplate gone. No `%raw`. No `module Id`. Just the domain.

### DCB Spec (Before)

```rescript
open Reventless

let name = "AddProduct"
module Id = Id.String
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type command = AddProduct({productId: @s.matches(DcbTag.string) string, name: string, price: float})

@schema
type event = ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})

@schema
type error = | ProductAlreadyExists
```

### DCB Spec (After)

```rescript
@@reventless.spec("AddProduct")

@schema
type command = AddProduct({productId: string, name: string, price: float})

@schema
type event = ProductAdded({productId: string, name: string, price: float})

@schema
type error = | ProductAlreadyExists
```

6 lines of boilerplate + 2 inline annotations gone. Pure domain model.
