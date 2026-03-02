# Analysis: API Component for Multi-Provider Platform APIs

## Executive Summary

This document analyses the design of a new `Api` component for Reventless that:

1. Follows the existing component structure pattern (`Api.res` / `Api_Builder.res` / `Api_Adapter.res` / `Api_Operations.res`).
2. Abstracts over different API protocols — GraphQL (AppSync today) and REST/OpenAPI in the future.
3. Derives schema fragments **from existing sury `@schema` annotations** on aggregate commands/events, read model states, DCB `StateChangeSlice` commands, and DCB `StateViewSlice` states — eliminating manual SDL authoring.
4. Stitches a unified API schema from the fragments contributed by every registered plugin.
5. Handles **dynamic registration at runtime**: when a plugin connects or disconnects from the Core, the live API schema is updated to reflect the change.
6. Supports **pure aggregate-based**, **pure DCB-based**, and **mixed** plugins (aggregates + DCB within the same plugin) transparently.

This analysis supersedes and generalises the backlog plan `docs/plans/Backlog/graphql-api-stitching.md`, which covers GraphQL-only deploy-time stitching. The approach here targets both deploy-time structure and runtime dynamism.

---

## Context and Scope

### What already exists

| What | Where | Notes |
|------|-------|-------|
| SDL strings for Core admin API | `reventless-core/src/core/API/PluginApi.res`, `CoreApi.res` | Hand-written, no type safety |
| GraphQL schema composition pattern | `CoreApi.res` | SDL string concatenation only |
| Plugin registration aggregate | `PluginSpec.res` + `PluginBehavior.res` | Handles heartbeat, connect, disconnect at runtime |
| Plugin self-description type | `Plugin.pluginDefinition` (sury-annotated) | Carries extension points but NOT API fragments |
| Read model resolver config | `ReadModel.config` in `reventless-spec` | GraphQL field names, index config, auth |
| Command resolver fields | `CommandGenerator_Adapter.Resolvers` `~fields: array<string>` | Tied to AppSync mutations today |
| AppSync resolver implementations | `CommandGeneratorResolvers_AppSync`, `QueryDbResolvers_AppSync` | Provider-specific, already adapter-pattern |

### Relationship to the existing backlog plan

`docs/plans/Backlog/graphql-api-stitching.md` proposed a deploy-time GraphQL stitching approach using hand-authored SDL fragment strings stored in `Plugin.outputs.graphqlSchema`. That design:

- Is purely **deploy-time** (Pulumi) — no runtime dynamism.
- Uses **hand-written SDL strings** — not derived from sury schemas.
- Is **GraphQL-only** — no abstraction for REST.

This analysis replaces that approach with a fully generic, sury-driven, runtime-capable design. The backlog plan should be superseded by this analysis once the design here is accepted.

### Relationship to the Platform extension plan

`docs/plans/platform-plugin-core-extension.md` established that:

- `Platform.T` gains `type api` and `type role` for provider-specific API gateway and role types.
- `Plugin.T` and `Core.T` both accept `~api` and `~apiRole` parameters.
- AWS platform fixes `type api = Types.AppSync.api` and `type role = Types.AppSync.role`.
- In-memory platform uses `type api = unit` and `type role = unit`.

The new `Api` component introduced here is the thing that `~api` and `~apiRole` ultimately refer to. The Platform extension plan should be extended to also expose an `Api` factory so callers can create the API handle through the Platform abstraction rather than directly constructing provider-specific resources.

---

## Current State Analysis

### The structural gap

All Reventless components follow this pattern:

```
Component.res         — types, module type T, outputs type
Component_Builder.res — Make functor, constructs infrastructure
Component_Adapter.res — abstract module type for provider-specific dependencies
Component_Operations.res — runtime operations (type-safe wrappers)
```

The API has none of this. It exists only as two files of SDL string constants (`PluginApi.res`, `CoreApi.res`). There is no builder, no adapter, no operations, and no component type.

### The stitching gap

Currently the `Core_Builder` does not stitch any plugin API schemas. Each plugin's aggregates and read models carry resolver field-name arrays (`fields: array<string>`), but there is no mechanism to collect these into a unified schema. The schema itself is defined entirely by the Core's hand-written SDL strings — plugin-specific types, queries, and mutations do not appear in any schema today.

### The dynamism gap

Plugin registration is fully runtime-driven. When a plugin Lambda starts, it sends a `Connect(pluginDefinition)` command to the Core's `Plugin` aggregate. The `pluginDefinition` carries extension point and extension metadata, but not any API schema fragment. Therefore the Core has no way to know a connecting plugin's API surface at runtime, and cannot update the API schema dynamically.

### The provider coupling gap

`CommandGeneratorResolvers_AppSync` and `QueryDbResolvers_AppSync` are provider-specific but already follow the adapter pattern — they are implementations of `CommandGenerator_Adapter.Resolvers` and `QueryDb_Adapter.Resolvers`. The adapter modules take `~api` as a first-class module type member. This pattern is sound and should be extended to the `Api` component level.

---

## Design Goals

1. **Component-first**: `Api` is a proper Reventless component with `Api.res`, `Api_Builder.res`, `Api_Adapter.res`, `Api_Operations.res`.
2. **Sury-driven schema generation**: Schema fragments (GraphQL SDL or OpenAPI paths) are generated FROM sury `@schema`-annotated types — no hand-written SDL for plugin-specific types.
3. **Protocol-agnostic**: The component core works for any API protocol. Concrete protocols (GraphQL, REST) are implemented as `Api_Adapter` providers.
4. **Plugin-contributed fragments**: Each plugin contributes an `apiSchemaFragment` to its `pluginDefinition`, so the Core can stitch fragments from all registered plugins.
5. **Deploy-time structure, runtime stitching**: The API infrastructure is created at Pulumi deploy time. Schema updates (adding/removing plugin fragments) happen at runtime via the Core's plugin registration mechanism.
6. **Unified ownership at Platform level**: The Platform owns the API resource and provides the `api` and `role` handles to both Core and Plugin builders.
7. **DCB and mixed plugins**: Both aggregate-based and DCB-based components (`StateChangeSlice`, `StateViewSlice`) contribute to the fragment. A plugin may combine both without any special configuration.

---

## The `Api` Component Architecture

### Package placement: `reventless-infra`, not `reventless-spec`

`reventless-spec` contains only the type declarations that **application/user code writes**: `Aggregate.Spec`, `ReadModel.Spec`, `StateChangeSlice.Spec`, `StateViewSlice.Spec`, `DcbEventLog.Spec`. Users declare these by annotating their own domain types.

The `Api` component is entirely a **platform concern** — no user/application code ever implements or declares an Api spec. Plugin authors do not write an Api spec; the schema is derived automatically from the specs they already have. This mirrors `Platform.T`, `ReadModel.T`, and `Aggregate.T`, all of which live in `reventless-infra`.

Therefore:
- **`Api.res`** → `reventless-infra/src/components/Api.res` (alongside `ReadModel.res`, `Aggregate.res`, etc.)
- **`Api_Adapter.res`** → `reventless-infra/src/components/Api_Adapter.res` (the Provider module type, like `Platform.T`, is something platform packages implement)
- **`Platform.T`** gains an `Api` factory sub-module, giving concrete platforms a uniform way to expose the API component

The `schemaFragment` type stays in `reventless-spec/Plugin.res` because it travels inside `pluginDefinition` (a sury-annotated type that already lives there). Only the component infrastructure types move to `reventless-infra`.

### `reventless-infra/src/components/Api.res`

Modelled after `ReadModel.res` and `Counter.res`:

