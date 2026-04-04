# Reventless PPX Guide

The Reventless PPX eliminates boilerplate from application code. Instead of manually declaring `let name`, `module Id`, `let moduleUrl`, and `@s.matches(DcbTag.string)`, you add a single annotation and the PPX injects everything at compile time.

---

## Setup

Add the PPX to your package's `rescript.json`. It **must** come before `sury-ppx`:

```json
{
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]
}
```

The PPX reads `package.json` (for the npm package name) and `rescript.json` (for namespace and dependencies) from the nearest parent directory. Both files must exist.

---

## Annotations

### `@@reventless.spec`

Use on **all spec files**: aggregate specs, read model specs, extension point specs, DCB slice specs, event mapping specs, and side effect specs.

**What it injects:**
| Binding | Condition | Value |
|---------|-----------|-------|
| `let name` | Not already declared | Derived from filename |
| `module Id` | Not already declared, and `reventless-spec` is a dependency | `Reventless.Id.String` |
| `let moduleUrl` | Not already declared | Computed npm specifier |

**Name derivation** strips known component suffixes from the filename:

| Filename | Derived name |
|----------|-------------|
| `Category.res` | `"Category"` |
| `ProductsReadModel.res` | `"Products"` |
| `AddCategory.res` | `"AddCategory"` |
| `CategoriesView.res` | `"Categories"` |
| `ProductsExtensionPoint.res` | `"Products"` |
| `ProductBehavior.res` | `"Product"` |

Stripped suffixes: `ExtensionPointMapping`, `ExtensionPoint`, `ReadModel`, `Behavior`, `Projections`, `Projection`, `Aggregate`, `Plugin`, `Slice`, `Spec`, `View`.

**Dotted names in spec packages:** When the `rescript.json` namespace ends in `Spec` (e.g., `CatalogSpec`), the PPX automatically prefixes the derived name with the plugin name:

| Filename | Namespace | Derived name |
|----------|-----------|-------------|
| `ProductsExtensionPoint.res` | `CatalogSpec` | `"Catalog.Products"` |
| `OrdersExtensionPoint.res` | `OrderingSpec` | `"Ordering.Orders"` |

The plugin name is the namespace with `Spec` stripped.

**Explicit name override:**

```rescript
@@reventless.spec("CustomName")
```

Use this when the derived name doesn't match your intent. The PPX still injects `module Id` and `moduleUrl`.

**`module Id` is skipped** when `reventless-spec` is not in the package's `rescript.json` dependencies. This allows lightweight spec packages (extension point specs) to use `@@reventless.spec` without depending on the full framework.

---

### `@@reventless.behavior`

Use on **all behavior files**.

**What it injects:**
| Binding | Condition | Value |
|---------|-----------|-------|
| `open Spec` | Not already present | Opens the spec module |
| `module Spec = Spec` | Not already declared | Aliases the spec module |
| `let moduleUrl` | Not already declared | Computed npm specifier |

**Spec module derivation:** strips `Behavior` from the filename.

| Filename | Derived spec |
|----------|-------------|
| `CategoryBehavior.res` | `open Category; module Spec = Category` |
| `OrderBehavior.res` | `open Order; module Spec = Order` |
| `ProductDemandBehavior.res` | `open ProductDemand; module Spec = ProductDemand` |

**Explicit spec override:**

```rescript
@@reventless.behavior(PluginSpec)
```

Use this when the spec module name doesn't match `{Filename minus Behavior}` — for example when the spec file is named differently than the behavior file's prefix.

---

### `@@reventless.dcbTags`

Use on **DCB slice files** (StateChangeSlice, AutomationSlice, InboundTranslationSlice) that have entity ID fields in `@schema` types.

**What it does:** Scans all `@schema`-annotated variant types. For every inline record field where:
- The field name ends in `Id` (case-sensitive: `productId`, `orderId`, `customerId`)
- The field type is `string`
- No `@s.matches(...)` is already present

...it injects `@s.matches(Reventless.DcbTag.string)` on the type expression.

**Before (manual):**
```rescript
@schema
type command = AddProduct({
  productId: @s.matches(DcbTag.string) string,
  name: string,
})

@schema
type event = ProductAdded({
  productId: @s.matches(DcbTag.string) string,
  name: string,
})
```

**After (with PPX):**
```rescript
@@reventless.dcbTags

@schema
type command = AddProduct({
  productId: string,
  name: string,
})

@schema
type event = ProductAdded({
  productId: string,
  name: string,
})
```

