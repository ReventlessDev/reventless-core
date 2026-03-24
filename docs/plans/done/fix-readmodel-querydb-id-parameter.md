# Fix: ReadModel vs StateViewSlice GraphQL Query & Type Schema Differences

## Problem 1: Query Field ID Parameter

GraphQL queries generated for **ReadModel** QueryDBs and **StateViewSlice** QueryDBs currently use the same schema shape. Both include `(id: ID!)` in the single-item query field.

- **ReadModel**: `(id: ID!)` parameter **should** be present — the read model has explicit identity separate from the data payload.
- **StateViewSlice**: `(id: ID!)` parameter should **not** be present — the ID is already embedded in the state payload (keyed by the entity's own ID field).

## Problem 2: GraphQL Type Definition Missing ID for ReadModels

The GraphQL **type definition** generated from a ReadModel's `stateSchema` does not include an `id` field. The partition key (used to store/retrieve the record) is stored separately from the state record and is not part of `stateSchema`. This means the GraphQL type lacks the `id` field that clients need.

- **ReadModel**: The generated GraphQL type should include an `id: ID!` field (injected from the partition key, not in the state record).
- **StateViewSlice**: The entity ID is already part of the state record (e.g., `productId: string`), so no injection is needed — the type is correct as-is.

### Desired Output

**ReadModel Query + Type:**
```graphql
type Product {
  id: ID!            # ← injected, not in stateSchema
  name: String!
  description: String!
  price: Float!
}

product(id: ID!): Product
products(nextToken: String, limit: Int): ProductsConnection!
```

**StateViewSlice Query + Type:**
```graphql
type ItemState {
  productId: String!  # ← already in stateSchema
  name: String!
  description: String!
  price: Float!
}

itemView: ItemState           # ← no (id: ID!) parameter
itemViews(nextToken: String, limit: Int): ItemStatesConnection!
```

## Files to Change

### 1. `reventless/reventless-infra/src/components/Api.res` — Add flag to `querySchemaEntry`

Add an optional field to distinguish ReadModel from StateViewSlice entries:

```rescript
type querySchemaEntry = {
  singleFieldName: string,
  listFieldName: string,
  returnTypeName: string,
  stateSchema: S.t<unknown>,
  authorization: option<Reventless.ReadModel.authorization>,
  excludeFields?: array<string>,
  description?: string,
  includeIdParam?: bool,  // NEW — defaults to true for backward compat
}
```

This single flag controls both behaviors:
- When `true` (default, ReadModel): query has `(id: ID!)` param AND type gets `id: ID!` field injected
- When `false` (StateViewSlice): query has no ID param AND type uses stateSchema as-is

### 2. `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res` — Set flag for StateViewSlice entries

When building `querySchemaEntry` for StateViewSlice, set `includeIdParam: false`:

```rescript
let stateViewEntries = DcbSpec.stateViewSlices->Array.map(
  module(V: StateViewSlice.T) => {
    let qn = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=V.Spec.name)
    {
      singleFieldName: qn.singleFieldName,
      listFieldName: qn.listFieldName,
      returnTypeName: qn.returnTypeName,
      stateSchema: V.Spec.stateSchema->Reventless.DcbTag.toUnknownSchema,
      authorization: None,
      includeIdParam: false,  // <-- NEW
    }
  }
)
```

ReadModel entries in `Plugin_Builder.res` don't need changes — the field defaults to `true` when omitted (optional field).

### 3. `reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` — Conditional ID param + ID field injection

**Query field** — update `deriveObjectQueryField` to conditionally include `(id: ID!)`:

```rescript
let deriveObjectQueryField = (
  ~singleFieldName: string,
  ~typeName: string,
  ~includeIdParam: bool=true,
): string =>
  if includeIdParam {
    `  ${singleFieldName}(id: ID!): ${typeName}`
  } else {
    `  ${singleFieldName}: ${typeName}`
  }
```

**Type definition** — update `deriveObjectTypeWithNested` (or equivalent) to inject `id: ID!` as the first field when `includeIdParam` is true:

```rescript
// When includeIdParam is true, prepend "id: ID!" to the generated type fields
let idFieldLine = if includeIdParam { "  id: ID!\n" } else { "" }
```

Update the call sites that pass `querySchemaEntry` data to these functions.

### 4. Resolver implementations — Conditional ID param in SDL and resolver logic

#### `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`

- Accept `includeIdParam` flag
- When `true`: generate SDL with `(id: ID!)`, resolver extracts ID from args and includes it in response
- When `false`: generate SDL without `(id: ID!)`, resolver returns the item without ID injection

#### `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`

- Same: accept flag, conditionally generate VTL resolver templates with/without ID parameter and response mapping

#### `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_NoOp.res`

- Accept flag for type compatibility (no-op implementation, minimal change)

### 5. Tests

#### Update existing tests:
- `reventless/reventless-in-memory/tests/SplitApiTest.res` — verify ReadModel queries have `(id: ID!)` and type includes `id: ID!`
- `reventless/reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res` — if it tests schema shape

#### Add new test cases:
- Test that ReadModel GraphQL type includes `id: ID!` field
- Test that StateViewSlice GraphQL type does NOT include an injected `id` field
- Test that StateViewSlice query schema does NOT include `(id: ID!)` parameter
- Test that ReadModel query schema still includes `(id: ID!)` parameter
- Test that the resolver for ReadModel single query returns the `id` field in the response
- Test that the resolver for StateViewSlice single query works without an ID argument

## Implementation Order

1. Add `includeIdParam?` to `querySchemaEntry` type in `Api.res`
2. Update `GraphQL_FragmentGenerator.res` — conditional query param + ID field injection in type
3. Update `Dcb_Builder.res` to set `includeIdParam: false` for StateViewSlice entries
4. Update `QueryDbResolvers_GraphQL.res` (in-memory) — SDL + resolver logic for both modes
5. Update `QueryDbResolvers_AppSync.res` (AWS) — SDL + VTL templates
6. Update `QueryDbResolvers_NoOp.res` — type compatibility
7. Build, fix warnings
8. Update/add tests
9. Verify with `npm run build && npm test`