```rescript
// The schema fragment a single plugin contributes to the platform API.
// The encoding is protocol-specific (SDL for GraphQL, JSON for OpenAPI).
// The fragment is serialisable via sury so it can travel in pluginDefinition.
// NOTE: schemaFragment is defined in reventless-spec/Plugin.res (shared with pluginDefinition).
// Api.schemaFragment is an alias so callers can reference it from the component module.
type schemaFragment = Plugin.schemaFragment

// Operations exposed at runtime (through Lambda or equivalent).
type operations = {
  // Update the live API with a new set of plugin fragments.
  // Called by the Core when a plugin connects or disconnects.
  updateSchema: array<schemaFragment> => promise<unit>,
}

type outputs = {
  // The provider-specific API resource handle.
  // Type is abstract — fixed by the concrete platform implementation.
  api: Pulumi.Output.t<JSON.t>,
  // The provider-specific role resource handle.
  role: Pulumi.Output.t<JSON.t>,
}

type t
type component = Component.t<t, outputs, operations>

module type T = {
  type api
  type role
  let make: (
    ~name: string,
    ~baseFragment: schemaFragment,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

> Note: `api` and `role` use `JSON.t` in the abstract `outputs` type above for illustration. In practice the `outputs` record would use abstract type parameters consistent with `Platform.T.api` and `Platform.T.role`.

There is no `Api.Spec` module type. Schema generation is an internal concern of `Plugin_Builder`: the builder collects entry values directly from the aggregate, read model, and DCB specs it already holds, and calls the fragment generator. Plugin authors do not write any API spec by hand.

### `reventless-infra/src/components/Api_Adapter.res`

Defines the abstract interface that a concrete API provider must implement. This module type is implemented by platform packages (reventless-aws, reventless-in-memory) — not by application code. The internal structure of `schemaFragment.encoded` is owned entirely by each provider's implementation.

```rescript
// Deploy-time: creates the API gateway resource.
// Receives the base fragment (Core admin API) already encoded in the provider's format.
type apiResourceMaker<'api, 'role> = (
  ~name: string,
  ~baseFragment: Api.schemaFragment,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {api: 'api, role: 'role}

// Runtime: stitches all active plugin fragments into a unified schema and pushes
// it to the API gateway. The provider owns all parsing, merging, and encoding.
// Receives the opaque array of plugin fragments plus the immutable base fragment.
type schemaUpdater = (
  ~apiId: string,
  ~baseFragment: Api.schemaFragment,
  ~pluginFragments: array<Api.schemaFragment>,
) => promise<unit>

// Generates a protocol-specific schemaFragment from the two unified entry arrays.
// The entry types capture the minimal information the generator needs:
//   mutationEntries: one per command source (aggregate or DCB slice)
//   queryEntries:    one per query source (read model or view slice)
// Aggregate vs DCB distinction is captured only in the pre-computed field names —
// the generator does not need to know which kind of component the entry came from.
type fragmentGenerator = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
) => Api.schemaFragment

module type Provider = {
  type api
  type role
  let makeApiResource: apiResourceMaker<api, role>
  let generateFragment: fragmentGenerator
  let updateSchema: schemaUpdater
}
```

### `reventless-core/src/components/Api/Api_Builder.res`

Follows the pattern of `Counter_Builder.res`:

```rescript
module Make = (Provider: Api_Adapter.Provider) => {
  type api = Provider.api
  type role = Provider.role

  let make = (~name, ~baseFragment, ~opts=?) : Api.component =>
    Component.make(
      ~componentType="reventless:Api",
      ~name,
      ~construct=(self, _name) => {
        let {api, role} = Provider.makeApiResource(
          ~name,
          ~baseSchema=baseFragment.encoded,
          ~opts,
        )
        self->Component.setOutputs({ api: api->..., role: role->... })
        self->Component.setOperations(
          Pulumi.Output.make({
            updateSchema: fragments =>
              Provider.updateSchema(~apiId=..., ~fragments),
          })
        )
      },
      ~opts,
    )
}
```

### `reventless-core/src/components/Api/Api_Operations.res`

Runtime type-safe wrapper. Provides `updateSchema` for use in the Core's plugin connect/disconnect callback:

```rescript
module Make = (Provider: Api_Adapter.Provider) => {
  let updateSchema = (operations: Api.operations, fragments) =>
    operations.updateSchema(fragments)
}
```

---

## Sury-Based Schema Generation

### Key insight

Sury's `@schema` annotation already generates a `schema` value for every annotated type. Both aggregate-based and DCB-based components carry these:

- Aggregates: `@schema type command = | AddProduct({...}) | UpdateProductPrice({...})`
- StateChangeSlices: `let commandSchema: S.t<command>` is already an **explicit member** of `StateChangeSlice.Spec` — no new annotation required.
- ReadModels and StateViewSlices: `@schema type state = {field: type, ...}`.

The sury `S.t<'a>` value carries field names, primitive types, and variant constructor names — sufficient to derive argument types for mutations and field types for query return objects across any API protocol.

### Unified entry types

There are exactly two generator input types. They cover all sources — aggregate and DCB — and together provide everything needed to generate **all three parts** of a GraphQL fragment (types, mutations, queries).

```rescript
// One mutationSchemaEntry per command source (aggregate OR DCB StateChangeSlice).
// Plugin_Builder pre-computes fieldNames using the naming convention:
//   Aggregate: ["PluginName_AggregateName_Cmd1", "PluginName_AggregateName_Cmd2", ...]
//   DCB slice: ["PluginName_SliceName"]  (usually a single-variant command)
// fieldNames[i] corresponds to the ith variant in commandSchema.
//
// The commandSchema contributes to the `mutations` part of the fragment (argument types).
// For variants with nested record payloads it also contributes to the `types` part
// (as GraphQL input types). For the common case of flat inline arguments no extra
// type declarations are needed.
type mutationSchemaEntry = {
  fieldNames: array<string>,
  commandSchema: S.t<'command>,
}

// One querySchemaEntry per query source (ReadModel OR StateViewSlice).
// Plugin_Builder pre-computes field names using the naming convention:
//   ReadModel:      singleFieldName = "PluginName_ReadModelName"  (e.g. "Catalog_Product")
//                   listFieldName   = Some("PluginName_ReadModelNames") (e.g. "Catalog_Products")
//                   returnTypeName  = "PluginNameReadModelName"   (e.g. "CatalogProduct")
//   StateViewSlice: entity name = slice.name with "View" suffix stripped, then singularized
//                   singleFieldName = "PluginName_EntityName"     (e.g. "Catalog_Category")
//                   listFieldName   = None  (v1: list queries not generated for DCB views)
//                   returnTypeName  = "PluginNameEntityName"      (e.g. "CatalogCategory")
//
// The stateSchema contributes to BOTH the `types` part (the named GraphQL object type
// declaration) AND the `queries` part (the query field declaration that references the type).
// This is why there is no separate "type entry": the type definitions ARE derived from the
// state schemas already present in querySchemaEntry.
type querySchemaEntry = {
  singleFieldName: string,
  listFieldName: option<string>,
  returnTypeName: string,
  stateSchema: S.t<'state>,
  authorization: option<ReadModel.authorization>,
}
```

`Plugin_Builder` assembles these two arrays from all four sources and passes them to `Provider.generateFragment`. A mixed plugin with both aggregates and DCB simply has more entries in each array — no special handling is needed.

**How the three-part GraphQL fragment is fully covered by two entry types:**

| Fragment part | Source |
|--------------|--------|
| `types` | Generated from each `querySchemaEntry.stateSchema` (return object types) + optionally from `mutationSchemaEntry.commandSchema` for nested payload input types |
| `mutations` | Generated from each `mutationSchemaEntry.commandSchema` (one field per variant) |
| `queries` | Generated from each `querySchemaEntry` (single-item field + optional list field) |

