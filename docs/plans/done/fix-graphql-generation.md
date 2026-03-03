# Fix GraphQL Schema Generation

## Status: done (steps 1-13 complete)

| Step | Status | Description |
|------|--------|-------------|
| 1 | done | Fix DCB mutation field arguments (remove `id`/`args`, inline command fields) |
| 2 | done | Add aggregate mutation generation |
| 3 | done | Remove "View" suffix from query names |
| 4 | done | Add plugin-name prefix to query names |
| 5 | done | Generate `typesSchema` for queries (singular + plural types) |
| 6 | done | Update existing tests |
| 7 | done | Build and verify zero warnings |
| 8 | done | Add `singularize` helper, fix naming in Plugin_Builder |
| 9 | done | Fix registry timing — populate before StateViewSlice creation |
| 10 | done | Extend `queryFieldNames` with `returnTypeName` and `pluralTypeName` |
| 11 | done | Fix QueryDbResolvers_GraphQL SDL and resolvers |
| 12 | done | Update tests (already correct from steps 1-7) |
| 13 | done | Build and verify — 0 warnings, 698 tests pass |

---

## Problems

Six issues with the current GraphQL schema generation:

### 1. DCB mutation fields use `(id: ID, args: String)` instead of inlined command fields

**Current** (`DcbCommandTopicResolvers_GraphQL.res:13`):
```graphql
Catalog_AddProduct(id: ID, args: String): String
```

**Expected**:
```graphql
Catalog_AddProduct(productId: ID!, name: String): String!
```

The `GraphQL_FragmentGenerator.generate()` already derives correct mutation field SDL from `commandSchema`. The problem is only in `DcbCommandTopicResolvers_GraphQL.register()` — it ignores the generated SDL and hardcodes `(id: ID, args: String)`. The resolver body then parses `args` as a JSON string, which is also wrong.

### 2. Aggregate-based plugins generate no mutations

`Plugin_Builder.res:193-199` correctly creates `mutationEntriesFromAggregates` and the fragment generator processes them into SDL. However, the SDL fields go into the fragment only — they are not registered in `GraphQL_Server` as resolver fields. Unlike DCB mutations (which call `dcbMutationResolverHook`), aggregate mutations rely on `CommandGeneratorResolvers_GraphQL.make()` which is called from `Aggregate_Builder` → `AggregateRuntime_Builder`. Those resolvers also hardcode `(id: ID, args: String)` (`CommandGeneratorResolvers_GraphQL.res:53`).

**Problem**: The fragment generator produces correct SDL, but the resolver registration overwrites it with `(id: ID, args: String)`. The two sets of SDL must be aligned.

### 3. "View" suffix not stripped from query names

`Plugin_Builder.res:225` strips "View" from StateViewSlice names for queries. But the resolver registration in `QueryDbResolvers_GraphQL` uses the raw `name` passed from the builder. If these don't match, there's a mismatch. Need to verify alignment.

### 4. Query names should be prefixed with plugin name + separator

**Current**: Query resolvers use names like `catalogProduct(id: ID!)`.
**Expected**: `Catalog_Product(id: ID!)` (plugin-prefixed).

Note: GraphQL field names must match `/[_A-Za-z][_0-9A-Za-z]*/` — **dots are not allowed**. Use underscore as separator (already the convention for mutations).

### 5. `typesSchema` is missing from generated fragments

The `GraphQL_FragmentGenerator.generate()` derives a single type per query entry (e.g., `type CatalogProduct { ... }`), but it does **not** generate:

- **Plural wrapper type**: `type CatalogProducts { nextToken: String, scannedCount: Int!, items: [CatalogProduct!]! }`
- **Referenced sub-types**: Nested object fields should generate their own type definitions
- **Plugin-prefixed type names**: Types should be named `Catalog.Product` (or `Catalog_Product` if dots disallowed)
- **Deduplication**: Each unique type should appear exactly once across the collected schema

The `PluginApi.res` shows the pattern: `Plugin` (singular) + `Plugins` (plural with `nextToken`, `scannedCount`, `items`).

### 6. List query return type should use the plural wrapper

**Current**: `everyPlugin(nextToken: String, limit: Int): [Plugin]`
**Expected**: `Catalog_Products(nextToken: String, limit: Int): Catalog_Products!` (returns the plural wrapper type with pagination)

