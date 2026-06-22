---
title: EventLog
sidebar_position: 1
---

# EventLog — Local

The local EventLog is the dev/test counterpart of the
[EventLog → DynamoDB](/infrastructure/aws/adapters/eventlog) adapter: append-only,
per-aggregate event storage. It ships **two backends** that implement the same
`EventLog_Adapter` interface:

| Backend | Source | Selected by |
|---|---|---|
| In-memory | `EventLog/EventLogStorage_InMemory.res` | `Backend.Memory` (default) |
| SQLite | `EventLog/EventLogStorage_Sqlite.res` | `Backend.Sqlite` / `REVENTLESS_LOCAL_BACKEND=sqlite` |

In-memory is ephemeral; SQLite persists across restarts. Both expose identical
`append` / `replay` / `replayStream` / `appendStream` operations and the same
per-aggregate optimistic-concurrency semantics — only the storage substrate differs.
Each backend's `Make(Bus, …)` functor registers its `replay` function on the bus so
other components (GraphQL resolvers, MCP resources) can look up event history by
aggregate name.

## Operations

| Operation | Description |
|-----------|-------------|
| `append` | Appends JSON events for an aggregate ID at a given `seqNr` |
| `replay` | Returns all events for an aggregate ID as an array, ordered by sequence |
| `replayStream` | Returns events as a `Stream` for API uniformity |
| `appendStream` | Appends events from a stream sequentially |

## In-Memory Backend

**Source:** `EventLogStorage_InMemory.res`

### Data Structure

Events are stored in a `Dict<string, array<JSON.t>>` managed by an STM `TRef`. The key
is the aggregate ID; the value is an ordered array of event JSON objects.

### Concurrency

`append` runs inside an STM transaction. In the single-threaded local process this gives
serialised, conflict-free writes; the `seqNr` is used to order events within the
aggregate.

## SQLite Backend

**Source:** `EventLogStorage_Sqlite.res`

### Schema

All EventLogs share one table, partitioned by `log_name`:

```sql
CREATE TABLE event_log (
  log_name     TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  seq_nr       INTEGER NOT NULL,
  payload      TEXT NOT NULL,   -- JSON.stringify of one event
  PRIMARY KEY (log_name, aggregate_id, seq_nr)
);
```

### Replay

`SELECT payload … WHERE log_name = ? AND aggregate_id = ? ORDER BY seq_nr ASC` — the
primary key already orders events within an aggregate. `replayStream` materialises the
array via `all()` and wraps it as a `Stream` (node:sqlite's `iterate()` could back a lazy
stream, but the current `Stream` API only exposes `fromIterable`).

### Append & Optimistic Concurrency

`append` runs inside a transaction:

1. It counts the aggregate's existing events and requires `seqNr == currentCount` — the
   caller's `seqNr` must be "the next free slot."
2. Each event is inserted at `seq_nr = seqNr + i`.
3. If a concurrent writer already inserted at the same
   `(log_name, aggregate_id, seq_nr)`, the **primary-key conflict** surfaces as
   `Error("conflict")`.

So the PK doubles as the optimistic-concurrency guard — the SQLite analogue of the
DynamoDB EventLog's conditional write on `sequenceNr`.

## Key Differences from AWS

| Aspect | Local (in-memory) | Local (SQLite) | AWS (DynamoDB) |
|---|---|---|---|
| Storage | `Dict` via STM `TRef` | Shared `event_log` table, partitioned by `log_name` | One table per log, `id` + `sequenceNr` keys |
| Concurrency | STM transaction | `seqNr` check + PK conflict → `conflict` | Conditional write on `sequenceNr` |
| Persistence | None (ephemeral) | Durable (across restarts) | Durable |
| Streaming | Array wrapped as `Stream` | `all()` wrapped as `Stream` | Paginated query |
