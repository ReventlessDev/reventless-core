# Debugging GraphQL Schemas

This guide explains how to inspect GraphQL schema generation at every level of the Reventless pipeline, both for a running platform and from test/script code.

## Overview

The GraphQL schema pipeline flows through four stages:

```
sury schemas (@schema types)
  → Plugin_Builder (collects mutation/query entries)
    → GraphQL_FragmentGenerator (derives SDL fragments)
      → GraphQL_Stitcher / GraphQL_Server (merges and serves)
```

Each stage has inspector functions you can call to see what was generated.

## Running with Debug Mode

By default the in-memory GraphQL server masks resolver errors (returning a generic "Unexpected error") and suppresses request logging. Set the `GRAPHQL_DEBUG` environment variable to enable verbose error reporting:

```bash
GRAPHQL_DEBUG=1 npx tsx src/Main.res.mjs
```

The DCB example package includes a convenience script for this:

```bash
cd examples/dcb/example-dcb
npm run dev    # starts with GRAPHQL_DEBUG=1
npm run run    # starts without debug (production-like)
```

When `GRAPHQL_DEBUG` is set:
- **`logging: true`** — graphql-yoga prints full error stack traces to the terminal
- **`maskedErrors: false`** — the actual error message appears in the GraphQL JSON response instead of "Unexpected error"

## Inspecting a Running Platform

### GraphiQL (browser)

The local platform starts with GraphiQL enabled. Open your browser at:

```
http://localhost:4000/graphql
```

This gives you an interactive schema explorer powered by the standard GraphQL introspection query. You can browse types, queries, and mutations and run test queries.

### Live SDL from the validated schema

After the platform starts, `GraphQL_Server` stores the live schema object. You can retrieve the canonical SDL — the representation that graphql-yoga actually parsed and is serving:

```rescript
// Get the SDL as a string
let sdl = ReventlessLocal.GraphQL_Server.getLiveSdl()
// option<string> — None if server hasn't started

// Print it to console
ReventlessLocal.GraphQL_Server.printLiveSdl()
```

This uses `graphql`'s `printSchema` on the live schema object, so it reflects exactly what the server accepted after validation and normalization.

### Full diagnostics

The `diagnostics()` function gives you a complete picture of the server's state, including **mismatch detection** (SDL fields without resolvers, or resolvers without SDL fields):

```rescript
let d = ReventlessLocal.GraphQL_Server.diagnostics()
// d.sdlMutationCount — number of mutation fields in SDL
// d.resolverMutationCount — number of registered mutation resolvers
// d.mismatches — array of mismatch descriptions (should be empty)
// d.fullSdl — the raw input SDL string
// d.serverRunning — whether the HTTP server is active

// Or print everything at once:
ReventlessLocal.GraphQL_Server.printDiagnostics()
```

Example output:

```
[GraphQL Diagnostics]
  Mutations: 8 SDL fields, 8 resolvers
    SDL: Catalog_AddProduct
    SDL: Catalog_RenameCategory
    ...
    Resolver: Catalog_AddProduct
    Resolver: Catalog_RenameCategory
    ...
  Queries: 3 SDL fields, 3 resolvers
    SDL: Catalog_Product
    ...
  No mismatches
  Server running: yes

--- Full SDL ---
type Query {
  Catalog_Product(id: ID!): CatalogProduct
  ...
}
...
--- End ---
```

### Input SDL vs live SDL

Compare the raw input SDL (before graphql-yoga parsing) with the live SDL (after parsing) to spot normalization differences:

```rescript
let inputSdl = ReventlessLocal.GraphQL_Server.getFullSdl()  // raw string fragments joined
let liveSdl = ReventlessLocal.GraphQL_Server.getLiveSdl()     // from printSchema
```

If the input SDL was malformed, graphql-yoga would have thrown at startup. If both exist but differ, the difference reveals normalization the parser applied.

### HTTP introspection (curl)

From a terminal, you can query the running server directly:

```bash
# Standard introspection query
curl -s http://localhost:4000/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ __schema { types { name } } }"}' | jq .

# List all mutations
curl -s http://localhost:4000/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ __schema { mutationType { fields { name } } } }"}' | jq .
```

## Inspecting During Development

### Granular level — individual sury schemas

Use `GraphQL_SchemaInspector` to see what GraphQL types a sury schema produces. All functions accept polymorphic `S.t<'a>` — no casting needed at the call site.

```rescript
// What GraphQL scalar does this schema map to?
GraphQL_SchemaInspector.inspectScalar(MySpec.someFieldSchema)
// "ID!" | "String" | "Float" | "Boolean"

// What GraphQL type definition does a state schema produce?
GraphQL_SchemaInspector.inspectObjectType(~typeName="Product", ProductSpec.stateSchema)
// Some("type Product {\n  id: ID!\n  name: String\n  price: Float\n}")

// What mutation fields does a command schema produce?
GraphQL_SchemaInspector.inspectMutationFields(~fieldPrefix="Catalog_Product", commandSchema)
// ["  Catalog_Product_Create(id: ID!, name: String): String!",
//  "  Catalog_Product_Rename(id: ID!, newName: String): String!"]

// What query fields does a state schema produce?
GraphQL_SchemaInspector.inspectQueryFields(~name="Catalog_Product", ~typeName="CatalogProduct", stateSchema)
// { typeDef: Some("type CatalogProduct { ... }"),
//   singleQuery: "  Catalog_Product(id: ID!): CatalogProduct",
//   listQuery: Some("  Catalog_Products(nextToken: String, limit: Int): [CatalogProduct]") }
```

### Plugin level — fragment inspection

After a plugin's schema fragment is generated, decode it to see types, mutations, and queries:

