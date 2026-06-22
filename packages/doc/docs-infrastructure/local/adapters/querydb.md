---
title: QueryDb
sidebar_position: 5
---

# QueryDb — Local

The local QueryDb is the dev/test counterpart of the
[QueryDb → DynamoDB](/infrastructure/aws/adapters/querydb) adapter: read-model storage
for projections. It ships **two backends** that implement the same `QueryDb_Adapter`
interface:

| Backend | Source | Selected by |
|---|---|---|
| In-memory | `QueryDb/QueryDbStorage_InMemory.res` | `Backend.Memory` (default) |
| SQLite | `QueryDb/QueryDbStorage_Sqlite.res` | `Backend.Sqlite` / `REVENTLESS_LOCAL_BACKEND=sqlite` |

Both expose identical `load` / `save` / `delete` (+ batch and stream) operations and
publish the same state-change descriptors on the bus. The notable difference is
**fidelity to the AWS feature set**: the in-memory backend ignores secondary indexes and
TTL, while the SQLite backend honours both (see below).

## Operations

| Operation | Description |
|-----------|-------------|
| `load` | Returns items for a given partition ID |
| `loadStream` | Stream variant of `load` |
| `save` | Stores a single item by ID (and optional sub-key) |
| `saveBatch` | Stores multiple items |
| `count` | Returns the increment value (no actual counter tracking) |
| `delete` | Removes an item by ID (and optional sub-key) |
| `deleteBatch` | Removes multiple items |

## Bus Integration

Each backend's `Make(Bus, …)` functor registers three functions on the bus:

- `registerQueryDb` — the full operations record for GraphQL resolvers
- `registerQueryDbScan` — a `() => array<JSON.t>` function for full scans
- `registerQueryDbStream` — a `() => Stream<JSON.t>` function for streaming scans (used by
  QueryEngine with `~limit`)

`save`/`delete` also publish `Updated`/`Removed` state-change descriptors on the bus so
subscriptions and live-update paths fire locally.

## In-Memory Backend

**Source:** `QueryDbStorage_InMemory.res`

### Data Structure

Items are stored in a `Dict<string, array<JSON.t>>` (a `ref`), keyed by partition ID. A
secondary `allItems` array is kept in sync for scan operations.

### Limitations

Secondary indexes are **ignored** — every lookup is by primary key — and TTL is **ignored**
(items never expire). This is sufficient for most tests; switch to SQLite when a test
depends on index-shaped queries or TTL expiry.

## SQLite Backend

**Source:** `QueryDbStorage_Sqlite.res`

### Schema

One table per registered QueryDb, named `qdb_<name>` (dashes become underscores):

```sql
CREATE TABLE qdb_<name> (
  partition_key TEXT NOT NULL,
  sub_key       TEXT NOT NULL DEFAULT '',
  item          TEXT NOT NULL,   -- JSON.stringify of the item
  expires_at    INTEGER,         -- unix epoch seconds; NULL = never expires
  PRIMARY KEY (partition_key, sub_key)
);
```

`sub_key` is derived from the configured `subIdField` (empty string for single-key
tables). `save` is an upsert (`ON CONFLICT(partition_key, sub_key) DO UPDATE`).

### Secondary Indexes

Each declared `indexConfig` creates a SQLite index over a `json_extract(item, '$.<field>')`
expression, so GSI-shaped lookups are actually indexed. Composite keys (`pkFields` /
`skFields` joined by their separators) become a single concatenated expression. The
DynamoDB `projectionType` is recorded for parity but is irrelevant in SQLite — every
column lives on the same row, so there is no covering-index distinction.

### TTL

TTL is honoured via **lazy expiry**: every read clause carries
`(expires_at IS NULL OR expires_at > strftime('%s','now'))`. There is no background
sweeper — expired rows linger on disk until they are next read (filtered out) or
overwritten by a new `save`.

## Key Differences from AWS

| Aspect | Local (in-memory) | Local (SQLite) | AWS (DynamoDB) |
|---|---|---|---|
| Storage | `Dict` + `allItems` array | One `qdb_<name>` table per QueryDb | One table per QueryDb |
| Secondary indexes | Ignored | `json_extract` indexes (incl. composite) | GSIs with configurable projections |
| TTL | Ignored | Lazy expiry via `expires_at` | DynamoDB TTL attribute |
| Persistence | None (ephemeral) | Durable (across restarts) | Durable |
| AppSync | None | None | DataSource integration for GraphQL |
