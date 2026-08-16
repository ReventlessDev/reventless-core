---
title: "DcbEventLog → DynamoDB"
---

## DcbEventLog → DynamoDB

The DcbEventLog adapter provides the **shared, tag-routed event store** that backs a
plugin's DCB (Dynamic Consistency Boundary) slices. Unlike the aggregate-style
[EventLog](/infrastructure/aws/adapters/eventlog) — which keeps one partition per aggregate instance — a single
DcbEventLog table holds the events of *every* DCB slice in the plugin, partitioned by
**DCB tag** rather than by aggregate id. Optimistic concurrency is enforced per command
through **consistency fences** committed atomically with the new events.

This page documents the **physical DynamoDB layout** and the runtime read/append paths.
For the conceptual model see [DCB slices](/app/dcb-slices) and
[DCB usage](/app/dcb-usage); for the cross-backend semantics and the
fence-scope rules see the
[DCB consistency checks internals](/framework/internals/dcb-consistency-checks);
for the in-memory backend used in local dev/tests see the
[local DcbEventLog adapter](/infrastructure/local/adapters/dcbeventlog).

**Source:**
`reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res` (deploy-time) and
`DcbEventLogStorage_DynamoDb_Runtime.res` (runtime).

## Table Structure

A single DynamoDB table per plugin stores three *kinds* of item, distinguished by the
shape of their primary key. All three share one composite key:

- **Partition key: `id`** (String)
- **Sort key: `position`** (String)

### Event items

The actual stored events.

- **`id`** — the **partition-tag** value, formatted `<tagKey>:<tagValue>`
  (e.g. `"orderId:ord-123"`). Composite partition tags join their segments via
  `getCompositePartitionKeyValue`; tagless events fall back to the literal `"dcb"`.
- **`position`** — a lexicographically sortable `<timestamp>-<uuidv4>` string. A batch
  appended in one call shares a base position and suffixes `-001`, `-002`, … so the
  events keep their relative order (`generatePositionForBatch`).
- **`event`** — the event type name.
- **`data`** — the event payload (JSON).
- **`recordedAt`** — ISO timestamp set at append time.
- **`tags`** — the full `[{key, value}]` array used to re-evaluate queries on read.
- **flattened `meta.*`** — each meta key (correlationId, causationId, …) is written as a
  top-level attribute so it stays GSI-projectable, matching the EventLog adapter; the read
  path reassembles it via `Reventless.Message.composeMeta`.
- **`tag_<key>`** — one attribute per tag, carrying the tag value. These are the GSI hash
  keys.
- **`tag_composite`** — present only when an event carries more than one tag: the sorted
  `key1:value1#key2:value2#…` concatenation used by composite (multi-tag) reads.

```json
{
  "id": "orderId:ord-123",
  "position": "1719100800000-550e8400-e29b-41d4-a716-446655440000",
  "event": "OrderPlaced",
  "data": { "...": "event payload" },
  "recordedAt": "2026-06-22T10:20:00.000Z",
  "tags": [
    { "key": "orderId", "value": "ord-123" },
    { "key": "productId", "value": "p-5" }
  ],
  "correlationId": "…",
  "tag_orderId": "ord-123",
  "tag_productId": "p-5",
  "tag_composite": "orderId:ord-123#productId:p-5"
}
```

### Fence sentinels

One control-flow item per distinct tag value, holding the highest position written under
that tag **for each event type**. These enforce optimistic concurrency.

- **`id`** = `fence#<tagKey>:<tagValue>` — the `fence#` prefix keeps fences out of the
  event partitions.
- **`position`** = the constant `"FENCE"`.
- **`pos#<eventType>`** — one attribute per event type, the latest position of that type
  bumped onto this fence. Scoping by type lets the OCC check mirror the read query's
  event-type filter (a slice reading only some of a partition's types is not conflicted by a
  sibling type).

Fences carry **no** `event`/`data` attributes; scans guard with `attribute_exists(event)`
so sentinels are never returned as events.

