# QueryDb Key Design Guide

This guide helps you choose the right key scheme, annotations, and query patterns for
StateViewSlice and ReadModel projections. It complements the
[Aggregate vs DCB Decision Guide](aggregate-vs-dcb-decision-guide.md) (which covers the
write-side) and the [PPX Guide](reventless-ppx.md) (which covers all PPX annotations).

---

## ReadModel vs StateViewSlice

Both project events into a QueryDb. The choice depends on where the events come from and
what query features you need.

| | ReadModel | StateViewSlice |
|---|---|---|
| **Event source** | Aggregate EventLog (per-entity stream) | DcbEventLog (shared tag-filtered log) |
| **Used with** | Aggregate approach | DCB approach |
| **ID module** | Configurable (`module Id: Id.T`) | Always `String` |
| **Annotations** | Full set (`@id`, `@subId`, `@index`, `@resolves`, etc.) | Same full set |
| **Infrastructure** | Identical QueryDb, DynamoDB table, GraphQL resolvers | Identical |

**Rule of thumb:** if the write-side uses an Aggregate, the read-side uses a ReadModel. If
the write-side uses DCB StateChangeSlices, the read-side uses StateViewSlices. The query-side
annotations and capabilities are identical.

---

## Key Pattern Decision

Every projection stores state in a QueryDb keyed by a string. The key scheme determines what
queries are possible.

```
                        ┌─────────────────────┐
                        │ One global value?   │
                        └──────┬──────────────┘
                               │ yes → Pattern 1: Singleton (key = "")
                               │ no ↓
                        ┌─────────────────────┐
                        │ One current record  │
                        │ per entity?         │
                        └──────┬──────────────┘
                               │ yes → Pattern 2: Entity-keyed
                               │ no ↓
                        ┌─────────────────────┐
                        │ History accumulates │
                        │ per entity?         │
                        └──────┬──────────────┘
                               │ yes → Use @subId for the varying dimension
                               │ no ↓
                        ┌─────────────────────┐
                        │ Need grouped queries│
                        │ by parent entity?   │
                        └──────┬──────────────┘
                               │ yes → Use @compositeId for partition key
                               │       + @subId for grouping dimension
                               │ no ↓
                        ┌─────────────────────┐
                        │ Need cross-cutting  │
                        │ queries (by category│
                        │ by environment)?    │
                        └──────┬──────────────┘
                               │ yes → Add @index on the cross-cutting field
                               │ no → Pattern 2 is sufficient
```

---

## Patterns at a Glance

| Pattern | Key | Use case | Example |
|---|---|---|---|
| **1 — Singleton** | `""` | One global aggregate value | Total order count |
| **2 — Entity-keyed** | `entityId` | Current state per entity | Product catalog |
| **3 — Entity+version** | partition + `@subId` | Version history per entity | Order status timeline |
| **4 — Composite+sub** | `@compositeId` + `@compositeSubId` | Hierarchical history | Schema changelog per component |

---

## Annotations Reference

### `@id` — single-field partition key

Declares which state field is the QueryDb partition key and generates a `makeId` helper.

```rescript
@@reventless.spec

@schema
type state = {
  @id productId: string,
  name: string,
  price: float,
}

let project = event => switch event {
  | ProductAdded({ productId, name, price }) =>
    [Set(productId, { productId, name, price })]
  | ProductRemoved({ productId }) =>
    [Delete(productId)]
}
```

PPX generates: `let makeId = (state: state) => state.productId`

The `makeId` function is a convenience — the `project` function still constructs the key
manually in `Set(key, state)`. `@id` documents which field IS the key and allows tests and
clients to reconstruct the key from any state record.

### `@compositeId` — multi-field partition key

When the partition key is built from multiple fields:

```rescript
@schema
type state = {
  @compositeId environment: string,
  @compositeId pluginName: string,
  version: string,
}
```

PPX generates: `let makeId = (state: state) => \`${state.environment}/${state.pluginName}\``

Default separator is `/`. Override with `@compositeId(~sep=":")`.

### `@subId` — single-field sort key

Adds a sort key (DynamoDB range key), enabling grouped queries per partition key.

```rescript
@schema
type state = {
  @id orderId: string,
  @subId timestamp: string,
  status: string,
  total: float,
}
```

PPX generates:
```rescript
let subIdConfig = Some({
  subIdField: "timestamp",
  getSubId: state => state.timestamp,
})
```

**What this enables:**

```graphql
# All status changes for one order — single DynamoDB Query, not a scan
query {
  Plugin_OrderHistoryById(id: "order-123") {
    items { timestamp status total }
  }
}

# Last 5 status changes
query {
  Plugin_OrderHistoryById(id: "order-123", reverse: true, limit: 5) {
    items { timestamp status }
  }
}
```

