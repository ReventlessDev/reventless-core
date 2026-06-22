---
title: DcbEventLog
sidebar_position: 13
---

# DcbEventLog — Local

The local DcbEventLog is the dev/test counterpart of the
[AWS DcbEventLog → DynamoDB](/infrastructure/aws/adapters/dcbeventlog) adapter: the
shared, tag-routed event store that backs a plugin's DCB slices. It ships **two
backends** that implement the same `DcbEventLog_Adapter` interface:

| Backend | Source | Selected by |
|---|---|---|
| In-memory | `DcbEventLogStorage_InMemory.res` | `Backend.Memory` (default) |
| SQLite | `DcbEventLogStorage_Sqlite.res` | `Backend.Sqlite` / `REVENTLESS_LOCAL_BACKEND=sqlite` |

In-memory is ephemeral (state lives for the lifetime of the process) and is the
default for tests; SQLite persists across restarts and is selected for local runs that
need durability. Both expose identical `read` / `append` / `readStream` operations and
the same tag-query and conflict semantics — only the storage substrate differs.

The `Make(Bus)` functor lives **only** on the in-memory module; dispatch is centralised
there so callers wire a single module regardless of backend.

## Operations

| Operation | Description |
|-----------|-------------|
| `read` | Returns events matching a tag-based query, optionally filtering by position (`~after`) |
| `append` | Appends events with optimistic-concurrency conflict detection via `appendCondition` |
| `readStream` | Stream variant of `read` |

## Tag-Based Query Matching

Both backends apply the same query semantics as the DynamoDB adapter:

- An empty query matches all events.
- Each query item can filter by `eventTypes` and/or `tags`.
- A query item matches if **all** its tag constraints match (AND) and the event type is
  in the allowed list.
- Multiple query items are combined with **OR** — an event matches if **any** query item
  matches.

## In-Memory Backend

**Source:** `DcbEventLogStorage_InMemory.res`

### Data Structure

Events are stored in a `ref<array<rawSequencedEvent>>`. A monotonically increasing
`ref<int>` position counter assigns a unique position to each appended event.

### Conflict Detection

`append` supports optimistic concurrency via `appendCondition`:

- Re-evaluates `condition.query` against events recorded after `condition.after`.
- Returns `Error("conflict: condition check failed")` if any matching event exists.
- Returns `Ok(position)` otherwise.

### Bus Integration

When created via `Make(Bus)`, the adapter registers its `read` function on the bus so
that MCP resources and other components can look up DCB event history.

## SQLite Backend

**Source:** `DcbEventLogStorage_Sqlite.res`

### Schema

Events and their tags are split across two tables, mirroring the
`tags`-as-separate-rows shape the DynamoDB adapter folds into one item:

```sql
CREATE TABLE dcb_event (
  log_name    TEXT NOT NULL,
  position    INTEGER NOT NULL,   -- per-log sequence (see below)
  event_type  TEXT NOT NULL,
  data        TEXT NOT NULL,      -- event payload (JSON)
  meta        TEXT NOT NULL,      -- message meta (JSON)
  recorded_at TEXT NOT NULL,
  PRIMARY KEY (log_name, position)
);

CREATE TABLE dcb_tag (
  log_name  TEXT NOT NULL,
  position  INTEGER NOT NULL,
  tag_key   TEXT NOT NULL,
  tag_value TEXT NOT NULL
);

CREATE INDEX dcb_tag_by_kv ON dcb_tag(log_name, tag_key, tag_value, position);
```

`position` is a per-`log_name` integer, allocated as `MAX(position) + 1` inside the
append transaction — a simple monotonic sequence rather than DynamoDB's
`<timestamp>-<uuid>` string. The `dcb_tag_by_kv` index is what makes tag-filtered reads
efficient.

### Read

`buildQuerySql` compiles a DCB query into one `SELECT … FROM dcb_event`:

- The `~after` filter becomes `position > ?`.
- Each clause's `eventTypes` becomes an `event_type IN (…)` list.
- Each tag constraint becomes an `EXISTS (SELECT 1 FROM dcb_tag …)` subquery correlated on
  `position` — so a clause with N tags ANDs N `EXISTS` subqueries.
- Clauses are joined with `OR`; results are `ORDER BY position ASC`.

Tags for each returned event are loaded from `dcb_tag` and reattached; `meta` is parsed
back through `Message.metaSchema`.

### Append & Conflict Detection

`append` runs inside a single SQLite transaction:

1. If a `condition` is supplied, it runs the equivalent of
   `read(condition.query, after=condition.after)`; **any** returned event aborts the
   transaction with `Error("conflict: condition check failed")`.
2. Each event is inserted under a freshly allocated `position`, with its tags written to
   `dcb_tag`.
3. The last inserted `position` is returned as a string.

There are **no fence sentinels** — the literal re-read inside the transaction is the
concurrency check, which the single-writer local process makes sufficient. This is the
key simplification over the DynamoDB backend's `TransactWriteItems` + per-tag fences.

`readStream` is materialised eagerly via `read` for now; true streaming via
`statement.iterate()` would need a `Stream.fromIteratorEffect` the current ReScript
`Stream` module does not expose. The `~strongConsistency` parameter is accepted for
interface parity and ignored — a local SQLite file is always consistent.

## Key Differences from AWS

| Aspect | Local (in-memory) | Local (SQLite) | AWS (DynamoDB) |
|---|---|---|---|
| Storage | `ref<array>` | `dcb_event` + `dcb_tag` tables | One table: events, fences, create guards |
| Position | Integer counter | Per-log `MAX(position)+1` | `<timestamp>-<uuid>` string |
| Tag index | Array filter | `dcb_tag_by_kv` index + `EXISTS` subqueries | `tag_<key>` / `tag_composite` GSIs |
| Concurrency | Array scan after position | Re-read inside a transaction | `TransactWriteItems` + per-tag fences |
| Durability | Ephemeral | Persists across restarts | Persistent |

See the [AWS DcbEventLog adapter](/infrastructure/aws/adapters/dcbeventlog) for the
fence/consistency mechanics that the local backends deliberately simplify away.