### Protocol-specific fragment generators

There is no protocol-agnostic generator. The sury-to-schema traversal is inherently protocol-specific (SDL types differ from JSON Schema types). Each protocol has its own generator module in `reventless-core`:

**`GraphQL_FragmentGenerator.res`**

Traverses the sury schemas to produce a three-part intermediate structure. The three parts are kept separate because the stitcher must merge them at the correct level — concatenating full SDL strings would require re-parsing.

```rescript
// The internal three-part structure for GraphQL. Not stored in reventless-spec types.
type graphqlFragmentData = {
  // SDL type definitions (no Query/Mutation wrappers).
  // One "type ReturnTypeName { fields... }" per querySchemaEntry.
  // Optionally "input CmdInputTypeName { fields... }" per mutationSchemaEntry variant
  // that has a complex nested payload (rare; flat args produce no extra type declarations).
  // Example: "type CatalogProduct { productId: ID!, name: String!, price: Float! }"
  types: string,
  // Bare mutation field declarations (no "type Mutation {}" wrapper).
  // e.g. "Catalog_Product_AddProduct(productId: ID!, name: String!, price: Float!): String!"
  mutations: string,
  // Bare query field declarations (no "type Query {}" wrapper).
  // e.g. "Catalog_Product(id: ID!): CatalogProduct"
  // e.g. "Catalog_Products(nextToken: String, limit: Int): [CatalogProduct!]!"
  queries: string,
}

// Encodes graphqlFragmentData as JSON and wraps in Api.schemaFragment.
let generate: (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
) => Api.schemaFragment  // encoded = JSON.stringify(graphqlFragmentData)
```

Sury type mapping for GraphQL:
- `string` → `String`, `float` → `Float`, `int` → `Int`, `bool` → `Boolean`
- `@s.matches(DcbTag.string)` → `ID!`
- Each variant `| CmdName({fields...})` → one mutation field `fieldNames[i](fields...): String!` (arguments inline)
- Each `state` record → a named `type ReturnTypeName { fields... }` in the `types` part + a query field in `queries` that returns it. `ReturnTypeName` comes from `querySchemaEntry.returnTypeName` (pre-computed by Plugin_Builder, no "State" or "View" suffixes)

**`GraphQL_Stitcher.res`**

Decodes each fragment's `encoded` field, stitches the three parts separately, then assembles the final SDL:

```rescript
let stitch: (
  ~baseFragment: Api.schemaFragment,
  ~pluginFragments: array<Api.schemaFragment>,
) => string  // final SDL string: all types + "type Query { all queries }" + "type Mutation { all mutations }"
```

Stitching rules per part:
- **types**: concatenated verbatim (plugin-name-prefixed type names prevent collisions)
- **mutations**: all mutation fields collected, then wrapped in a single `type Mutation { ... }`
- **queries**: all query fields collected, then wrapped in a single `type Query { ... }`

**`OpenAPI_FragmentGenerator.res`** (future)

Same two entry types as input, different output encoding:

```rescript
type openApiFragmentData = {
  paths: JSON.t,    // path item objects merged under /plugin-name/...
  schemas: JSON.t,  // component schemas (PluginNameXxxState, etc.)
}

// Encodes openApiFragmentData as JSON into Api.schemaFragment.encoded.
let generate: (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
) => Api.schemaFragment
```

REST path naming follows the same conventions as GraphQL field names but in kebab-case (see Naming Conventions below).

### Naming conventions

The following conventions apply platform-wide and guarantee uniqueness of all field, type, and path names across all plugins.

**Deriving the entity name from a StateViewSlice spec name**

StateViewSlice names typically carry a "View" suffix (e.g. `"CategoriesView"`, `"ProductsView"`) that describes the component, not the entity. This suffix is an implementation artifact and is stripped before generating any API names:

```
CategoriesView → strip "View" → Categories → singularize → Category
ProductsView   → strip "View" → Products   → singularize → Product
```

ReadModel names are used directly since they already follow the singular entity convention (e.g. `"Product"`, `"Category"`).

**GraphQL mutations**

| Source | Pattern | Example (plugin `"Catalog"`) |
|--------|---------|------------------------------|
| Aggregate command | `PluginName_AggregateName_CmdName` | `Catalog_Product_AddProduct` |
| DCB StateChangeSlice | `PluginName_SliceName` | `Catalog_AddCategory` |

- `AggregateName` = `Aggregate.Spec.name` (e.g. `"Product"`).
- `CmdName` = the variant constructor name (e.g. `AddProduct`).
- `SliceName` = `StateChangeSlice.Spec.name` (e.g. `"AddCategory"`). For single-variant slices the slice name IS the command name — no further suffix.

**GraphQL queries**

| Source | Pattern | Example (plugin `"Catalog"`) |
|--------|---------|------------------------------|
| ReadModel — single item | `PluginName_EntityName` | `Catalog_Product` |
| ReadModel — all items | `PluginName_EntityNames` | `Catalog_Products` |
| StateViewSlice — single item | `PluginName_EntityName` (derived from slice name) | `Catalog_Category` |
| StateViewSlice — all items | `PluginName_EntityNames` | `Catalog_Categories` |

- ReadModel `"Product"` → entity name `Product` → single `Catalog_Product`, list `Catalog_Products`.
- StateViewSlice `"CategoriesView"` → strip "View" → `Categories` → singularize → entity `Category` → single `Catalog_Category`, list `Catalog_Categories`.
- **Convention**: ReadModel spec names should be **singular** (e.g. `"Product"`, not `"Products"`) so that automatic pluralization is well-defined.
- StateViewSlice list queries are **not generated in v1** (see Open Question Q9). The column is shown for completeness.

**GraphQL type names** (generated object types in the `types` fragment)

| Source | Singular object type | List / plural type |
|--------|---------------------|--------------------|
| ReadModel `"Product"` | `CatalogProduct` | `CatalogProducts` |
| StateViewSlice `"CategoriesView"` → entity `"Category"` | `CatalogCategory` | `CatalogCategories` |

Rules:
- Type name = `PluginName` + entity name (PascalCase). No "State", "View", or "List" suffixes.
- The list type wrapping a page of results uses the **plural** entity name, not a "List" or "Connection" suffix. E.g. a paginated result type is `CatalogProducts`, not `CatalogProductList`.

**REST paths** (OpenAPI, future)

| Source | Pattern | Example |
|--------|---------|---------|
| Aggregate mutation | `POST /plugin-name/aggregate-name/cmd-name` | `POST /catalog/product/add-product` |
| DCB mutation | `POST /plugin-name/cmd-name` | `POST /catalog/add-category` |
| ReadModel — single | `GET /plugin-name/entity-name/{id}` | `GET /catalog/product/{id}` |
| ReadModel — list | `GET /plugin-name/entity-names` | `GET /catalog/products` |
| StateViewSlice — single | `GET /plugin-name/entity-name/{id}` | `GET /catalog/category/{id}` |
| StateViewSlice — list | `GET /plugin-name/entity-names` | `GET /catalog/categories` |

All names use lowercase kebab-case for REST paths (strip "View" from slice names, singularize for single-item paths). GraphQL field names use `_` as separator. GraphQL type names use PascalCase with no technical suffixes.

---

## DCB-Based and Mixed Plugin Support

### How DCB slices map to API fields

A DCB plugin provides its write-side API through `StateChangeSlice` components and its read-side API through `StateViewSlice` components. Both carry `@schema`-annotated types directly in their `Spec`, so no additional declarations are needed.

**Write side (mutations) — `StateChangeSlice.Spec`**