```rescript
// Inspect a fragment as structured data
let info = GraphQL_SchemaInspector.inspectFragment(plugin.apiSchemaFragment)
// info.types: ["type CatalogProduct { ... }", ...]
// info.mutations: ["  Catalog_AddProduct(...): String!", ...]
// info.queries: ["  Catalog_Product(id: ID!): CatalogProduct", ...]
// info.sdlPreview: full SDL string preview

// Print a formatted summary to console
GraphQL_SchemaInspector.printFragment(plugin.apiSchemaFragment)
```

To inspect what entries `Plugin_Builder` assembles *before* they become a fragment:

```rescript
let summary = GraphQL_SchemaInspector.inspectPluginEntries(~mutationEntries, ~queryEntries)
// "Mutations (8): Catalog_AddProduct, Catalog_RenameCategory, ...
//  Queries (3): Catalog_Product(id) -> CatalogProduct, ..."
```

### Platform level — registered resolvers and SDL

See what's registered in the server's internal registry:

```rescript
// The Query/Mutation SDL built from registered resolver fields
let sdl = GraphQL_Server.getRegisteredSdl()

// The resolver function names (keys in the resolver dicts)
let names = GraphQL_Server.getRegisteredResolverNames()
// names.mutations: ["Catalog_AddProduct", ...]
// names.queries: ["Catalog_Product", ...]

// The live schema object (for programmatic use)
let schema = GraphQL_Server.getSchema()
// option<GraphqlYoga.schema>
```

## DCB Example Debug Script

The DCB example includes a ready-made debug script that boots the platform and dumps everything:

```bash
cd examples/dcb/example-dcb
npx rescript          # compile ReScript → JS
node src/DebugSchema.res.mjs
```

This prints the live SDL and full diagnostics, then exits. To keep the server running for GraphiQL:

```rescript
// In DebugSchema.res, comment out the last line:
// ReventlessLocal.GraphQL_Server.stop()
```

Then visit `http://localhost:4000/graphql` in a browser.

## Integrating Into a New Platform Instance

When building a new local platform (e.g., in a test or example), add diagnostics after all components are wired:

```rescript
module Platform = ReventlessLocal.Platform.Make()
module MyPlugin = MyPluginModule.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(MyPlugin)],
)

// 2. Inspect — pick the level you need

// Quick check: is the server running with the right schema?
ReventlessLocal.GraphQL_Server.printLiveSdl()

// Detailed check: are all resolvers matched to SDL fields?
ReventlessLocal.GraphQL_Server.printDiagnostics()

// Programmatic check in a test:
let d = ReventlessLocal.GraphQL_Server.diagnostics()
assert(d.mismatches->Array.length == 0)

// 3. Cleanup
ReventlessLocal.GraphQL_Server.stop()
// or GraphQL_Server.reset() between test suites
```

## Common Debugging Scenarios

### Schema is empty or has only `_noop` fields

Check that your plugin's `dcbSpec` is being passed correctly. Without it, no StateChangeSlice mutations or StateViewSlice queries are generated. Use `printDiagnostics()` to see if any SDL fields or resolvers are registered.

### Mutations appear but return errors at runtime

Use `diagnostics()` to check for mismatches — a mutation might have an SDL field but no resolver (or the resolver name doesn't match the field name). The `mismatches` array will flag these.

### A field is missing from the schema

Use `inspectMutationFields` or `inspectQueryFields` with the spec's schema to see what would be generated. If the schema is a plain `String` or `Number` instead of an `Object` or `Union`, no fields will be derived.

### Comparing input SDL to live SDL

If the schema looks wrong in GraphiQL, compare:

```rescript
Console.log("=== INPUT SDL ===")
Console.log(GraphQL_Server.getFullSdl())
Console.log("=== LIVE SDL ===")
Console.log(GraphQL_Server.getLiveSdl())
```

If they differ, the graphql parser normalized something. If the input SDL is wrong, trace back to the fragment generator using `inspectFragment`.

## API Reference

### `ReventlessCore.GraphQL_SchemaInspector`

| Function | Signature | Description |
|----------|-----------|-------------|
| `inspectScalar` | `S.t<'a> => string` | GraphQL scalar type for a field schema |
| `inspectObjectType` | `(~typeName, S.t<'a>) => option<string>` | GraphQL type definition SDL |
| `inspectMutationFields` | `(~fieldPrefix, S.t<'a>) => array<string>` | Mutation field SDL lines |
| `inspectQueryFields` | `(~name, ~typeName, S.t<'a>) => queryFieldInspection` | Type def + query field SDL |
| `inspectFragment` | `apiSchemaFragment => fragmentInspection` | Decoded fragment breakdown |
| `printFragment` | `apiSchemaFragment => unit` | Formatted fragment to console |
| `inspectPluginEntries` | `(~mutationEntries, ~queryEntries) => string` | Summary of plugin entries |

### `ReventlessLocal.GraphQL_Server`

| Function | Signature | Description |
|----------|-----------|-------------|
| `getRegisteredSdl` | `unit => string` | Query/Mutation SDL from registered resolvers |
| `getRegisteredResolverNames` | `unit => resolverNames` | Mutation and query resolver keys |
| `getFullSdl` | `unit => option<string>` | Last raw input SDL passed to `createSchema` |
| `getSchema` | `unit => option<schema>` | Live GraphQL schema object |
| `getLiveSdl` | `unit => option<string>` | Canonical SDL via `printSchema` |
| `printLiveSdl` | `unit => unit` | Print live SDL to console |
| `diagnostics` | `unit => diagnostics` | Full diagnostics with mismatch detection |
| `printDiagnostics` | `unit => unit` | Print diagnostics to console |
