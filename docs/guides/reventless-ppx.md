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
| `open Reventless.ReadModel` + `let config` + `let subIdConfig` | Filename contains `ReadModel`, `@schema type state` present, `let config` not declared | ReadModel defaults |

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

Use on **DCB slice files** outside `*Slice/` folders that have entity ID fields in `@schema` types. Files inside any `*Slice/` folder (StateChangeSlice, StateViewSlice, AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice) get dcbTags automatically via `@@reventless.spec` — no explicit `@@reventless.dcbTags` needed.

**What it does:** Scans all `@schema`-annotated variant types and injects `@s.matches(Reventless.DcbTag.string)` on fields that match these rules (unless `@s.matches(...)` is already present):

| Field pattern | Type | Injection |
|---|---|---|
| `*Id: string` | scalar | `@s.matches(DcbTag.string)` on the type |
| `*Id: array<string>` | array (singular name) | `@s.matches(DcbTag.string)` on the element type — for cross-entity queries |
| `*Ids: array<string>` | array (plural name) | `@s.matches(DcbTag.string)` on the element type — for multi-value storage |

The PPX generates the fully qualified `Reventless.DcbTag.string`, so no `open Reventless` is needed just for DCB tags.

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

**Combine with `@@reventless.spec`:** Most DCB files outside slice folders use both annotations:

```rescript
@@reventless.spec
@@reventless.dcbTags
```

---

### `@partitionTag`, `@noTag`, `@dcbTag` — field-level DCB tag control

These field attributes give fine-grained control over DCB tag injection. They work in any `@@reventless.spec` or `@@reventless.behavior` file, regardless of whether dcbTags auto-inference is active.

| Annotation | Placed on | Effect |
|---|---|---|
| `@partitionTag` | A `*Id: string` field | Injects `@s.matches(DcbTag.partition)` — marks this field as the partition key. Required when a variant has multiple `*Id` fields. |
| `@noDcbTag` | A `*Id: string` field | Suppresses auto-tagging — the field stays as plain `string`. Use when the field is payload data, not a DCB query key. |
| `@dcbTag` | Any `string` field | Injects `@s.matches(DcbTag.string)` — explicit opt-in for fields that don't follow `*Id` naming (e.g., `sku`, `slug`, `reference`). |

The PPX strips all three attributes from the output AST, so the compiler never sees them as unknown attributes.

**`@partitionTag` — multiple `*Id` fields:**
```rescript
// In a StateChangeSlice file — both productId and orderId would otherwise
// both get auto-tagged, making partition derivation ambiguous
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,  // partition key
      orderId: string,                  // also tagged as DcbTag.string
    })
```

**`@noDcbTag` — payload-only field:**
```rescript
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,
      @noDcbTag orderId: string,  // not a DCB tag — plain string in the event store
    })
```

**`@dcbTag` — non-`*Id` field name:**
```rescript
@@reventless.dcbTags

@schema
type event =
  | SkuAdded({
      @dcbTag sku: string,  // not *Id naming, but should be a DCB tag
      name: string,
    })
```

---

### `@compositePartitionTag` — composite DCB partition key

`@compositePartitionTag` lets you form the DynamoDB partition key from multiple fields, concatenated in declaration order with a configurable separator. Use it when a single field is too coarse for partitioning and a composite identity (e.g. `environment/platform/plugin`) distributes events better across partitions.

Each annotated field is still a regular DCB tag (individually queryable). The composite key is derived automatically at runtime from the stored tag values.

**Syntax:**

```rescript
@compositePartitionTag            // uses "/" after this field (default)
@compositePartitionTag("/")       // explicit default — identical behaviour
@compositePartitionTag(":")       // uses ":" after this field
```

The separator on the **last** annotated field is ignored (nothing follows it).

**Example — three-segment composite key `env/platform/plugin`:**