Each `StateChangeSlice` in `Plugin.DcbSpec.stateChangeSlices` becomes one or more mutation fields. The slice's `commandSchema: S.t<command>` (already required by `StateChangeSlice.Spec`) drives the argument types.

Because DCB slices are typically single-command (one variant, e.g. `| AddCategory({categoryId, name})`), the generated mutation field is simply `PluginName_SliceName`. When a slice's `command` type has multiple variants (less common in DCB), each variant becomes its own field: `PluginName_SliceName_VariantName`.

Example for the `Catalog` plugin with two slices (`AddCategory`, `RenameCategory`):
```graphql
# mutations fragment contributed by the Catalog plugin (DCB)
Catalog_AddCategory(categoryId: ID!, name: String!): String!
  @aws_auth(cognito_groups: ["Admin"])
Catalog_RenameCategory(categoryId: ID!, name: String!): String!
  @aws_auth(cognito_groups: ["Admin"])
```

All DCB mutations in the same plugin route to the same shared DCB CommandTopic Lambda (the filtering Lambda in `Plugin_Builder`). From the API perspective there are N mutation fields; from the infrastructure perspective they all land in one Lambda which dispatches by command type using the sury schema.

**Read side (queries) — `StateViewSlice.Spec`**

Each `StateViewSlice` in `Plugin.DcbSpec.stateViewSlices` becomes a query field. The slice's `@schema type state` drives the return type.

Example for the `Catalog` plugin with two view slices (`CategoriesView` → entity `Category`; `ProductsView` → entity `Product`):

```graphql
# queries fragment contributed by the Catalog plugin (DCB)
# "View" suffix stripped, entity name singularized for field and type names.
Catalog_Category(id: ID!): CatalogCategory
  @aws_auth(cognito_groups: ["User", "Admin"])
Catalog_Product(id: ID!): CatalogProduct
  @aws_auth(cognito_groups: ["User", "Admin"])

# generated types (in the `types` part of the fragment)
type CatalogCategory {
  categoryId: ID!
  name: String!
  archived: Boolean!
}
type CatalogProduct {
  productId: ID!
  name: String!
  description: String!
  price: Float!
}
```

### Mixed plugin example

A plugin may freely combine aggregate-based and DCB-based components. The `Plugin_Builder` collects schema entries from all sources into the two unified arrays:

- `~aggregates` → `mutationSchemaEntry` (one per aggregate, field names use `PluginName_AggregateName_CmdName`)
- `~readModels` → `querySchemaEntry` (one per read model)
- `~dcbSpec.stateChangeSlices` → `mutationSchemaEntry` (one per slice, field names use `PluginName_SliceName`)
- `~dcbSpec.stateViewSlices` → `querySchemaEntry` (one per slice)

Consider a hypothetical `Catalog` plugin that uses the `Product` aggregate (aggregate-based) but the `Category` commands and views via DCB:

```graphql
# ── mutations ──────────────────────────────────────────────────────────────
# aggregate-based (Product aggregate)
Catalog_Product_AddProduct(productId: ID!, name: String!, price: Float!): String!
  @aws_auth(cognito_groups: ["Admin"])
Catalog_Product_UpdateProductPrice(productId: ID!, price: Float!): String!
  @aws_auth(cognito_groups: ["Admin"])

# DCB-based (StateChangeSlice commands for categories)
Catalog_AddCategory(categoryId: ID!, name: String!): String!
  @aws_auth(cognito_groups: ["Admin"])
Catalog_RenameCategory(categoryId: ID!, name: String!): String!
  @aws_auth(cognito_groups: ["Admin"])

# ── queries ─────────────────────────────────────────────────────────────────
# ReadModel "Product" — single item and list
Catalog_Product(id: ID!): CatalogProduct
  @aws_auth(cognito_groups: ["User", "Admin"])
Catalog_Products(nextToken: String, limit: Int): [CatalogProduct!]!
  @aws_auth(cognito_groups: ["User", "Admin"])

# StateViewSlice "CategoriesView" → entity "Category"
Catalog_Category(id: ID!): CatalogCategory
  @aws_auth(cognito_groups: ["User", "Admin"])

# ── types ────────────────────────────────────────────────────────────────────
type CatalogProduct {
  productId: ID!
  name: String!
  price: Float!
}

type CatalogCategory {
  categoryId: ID!
  name: String!
  archived: Boolean!
}
```

The stitcher merges all of these into the unified platform `type Query {}` and `type Mutation {}` blocks alongside fragments from other plugins and the Core admin API.

### DCB resolver wiring

For AppSync, each DCB mutation field needs an AppSync resolver. All DCB mutations in one plugin share a single Lambda (the DCB CommandTopic Lambda). `CommandGeneratorResolvers_AppSync` (or a new DCB-aware variant) creates one AppSync resolver per DCB mutation field, all pointing to the same Lambda data source:

```
Catalog_AddCategory    → AppSync resolver → DCB CommandTopic Lambda (Catalog)
Catalog_RenameCategory → AppSync resolver → DCB CommandTopic Lambda (Catalog)
```

The DCB CommandTopic Lambda receives the mutation name as part of its input and dispatches to the correct `StateChangeSlice` via the sury schema registry already implemented in `Plugin_Builder`.

For REST, each DCB mutation path has its own route handler inside the same Lambda.

### StateViewSlice resolver wiring

`QueryDbResolvers_AppSync` already supports DynamoDB-backed query tables; each `StateViewSlice` uses a `QueryDb` internally. The resolver setup for `Catalog_Category` is the same DynamoDB read pattern used by aggregate `ReadModel` resolvers — no new infrastructure type is needed.

---

## Deploy-Time vs. Runtime Stitching

There are two timescales at which schema stitching occurs:

### Deploy-time (Pulumi)

At Pulumi deploy time:

1. The `Core_Builder` knows which aggregates and read models belong to the Core's own built-in API (`CoreApi` / `PluginApi`).
2. The `Api_Builder` creates the API gateway resource (AppSync API, API Gateway REST API) with the Core's base schema as the initial schema.
3. No plugin-specific fragments are known at deploy time — plugins are independently deployed and register dynamically at runtime.

The deploy-time schema therefore contains only:

- The Core's own admin types/queries/mutations (`Plugin`, `CoreApi` content).
- A placeholder or empty `type Query` / `type Mutation` body that plugin fragments will be added to at runtime.

For AppSync specifically, the schema resource must be valid at creation time, so the base schema (core admin API) must be complete and valid SDL.

### Runtime (Lambda)

At runtime, when a plugin Lambda starts:

1. It sends a `Connect(pluginDefinition)` command to the Core's Plugin aggregate.
2. The `pluginDefinition` now carries an `apiSchemaFragment` field (see next section).
3. The Core's plugin connect handler receives the fragment and calls `Api.operations.updateSchema`.
4. `updateSchema` collects the fragments from all currently-active plugins (from the PluginReadModel) plus the base fragment and stitches them into a new unified schema.
5. The stitched schema is pushed to the API gateway (AppSync `startSchemaCreation` / API Gateway deployment).

When a plugin disconnects or is deactivated:

1. Its fragment is removed from the stitch.
2. The schema is updated without that plugin's types/queries/mutations.

This gives true dynamic schema management driven by the existing plugin lifecycle events.

---

## Extending `pluginDefinition` for API Schema Fragments

The key enabler for runtime stitching is extending `Plugin.pluginDefinition` to carry the API schema fragment:

```rescript
// In reventless-spec/src/components/Plugin.res

@schema
type apiSchemaFragment = {
  encoded: string,   // SDL string (GraphQL) or JSON blob (OpenAPI)
  protocol: string,  // "graphql" | "openapi" | "none"
}

@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  extensionProtocols: array<extensionProtocol>,
  apiSchemaFragment: apiSchemaFragment,  // NEW
}
```

