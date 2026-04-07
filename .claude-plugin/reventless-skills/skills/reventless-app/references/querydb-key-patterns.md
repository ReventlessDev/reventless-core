# QueryDb Key Design Patterns

For the full guide see `docs/guides/querydb-key-design-guide.md`.

## Annotation Summary

All annotations go on `@schema type state` fields in `@@reventless.spec`-annotated ReadModel or StateViewSlice files.

| Annotation | Purpose | Generates |
|---|---|---|
| `@id fieldName` | Partition key (one string field) | `let makeId` |
| `@compositeId` on 2+ fields | Composite partition key | `let makeId` with concatenation |
| `@subId fieldName` | Sort key (one string field) | `let subIdConfig = Some({...})` |
| `@compositeSubId` on 2+ fields | Composite sort key | `let subIdConfig = Some({ subIdField: "_subId", ... })` |
| `@index fieldName` | Simple GSI, no sort key | Entry in `let config` indexes |
| `@index("name")` on 1+ fields | Named GSI partition key | Entry with pk |
| `@indexSubId("name")` on 1+ fields | Named GSI sort key | Entry with sk (requires matching `@index("name")`) |
| `@index({group, authTable})` | GSI with authorization | Entry with authorization field |
| `@resolves({table, field})` | Cross-table single-ID resolver | `config.idResolvers` entry |
| `@resolvesMany({table, field})` | Cross-table multi-ID resolver | `config.idsResolvers` entry |

## Key Pattern Decision

```
Is the state a singleton per entity (one record per ID)?
  Yes → Use @id on the entity ID field
       Does each entity have versioned sub-records?
         No  → simple entity: @id only
         Yes → add @subId for sort key range queries
  No  → One ID maps to many records (multi-tenant, versioned, line items)?
         Use @id for outer partition + @subId for sort within partition
```

## Pattern Examples

### Singleton entity (most common)
```rescript
@schema
type state = {
  @id productId: string,
  name: string,
  price: float,
}
```

### Entity with composite partition key
```rescript
@schema
type state = {
  @compositeId tenantId: string,
  @compositeId productId: string,
  name: string,
}
// makeId: `${tenantId}/${productId}`
```

### Entity with sort key (versioned / time-series sub-records)
```rescript
@schema
type state = {
  @id orderId: string,
  @subId lineItemId: string,   // enables orderById(id, from?, to?, prefix?, ...) query
  productId: string,
  quantity: int,
}
```

### Composite sort key
```rescript
@schema
type state = {
  @id projectId: string,
  @compositeSubId createdAt: string,  // stored as _subId: "{createdAt}/{taskId}"
  @compositeSubId taskId: string,
  title: string,
}
```

### GSI for secondary access pattern
```rescript
@schema
type state = {
  @id productId: string,
  @index categoryId: string,   // generates productByCategoryId(categoryId: ID!) query
  name: string,
}
```

### Named GSI with sort key
```rescript
@schema
type state = {
  @id orderId: string,
  @index("byCustomerDate") customerId: string,
  @indexSubId("byCustomerDate") createdAt: string,
  total: float,
}
// GSI: partition = customerId, sort = createdAt
// Query: orderByCustomerDate(customerId, from?, to?, prefix?, ...)
```

### Cross-table resolver
```rescript
@schema
type state = {
  @id orderId: string,
  @resolves({table: "Products", field: "product"}) productId: string,
  // Adds virtual GraphQL field: product: Product
  quantity: int,
}
```

### Cross-plugin resolver
```rescript
@resolves({table: "Products", field: "product", plugin: "CatalogPlugin"}) productId: string,
```

### Array of IDs resolver
```rescript
@schema
type state = {
  @id cartId: string,
  @resolvesMany({table: "Products", field: "products"}) productIds: array<string>,
  // Adds virtual GraphQL field: products: [Product!]!
}
```

## Sort Key Query Arguments

When `@subId` or `@compositeSubId` is set, the `{name}ById` query gains these optional arguments:

| Argument | Type | Effect |
|---|---|---|
| `id` | `ID!` | Required — the partition key |
| `prefix` | `String` | `begins_with` — e.g. `"2024-"` |
| `from` | `String` | Lower bound (inclusive) |
| `to` | `String` | Upper bound (inclusive) |
| `eq` | `String` | Exact match |
| `reverse` | `Boolean` | Reverse sort order |
| `limit` | `Int` | Max items to return |
| `nextToken` | `String` | Pagination cursor |

**Lexicographic sort key caveats:**
- Timestamps: ISO 8601 (`2024-01-15T10:30:00Z`) sorts correctly
- Versions: `v1`, `v2`, `v10` sorts as `v1 < v10 < v2` — use zero-padded: `v001`, `v002`, `v010`
- Composite keys: `region/date` — all segments must sort consistently

## Separator Conventions

Default separator is `/`. Override with `~sep` parameter:
```rescript
@compositeId(~sep=":") tenantId: string,
@compositeId(~sep=":") productId: string,
// makeId: `${tenantId}:${productId}`
```