```rescript
@@reventless.spec

@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,   // partition: env/...
      @compositePartitionTag platformName: string,  // partition: env/platform/...
      @compositePartitionTag pluginName: string,    // last field — sep ignored
      version: string,
    })
// Composite partition key value: "{environment}/{platformName}/{pluginName}"
// Each field is also individually queryable as a DcbTag.string.
```

**Constraints:**

| Rule | Behaviour |
|---|---|
| Non-`string` field annotated | No-op — field is left untouched |
| `@compositePartitionTag` and `@partitionTag` on the same schema | `derivePartitionTagV2` throws at startup |
| Fewer than 2 fields annotated | `derivePartitionTagV2` throws at startup |

**Placement:** Place `@compositePartitionTag` **before the field name**, exactly like `@partitionTag`:

```rescript
// CORRECT
@compositePartitionTag environment: string

// WRONG — annotation on the type, not the field (silently ignored)
environment: @compositePartitionTag string
```

---

### `@id`, `@compositeId` — partition key derivation

Use on `@schema type state` fields in ReadModel and StateViewSlice spec files. The PPX generates `let makeId` from the annotated field(s). This replaces a manual `let makeId` declaration.

| Annotation | Usage | Generated code |
|---|---|---|
| `@id` | One `string` field | `let makeId = (state: state) => state.fieldName` |
| `@compositeId` | Multiple `string` fields | `let makeId = (state: state) => \`${state.f1}/${state.f2}/...\`` |
| `@compositeId(~sep=":")` | Multiple `string` fields, custom separator | Same with `:` between segments |

**`@id` — simple entity key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id productId: string,
  name: string,
  price: float,
}
// PPX generates: let makeId = (state: state) => state.productId
```

**`@compositeId` — multi-segment key:**
```rescript
@@reventless.spec