The fragment is generated by `Plugin_Builder` at Pulumi deploy time (same time the Lambda code and its infrastructure are created), embedded in the Lambda's configuration, and sent as part of the `Connect` command when the Lambda starts.

Because `pluginDefinition` is sury-annotated, the new field is automatically serialised/deserialised without any manual JSON handling.

---

## The Api Adapter Pattern for GraphQL vs. REST

### GraphQL / AppSync adapter (`reventless-aws`)

```rescript
// reventless-aws/src/components/Api/AppSync_Adapter.res
module Make = (Config: { let region: string }) => {
  type api = PulumiAws.AppSync.GraphQLApi.t
  type role = PulumiAws.IAM.Role.t

  let makeApiResource = (~name, ~baseSchema, ~opts) => {
    let api = PulumiAws.AppSync.GraphQLApi.make(~name, ~args={schema: baseSchema, ...}, ~opts)
    let role = PulumiAws.IAM.Role.make(...)
    {api, role}
  }

  let generateFragment = (~mutationEntries, ~queryEntries) =>
    GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)

  let updateSchema = (~apiId, ~baseFragment, ~pluginFragments) => {
    let stitched = GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)
    AwsSdk.AppSync.startSchemaCreation(~apiId, ~definition=stitched)
  }
}
```

The `GraphQL_FragmentGenerator` and `GraphQL_Stitcher` modules live in `reventless-core` (protocol-agnostic core) — only the AWS SDK call in `updateSchema` is provider-specific.

### REST / OpenAPI adapter (future)

```rescript
// reventless-aws/src/components/Api/ApiGateway_Adapter.res (future)
module Make = (Config: { let stageName: string }) => {
  type api = PulumiAws.APIGateway.RestApi.t
  type role = PulumiAws.IAM.Role.t

  let makeApiResource = (~name, ~baseSchema, ~opts) => {
    let api = PulumiAws.APIGateway.RestApi.make(~name, ~args={body: baseSchema, ...}, ~opts)
    ...
  }

  let generateFragment = (~mutationEntries, ~queryEntries) =>
    OpenAPI_FragmentGenerator.generate(~mutationEntries, ~queryEntries)

  let updateSchema = (~apiId, ~baseFragment, ~pluginFragments) => {
    let stitched = OpenAPI_Stitcher.stitch(~baseFragment, ~pluginFragments)
    AwsSdk.APIGateway.putRestApi(~restApiId=apiId, ~body=stitched)
  }
}
```

### In-memory adapter — graphql-yoga-based (not a no-op)

`reventless-in-memory` already contains a fully functional GraphQL server built on `graphql-yoga` (`GraphQL_Server.res`). During `Platform.Make()`, each component (aggregates, read models, etc.) registers its SDL fields and resolver functions into a module-level registry, and `GraphQL_Server.start()` assembles them into a running yoga server at the end.

Rather than using a no-op, the in-memory `Api` adapter should drive this existing server — giving developers a real, live GraphQL API that reflects the exact same schema as production (since both use the same `GraphQL_FragmentGenerator` entry types).

**Feasibility**

The key requirement is **hot schema reloading**: when `updateSchema` is called (a plugin connects at runtime), the yoga server must reflect the new schema without a full restart. This is straightforward in graphql-yoga — the schema object can be replaced by stopping the current http server and starting a new one with the rebuilt SDL. In a development/test context (the only context for `reventless-in-memory`) this is perfectly acceptable.

Alternatively, graphql-yoga supports dynamic schemas via a schema-reference holder pattern (expose a `ref<schema>` and wrap the yoga instance so it reads the current ref value on each request). This enables true hot-reload without reconnecting clients.

**The existing `GraphQL_Server` needs one new function:**

```rescript
// Rebuilds the schema from new SDL and hot-reloads the running server.
// Existing resolver registrations (from CommandGeneratorResolvers_GraphQL,
// QueryDbResolvers_GraphQL) are preserved — only the SDL changes.
// Called by the in-memory Api adapter's updateSchema.
let rebuildSchema = (~baseFragment: Api.schemaFragment, ~pluginFragments: array<Api.schemaFragment>) => {
  // Decode and stitch all fragment SDL parts (reusing GraphQL_Stitcher logic)
  let stitchedSdl = GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  let newSchema = YG.createSchema({"typeDefs": stitchedSdl, "resolvers": resolvers})
  // Hot-reload: stop old server, start new one on same port
  stop()
  let yoga = YG.createYoga({"schema": newSchema, "graphiql": true, "logging": false})
  let server = YG.createServer(yoga)
  server->YG.listen(activePort.contents, () => ())
  activeServer.contents = Some(server)
}
```

**In-memory Api adapter:**

```rescript
// reventless-in-memory/src/adapter/Api/GraphQL_InMemory_Adapter.res
module Make = () => {
  type api = unit
  type role = unit

  // Deploy-time: start the graphql-yoga server with the Core's base SDL.
  // ~baseFragment contains the Core admin API types/queries/mutations.
  // This replaces the unconditional GraphQL_Server.start() call in Platform.Make().
  let makeApiResource = (~name=_, ~baseFragment: Api.schemaFragment, ~opts=_) => {
    GraphQL_Server.startWithBaseFragment(baseFragment)
    {api: (), role: ()}
  }

  // Fragment generation: use the same GraphQL_FragmentGenerator as the AWS adapter.
  // This gives the in-memory server exactly the same typed SDL as production
  // (real argument types from sury schemas, not generic `(id: ID, args: String): String`).
  let generateFragment = (~mutationEntries, ~queryEntries) =>
    GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)

  // Runtime: rebuild the graphql-yoga schema to include the new plugin's SDL.
  // Called when a plugin connects to the Core.
  let updateSchema = (~apiId=_, ~baseFragment, ~pluginFragments) => {
    GraphQL_Server.rebuildSchema(~baseFragment, ~pluginFragments)
    Promise.resolve()
  }
}
```

**Interaction with existing per-component resolver registration**

The existing `CommandGeneratorResolvers_GraphQL` and `QueryDbResolvers_GraphQL` register resolvers (handler functions) AND SDL strings into `GraphQL_Server` during component construction. With the new Api adapter, the SDL from `generateFragment` is the authoritative schema (typed, from sury). The per-component SDL registrations become redundant for schema shape, but their **resolver functions** are still needed.

Resolution: split the existing registration into two concerns:
- **Resolver functions** (the `dict<resolverFn>` part): still registered per-component, consumed by `GraphQL_Server.rebuildSchema`.
- **SDL fields** (the `array<string>` part): no longer registered per-component; SDL is generated by the Api adapter instead.

The `GraphQL_Server.registerMutations` / `registerQueries` functions need only preserve the `resolvers` dict going forward. The SDL can be dropped on the floor (or removed). This is a small refactor internal to `reventless-in-memory`.

Until that refactor is done, the per-component SDL can remain registered (harmlessly generating a lower-fidelity schema) and the Api adapter can override it on first `rebuildSchema` call. The important invariant is that resolver function names match the field names in the SDL — since both sides use the same `Plugin_Builder` naming conventions, they will.

**Result for local development**

With this adapter, `Platform.Make()` produces a running graphql-yoga server with the Core's admin schema. Each plugin that calls `Connect` causes `updateSchema` → `rebuildSchema` → the GraphiQL playground at `localhost:4000/graphql` immediately reflects that plugin's typed mutations and queries. This mirrors the production AppSync behavior in a local dev loop.

---

## Integration with Plugin Registration

### `Plugin_Builder` changes

`Plugin_Builder.Make` currently accepts `~aggregates`, `~readModels`, and `~dcbSpec`. With this change it also:

