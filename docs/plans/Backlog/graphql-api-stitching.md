# Plan: GraphQL API Stitching for Multi-Plugin Platforms

## Problem Statement

Each Reventless plugin defines its own domain: aggregates with commands, read models with queries, and optionally DCB state-change/view slices. When multiple plugins are deployed together as a single **platform**, clients need a **unified GraphQL API** — not one endpoint per plugin. Today this is stitched manually and ad hoc (see `CoreApi.res` + `PluginApi.res`). This plan describes a systematic, plugin-driven approach.

---

## Design Goals

1. Each plugin **declares its own schema fragment** (types, queries, mutations) as part of its spec.
2. The platform **Core** collects all fragments at deploy-time and stitches them into one unified schema.
3. The **reventless-core** package provides the generic stitching mechanism.
4. The **reventless-aws** package implements the AppSync-specific realisation that builds on it.
5. No runtime schema introspection or federation — all stitching happens at Pulumi deploy time.

---

## Background: What Already Exists

### SDL composition pattern (CoreApi / PluginApi)
`reventless-core/src/core/API/PluginApi.res` and `CoreApi.res` already compose SDL strings from parts. The pattern is:

```rescript
let typesSchema = `type Plugin { ... }`
let queriesSchema = `plugin(id: ID!): Plugin ...`
let mutationsSchema = `Plugin_Activate(id: ID!): String! ...`
let graphQLSchema = `${typesSchema}\ntype Query {\n${queriesSchema}\n}\ntype Mutation {\n${mutationsSchema}\n}`
```

This shows SDL concatenation works today — it just needs to be generalised across plugins.

### AppSync resolvers (per component)
- `CommandGeneratorResolvers_AppSync` maps aggregate command fields → AppSync Mutation resolvers (VTL → Lambda).
- `QueryDbResolvers_AppSync` maps read model fields → AppSync Query resolvers.
- Both take a `fields: array<string>` argument — the field names must exactly match the SDL declaration.

### Plugin.outputs
`reventless-spec/src/components/Plugin.res` defines `outputs` with `resolvers: Pulumi.Output.t<array<Adapter.resource>>`. The resolvers are already collected — the schema fragment is the missing companion.

### Plugin.T make signature
```rescript
let make: (~name, ~version, ~heartbeatInterval, ~extensionPoints, ~extensions,
           ~aggregates, ~readModels, ~tasks, ~api, ~apiRole, ~scheduler, ~dcbSpec, ~opts) => component
```
The `api` and `apiRole` parameters are already the hook point for platform-level API infrastructure.

---

## Generic Approach: reventless-core and reventless-spec

### Phase 1 — Define the schema contributor contract (reventless-spec)

**New file: `reventless-spec/src/components/GraphqlSchema.res`**

```rescript
// A plugin-level schema fragment contributed to the platform's unified GraphQL API.
// typesFragment:     SDL type definitions (no Query/Mutation wrappers)
// queriesFragment:   bare fields to merge into the unified Query type
// mutationsFragment: bare fields to merge into the unified Mutation type
module type Contributor = {
  let typesFragment: string
  let queriesFragment: string
  let mutationsFragment: string
}

// Minimal helper type carried in Plugin.outputs
type fragment = {
  types: string,
  queries: string,
  mutations: string,
}
```

**Extend `Plugin.outputs` in `reventless-spec/src/components/Plugin.res`:**

```rescript
type outputs = {
  ...existing fields...
  graphqlSchema: Pulumi.Output.t<fragment>,  // NEW
}
```

Where `fragment` is `GraphqlSchema.fragment`.

### Phase 2 — Plugin-level SDL generation (reventless-core)

**New file: `reventless-core/src/components/Plugin/Plugin_GraphqlSchema.res`**

Provides a helper that, given a plugin's aggregates and read models, generates the SDL fragment:

```rescript
// Generates the SDL fragment for one plugin.
// - mutationFields: collected from all CommandGenerator specs in the plugin
// - queryFields:    collected from all ReadModel / StateViewSlice specs
// Returns GraphqlSchema.fragment
let make: (
  ~pluginName: string,
  ~mutationFields: array<(string, string)>,  // (fieldName, sdlArgs+return)
  ~queryFields: array<(string, string)>,
  ~extraTypes: string=?,
) => GraphqlSchema.fragment
```

Each aggregate's `CommandGenerator.Spec` already knows its mutation field names (via `fields`). Each `ReadModel.Spec` knows its query shape. The builder calls `Plugin_GraphqlSchema.make` and stores the result in `Plugin.outputs.graphqlSchema`.