The **creation guard** (serialising concurrent *first* writers to an entity) is **folded into
the fence**: at `after = None` the partition-tag fence `Update` is gated on
`attribute_not_exists(pos#<producedType>)`, so two first-writers of the same type collide on
that attribute. Because the guard is the per-type attribute, it never false-conflicts a
different slice that merely shares the partition — so there is no separate `create#…` sentinel
row (see [Conditional append](#conditional-append--optimistic-concurrency)).

## Global Secondary Indexes

One GSI is created **per tagged field** in the plugin's events (the `indexes` passed to
`make` are the `tag_<key>` attribute names, plus `tag_composite`). Each GSI uses
`tag_<key>` as its hash key and reuses `position` as range key. The **projection type
differs by index**:

| Index | Hash key | Range key | Projection | Reader |
|---|---|---|---|---|
| `tag_<key>` (per tag) | `tag_<key>` | `position` | **KEYS_ONLY** | Cross-partition secondary-tag read: `Query` (keys) → `BatchGetItem` (payloads) |
| `tag_composite` | `tag_composite` | `position` | **ALL** | Composite (multi-tag AND) reads, resolved directly from the index |

```rescript
let projectionType =
  DcbEventLogStorage_DynamoDb_Runtime.indexKeepsFullProjection(indexName)
    ? PulumiAws.DynamoDb.Table.ALL        // only "tag_composite"
    : PulumiAws.DynamoDb.Table.KEYS_ONLY  // every per-tag "tag_<key>" index
```

`KEYS_ONLY` on the per-tag indexes drops the per-GSI event-payload storage multiplier and
most of the per-write WCU while keeping the index queryable; the payloads are fetched from
the base table with `BatchGetItem` only when a secondary-tag read actually runs.

The table is created with a DynamoDB **stream** (`NEW_IMAGE`) enabled — the
`EventTopicPublisher_DynamoDbStream` adapter connects the EventTopic to it so newly
appended events fan out to projections and StateViewSlices.

## Read Path — decision reads

A DCB query is an OR of query items, each an AND of tag constraints (optionally narrowed by
`eventTypes`). The adapter routes each item by its shape:

- **Single-tag, partition-scoped (default)** — a direct **base-table `Query`** on
  `id = "<key>:<value>" AND position > :after`. Strong consistency is opt-in per slice
  (`readConsistency`); GSIs are always eventually consistent.
- **Single-tag, cross-partition** (a `@crossPartition` secondary tag) — a `Query` on the
  `tag_<key>` GSI returns `{id, position}` keys, then `BatchGetItem` resolves full events
  from the base table.
- **Multi-tag (AND)** — a `Query` on the `tag_composite` GSI
  (`tag_composite = "<sorted composite>" AND position > :after`); the `ALL` projection
  returns full events directly.
- **Tagless / by-type** — a base-table `Scan` with
  `FilterExpression: attribute_exists(event) AND event IN (…)`. Expensive; the
  `attribute_exists(event)` guard excludes fence sentinels.

Multiple query items are merged by `position` (k-way lazy merge, deduped by position) so the
slice sees one ascending stream. The latest position seen is returned as the read head and
becomes the next `~after`.

## Conditional Append — optimistic concurrency

The slice reads its decision model at some `after` position, decides, then appends with a
condition. Everything — new event `Put`s **and** the fence operations — rides a single
`TransactWriteItems` call, so the append is atomic and conflict-detecting.

Each distinct tag value involved gets exactly one fence operation, whose *role* depends on
whether the query read that tag and whether the read was partition-scoped. The check is
scoped to the **consumed** event types (`pos#<consumedType>`); the bump advances the
**produced** types (`pos#<producedType>`):

| Fence role | Operation | Condition |
|---|---|---|
| Tag the query read (and writes) | `Update` (check + bump) | per consumed type: `attribute_not_exists(pos#<T>) OR pos#<T> <= :after` |
| Tag read but not advanced (partition-scoped, single-tag clause) | `ConditionCheck` | same predicate, no bump |
| Partition / cross-partition tag carried by a new event | `Update` (unconditional bump) | `SET pos#<producedType> = :new` |
| First write to an entity (`after = None`, folded create guard) | `Update` on the partition fence | per consumed ∪ produced type: `attribute_not_exists(pos#<T>)` |

A **`@compositePartitionTag`** partition is the exception to "one fence op per tag value":
its member fields join into a single composite partition value, so the whole composite
clause collapses to **one** fence on `fence#<compositeValue>` (check + bump), never one per
member — keeping the fence as selective as the composite entity and matching the single
`tag_composite` read.

```rescript
// conditional fence (one consumed type shown): rejects if another writer of a
// type this slice reads already advanced past :after
conditionExpression: "attribute_not_exists(#posT) OR #posT <= :after"  // #posT = pos#<consumedType>
updateExpression:    "SET #posP = :new"                                // #posP = pos#<producedType>
```

If any condition fails, DynamoDB cancels the whole transaction
(`TransactionCanceledException`), which the runtime classifies as a `Conflict` error; the
slice callback retries the read-decide-append cycle. The key rule — *the fence scope must
equal the read scope* — is why `@crossPartition` must be declared explicitly: a
cross-partition tag is fenced by **every** carrier, primary or secondary. See the
[consistency-checks internals](/framework/internals/dcb-consistency-checks)
for worked `PlaceOrder` / `RecordProductDemand` examples.

`TransactWriteItems` is capped at **100 items per call** (events + fences + guards
combined). Exceeding it returns a clear error — reduce the events or the number of distinct
tag values per command.

### Unconditional append

When called with no condition (imports, seeding, replay) there is no decision read; the
adapter still writes events and bumps every carried tag's fence in one atomic
`TransactWriteItems`.

## Deploy-time to Runtime Flow

```
1. Deploy-time (DcbEventLogStorage_DynamoDb.res):
   └─> Create DynamoDB table: PK=id, SK=position, stream=NEW_IMAGE
   └─> Create one GSI per tag (tag_<key> KEYS_ONLY) + tag_composite (ALL)
   └─> Bind runtime ops with ~partitionTag and ~crossPartitionTagKeys

2. Runtime (DcbEventLogStorage_DynamoDb_Runtime.res):
   └─> read / readStream  — route query items to base table / GSI / scan, merge by position
   └─> append             — TransactWriteItems: event Puts + per-type fence Updates/Checks
   └─> conflicts surface as TransactionCanceledException → Conflict → slice retries
```

## Key Differences from the Aggregate EventLog

| Aspect | EventLog (aggregate) | DcbEventLog (DCB) |
|---|---|---|
| Partition key | aggregate instance `id` | `<partitionTag>:<value>` |
| Sort key | `sequenceNr` | `position` (`<timestamp>-<uuid>`) |
| Scope | one stream per aggregate | one table per plugin, many slices |
| Concurrency | per-aggregate sequence | per-tag, per-event-type fences in `TransactWriteItems` |
| Cross-entity query | not supported | tag GSIs (`tag_<key>`, `tag_composite`) |