1. Builds the two unified entry arrays, applying the naming conventions:

   **`mutationEntries: array<mutationSchemaEntry>`**
   - From `~aggregates`: one entry per aggregate. `fieldNames` = `[pluginName ++ "_" ++ aggName ++ "_" ++ constructor1, ...]` for each command variant; `commandSchema` from `Aggregate.Spec`.
   - From `~dcbSpec.stateChangeSlices`: one entry per slice. `fieldNames` = `[pluginName ++ "_" ++ slice.name]` (single-variant convention); `commandSchema` from `StateChangeSlice.Spec.commandSchema`.

   **`queryEntries: array<querySchemaEntry>`**
   - From `~readModels`: one entry per read model. `singleFieldName` = `pluginName ++ "_" ++ rm.name`; `listFieldName` = `Some(pluginName ++ "_" ++ pluralize(rm.name))`; `returnTypeName` = `pluginName ++ rm.name` (e.g. `"CatalogProduct"`); `stateSchema` and `authorization` from `ReadModel.Spec`.
   - From `~dcbSpec.stateViewSlices`: one entry per slice. Entity name = slice name with "View" suffix stripped, then singularized (e.g. `"CategoriesView"` → `"Category"`). `singleFieldName` = `pluginName ++ "_" ++ entityName`; `listFieldName` = `None` (v1); `returnTypeName` = `pluginName ++ entityName` (e.g. `"CatalogCategory"`); `stateSchema` from `StateViewSlice.Spec`.

2. Calls `Provider.generateFragment(~mutationEntries, ~queryEntries)` to produce the `apiSchemaFragment`. The `Provider` module is bound at `Plugin_Builder.Make` time — the same provider used for resolver wiring.

3. Embeds the fragment into the Lambda configuration (as an environment variable or embedded in the heartbeat payload).

4. The heartbeat Lambda sends the fragment as part of `Connect(pluginDefinition)` at startup.

No new parameters are needed beyond what the builder already receives. A plugin with no DCB spec contributes only aggregate-based entries; a DCB-only plugin contributes only slice-based entries; a mixed plugin contributes to both. All cases produce the same two-array shape.

### `Core_Builder` / plugin connect handler changes

The Core's plugin connect handler (in `PluginBehavior.res` and `Core_Callback.res`) currently processes the `Connect(pluginDefinition)` command and records the plugin's extension points and extensions. With this change it also:

1. Extracts `pluginDefinition.apiSchemaFragment`.
2. Reads the current set of all active plugin fragments from the PluginReadModel.
3. Calls `Api.operations.updateSchema(allFragments)` — a new operation on the `Api` component.

The `Api` component's `operations` are passed into the Core builder as a new `~api: Api.component` parameter. This aligns with the existing pattern where `Core_Builder` takes `~api: ClonerRunner.api` today.

### `PluginReadModel` extension

The PluginReadModel state needs to carry `apiSchemaFragment` so the Core can reconstruct the full set of fragments when one plugin connects or disconnects:

```rescript
// PluginReadModelSpec.res
@schema
type state = {
  ...existing fields...,
  apiSchemaFragment: Plugin.apiSchemaFragment,  // NEW
}
```

The `PluginProjection` updates this field from `Connected`, `Reconnected`, and `Disconnected` events.

---

## The `Api` Component Placement in the Component Hierarchy

```
Platform
  └── Core (owns the Api component)
        ├── Api component
        │     ├── Deploy-time: creates API gateway resource
        │     └── Runtime: updateSchema operation
        ├── Plugin aggregate (heartbeat / connect / disconnect)
        ├── PluginReadModel (active plugin registry with fragments)
        └── Cloner

Plugin (receives api + apiRole from Platform/Core)
  ├── Aggregates          (aggregate-based — each → mutationSchemaEntry in Plugin_Builder)
  ├── ReadModels          (aggregate-based — each → querySchemaEntry  in Plugin_Builder)
  └── DcbSpec (optional)
        ├── DcbEventLog
        ├── StateChangeSlices  (DCB write side — each → mutationSchemaEntry in Plugin_Builder)
        └── StateViewSlices    (DCB read side  — each → querySchemaEntry  in Plugin_Builder)
```

The Api component is owned by the Core (not by individual plugins). The Core creates it once and provides the `api` and `role` handles to plugins so they can attach their resolvers (Lambda data sources, etc.).

---

## Resolver Wiring After Schema Update

When the schema is updated at runtime to include a new plugin's mutations and queries, the corresponding resolver infrastructure must already be deployed. This is feasible because:

- **Aggregate mutation resolvers** (`CommandGeneratorResolvers_AppSync`) are deployed as Pulumi resources when the Plugin stack is deployed. They exist before the plugin Lambda starts.
- **DCB mutation resolvers**: all DCB mutations in one plugin point to the same DCB CommandTopic Lambda. The AppSync resolver resources for each `PluginName_SliceName` field are deployed at Pulumi time, all referencing the single DCB Lambda data source. At runtime, the Lambda dispatches to the correct slice by matching the sury command schema.
- **Query resolvers** (`QueryDbResolvers_AppSync`) are deployed per ReadModel and per StateViewSlice. Both use a DynamoDB-backed QueryDb table — the resolver setup is identical. They exist before the plugin Lambda starts.
- AppSync resolver resources reference field names in the schema. In AppSync, resolvers can be attached to fields that do not yet exist in the schema — they become active once the schema contains the field.

Therefore: deploy the resolvers at Pulumi time (current behaviour), update the schema at Lambda connect time (new behaviour). The two are decoupled and work correctly for both aggregate-based and DCB-based mutations/queries.

For REST / API Gateway this is equally clean: deploy the integration Lambdas and routes at Pulumi time, update the API spec at Lambda connect time.

---

## Schema Stitching Rules

Each protocol's stitcher owns its own rules. The Core's `updateSchema` operation simply passes the opaque fragment array to `Provider.updateSchema`; it does not inspect the encoded content.

### GraphQL stitching (`GraphQL_Stitcher.res`)

Each fragment's `encoded` field is a JSON blob `{types, mutations, queries}`. The stitcher decodes all fragments and merges the three parts separately — this is why the three parts are stored separately rather than as a fully-formed SDL string.

1. **types**: all `types` strings concatenated verbatim. Plugin-name-prefixed type names (`CatalogProduct`, `CatalogCategory`) prevent cross-plugin collisions by construction.
2. **mutations**: all `mutations` strings concatenated (bare field declarations, no wrapper); then wrapped in a single `type Mutation { ... }`. Uniqueness is guaranteed by the `PluginName_AggregateName_CmdName` (aggregate) and `PluginName_SliceName` (DCB) conventions.
3. **queries**: all `queries` strings concatenated (bare field declarations, no wrapper); then wrapped in a single `type Query { ... }`. Uniqueness is guaranteed by `PluginName_ReadModelName` / `PluginName_ReadModelNames` (aggregate) and `PluginName_SliceName` (DCB) conventions.
4. The base fragment (`CoreApi` / `PluginApi` content) is always merged first — its types, mutations, and queries are prepended to each respective section.
5. Auth directives (`@aws_auth(cognito_groups: [...])`) are emitted by the generator per field and preserved verbatim in the `mutations` / `queries` strings.

### OpenAPI stitching (`OpenAPI_Stitcher.res`) — future

Each fragment's `encoded` field is a JSON blob `{paths, schemas}`.

1. **paths**: deep-merged into the root `paths` object. Plugin-name prefixes (`/catalog/`, `/ordering/`) prevent path collisions.
2. **schemas**: deep-merged into `components/schemas`. Plugin-name-prefixed schema names prevent collisions.
3. The base spec (Core admin API) provides the root OpenAPI document that plugin fragments are merged into.
4. Auth is via security scheme references embedded in each path item — emitted by the generator and preserved verbatim.

