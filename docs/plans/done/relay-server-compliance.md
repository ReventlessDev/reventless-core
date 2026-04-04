# Plan: Add Relay Server Compliance to Reventless GraphQL API

**Date:** 2026-04-03
**Target:** GraphQL schema generation and resolvers support Relay conventions, enabling rescript-relay clients

---

## Context

reventless-ui is migrating from `rescript-apollo-client` (unmaintained) to `rescript-relay` for type-safe GraphQL in ReScript 12. Relay requires specific server-side conventions that the current auto-generated schema does not provide.

### What Relay Requires

| Convention | Description | Current State |
|-----------|-------------|---------------|
| **Node interface** | `interface Node { id: ID! }` + `node(id: ID!): Node` root query | Not present |
| **Global Object IDs** | Every entity's `id` must be globally unique | IDs are per-aggregate (UUIDs, likely unique already) |
| **Connection spec** | `edges`/`pageInfo` for pagination | Uses AppSync-style `items`/`nextToken`/`scannedCount` |

### Architecture Overview

The schema is **auto-generated** from aggregate/read-model definitions:

```
Plugin apiSchemaFragment → GraphQL_Stitcher → SDL → AppSync / graphql-yoga
                                ↑
GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
```

Key files:
- `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` — generates SDL from sury schemas
- `reventless-core/src/components/Api/GraphQL_Stitcher.res` — merges fragments into final SDL
- `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — AppSync resolver deployment
- `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` — in-memory resolver deployment

---

## Phase 1: Global Object IDs

### 1.1 Verify ID Uniqueness

**Question:** Are entity IDs already globally unique?

Current ID generation uses `Uuid.v4` (from `Message.res`). If all entities use UUIDv4, they're effectively globally unique without encoding.

**Action:**
- Audit ID generation across aggregates and read models
- If all UUIDs: global uniqueness is satisfied without changes
- If not all UUIDs: introduce `base64(TypeName:localId)` encoding at the schema layer

### 1.2 Add Node Interface to Schema Generation

Add the Relay Node interface and `node` root query to the stitched schema.

**Files to modify:**
- `GraphQL_Stitcher.res` — inject Node interface and `node` query into stitched SDL

**Implementation:**

The stitcher already composes `types`, `queries`, `mutations` arrays. Add Relay base types:

```rescript
// In GraphQL_Stitcher.stitch():
let relayBaseTypes = `interface Node {
  id: ID!
}`

let nodeQuery = `  node(id: ID!): Node`
```

Make each generated object type implement `Node`:
```
// Current:  type shop_Product { id: ID! name: String! ... }
// Relay:    type shop_Product implements Node { id: ID! name: String! ... }
```

**Files to modify:**
- `GraphQL_FragmentGenerator.res` — `objectRefToGraphQL` and `deriveObjectTypeWithNested` should emit `implements Node` when `includeIdParam` is true (entities with IDs implement Node)

### 1.3 Add Node Resolver

The `node(id: ID!): Node` query must resolve any entity by its global ID.

**AppSync (`QueryDbResolvers_AppSync.res`):**
- Needs a pipeline resolver that:
  1. Decodes the ID to determine the entity type (if IDs need encoding) or queries a type registry
  2. Routes to the correct DynamoDB table
  3. Returns the entity with `__typename` set

- If IDs are already UUIDs and globally unique, the resolver needs a registry mapping ID → table. This is complex in AppSync's VTL/JS resolver model.

**Alternative approach:** Since AppSync resolvers are type-based, the `node` query could be a Lambda resolver that looks up the entity type from a metadata index or tries each table.

**In-memory (`QueryDbResolvers_GraphQL.res`):**
- Simpler: iterate all registered QueryDb instances, try `loadStream(id)` until one returns a result
- Return with `__typename` field set

**Action:**
- For AppSync: create a Lambda-backed resolver for `node` that queries a type registry
- For in-memory: create a resolver that scans all QueryDb instances

### 1.4 Add `__typename` to All Responses

Relay uses `__typename` for cache normalization. GraphQL servers return this automatically for interfaces/unions, but resolvers must ensure objects are properly typed.

**AppSync:** Automatically handled — AppSync adds `__typename` based on the schema type.
**In-memory (graphql-yoga):** Automatically handled by GraphQL execution engine.

No changes needed here.

---

## Phase 2: Connection Spec for Pagination

### 2.1 Generate Connection Types

Replace the current plural wrapper type:

```graphql
# Current
type shop_Products {
  nextToken: String
  scannedCount: Int!
  items: [shop_Product!]!
}