---

## Files to Change

### Core Generation (`reventless/reventless-core/`)

| File | Change |
|------|--------|
| `src/components/Api/GraphQL_FragmentGenerator.res` | Generate plural wrapper types; derive nested object types; support plugin-name prefix on types; deduplicate types |
| `src/components/Plugin/Plugin_Builder.res` | Pass `pluginName` to query entries for type-name prefixing; ensure query names are `PluginName_EntityName` |
| `reventless-infra/src/components/Api.res` | Add `pluginName` field to `querySchemaEntry` if needed for type prefixing |

### In-Memory Resolvers (`reventless/reventless-in-memory/`)

| File | Change |
|------|--------|
| `src/adapter/CommandGenerator/DcbCommandTopicResolvers_GraphQL.res` | Remove `(id: ID, args: String)` hardcode; use schema-derived args; parse inline args instead of JSON `args` string |
| `src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res` | Same: use schema-derived SDL instead of hardcoded `(id: ID, args: String)` |
| `src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` | Align query names with fragment generator (plugin-prefixed, no "View" suffix) |

### Tests (`reventless/reventless-in-memory/tests/`)

| File | Change |
|------|--------|
| `tests/adapter/GraphQL_SchemaInspectorTest.res` | Update expected values to match new type structures |

### Code Generator (`reventless/reventless-gen/`)

| File | Change |
|------|--------|
| `plop-templates/API/Api.re.hbs` | Update template to match new naming and type conventions |
| `plop-templates/API/addCommandToApiMutation.re.hbs` | Update mutation template |

---

## Implementation Steps

### Step 1: Fix DCB mutation field arguments

**File**: `reventless/reventless-in-memory/src/adapter/CommandGenerator/DcbCommandTopicResolvers_GraphQL.res`

Currently `register(~fieldName)` hardcodes `(id: ID, args: String)`. Change it to accept the schema-derived SDL field string from the fragment generator, or accept the `commandSchema` and derive the args inline.

**Approach**: Extend `dcbMutationResolverHook` signature to pass `commandSchema: S.t<unknown>` alongside `fieldName`. Then in `register()`:
1. Use `GraphQL_FragmentGenerator.deriveMutationFieldFromObject` to get the correct SDL
2. Build the resolver to extract individual args from the GraphQL args object (not parse a JSON string)