**Extend `Plugin_Builder.res`**

Inside the `make` function, after building all aggregates and read models, derive the `graphqlSchema` fragment and include it in `outputs`.

### Phase 3 — Schema stitching in Core (reventless-core)

**New file: `reventless-core/src/core/GraphqlSchemaStitcher.res`**

```rescript
// Merges an array of GraphqlSchema.fragment values into one SDL string.
// Rules:
//   - typesFragments are concatenated as-is (types from different plugins must not collide)
//   - queriesFragments are merged into a single `type Query { ... }` block
//   - mutationsFragments are merged into a single `type Mutation { ... }` block
//   - A base fragment (platform schema) is prepended
let stitch: (
  ~baseFragment: GraphqlSchema.fragment,
  ~pluginFragments: array<Pulumi.Output.t<GraphqlSchema.fragment>>,
) => Pulumi.Output.t<string>   // the final SDL string
```

The base fragment contains the existing `PluginApi` + `CoreApi` types/queries/mutations.

**Extend `Core.outputs` in `reventless-spec/src/components/Core.res`** (if it exists) or `CoreApi`:

```rescript
type outputs = {
  ...existing fields...
  unifiedGraphqlSchema: Pulumi.Output.t<string>,   // final stitched SDL
}
```

The `Core_Builder` calls `GraphqlSchemaStitcher.stitch` with all plugin `graphqlSchema` outputs and stores the result.

---

## AWS-Specific Approach: reventless-aws / AppSync

Builds directly on Phase 1–3 above. The AppSync realisation consumes `Core.outputs.unifiedGraphqlSchema` to create an `AppSync.GraphQLApi` and wires all resolver infrastructure.

### Phase 4 — AppSync Core Builder (reventless-aws)

**New file or extension: `reventless-aws/src/core/Core_AppSync_Builder.res`**

```rescript
// Creates the AppSync GraphQL API from the stitched schema and wires all plugin resolvers.
module Make = (Plugins: { let plugins: array<module(ReventlessSpec.Plugin.T)> }) => {
  let make = (~name, ~auth, ~opts) => {
    // 1. Stitch all plugin schemas (via GraphqlSchemaStitcher)
    let schema = GraphqlSchemaStitcher.stitch(~baseFragment, ~pluginFragments)

    // 2. Create the AppSync API resource
    let api = PulumiAws.AppSync.GraphQLApi.make(~name, ~args={ schema, authenticationType: auth, ... }, ~opts)

    // 3. For each plugin, attach its resolvers to the API
    //    - CommandGeneratorResolvers_AppSync for mutations
    //    - QueryDbResolvers_AppSync for queries
    //    Both already collect their Adapter.resource list from Plugin.outputs.resolvers

    // 4. Return Core.outputs including the api handle
    { api, unifiedGraphqlSchema: schema, ... }
  }
}
```

**AppSync-specific schema considerations:**

- Auth directives: Each plugin fragment may include `@aws_auth(cognito_groups: [...])` on its fields. The stitcher preserves these verbatim — they are part of the fragment strings.
- No merging of conflicting type names across plugins — plugin authors must prefix their types (e.g., `CatalogProduct`, `OrderingOrder`). A naming convention should be documented.
- `type Query` and `type Mutation` in AppSync SDL must appear exactly once — the stitcher ensures this by merging all field fragments into a single `type Query { }` and `type Mutation { }` block.
- The existing `CoreApi.graphQLSchema` (admin plugin/extension management queries) becomes the `baseFragment` in `GraphqlSchemaStitcher.stitch`.

**Resolver wiring stays as-is:**

The AppSync resolver infrastructure (`CommandGeneratorResolvers_AppSync`, `QueryDbResolvers_AppSync`) does not change. It is already driven by `fields: array<string>` per aggregate/read-model. The SDL fragment must declare fields whose names exactly match those `fields` arrays — this invariant is enforced by generating both from the same spec.

---

## File Map

### New files

| Package | File | Purpose |
|---------|------|---------|
| `reventless-spec` | `src/components/GraphqlSchema.res` | `Contributor` module type + `fragment` record |
| `reventless-core` | `src/components/Plugin/Plugin_GraphqlSchema.res` | Per-plugin SDL fragment generator |
| `reventless-core` | `src/core/GraphqlSchemaStitcher.res` | Merge fragments into unified SDL |
| `reventless-aws` | `src/core/Core_AppSync_Builder.res` | AppSync API creation + resolver wiring |