The PPX generates the fully qualified `Reventless.DcbTag.string`, so no `open Reventless` is needed just for DCB tags.

**Explicit annotations take precedence.** If a field already has `@s.matches(CustomSchema)`, the PPX won't overwrite it.

**Combine with `@@reventless.spec`:** Most DCB files use both annotations:

```rescript
@@reventless.spec
@@reventless.dcbTags
```

---

## Examples

### Aggregate spec

```rescript
// Category.res
@@reventless.spec

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | Archive

@schema
type event =
  | Added({name: string})
  | Renamed({name: string})
  | Archived

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
```

PPX injects: `let name = "Category"`, `module Id = Reventless.Id.String`, `let moduleUrl = "..."`.

### Behavior

```rescript
// CategoryBehavior.res
@@reventless.behavior

@schema
type state =
  | NotCreated
  | Active({name: string})
  | Archived

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name})) => Active({name: name})
  | (Active(_), Renamed({name})) => Active({name: name})
  | (Active(_), Category.Archived) => Archived
  | _ => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name})) => Ok([Added({name: name})])
  | (Active(_), Add(_)) => Error(CategoryAlreadyExists)
  | (Active(_), Archive) => Ok([Category.Archived])
  | (Archived, Archive) => Ok([]) // idempotent
  | _ => Error(CategoryNotFound)
  }
```

PPX injects: `open Category`, `module Spec = Category`, `let moduleUrl = "..."`.

### Read model spec

```rescript
// CategoriesReadModel.res
@@reventless.spec

@schema
type state = {
  name: string,
  archived: bool,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

PPX derives: `let name = "Categories"` (strips `ReadModel` suffix).

### Extension point spec (in a `*Spec` package)

```rescript
// ProductsExtensionPoint.res (in CatalogSpec namespace)
@@reventless.spec

@schema
type command = unit

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

PPX derives: `let name = "Catalog.Products"` (namespace `CatalogSpec` → `"Catalog"` + filename → `"Products"`). No `module Id` injected (no `reventless-spec` dependency).

### DCB StateChangeSlice

```rescript
// AddCategory.res
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

@schema
type command = AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: string, name: string})

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name})])
    }
  }
```

PPX injects `let name = "AddCategory"`, `module Id`, `let moduleUrl`, and `@s.matches(Reventless.DcbTag.string)` on the `categoryId` fields in both `command` and `event` types.

---

## Conventions

### PPX ordering

`reventless-ppx` **must** come before `sury-ppx` in `ppx-flags`. The reventless PPX injects `@s.matches` annotations that sury-ppx then processes into schema code.

### Namespace conventions

| Package type | Namespace pattern | Effect on name derivation |
|-------------|-------------------|--------------------------|
| Spec package | `CatalogSpec` | Dotted names: `"Catalog.Products"` |
| Plugin package | `CatalogPlugin` | Simple names: `"Category"` |
| Platform package | `true` or custom | Simple names |

### When to use explicit names

Use `@@reventless.spec("ExplicitName")` when:
- The desired name differs from the filename (rare)
- The file is a framework-internal component (e.g., `PluginSpec.res` → `"Plugin"` works, but being explicit is clearer)

Use `@@reventless.behavior(SpecName)` when:
- The spec module name doesn't match `{filename minus Behavior}` (e.g., `PluginBehavior.res` opens `PluginSpec`, not `Plugin`)

### Files that cannot use PPX annotations

The PPX operates at **file level only**. These patterns cannot be auto-generated:

- `moduleUrl` inside functor bodies (e.g., projection modules in `*Plugin.res`)
- `@s.matches(DcbTag.string)` inside inner modules (e.g., `Delegate` in `ExtensionPointMapping` files)
- Spec definitions inside inner modules in test fixtures

For these cases, use the manual declarations.

---

## What the PPX replaces

| Before (manual) | After (PPX) |
|-----------------|-------------|
| `open Reventless` | (not needed for specs — `module Id` uses fully qualified path) |
| `module Id = Id.String` | Auto-injected by `@@reventless.spec` |
| `let name = "Category"` | Derived from filename |
| `let moduleUrl: string = %raw(\`import.meta.url\`)` | Computed at compile time |
| `open Spec; module Spec = Spec` | Auto-injected by `@@reventless.behavior` |
| `@s.matches(DcbTag.string)` on `*Id` fields | Auto-injected by `@@reventless.dcbTags` |