Without `@subId`, the only queries are "get one item by exact key" or "scan the entire table".
With `@subId`, you unlock "get all items for one entity" and all sort key conditions.

### `@compositeSubId` — multi-field sort key

When the sort key should be built from multiple fields for hierarchical prefix queries:

```rescript
@schema
type state = {
  @id orderId: string,
  @compositeSubId category: string,
  @compositeSubId productId: string,
  quantity: int,
}
```

PPX generates a computed sort key: `"electronics/prod-456"`. This enables:

```graphql
# All line items for an order
OrderLineById(id: "order-123") { ... }

# Only electronics line items — prefix on first segment
OrderLineById(id: "order-123", prefix: "electronics/") { ... }
```

The composite value is stored as a synthetic `"_subId"` attribute in DynamoDB, injected by
`QueryDb_Operations` before saving.

---

## GSI Indexes

Global Secondary Indexes allow querying by a field other than the partition key.

### `@index` — standalone GSI

```rescript
@schema
type state = {
  @id productId: string,
  @index category: string,
  name: string,
  price: float,
}
```

Creates a GSI named `"category"` — enables querying all products in a category without
scanning the entire table.

**Parameters:**
- `@index(~projection=KEYS_ONLY)` — only keys projected (smaller index, lower cost)
- `@index(~include=["name", "price"])` — specific attributes projected

### `@index("name")` + `@indexSubId("name")` — GSI with sort key

```rescript
@schema
type state = {
  @id productId: string,
  @index("byCategory") category: string,
  @indexSubId("byCategory") createdAt: string,
  name: string,
}
```

Creates a GSI with `category` as partition key and `createdAt` as sort key — enables
"all products in electronics, newest first".

Multiple fields with the same `@index("name")` form a **composite GSI partition key**
(concatenated, same as `@compositeId`). Multiple fields with the same `@indexSubId("name")`
form a **composite GSI sort key**.

### `@index` with authorization

```rescript
@index(~group="Admin", ~authTable="Ownership") ownerId: string
```

Adds an authorization rule: only members of the `"Admin"` Cognito group (or the resource
owner) can query this index.

---

## Cross-Table Resolvers

### `@resolves` — single-item join

```rescript
@schema
type state = {
  @id orderId: string,
  @resolves(~to="Customers", ~as="customer") customerId: string,
  total: float,
}
```

Creates a virtual `customer` field on the `Order` GraphQL type that resolves to the
`Customers` table by primary key lookup.

**Parameters:**
- `~via="indexName"` — resolve via a GSI instead of primary key
- `~plugin="OtherPlugin"` — cross-plugin table reference

### `@resolvesMany` — batch join

```rescript
@schema
type state = {
  @id orderId: string,
  @resolvesMany(~to="Products", ~as="products") productIds: array<string>,
  total: float,
}
```

Creates a virtual `products` field that batch-resolves all product IDs to `Product` objects.

---

## Sort Key Query Conditions

When a `@subId` (or `@compositeSubId`) is present, `{name}ById` accepts optional arguments
for sort key filtering:

| Argument | DynamoDB condition | Example |
|---|---|---|
| `eq: "v1.0"` | `sk = :eq` | Exact version lookup |
| `prefix: "2024-01/"` | `begins_with(sk, :prefix)` | All January 2024 entries |
| `from: "2024-01-01"` | `sk >= :from` | Everything since January 1 |
| `to: "2024-06-30"` | `sk <= :to` | Everything up to June 30 |
| `from` + `to` | `sk BETWEEN :from AND :to` | Date range |
| `reverse: true` | `ScanIndexForward: false` | Newest first |
| `limit: 10` | `Limit: 10` | Page size |
| `nextToken: "..."` | Pagination cursor | Next page |

**Mutual exclusivity:** `eq`, `prefix`, and `from`/`to` are mutually exclusive — use one
group per query. `reverse`, `limit`, and `nextToken` combine freely with any.

**Return type** is a Connection with pagination:

```graphql
type OrderHistoryByIdConnection {
  items: [OrderHistory]
  nextToken: String
}
```

### Common query patterns

```graphql
# Last 5 status changes for an order
OrderHistoryById(id: "order-123", reverse: true, limit: 5) {
  items { timestamp status total }
  nextToken
}

# Status changes in a date range
OrderHistoryById(id: "order-123", from: "2024-01-01", to: "2024-03-31") {
  items { timestamp status total }
}

# Next page
OrderHistoryById(id: "order-123", reverse: true, limit: 5, nextToken: "abc...") {
  items { ... }
  nextToken
}
```