### Modified files

| Package | File | Change |
|---------|------|--------|
| `reventless-spec` | `src/components/Plugin.res` | Add `graphqlSchema: Pulumi.Output.t<GraphqlSchema.fragment>` to `outputs` |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | Populate `graphqlSchema` in `outputs` |
| `reventless-core` | `src/core/Core_Builder.res` | Call `GraphqlSchemaStitcher.stitch`, expose in `outputs` |

---

## Schema Fragment Example

Given a `Catalog` plugin with a `Product` aggregate (commands: `CreateProduct`, `UpdateProductPrice`) and a `ProductsView` read model:

**types fragment:**
```graphql
type CatalogProduct {
  id: ID!
  name: String!
  price: Float!
}
type CatalogProducts {
  items: [CatalogProduct!]!
  nextToken: String
}
```

**queries fragment:**
```graphql
CatalogProduct_get(id: ID!): CatalogProduct
  @aws_auth(cognito_groups: ["User", "Admin"])
CatalogProducts_list(nextToken: String, limit: Int): CatalogProducts!
  @aws_auth(cognito_groups: ["User", "Admin"])
```

**mutations fragment:**
```graphql
CatalogProduct_CreateProduct(id: ID!, name: String!, price: Float!): String!
  @aws_auth(cognito_groups: ["Admin"])
CatalogProduct_UpdateProductPrice(id: ID!, price: Float!): String!
  @aws_auth(cognito_groups: ["Admin"])
```

The stitcher combines this with fragments from `Ordering`, `Inventory`, etc., plus the base `PluginApi` admin schema.

---

## Naming Conventions (to document)

To avoid SDL type collisions across plugins:

1. **Type names** must be prefixed with the plugin name: `CatalogProduct`, `OrderingOrder`, `InventoryStockLevel`.
2. **Query fields** should follow `PluginName_ReadModelName_operation` or `PluginName_TypeName_verb`.
3. **Mutation fields** already follow `AggregateName_CommandName` from `CommandGeneratorResolvers_AppSync`.
4. Shared cross-cutting types (pagination cursors, error types) should live in the base fragment.

---

## Open Questions

1. **Who owns the `typesFragment`?** Should it be generated from `@schema`-annotated types automatically (via sury-ppx introspection), or always written manually as SDL strings? Auto-generation from `@schema` would reduce duplication but requires a new ppx pass or reflection layer.

2. **StateViewSlice queries**: DCB-based plugins use `StateViewSlice` for queries rather than `ReadModel`. The fragment generator needs to handle both. The query fields for `StateViewSlice` map to `QueryDbResolvers_AppSync` the same way.

3. **ExtensionPoint GraphQL exposure**: Should extension point command topics also be exposed as mutations (for direct cross-plugin calls via the API), or is that out of scope?

4. **Schema versioning at runtime**: The `extensionProtocol` in `Plugin.pluginDefinition` carries command/event schema versions. Should the stitched SDL include a `schemaVersion` scalar field for clients to detect changes?

5. **Subscription support**: AppSync supports `type Subscription`. Is real-time push via AppSync subscriptions (backed by SNS/DynamoDB Streams) in scope for this plan or a separate follow-up?

---

## Implementation Order

```
Phase 1: GraphqlSchema.res in reventless-spec         (small, no breaking changes)
Phase 2: Plugin_GraphqlSchema.res in reventless-core  (new helper, no breaking changes)
Phase 3: Plugin_Builder.res + Core_Builder.res        (additive: new field in outputs)
Phase 4: Core_AppSync_Builder.res in reventless-aws   (new file, consumes Phase 1-3)
```

Phases 1–2 are purely additive. Phase 3 adds a field to `Plugin.outputs` which may require updating existing example plugins to pass the new `graphqlSchema` field (could be optional `?`). Phase 4 is entirely new.

---

## Status

- [ ] Phase 1: Define `GraphqlSchema.fragment` type and `Contributor` module type in `reventless-spec`
- [ ] Phase 2: Implement `Plugin_GraphqlSchema.res` fragment generator in `reventless-core`
- [ ] Phase 3: Wire fragment generation into `Plugin_Builder` and stitching into `Core_Builder`
- [ ] Phase 4: Implement `Core_AppSync_Builder.res` in `reventless-aws`
- [ ] Document naming conventions for plugin type/field names
- [ ] Resolve open questions (auto-generation, StateViewSlice, subscriptions)