@schema
type state = {
  @compositeId tenantId: string,
  @compositeId productId: string,
  name: string,
}
// PPX generates: let makeId = (state: state) => `${state.tenantId}/${state.productId}`
```

**Constraints:** `@id` and `@compositeId` cannot both appear on the same type. Both require `string` fields.

---

### `@subId`, `@compositeSubId` — sort key derivation

Use on `@schema type state` fields in ReadModel and StateViewSlice spec files. The PPX generates `let subIdConfig` from the annotated field(s). This replaces the default `let subIdConfig = None` injected by `@@reventless.spec`.

| Annotation | Usage | Generated code |
|---|---|---|
| `@subId` | One `string` field | `let subIdConfig = Some({ subIdField: "fieldName", getSubId: state => state.fieldName })` |
| `@compositeSubId` | Multiple `string` fields | Synthetic `_subId` attribute: `let subIdConfig = Some({ subIdField: "_subId", getSubId: state => \`${state.f1}/${state.f2}/...\` })` |
| `@compositeSubId(~sep=":")` | Multiple `string` fields, custom separator | Same with `:` |

**`@subId` — version as sort key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id productId: string,
  @subId version: string,
  name: string,
}
// Enables: productById(id: ID!): ProductByIdConnection!
//   with sort key args: prefix, from, to, eq, reverse, limit, nextToken
```

**`@compositeSubId` — composite sort key:**
```rescript
@@reventless.spec

@schema
type state = {
  @id orderId: string,
  @compositeSubId createdAt: string,
  @compositeSubId lineItemId: string,
  amount: float,
}
// PPX generates: let subIdConfig = Some({ subIdField: "_subId", getSubId: ... })
// Stored _subId value: "{createdAt}/{lineItemId}"
```

**Constraints:** `@subId` and `@compositeSubId` cannot both appear on the same type. `@subId` requires a `string` field.

---

### `@index`, `@indexSubId` — GSI annotations

Use on `@schema type state` fields to declare DynamoDB Global Secondary Indexes. The PPX aggregates all index annotations and generates `let config` with an `indexes` array.

**`@index` — simple GSI (no sort key):**
```rescript
@schema
type state = {
  @id productId: string,
  @index categoryId: string,
  name: string,
}
// GSI: partition key = categoryId, ALL projection
// Query field generated: productByCategoryId(categoryId: ID!): ...
```

**`@index` with projection options:**
```rescript
// KEYS_ONLY projection
@index({projection: "KEYS_ONLY"}) categoryId: string,

// INCLUDE projection
@index({projection: "INCLUDE", fields: ["name", "price"]}) categoryId: string,
```

**Named `@index` with `@indexSubId` — GSI with sort key:**

Use the same name on both annotations to link them. The named index gets both a partition key and a sort key.

```rescript
@schema
type state = {
  @id productId: string,
  @index("byCategoryDate") categoryId: string,
  @indexSubId("byCategoryDate") createdAt: string,
  name: string,
}
// GSI: partition = categoryId, sort = createdAt
```

**Composite GSI keys** — annotate multiple fields with the same name:
```rescript
@schema
type state = {
  @id productId: string,
  @index("byTenantCategory") tenantId: string,
  @index("byTenantCategory") categoryId: string,  // composite pk: tenantId/categoryId
  @indexSubId("byTenantCategory") region: string,
  @indexSubId("byTenantCategory") createdAt: string,  // composite sk: region/createdAt
  name: string,
}
// Synthetic attributes injected at save: _byTenantCategory_pk, _byTenantCategory_sk
```

**Authorization — restrict GSI access by Cognito group:**
```rescript
@index({group: "admin", authTable: "PlatformAuth"}) tenantId: string,
```

**Constraints:** `@indexSubId("name")` without a matching `@index("name")` is an error.

---

### `@resolves`, `@resolvesMany` — cross-table resolvers

Use on `@schema type state` fields to generate virtual GraphQL fields that resolve IDs to objects from another QueryDb table.

**`@resolves` — resolve a single ID to its object:**

```rescript
@schema
type state = {
  @id orderId: string,
  @resolves({table: "Products", field: "product"}) productId: string,
  quantity: int,
}
// Adds virtual GraphQL field: product: Product
// Resolved by GetItem on the Products table using productId
```

**`@resolves` via GSI index:**
```rescript
@resolves({table: "Orders", field: "currentOrder", via: "byProductId"}) productId: string,
// Resolved by querying Orders table's byProductId GSI
```

**`@resolves` with cross-plugin table:**
```rescript
@resolves({table: "Products", field: "product", plugin: "CatalogPlugin"}) productId: string,
```

**`@resolvesMany` — resolve an array of IDs:**
```rescript
@schema
type state = {
  @id cartId: string,
  @resolvesMany({table: "Products", field: "products"}) productIds: array<string>,
}
// Adds virtual GraphQL field: products: [Product!]!
// Resolved by BatchGetItem on the Products table
```

**Note:** `@resolves` and `@resolvesMany` use **record payload syntax** (`({key: "value"})`), not labeled-arg syntax. The keywords `~to` and `~as` are reserved in ReScript and cannot be used as labeled args.

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
```

PPX derives: `let name = "Categories"` (strips `ReadModel` suffix). Because the filename contains `ReadModel` and the file has `@schema type state` with no `let config`, the PPX also auto-injects:

```rescript
open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

To override, declare `let config` explicitly — the PPX skips injection when `let config` is present.

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

These patterns cannot be auto-generated:

- `moduleUrl` for ExtensionPoint inline modules inside functor bodies — requires top-level `%raw` captured by closure
- Spec definitions inside inner modules in test fixtures

For these cases, use the manual declarations.

---

## `@reventless.projections`

Use on **projection module bindings** inside plugin functor bodies. This attribute works at any nesting depth (inside functors, modules, etc.).

**What it injects** (into the module body):
| Binding | Condition | Value |
|---------|-----------|-------|
| `module M` | Not already declared | `Reventless.Projection.Mappings.Make(Target)` |
| `module type Mapping` | Not already declared | `M.Mapping` |
| `let moduleUrl` | Not already declared | Computed npm specifier |

The `Target` module is extracted from the module constraint (`with module Target := XReadModel`).

**Before (manual):**
```rescript
module ProductProjections: Mappings with module Target := ProductsReadModel = {
  module M = Mappings.Make(ProductsReadModel)
  module type Mapping = M.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
}
```

**After (with PPX):**
```rescript
@reventless.projections
module ProductProjections: Mappings with module Target := ProductsReadModel = {
  let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
}
```

The `Mapping` module type is available for the `mappings` type annotation because the PPX injects `module type Mapping = M.Mapping` before the developer-authored code.

---

## `@reventless.delegate`

Use on **`Delegate` module bindings** outside `*ExtensionPointMapping*` files that need the same auto-transformation. Inside `*ExtensionPointMapping*` files, any module named `Delegate` is auto-transformed by `@@reventless.spec` without this attribute. Works at any nesting depth.

**What it injects** (into the module body):
| Binding | Condition | Value |
|---------|-----------|-------|
| `module Id` | Not already declared | `Reventless.Id.String` |
| `@schema type command = unit` | Not already declared | Sury generates `commandSchema` from this |
| dcbTags on `@schema type event` | Event type present | `@s.matches(Reventless.DcbTag.string)` on `*Id: string` fields |
| `@schema type error = unit` | Not already declared | Sury generates `errorSchema` from this |
| `let moduleUrl` | Not already declared | Computed npm specifier |

**Before (manual):**
```rescript
module Delegate = {
  let name = "CatalogEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema
  type event =
    | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, price: float})
    | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