---

## Combining Current State and Audit Log

Use a sentinel sort key to store both current state and full history in one QueryDb:

```rescript
@schema
type state = {
  @id orderId: string,
  @subId version: string,      // "v1", "v2", ... or "~current"
  status: string,
  total: float,
}
```

In the `project` function, write two entries per event — one for history, one for current:

```rescript
| OrderStatusChanged({ orderId, status, total, version }) => {
    let state = { orderId, version, status, total }
    [
      Set(orderId, state),                                           // history
      Set(orderId, { ...state, version: "~current" }),               // current (overwrites)
    ]
  }
```

Both `Set` calls use the same partition key (`orderId`) but produce different sort keys
because `getSubId` extracts the `version` field, which differs (`"v3"` vs `"~current"`).

**Queries:**

```graphql
# Full history + current state
Plugin_OrderById(id: "order-123") { items { version status } }

# Just current state
Plugin_OrderById(id: "order-123", eq: "~current") { items { status total } }

# History only (tilde sorts after all alphanumeric values)
Plugin_OrderById(id: "order-123", to: "z") { items { version status } }
```

---

## Sort Key Formatting

Sort keys are compared lexicographically. Choose a format that sorts correctly:

| Data type | Format | Correct sort? |
|---|---|---|
| ISO timestamp | `"2024-01-15T10:30:00Z"` | Yes — lexicographic = chronological |
| Date | `"2024-01-15"` | Yes |
| Padded integer | `"000042"` | Yes — zero-padded sorts numerically |
| Semantic version | `"1.2.0"` | Mostly — `"1.10.0"` sorts before `"1.9.0"` |
| Padded semver | `"001.002.000"` | Yes |
| Unpadded integer | `"42"` | No — `"9"` sorts after `"42"` |

**Recommendation:** use ISO timestamps for time-based sort keys, zero-padded segments for
version-based sort keys.

---

## Complete Example

An order tracking StateViewSlice using the full annotation set. Note how each record field
appears exactly once — multiple annotations stack on the same field declaration.

```rescript
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({
      @partitionTag orderId: string,
      customerId: string,
      total: float,
      placedAt: string,
    })
  | OrderStatusChanged({
      @partitionTag orderId: string,
      status: string,
      total: float,
      changedAt: string,
    })

@schema
type state = {
  @id orderId: string,
  @subId @indexSubId("byStatus") changedAt: string,
  @index @resolves(~to="Customers", ~as="customer") customerId: string,
  @index("byStatus") status: string,
  total: float,
}

let project = event => switch event {
  | OrderPlaced({ orderId, customerId, total, placedAt }) =>
    [Set(orderId, { orderId, changedAt: placedAt, customerId,
                    status: "placed", total })]
  | OrderStatusChanged({ orderId, status, total, changedAt }) =>
    [Set(orderId, { orderId, changedAt, customerId: "",
                    status, total })]
}
```

`@id orderId` — main table partition key.
`@subId @indexSubId("byStatus") changedAt` — main table sort key AND sort key for the
"byStatus" GSI. Two annotations on one field.
`@index @resolves(~to="Customers", ~as="customer") customerId` — standalone GSI AND
cross-table resolver. Two annotations on one field.
`@index("byStatus") status` — partition key for the "byStatus" GSI.

**Note on the project function:** `OrderStatusChanged` sets `customerId: ""` because the
event doesn't carry the customer ID. With `@subId`, each `Set` with a different `changedAt`
value creates a new entry (different sort key). Use `Update` instead of `Set` if you need
to preserve fields from the previous entry.

**Generated queries:**

```graphql
# Full timeline for one order — all entries sorted by changedAt ascending
query {
  Plugin_OrderTrackingById(id: "order-123") {
    items { changedAt status total }
  }
}

# Last status change — reverse sort, limit 1
query {
  Plugin_OrderTrackingById(id: "order-123", reverse: true, limit: 1) {
    items { changedAt status }
  }
}

# All orders by a customer (via standalone GSI on customerId)
query {
  Plugin_OrderTrackings(customerId: "cust-456") {
    edges { node { orderId status total } }
  }
}

# All "shipped" orders, newest first (via named GSI "byStatus" with changedAt sort key)
query {
  Plugin_OrderTrackings(status: "shipped", reverse: true) {
    edges { node { orderId changedAt } }
  }
}

# Single order with expanded customer object (via @resolves)
query {
  Plugin_OrderTracking(id: "order-123") {
    orderId status total
    customer { name email }
  }
}
```