### Collision detection

Both stitchers should detect and report:
- **GraphQL**: duplicate type names in the `types` section; duplicate field names in the `mutations` or `queries` sections.
- **OpenAPI**: duplicate path entries; duplicate schema component names.

A detected collision results in a rejected `promise` (the schema is not updated) and a structured error log entry identifying the conflicting plugin names and field/type names.

---

## Module Placement Summary

### New files

| Package | File | Purpose |
|---------|------|---------|
| `reventless-infra` | `src/components/Api.res` | `Api.T`, `schemaFragment` alias, `operations`, `outputs`, entry types (`mutationSchemaEntry`, `querySchemaEntry`) |
| `reventless-infra` | `src/components/Api_Adapter.res` | `Provider` module type (`makeApiResource`, `generateFragment`, `updateSchema`) — implemented by platform packages, not application code |
| `reventless-core` | `src/components/Api/Api_Builder.res` | `Api_Builder.Make` functor |
| `reventless-core` | `src/components/Api/Api_Operations.res` | Runtime wrappers for `operations` |
| `reventless-core` | `src/components/Api/GraphQL_FragmentGenerator.res` | Traverses sury schemas → `graphqlFragmentData{types,mutations,queries}` → encodes to `schemaFragment` |
| `reventless-core` | `src/components/Api/GraphQL_Stitcher.res` | Decodes fragments, stitches types/mutations/queries separately, assembles final SDL |
| `reventless-core` | `src/components/Api/OpenAPI_FragmentGenerator.res` | (Future) Traverses sury schemas → `openApiFragmentData{paths,schemas}` → encodes to `schemaFragment` |
| `reventless-core` | `src/components/Api/OpenAPI_Stitcher.res` | (Future) Decodes fragments, merges paths and component schemas |
| `reventless-aws` | `src/components/Api/AppSync_Adapter.res` | AppSync `Provider`: creates GraphQL API resource, delegates to `GraphQL_FragmentGenerator` + `GraphQL_Stitcher`, calls AppSync SDK |
| `reventless-in-memory` | `src/adapter/Api/GraphQL_InMemory_Adapter.res` | graphql-yoga `Provider`: drives `GraphQL_Server` with typed SDL from sury schemas; `updateSchema` hot-reloads the running server |

### Modified files

| Package | File | Change |
|---------|------|--------|
| `reventless-spec` | `src/components/Plugin.res` | Add `apiSchemaFragment` to `pluginDefinition` |
| `reventless-core` | `src/core/Aggregates/Plugin/PluginSpec.res` | No change needed (carries `pluginDefinition` already) |
| `reventless-core` | `src/core/ReadModels/Plugin/PluginReadModelSpec.res` | Add `apiSchemaFragment` to `state` |
| `reventless-core` | `src/core/ReadModels/Plugin/PluginProjection.res` | Project `apiSchemaFragment` from events |
| `reventless-core` | `src/core/Core/Core_Builder.res` | Accept `~api: Api.component`; pass `Api.operations` to connect handler |
| `reventless-core` | `src/core/Core/Core.res` | Add `api: Api.outputs` to `outputs`; add `type api` / `type role` |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | Generate `apiSchemaFragment`, embed in Lambda env / heartbeat |
| `reventless-infra` | `src/types/Platform.res` | Add `module Api` factory to `Platform.T` |
| `reventless-aws` | `src/Platform.res` | Implement `Platform.Api` using `AppSync_Adapter` |
| `reventless-in-memory` | `src/Platform.res` | Implement `Platform.Api` using `GraphQL_InMemory_Adapter`; remove unconditional `GraphQL_Server.start()` call (now driven by `makeApiResource`) |
| `reventless-in-memory` | `src/adapter/GraphQL_Server.res` | Add `startWithBaseFragment` + `rebuildSchema` functions for hot schema reloading |

---

## Open Design Questions

### Q1: Sury schema reflection API

Sury generates `schema: S.t<type>` values. The `S.t<'a>` type exposes structural information (field names, types, variant constructors). The fragment generators need to traverse this structure. Is the existing sury API surface sufficient for this traversal, or does it require additional bindings?

Action: audit `S.t` in rescript-sury (or the bundled sury-ppx) to determine if field enumeration is supported. If not, consider an alternative: have the `Spec` modules declare their schema as a ReScript value (`commandSchema: array<fieldDescriptor>`) that `Plugin_Builder` derives from the existing `fields: array<string>` plus sury-provided type information.

### Q2: Fragment generation location (deploy-time vs. compile-time)

Option A: fragments are generated at Pulumi deploy time (inside `Plugin_Builder.Make`). This is the natural fit for the component builder pattern.

Option B: fragments are generated at compile time (via a ppx or code generation step). This produces static values embedded in the Lambda code.

Option B is more robust (no runtime string generation) but requires additional tooling. Option A is consistent with the existing pattern and sufficient for v1. Recommend Option A.

### Q3: Schema update granularity