**After (with PPX):**
```rescript
@reventless.delegate
module Delegate = {
  let name = "CatalogEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}
```

The developer only writes `let name` and the `@schema type event`. Everything else is auto-generated. The `@s.matches(Reventless.DcbTag.string)` annotation is applied automatically to `*Id: string` fields via the same logic as `@@reventless.dcbTags`.

---

## What the PPX replaces

| Before (manual) | After (PPX) |
|-----------------|-------------|
| `open Reventless` | (not needed for specs — `module Id` uses fully qualified path) |
| `module Id = Id.String` | Auto-injected by `@@reventless.spec` |
| `let name = "Category"` | Derived from filename |
| `let moduleUrl: string = %raw(\`import.meta.url\`)` | Computed at compile time |
| `open Spec; module Spec = Spec` | Auto-injected by `@@reventless.behavior` |
| `@s.matches(DcbTag.string)` on `*Id`/`*Ids` fields | Auto-injected by `@@reventless.dcbTags` (or automatically in `*Slice/` folders) |
| `@s.matches(DcbTag.partition)` on partition key field | Use `@partitionTag` field annotation |
| `@s.matches(DcbTag.string)` on non-`*Id` field | Use `@dcbTag` field annotation |
| Suppress auto-tagging on a `*Id` field | Use `@noDcbTag` field annotation |
| `module M = Mappings.Make(...)` + boilerplate | Auto-injected by `@reventless.projections` |
| `open Reventless.ReadModel; let config = config(); let subIdConfig = None` | Auto-injected by `@@reventless.spec` for `*ReadModel*` files |
| `module Id`, `@schema command/error = unit`, `@s.matches`, `moduleUrl` in Delegate | Auto-injected in `*ExtensionPointMapping*` files; use `@reventless.delegate` elsewhere |
| `let makeId = ...` in ReadModel/StateViewSlice spec | Use `@id` or `@compositeId` on `@schema type state` fields |
| `let subIdConfig = Some({...})` in ReadModel/StateViewSlice spec | Use `@subId` or `@compositeSubId` on `@schema type state` fields |
| `let config = config(~indexes=[...])` with manual `indexConfig` records | Use `@index`/`@indexSubId` on `@schema type state` fields |
| Manual `idResolverConfig`/`idsResolverConfig` entries in `let config` | Use `@resolves`/`@resolvesMany` on `@schema type state` fields |