# Relay Connection spec
type shop_ProductEdge {
  node: shop_Product!
  cursor: String!
}

type shop_ProductConnection {
  edges: [shop_ProductEdge!]!
  pageInfo: PageInfo!
  totalCount: Int
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

**Files to modify:**
- `GraphQL_FragmentGenerator.res`:
  - Replace `derivePluralWrapperType` with `deriveConnectionType` that generates `Edge` + `Connection` types
  - Replace `deriveListQueryField` to use `first`/`after`/`last`/`before` arguments
  - Add `PageInfo` type to the stitcher base types (once, not per entity)

```rescript
let deriveConnectionType = (~singularTypeName: string): array<string> => [
  `type ${singularTypeName}Edge {\n  node: ${singularTypeName}!\n  cursor: String!\n}`,
  `type ${singularTypeName}Connection {\n  edges: [${singularTypeName}Edge!]!\n  pageInfo: PageInfo!\n  totalCount: Int\n}`,
]

let deriveConnectionQueryField = (~listFieldName: string, ~singularTypeName: string): string =>
  `  ${listFieldName}(first: Int, after: String, last: Int, before: String): ${singularTypeName}Connection!`
```

### 2.2 Update Query Naming

Current: `everyPlugin(nextToken, limit): Plugins!`
Relay: `plugins(first, after, last, before): PluginConnection!`

The naming already uses `pluralize(name)` for list queries. The return type changes from `{pluralTypeName}` to `{singularTypeName}Connection`.

**Files to modify:**
- `Api_Naming.res` — update `pluralTypeName` to use `Connection` suffix, or add a new `connectionTypeName` field to `queryNames`

### 2.3 Update AppSync Resolvers for Connection Spec

Current AppSync resolvers use `Resolver.Functions.listAllItems` which returns `{ items, nextToken, scannedCount }`.

**Files to modify:**
- `QueryDbResolvers_AppSync.res` — the list resolver VTL/JS code must transform DynamoDB scan results into connection format:

```javascript
// Current resolver output:
{ nextToken, scannedCount, items }

// Relay connection output:
{
  edges: items.map((item, i) => ({ node: item, cursor: encodeCursor(i, nextToken) })),
  pageInfo: {
    hasNextPage: !!nextToken,
    hasPreviousPage: !!args.after,
    startCursor: edges[0]?.cursor,
    endCursor: edges[edges.length - 1]?.cursor,
  },
  totalCount: scannedCount,
}
```

- The `first`/`after` arguments map to DynamoDB's `limit`/`ExclusiveStartKey`
- Cursor encoding: `base64(JSON.stringify({ nextToken, index }))` — opaque to the client

**Files to modify:**
- Resolver function templates in AppSync (wherever `Resolver.Functions.listAllItems` is defined)

### 2.4 Update In-Memory Resolvers for Connection Spec

**Files to modify:**
- `QueryDbResolvers_GraphQL.res` — the `listResolver` must return connection-shaped data instead of `{ nextToken, scannedCount, items }`:

```rescript
let items = /* ... existing scan logic ... */
let edges = items->Array.mapWithIndex((item, i) => {
  Obj.magic({"node": item, "cursor": Int.toString(i)})
})
Obj.magic({
  "edges": edges,
  "pageInfo": {
    "hasNextPage": false,
    "hasPreviousPage": false,
    "startCursor": edges->Array.get(0)->Option.map(e => (e->Obj.magic)["cursor"]),
    "endCursor": edges->Array.at(-1)->Option.map(e => (e->Obj.magic)["cursor"]),
  },
  "totalCount": items->Array.length,
})
```

---

## Phase 3: Backward Compatibility

### 3.1 Strategy: Feature Flag or Breaking Change?

**Option A: Feature flag** — Add a `relayCompliant` option to `querySchemaEntry` or a global config. When enabled, generate connection types; when disabled, generate the current `items/nextToken` pattern.

**Option B: Breaking change** — Switch entirely to connection spec. All existing clients must update.

**Recommendation: Option A (feature flag)** initially, then deprecate the old pattern.

```rescript
// In ReventlessInfra.Api
type querySchemaEntry = {
  // ... existing fields ...
  connectionSpec?: bool,  // default false for backward compat
}
```

This allows reventless-ui to opt into Relay connections while other consumers continue using the current pattern.

### 3.2 Schema Export for Relay Compiler

The Relay compiler needs the schema in SDL format (`.graphql` file). Currently the schema is available as:
- Introspection JSON (`reventless-core-schema.json` in reventless-ui)
- SDL string (generated by `GraphQL_Stitcher.stitch`)

**Action:** Add a script or API endpoint that exports the stitched SDL to a `.graphql` file for the Relay compiler.

For the in-memory dev server (graphql-yoga), this could be:
```bash
# Fetch SDL from running dev server
curl http://localhost:4000/sdl > schema.graphql
```

Or a build step that writes the stitched SDL to disk during `rescript build`.

---

## Execution Checklist

```
Phase 1 — Global Object IDs
  [x] 1.1  Audit: entity IDs are app-provided strings (NOT UUIDs) → base64(TypeName:localId) encoding added
  [x] 1.2  GraphQL_FragmentGenerator: add `implements Node` to entity types
  [x]      GraphQL_Stitcher: inject `interface Node { id: ID! }` base type
  [x] 1.3  In-memory: add `node(id: ID!)` resolver (scan all QueryDb instances via nodeTypeRegistry)
  [x] 1.3  AppSync: add `node(id: ID!)` pipeline resolver (NONE datasource decode + per-type DynamoDB functions)
  [x] 1.4  Verify __typename is returned (automatic for graphql-yoga; set in node resolver)

Phase 2 — Connection Spec
  [x] 2.1  GraphQL_FragmentGenerator: add deriveConnectionType (Edge + Connection)
  [x]      GraphQL_Stitcher: inject `type PageInfo { ... }` base type
  [x] 2.2  Api_Naming: add connectionSpec to queryNames (propagated from registry)
  [x] 2.3  AppSync resolvers: listAllItemsConnection template added
  [x]      AppSync resolvers: accept first/after/last/before arguments (via connectionSpec flag)
  [x] 2.4  In-memory resolvers: transform list results to edges/pageInfo format
  [x]      In-memory resolvers: accept first/after/last/before arguments (via connectionSpec flag)

Phase 3 — Integration
  [x] 3.1  Add connectionSpec flag to querySchemaEntry (opt-in per query)
  [x] 3.2  Add SDL export via /sdl endpoint on in-memory graphql-yoga server
  [x]      Verify: in-memory server serves Relay-compliant schema (tests pass)
  [x]      Verify: AppSync serves Relay-compliant schema (resolver templates + NodeResolver_AppSync wiring)

Phase 4 — Make Connection Spec the Default (global flag)
  [x] 4.1  Plugin_Builder: pass connectionSpec=true when building querySchemaEntry for all read models
  [x]      Dcb_Builder: same for StateViewSlice, AutomationSlice, OutboundTranslationSlice, InboundTranslationSlice query entries
  [x] 4.2  Api_Naming: default connectionSpec=true in all queryFieldNamesFor* functions
  [x]      GraphQL_FragmentGenerator: default Option.getOr(true) instead of false
  [x]      In-memory resolver: default true when registry entry absent
  [x]      AppSync resolver: default true when registry entry absent
  [x]      (kept connectionSpec?: bool field as an explicit opt-out escape hatch)
  [x] 4.3  Examples pick up connection spec automatically via Plugin_Builder/Dcb_Builder (no example changes needed)
  [x] 4.4  GraphQL_SchemaInspectorTest: updated legacy test to use explicit connectionSpec=false; updated inspectFragment assertions for connection shape
```

---

## Files Inventory

### Must Modify

| File | Change |
|------|--------|
| `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` | Add `implements Node`, connection types, connection query fields |
| `reventless-core/src/components/Api/GraphQL_Stitcher.res` | Inject Node interface, PageInfo type |
| `reventless-core/src/components/Api/Api_Naming.res` | Add `connectionTypeName` to `queryNames` |
| `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Connection-format list resolver, node resolver |
| `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` | Connection-format list resolver, node resolver |

### Must Modify (resolver function templates)

| File | Change |
|------|--------|
| `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` | `listAllItemsConnection`, `nodeDecodeGlobalId`, `nodeGetItemForType` templates |
| `rescript-pulumi-aws/src/AppSync/AppSync_DataSource.res` | Added `NONE` data source type + `makeNoneDataSource` helper |

### New Files

| File | Purpose |
|------|---------|
| `reventless-aws/src/adapter/QueryDb/NodeResolver_AppSync.res` | AppSync pipeline resolver for `node(id: ID!)` — wires NONE decode + per-type DynamoDB functions |

### May Modify

| File | Change |
|------|--------|
| `reventless-spec/src/components/Plugin.res` | If `apiSchemaFragment` format changes |
| `ReventlessInfra.Api` types | Add `connectionSpec` flag to `querySchemaEntry` |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `node` resolver performance (scanning all tables) | Medium | Medium | Type registry lookup instead of scan; cache mapping |
| DynamoDB cursor encoding mismatch with Relay expectations | Low | High | Relay treats cursors as opaque strings — any encoding works |
| Breaking existing non-Relay clients | High if no flag | High | No non-Relay clients planned — making connection spec the default (Phase 4) |
| AppSync `node` resolver complexity | Medium | Medium | Lambda resolver is flexible; VTL would be harder |
| Connection spec in AppSync VTL templates | Medium | Medium | Use JS resolvers (AppSync supports both) |

---

## Phase 4: Make Connection Spec the Default

### Context

Phase 3 implemented `connectionSpec` as an opt-in flag per `querySchemaEntry`. However, since no non-Relay clients are planned, the opt-in adds noise without benefit. The goal is to make connection spec the unconditional default for all list queries.

### 4.1 Plugin_Builder and Dcb_Builder

`Plugin_Builder.res` builds `querySchemaEntry` records from read models without setting `connectionSpec` (defaults to `false`). Same for `Dcb_Builder.res` for StateViewSlice query entries.

**Change:** Pass `connectionSpec: true` in the built entries, or remove the field check and always generate connection types.

### 4.2 Remove or Default the Flag

Two options:
- **Keep field, default true** — least churn; existing code that sets `connectionSpec: false` can still opt out
- **Remove field entirely** — cleaner; connection spec is unconditional

Recommended: keep the field but default to `true` in `GraphQL_FragmentGenerator` and resolvers, so the field can still be used to opt out if ever needed.

### 4.3 Update Examples

Both `online-shop-aggregates` and `online-shop-dcb` will automatically pick up connection spec once `Plugin_Builder` / `Dcb_Builder` pass `connectionSpec: true`. Verify the generated SDL uses `ProductConnection`, `edges`, `pageInfo`, etc.

### 4.4 Update Tests

`GraphQL_SchemaInspectorTest.res` has test cases asserting the legacy plural wrapper shape (`connectionSpec=false (default) generates legacy plural wrapper`). These must be updated or removed once the default flips.

### Files to Modify

| File | Change |
|------|--------|
| `reventless-core/src/components/Plugin/Plugin_Builder.res` | Set `connectionSpec: true` in read model query entries |
| `reventless-core/src/components/Dcb/Dcb_Builder.res` | Set `connectionSpec: true` in StateViewSlice query entries |
| `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` | Change default from `false` to `true` |
| `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` | Change default from `false` to `true` |
| `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Change default from `false` to `true` |
| `reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res` | Update/remove legacy plural wrapper test |