When plugin A connects, should the `updateSchema` call include:
- (a) only the fragments of all currently active plugins, or
- (b) an incremental delta (just add/remove one plugin's fragment)?

Option (a) is simpler and more resilient to partial failures. The full stitch reruns on each connect/disconnect. For a platform with tens of plugins this is fast. Recommend Option (a).

### Q4: Schema update consistency during multi-plugin startup

If multiple plugin Lambdas start simultaneously, each sends a `Connect` command and each triggers a `updateSchema` call. These calls may interleave, causing intermediate schema states.

Mitigation: the `updateSchema` reads the active plugin list from the PluginReadModel (which is eventually consistent) and re-stitches. A Lambda-level DynamoDB conditional write (optimistic locking) or a dedicated schema-update SQS queue can serialise the updates. This is an infrastructure concern handled inside the AppSync adapter's `updateSchema` implementation.

### Q5: Backward compatibility for `pluginDefinition`

Adding `apiSchemaFragment` to `pluginDefinition` is a breaking change for existing plugins that send `Connect(pluginDefinition)` commands. Existing plugins will not include the new field, so the JSON deserialisation will fail unless the field is made optional.

Resolution: declare `apiSchemaFragment` as optional in the sury schema (`apiSchemaFragment?: apiSchemaFragment`). When absent, the Core treats the connecting plugin as contributing no API surface (safe default — existing behaviour is preserved).

### Q6: Resolver attachment before schema existence

For AppSync, resolvers are Pulumi resources that reference field names in the schema. If a plugin's resolvers are deployed before the plugin's fragment is added to the live schema, AppSync may reject the resolver creation (field does not exist in schema).

Resolution: the initial deploy-time schema (from `Api_Builder`) should include all known plugins' fragments if the plugin is deployed in the same Pulumi stack as the Core. For multi-stack deployments, the schema update at Lambda connect time adds the fields before they are invoked by any client. AppSync resolvers attached to non-existent fields do not cause errors at attachment time — only if a client calls the field before the schema is updated.

### Q7: Protocol indicator in `apiSchemaFragment`

The `protocol` field in `apiSchemaFragment` allows a Core that supports multiple API types (both GraphQL and REST) to route each fragment to the correct stitcher. In practice, a single platform will have one API type. This field is kept for forward compatibility but need not be acted on in v1.

### Q8: Auth configuration for DCB mutations and queries

Aggregate queries carry `ReadModel.config.authorization` entries that the generator translates into `@aws_auth(cognito_groups: [...])` directives. DCB `StateChangeSlice` and `StateViewSlice` have no equivalent today.

Options:
- (a) Add optional `authorization?: authorization` to `StateChangeSlice.Spec` and `StateViewSlice.Spec` — mirrors the `ReadModel.config.authorization` pattern.
- (b) Let the schema fragment generator accept a plugin-level default auth group, applied uniformly to all DCB fields in that plugin.
- (c) Emit no auth directive by default for DCB fields and let the AppSync API's default auth mode apply.

Recommend option (a) for parity with aggregate read models, but (c) is acceptable for v1 to avoid spec changes. The analysis should record that DCB auth configuration is deferred.

### Q9: StateViewSlice all-items (list) query

The current analysis generates a single query field `PluginName_SliceName(id: ID!): State` for each `StateViewSlice`. A list/pagination query (analogous to the aggregate `Catalog_Products` all-items query) is not included.

`StateViewSlice` does not have a `ReadModel.config` with `idResolvers`, so the conventions for generating a list query are not yet defined. Options:
- (a) Always generate a list query `PluginName_SliceNames(nextToken, limit): SliceList!` alongside the single-item query.
- (b) Do not generate a list query for StateViewSlice unless the spec is extended to opt in.
- (c) Let `StateViewSlice.Spec` carry an optional `listConfig` that mirrors `ReadModel.config`.

Recommend (b) for v1 — single-item queries cover the most common access pattern. List queries for DCB views can be added in a follow-on once the query infrastructure is clearer.

---

## Implementation Order

```
Phase 1: Add apiSchemaFragment (optional) to pluginDefinition in reventless-spec
         — small, backward-compatible, prerequisite for all other phases

Phase 2: Define Api.res and Api_Adapter.res in reventless-infra
         — Api.res: schemaFragment alias, mutationSchemaEntry, querySchemaEntry, operations, outputs, T
           (NOT in reventless-spec — the API component is a platform concern, not a user-declared Spec)
         — Api_Adapter.res: Provider module type (makeApiResource, generateFragment, updateSchema)
         — no implementations yet

Phase 3: Implement GraphQL_FragmentGenerator and GraphQL_Stitcher in reventless-core
         — input: two unified entry types (mutationSchemaEntry, querySchemaEntry)
         — GraphQL_FragmentGenerator produces graphqlFragmentData{types,mutations,queries}
           encoded as JSON in schemaFragment.encoded
         — GraphQL_Stitcher decodes fragments, merges the three parts separately,
           wraps queries/mutations in their type blocks, prepends base fragment
         — pure SDL-generation logic, testable independently of AWS
         — verify naming conventions produce correct, unique field names for all
           aggregate, DCB, and mixed-plugin scenarios

Phase 4: Implement Api_Builder.res and Api_Operations.res in reventless-core
         — wires the component builder pattern; no AWS dependency

Phase 5: Implement AppSync_Adapter.res in reventless-aws
         — provides AppSync-specific makeApiResource + updateSchema

Phase 6: Extend Plugin_Builder to build the two entry arrays and call generateFragment
         — mutationEntries: one per aggregate (fieldNames from naming convention) +
           one per StateChangeSlice (fieldNames = [pluginName_sliceName])
         — queryEntries: one per ReadModel + one per StateViewSlice
         — calls Provider.generateFragment(~mutationEntries, ~queryEntries)
         — handles mixed plugins transparently (both entry arrays may be non-empty)
         — fragment travels in pluginDefinition.apiSchemaFragment

Phase 7: Extend PluginReadModelSpec and PluginProjection to carry apiSchemaFragment
         — allows Core to reconstruct full fragment set on connect/disconnect

Phase 8: Extend Core_Builder and Core connect handler to call Api.operations.updateSchema
         — completes the runtime stitching loop for both aggregate and DCB plugins

Phase 9: Implement GraphQL_InMemory_Adapter for reventless-in-memory
         — uses graphql-yoga (already present) rather than a no-op
         — extend GraphQL_Server with startWithBaseFragment + rebuildSchema
         — generateFragment delegates to GraphQL_FragmentGenerator (same as AppSync adapter)
         — updateSchema calls GraphQL_Server.rebuildSchema (hot-reload without server restart)
         — remove unconditional GraphQL_Server.start() from Platform.Make; let makeApiResource drive it

Phase 10: Update Platform.T and concrete Platform implementations (AWS, in-memory)
          — exposes Api factory through Platform abstraction

Phase 11: Resolve Q8 (DCB auth configuration) — extend StateChangeSlice.Spec /
          StateViewSlice.Spec if option (a) is chosen

Phase 12: Update examples (both aggregate-only and DCB/mixed) and documentation
```

Phases 1–4 have no AWS dependency and can be built and tested in isolation. Phase 3 should include unit tests for all four entry types including mixed-plugin scenarios. Phases 6–8 are the runtime stitching loop and can be validated end-to-end with in-memory tests (DCB E2E test pattern) once Phase 9 is complete.

---

## Summary

The API component introduces a clean, component-structured abstraction over multi-provider platform APIs. The design rests on four simplifying decisions:

**1. Platform concern, not a spec concern.** `Api.res` and `Api_Adapter.res` live in `reventless-infra`, not `reventless-spec`. The `reventless-spec` package contains only types that user/application code declares (Aggregate.Spec, ReadModel.Spec, etc.). No user ever writes an API spec — the schema is derived automatically. `Api.T` follows the same pattern as `ReadModel.T`, `Aggregate.T`, and `Platform.T`, all of which live in `reventless-infra`. Only the opaque `schemaFragment` type stays in `reventless-spec/Plugin.res` because it travels inside `pluginDefinition`.

**2. Two entry types, not four.** `Plugin_Builder` reduces all schema sources — aggregate commands, DCB StateChangeSlice commands, ReadModel states, StateViewSlice states — to two uniform entry types (`mutationSchemaEntry`, `querySchemaEntry`). The aggregate-vs-DCB distinction is captured only in the pre-computed field names; the generator is unaware of it.

**3. Three-part fragment encoding for GraphQL; protocol-specific for others.** For GraphQL, `schemaFragment.encoded` is a JSON blob `{types, mutations, queries}` — three strings kept separate so the stitcher can merge them at the correct level (all types together, all mutation fields together, all query fields together) before wrapping in `type Query {}` / `type Mutation {}`. For OpenAPI the encoding would use `{paths, schemas}`. The `schemaFragment` type in `reventless-spec` is opaque (`encoded: string`) — only the protocol-specific generator and stitcher know the internal structure.

**4. No protocol-agnostic generator layer.** The sury-to-schema traversal is inherently protocol-specific (SDL vs JSON Schema). Each protocol has its own generator (`GraphQL_FragmentGenerator`, future `OpenAPI_FragmentGenerator`) in `reventless-core`. Provider-specific infrastructure (AppSync API resource creation, API Gateway deployment) lives in `reventless-aws`. The `Api_Adapter.Provider` interface binds these two concerns together behind a single module type.

**In-memory adapter uses the existing graphql-yoga server** (not a no-op). `reventless-in-memory` already runs a graphql-yoga server that collects resolvers during component construction. The `GraphQL_InMemory_Adapter` drives this server with typed SDL generated by the same `GraphQL_FragmentGenerator` as the AppSync adapter, and hot-reloads the schema via `GraphQL_Server.rebuildSchema` when plugins connect. The result is a real local GraphQL API that mirrors production behaviour — developers get a live GraphiQL playground that updates as plugins register.

By extending `pluginDefinition` with an `apiSchemaFragment` and calling `Provider.updateSchema` in the plugin connect/disconnect handler, the already-existing dynamic plugin registration mechanism becomes a dynamic API schema management system — no new infrastructure is needed. Field name uniqueness across the entire platform is guaranteed by construction through the plugin-name-prefixed naming conventions.
