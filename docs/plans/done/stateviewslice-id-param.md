# Plan: StateViewSlice Id-Parameterised Singular Queries

## Overview

StateViewSlice singular queries currently have no `id` parameter (`Plugin_Entity: Plugin_Entity`), causing the resolver to always load from the empty-string partition key — a latent bug that always returns `null`. The fix is Option A from the analysis: enable `includeIdParam: true` for StateViewSlice singular queries, matching ReadModel behaviour.

Enabling `includeIdParam` has three cascading effects already handled by existing infrastructure:
1. SDL changes from `Plugin_Entity: Plugin_Entity` to `Plugin_Entity(id: ID!): Plugin_Entity`
2. The generated GraphQL type changes to `implements Node { id: ID! ... }` — StateViewSlice types join the Relay node graph
3. The resolver injects an encoded Relay global `id` field into every singular response (`encodeGlobalId(typeName, id)`)

**What does not change**: DCB event projection logic, QueryDb storage, connection (plural) queries, AWS DynamoDB table structure.

---

## Step 1 — Fix `Api_Naming.res`

**File**: `reventless/reventless-core/src/components/Api/Api_Naming.res:51`

```rescript
// Before
let queryFieldNamesForStateView = (~plugin, ~viewName, ~connectionSpec=true) => {
  ...
  {
    ...
    includeIdParam: false,   // ← line 51
    ...
  }
}

// After
  includeIdParam: true,
```

This is the authoritative flag that controls SDL generation, type shape, and resolver behaviour downstream.

**Scope**: `reventless-core` only.

---

## Step 2 — Fix `Dcb_Builder.res`

**File**: `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res:491`

The query entry construction for StateViewSlices hardcodes `includeIdParam: false` **independently of `Api_Naming`**, which means the Step 1 change alone has no effect on the generated query entries passed to `GraphQL_FragmentGenerator`. This line must also be updated.

```rescript
// Before (line 491 in the query entry record literal)
includeIdParam: false,

// After
includeIdParam: qn.includeIdParam,
```

`qn` is the `queryNames` record returned by `Api_Naming.queryFieldNamesForStateView` already in scope at that call site.

**Scope**: `reventless-core` only.

---

## Step 3 — Verify Node interface registration

**File**: `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res:155–159`

When `includeIdParam` is `true`, the resolver calls `r.registerNodeType(~typeName, ~queryDbName)` to register the type in the Relay global `node(id: ID!)` resolver. This code path already exists and is gated on `includeIdParam`. No code change needed — confirm in review that the registration fires correctly for StateViewSlice types after Steps 1–2.

**Scope**: verification only.

---

## Step 4 — Verify AWS AppSync resolver generation

**File**: `reventless/reventless-aws/src/adapter/...` (AppSync resolver template for singular queries)

The AppSync resolver for the singular query field reads `args["id"] ?? ""` and uses it as the partition key for the DynamoDB `GetItem` or `Query`. With `includeIdParam: true`, `args["id"]` will now be populated by callers — the resolver logic is already correct. Confirm that the generated AppSync resolver function for StateViewSlice singular queries does not need a separate code path from ReadModel singular resolvers.

**Scope**: verification only. No code change expected.

---

## Completion criteria

- `Plugin_Entity(id: ID!): Plugin_Entity` appears in generated SDL (not `Plugin_Entity: Plugin_Entity`)
- `Plugin_Entity` type definition includes `implements Node` and `id: ID!` field
- `Plugin_Entity(id: "some-product-id")` resolver returns the projected state for that product
- `Plugin_Entity` (no `id` arg) is rejected by GraphQL schema validation
- `Plugin_Item(id: "item-123")` returns projected order state
- All existing plural/connection queries for StateViewSlices are unaffected
- Existing tests for StateViewSlice connection queries pass unchanged