**File**: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` — update hook type:
```rescript
// from:
let dcbMutationResolverHook: ref<option<(~fieldName: string) => unit>>
// to:
let dcbMutationResolverHook: ref<option<(~fieldName: string, ~commandSchema: S.t<unknown>) => unit>>
```

**File**: `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res` — pass schema in hook call:
```rescript
registerResolver(
  ~fieldName=`${name}_${S.Spec.name}`,
  ~commandSchema=S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema,
)
```

**Note on DCB command schemas**: DCB StateChangeSlice commands are single-variant unions (e.g., `type command = | PlaceOrder({...})`). The `commandSchema` processed by `DcbTag.toUnknownSchema` presents as a `Union` with one `anyOf` entry. The generated SDL should inline the variant's fields **without** an ID argument (the entity ID is part of the command payload fields, tagged with `@s.matches(DcbTag.string)`).

### Step 2: Add aggregate mutation generation

**File**: `reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`

Currently hardcodes `${field}(id: ID, args: String): String`. Change to derive SDL from the aggregate's `commandSchema`.

**Approach**: The `fields` array passed to `make()` contains field names but not schemas. Need to also pass command schemas. This requires:

1. **`reventless-infra/src/adapter/CommandGenerator_Adapter.res`**: Update `resolversMaker` type to accept `commandSchema` per field, or pass the full `mutationSchemaEntry`
2. **`reventless-core/src/components/CommandGenerator/CommandGenerator_Builder.res`**: Forward the schema
3. **`CommandGeneratorResolvers_GraphQL.res`**: Use schema to derive SDL args

For aggregate commands (union types), each variant becomes a separate mutation field:
```graphql
Catalog_Product_AddProduct(id: ID!, productId: String, name: String): String!
```
Note: aggregate mutations **include** an `id: ID!` argument (the aggregate ID), plus all inline fields from the command variant.

### Step 3: Remove "View" suffix from query names

Verify that `Plugin_Builder.res:225`'s `stripViewSuffix` is consistently applied in both:
- Fragment generation (query entry `singleFieldName`)
- Resolver registration (`QueryDbResolvers_GraphQL.make ~name`)

If the builder strips "View" for fragment entries but passes the raw name to the builder, fix the builder to pass the stripped name.

### Step 4: Add plugin-name prefix to query names

**Current flow**: `QueryDbResolvers_GraphQL.make(~name)` receives a name like `CatalogProduct` and registers `catalogProduct(id: ID!)`.

**Required**: Query names should be `Catalog_Product(id: ID!)` and list queries `Catalog_Products(nextToken: String, limit: Int)`.

The fragment generator already uses `${name}_${R.Spec.name}` for `singleFieldName`. The resolver registration must use the same names.

**Approach**: Either:
- (a) Pass the plugin-prefixed names to `QueryDbResolvers_GraphQL.make` (preferred), or
- (b) Pass `pluginName` separately and construct prefixed names in the resolver

Since the fragment generator already constructs `singleFieldName` and `listFieldName`, option (a) is cleaner — pass these through to the resolver maker.

Note: Dots are **not valid** in GraphQL names (`/[_A-Za-z][_0-9A-Za-z]*/`). Use underscore `_` as separator.

### Step 5: Generate `typesSchema` (singular + plural types)

**File**: `reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`

For each `querySchemaEntry`, generate:

1. **Singular type** (already exists, just needs plugin prefix):
```graphql
type Catalog_Product {
  productId: ID!
  name: String
  description: String
  price: Float
}
```

2. **Plural wrapper type** (new):
```graphql
type Catalog_Products {
  nextToken: String
  scannedCount: Int!
  items: [Catalog_Product!]!
}
```

3. **Referenced types**: If a field schema is an `Object`, derive it as a separate type definition. Collect all derived types in a set to deduplicate.

4. **Type name prefix**: All types prefixed with `PluginName_` (using underscore since dots not allowed in GraphQL).

**Changes to `querySchemaEntry`** (in `Api.res`): Add `pluginName` field or rename `returnTypeName` to include the prefix (already does: `${name}${R.Spec.name}`). May just need to adjust the naming pattern from `CatalogProduct` to `Catalog_Product`.

**Changes to `generate()`**:
- After deriving the singular type, also generate the plural type
- Track seen type names in a `Set` to deduplicate
- Update list query return type to reference the plural wrapper instead of `[TypeName]`

**Update list query SDL**: Change from:
```graphql
Catalog_Products(nextToken: String, limit: Int): [Catalog_Product]
```
to:
```graphql
Catalog_Products(nextToken: String, limit: Int): Catalog_Products!
```
(returning the plural wrapper type, same pattern as `PluginApi.res`)

### Step 6: Update existing tests

**File**: `reventless/reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res`

Update test expectations to match:
- New type name format (with prefix separator)
- Plural wrapper types in fragments
- Updated mutation arg signatures

### Step 7: Build and verify

```bash
cd reventless/reventless-core && npm run build
cd reventless/reventless-in-memory && npm run build
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
cd reventless/reventless-in-memory && npm test
```

---

## Design Decisions

### Dots vs underscores in type/query names
GraphQL identifiers must match `[_A-Za-z][_0-9A-Za-z]*`. Dots are not allowed. Use underscore `_` as the plugin-name separator (consistent with existing mutation naming: `Catalog_Product_AddProduct`).

### Aggregate mutations: ID field
Aggregate-based mutations include an explicit `id: ID!` argument (the aggregate instance ID, provided by the caller) plus the inline command variant fields. This mirrors the existing `addCommandToApiMutation.re.hbs` template which generates `AggName_CommandName(id: ID!): String!`.

### DCB mutations: No separate ID field
DCB mutations do **not** have a separate `id: ID!` argument. The entity ID is part of the command payload (e.g., `productId: ID!` tagged with `@s.matches(DcbTag.string)`). The mutation only has the fields from the command variant.

### Resolver alignment strategy
The resolver SDL must match the fragment generator SDL exactly. Rather than having two independent SDL generation paths, the resolver makers should either:
- Receive the generated SDL from the fragment (pass-through)
- Receive the schema and use the same derivation functions

The second approach is more maintainable since it uses a single source of truth (`GraphQL_FragmentGenerator`).
