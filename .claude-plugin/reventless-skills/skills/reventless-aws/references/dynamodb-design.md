# DynamoDB Table Design

## EventLog Table

Stores per-entity event streams for aggregates.

| Attribute | Type | Key | Purpose |
|-----------|------|-----|---------|
| `pk` | String | Partition Key | Entity ID |
| `sk` | Number | Sort Key | Event sequence number |
| `event` | String | — | JSON-encoded event |
| `meta` | Map | — | Message metadata (time, user, correlationId) |
| `tag` | String | — | Event type tag |

**Access patterns:**
- `replay(id)`: Query `pk = id`, sorted by `sk` ascending
- `append(version, id, events)`: Conditional PutItem with `sk = version + 1` (optimistic concurrency)

## DcbEventLog Table

Stores shared event log for DCB with tag-based filtering.

| Attribute | Type | Key | Purpose |
|-----------|------|-----|---------|
| `pk` | String | Partition Key | Event log partition |
| `sk` | Number | Sort Key | Global sequence number |
| `event` | String | — | JSON-encoded event |
| `meta` | Map | — | Message metadata |
| `tags` | Map | — | Entity ID tags for filtering |

**GSI for tag queries:**

| Attribute | Type | Key | Purpose |
|-----------|------|-----|---------|
| `tagValue` | String | GSI Partition Key | Entity ID value |
| `sk` | Number | GSI Sort Key | Same sequence number |

**Access patterns:**
- `read(tags, eventTypes)`: GSI query on tag values, filter by event type
- `append(position, events)`: Conditional PutItem with `sk = position + 1`

## QueryDb Table

Stores read model / view slice projections.

| Attribute | Type | Key | Purpose |
|-----------|------|-----|---------|
| `pk` | String | Partition Key | Read model name + entity ID |
| `sk` | String | Sort Key | Sub-ID (default: `"_"`) |
| `state` | Map | — | JSON-encoded read model state |
| `ttl` | Number | — | Optional TTL for auto-expiry |

**Access patterns:**
- `load(id)`: GetItem `pk = readModelName#id`
- `save(id, state)`: PutItem
- `query(id, filters)`: Query with FilterExpression
- `scan(filters)`: Scan with FilterExpression (use sparingly)
- `delete(id)`: DeleteItem

## Table Naming

Tables are named by combining the plugin name and component name:

```
{PluginName}{ComponentName}
```

Examples:
- `CatalogProductEventLog`
- `CatalogProductsQueryDb`
- `CatalogDcbEventLog`
- `OrderingOrdersQueryDb`

## Capacity Planning

| Component | Read Pattern | Write Pattern | Recommendation |
|-----------|-------------|--------------|----------------|
| EventLog | Replay on command (bounded by entity history) | Append per command | On-demand |
| DcbEventLog | Tag query on command (bounded by matching events) | Append per command | On-demand |
| QueryDb | Per-query (single item or filtered scan) | Per-event (projection) | On-demand for dev, provisioned for prod |
