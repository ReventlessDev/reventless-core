# DCB EventLog Partitioning Improvement Analysis

> **Status: Implemented (2026-03-28).** Multi-clause DCB queries were addressed by `docs/plans/done/multi-clause-dcb-queries-plan.md`. Primary-tag partitioning was implemented as an in-place change (no V2 module) — see `docs/plans/done/dcb-eventlog-primary-tag-partitioning.md`. The partition key is now `"<tagKey>:<tagValue>"` derived from each event's tags.

**Date**: 2026-03-06 (reviewed 2026-03-27)
**Scope**: Analysis of the current single-partition ("dcb") design, its limitations, and alternative partitioning strategies.

## 1. Current Design

### How It Works

The DCB EventLog stores all events in a single DynamoDB partition with the fixed key `id="dcb"`. Each event gets a position string (`"${timestamp}-${uuid}"`) as its sort key, establishing a global total order across all events.

**DynamoDB table structure:**
```
Partition Key: id = "dcb"  (fixed for ALL events)
Sort Key:      position    (timestamp-uuid string)
Attributes:    eventType, data, tags[], tag_<field>, tag_composite
```

**GSI structure (one per tagged field):**
```
GSI "tag_itemId":     hashKey = tag_itemId,    rangeKey = position
GSI "tag_composite":  hashKey = tag_composite,  rangeKey = position
```

All queries — whether for a single entity ("itemId=item-123") or a broader filter — hit the same physical partition. The GSIs provide efficient tag-based lookups, but their base table data still originates from the single "dcb" partition.

### What the StateChangeSlice Actually Queries

The critical consumer is `StateChangeSlice_Callback.res` (lines 34-103). On every command, it:

1. Calls `DcbTag.buildQueryFromCommand` to automatically construct a query from the command's tagged fields — scalar tags are AND'd into one clause, tagged array fields produce multiple OR clauses (one per element)
2. Streams all events matching the query via `readStream` and folds them into the decision model using `Spec.evolve`
3. Calls `Spec.decide` to produce new events, then conditionally appends with: `{query, after: headPosition}`
4. On conflict (another writer appended matching events), retries from step 1 (up to 3 retries)

**Key observation**: The query is always scoped to the command's tag values. A command for item "item-123" only needs events tagged with `itemId=item-123`. It does not need to read events from other items. The "global" partition is never actually queried globally — it is always filtered through a GSI.

---

## 2. Problems with the Single-Partition Design

### 2.1 DynamoDB Hot Partition

DynamoDB partitions have throughput limits:
- **3,000 RCU and 1,000 WCU per partition** (with on-demand mode, adaptive capacity helps but doesn't eliminate the ceiling)
- All DCB EventLog reads and writes funnel through one partition
- Under load, this becomes a bottleneck — throttling affects ALL entities, not just the busy ones

Even though GSI queries route through separate physical structures, the base table writes all go to the `id="dcb"` partition. Every `append` operation writes to this single hot spot.

### 2.2 Partition Size Limits

- **DynamoDB**: 10GB per partition before automatic splitting. DynamoDB handles splits transparently, but after a split, the throughput is divided across the split partitions. With a single logical partition key (`"dcb"`), all items remain in the same logical partition even after physical splits.
- **Azure Cosmos DB**: **20GB hard limit** per logical partition. A single-partition design on Cosmos DB would hit this ceiling and require a complete redesign (see `azure-cloud-provider-analysis.md`).
- **GCP Firestore**: No hard partition limit, but performance degrades with very large collections in a single scope.

### 2.3 No Horizontal Scaling

The single partition means the DCB EventLog cannot scale horizontally. Adding more DynamoDB capacity units doesn't help — the throughput ceiling is per-partition. In contrast, a well-partitioned table distributes load across many partitions and scales linearly.

### 2.4 Cross-Cloud Portability

The single-partition design is an AWS-specific optimization that assumes DynamoDB's partition management. It becomes a liability on other cloud providers:
- Cosmos DB's 20GB partition limit makes it a non-starter at scale
- Bigtable's performance depends on key distribution — a single row key prefix creates a hotspot
- Firestore collections under a single document scope have write rate limits

### 2.5 Conditional Append Race Window

The current conditional append is **not atomic**:
1. Read events matching the condition query (separate DynamoDB query)
2. Check if any events exist after the `after` position
3. If not, write new events (batch write)

Between steps 1 and 3, another writer can append events. The retry loop (3 attempts) mitigates this, but does not eliminate it. With higher throughput (more concurrent writers), the race window grows proportionally since all writers target the same partition.

---

## 3. Why Global Ordering Exists (and Whether We Need It)

### The Original Motivation

The single partition provides a **global total order** across all events. This means any two events can be compared by position, regardless of which entity they belong to. The `readStream` k-way merge and `read` sort both rely on this property.

### Do We Actually Need Global Order?

Examining the consumers:

| Consumer | Needs Global Order? | Actually Needs |
|----------|-------------------|----------------|
| **StateChangeSlice** (command handler) | No | Events for a specific tag combination, ordered within that scope |
| **Conditional Append** | Partially | "No events matching this query exist after position X" — needs order within the query scope, not globally |
| **ReadStream** (k-way merge) | No | Position-sorted stream within a query's result set |
| **EventTopic** (event publication) | No | Just needs to publish events after successful append |

**Conclusion**: No consumer requires true global order across all entities. Every read operation filters by tags first. Order is only needed **within a tag scope** (typically a single entity or entity combination).

---

## 4. Alternative Partitioning Strategies

### 4.1 Strategy: Primary Tag as Partition Key

**Concept**: Instead of `id="dcb"`, use the primary tag value as the partition key. Each entity gets its own partition.

```
Partition Key: id = "itemId:item-123"   (derived from primary tag)
Sort Key:      position                  (timestamp-uuid, local to partition)
```

**How it works**:
- At schema definition time, the first `@s.matches(DcbTag.string)` field is designated as the "primary tag"
- The partition key becomes `"<tagKey>:<tagValue>"` (e.g., `"itemId:item-123"`)
- Each entity's events are isolated in their own partition
- GSIs remain for secondary tag lookups across partitions

**Query execution**:
- Single-entity query (common case): Direct partition key lookup — no GSI needed, no scan
- Multi-tag query (same entity): Partition key + filter on secondary tags
- Cross-entity query (rare): Scatter-gather across partitions via GSI

**Conditional append**:
- Same read-then-write pattern, but now scoped to a single partition
- Reduced contention — only writers to the same entity compete
- Could use DynamoDB transactions for true atomicity within a partition

**Pros**:
- Eliminates the hot partition bottleneck
- Scales horizontally with the number of entities
- Each partition stays small (one entity's events)
- Compatible with Cosmos DB (entity = logical partition, well within 20GB)
- Conditional append contention reduced to per-entity level
- Enables DynamoDB transactions for atomic read-check-write within a partition

**Cons**:
- Position ordering is now per-partition, not global (but we showed global order isn't needed)
- Cross-entity queries require scatter-gather (but these are rare in practice)
- Requires identifying a "primary tag" — may not always be obvious
- Schema change: the partition key derivation must be deterministic and consistent

**Effort**: Medium. The adapter changes are localized — `DcbEventLogStorage_DynamoDb_Runtime.res` needs a different `id` value, and the `read` operation adjusts its query strategy. Core interfaces (`DcbEventLog_Adapter.res`) remain unchanged since the `read(~query, ~after?)` signature doesn't assume a partition key.

### 4.2 Strategy: Event-Stream-per-Entity (Aggregate-Like)

**Concept**: Model each entity as its own event stream, similar to how the Aggregate EventLog works (`id` = entity ID, `sequenceNr` = integer sequence).

```
Partition Key: id = "item-123"
Sort Key:      sequenceNr = 1, 2, 3, ...
```

**How it works**:
- Each entity has its own monotonically increasing sequence
- Tags are still stored for cross-entity queries via GSIs
- The decision model is built by reading one entity's stream
- Conditional append uses `sequenceNr` for optimistic concurrency (like aggregates)

**Pros**:
- Maximum distribution — identical to aggregate event logs
- Integer sequence numbers enable DynamoDB conditional writes (`attribute_not_exists(sequenceNr)`)
- True optimistic concurrency without the read-then-write race
- Trivially portable to any cloud provider
- Well-understood pattern (it's how aggregates already work)

**Cons**:
- **Fundamentally changes the DCB model**. DCB is designed for decision models that span multiple event types from a shared log — not per-entity streams. If a decision model needs events from multiple entities (e.g., "order + inventory"), this approach requires reading multiple streams and merging.
- Cross-entity decision models become scatter-gather reads
- Loses the simplicity of "one log, one query" that makes DCB appealing
- Blurs the line between DCB and aggregates — may not justify its existence as a separate concept

**Effort**: High. This is architecturally significant — it changes what DCB means.

### 4.3 Strategy: Tag-Combination Partition Key

**Concept**: The partition key is derived from **all tags** in the query, not just one. This groups events by the exact tag combination that queries will use.

```
Partition Key: id = "itemId:item-123"                         (single tag)
Partition Key: id = "categoryId:cat-1#itemId:item-123"        (multi-tag)
```

**How it works**:
- Each unique tag combination becomes a partition
- Events with multiple tags are written to **multiple partitions** (fan-out write)
- Queries hit exactly one partition — the one matching their tag combination
- No GSIs needed for tag filtering — the partition key IS the filter

**Pros**:
- Every query hits exactly one partition — optimal read performance
- No scatter-gather for any query pattern
- Partition sizes are naturally bounded by entity cardinality

**Cons**:
- **Write amplification**: An event with N tag combinations must be written to N partitions. For events with 3 tags, that's up to 7 partitions (all subsets). This significantly increases write costs and latency.
- Complexity in maintaining consistency across partitions
- Conditional append must check all relevant partitions — hard to make atomic
- Storage cost multiplied by the number of tag combinations

**Effort**: Very High. Write amplification and multi-partition consistency make this impractical for most workloads.

### 4.4 Strategy: Sharded Single Log with Deterministic Routing

**Concept**: Keep the single-log semantics but distribute events across N shards. The shard is determined by hashing the primary tag value.

```
Partition Key: id = "dcb-shard-3"   (shard = hash(primaryTag) % N)
Sort Key:      position              (timestamp-uuid)
```

**How it works**:
- N fixed shards (e.g., 16 or 64) replace the single "dcb" partition
- Events are routed to a shard based on their primary tag: `shard = hash(primaryTag) % N`
- Queries for a specific tag value hit exactly one shard (deterministic routing)
- Cross-entity queries scan all shards and merge results

**Pros**:
- Distributes write load across N partitions
- Single-entity queries still hit one shard (same performance as Strategy 4.1)
- No schema changes — transparent to the application
- Shard count tunable at deploy time
- Compatible with all cloud providers (each shard < 20GB on Cosmos DB if N is large enough)
- Conditional append scoped to one shard — reduced contention

**Cons**:
- Cross-entity queries require N parallel reads + merge (but these are already rare)
- Shard rebalancing (changing N) requires data migration
- Position ordering is per-shard — cross-shard ordering requires k-way merge (already implemented for multi-query-item reads)
- Slightly more complex deployment configuration

**Effort**: Low-Medium. The routing logic is simple (`hash % N`), and the existing k-way merge infrastructure handles multi-shard reads.

---

## 5. Recommended Approach: Primary Tag Partitioning (Strategy 4.1)

### Why This Strategy

Strategy 4.1 (Primary Tag as Partition Key) is the best balance of simplicity, performance, and portability:

1. **It matches how DCB is actually used.** Every StateChangeSlice command carries tags that scope the query to a specific entity. The primary tag is always present and always filters the query. Using it as the partition key makes the common case (single-entity reads/writes) a direct key lookup — no GSI, no scan.

2. **It eliminates the hot partition without changing the programming model.** The `read(~query, ~after?)` interface doesn't change. The adapter internally derives the partition key from the query's tags. Application code (StateChangeSlice specs, decision models) remains identical.

3. **It's portable.** Every cloud provider supports partition-key-based distribution. Cosmos DB partitions by a designated field. Firestore uses subcollections. Bigtable distributes by row key prefix. This strategy works everywhere.

4. **It enables per-entity transactions.** On DynamoDB, a single-partition transaction can atomically read-check-write, eliminating the conditional append race window entirely. On Cosmos DB, the same applies via stored procedures or transactional batch.

5. **It's the smallest change.** The core adapter interface doesn't change. The infrastructure types don't change. Only the AWS (and future Azure/GCP) adapter implementations change their partition key derivation.

### What Needs to Change

#### Spec Layer (`reventless-spec`)

Add a concept of "primary tag" to the DcbEventLog or DcbTag:

```rescript
// DcbTag.res — new
type partitionTag = {key: string}  // identifies which tag field is the partition key

// Could be derived automatically: the first @s.matches(DcbTag.string) field
// Or explicitly annotated: @s.matches(DcbTag.partition) string
```

**Decision needed**: Should the primary tag be implicit (first tagged field) or explicit (new annotation)? Explicit is safer — it makes the partitioning strategy visible in the schema and prevents accidental changes from reordering fields.

#### Adapter Interface (`reventless-core`)

No changes to `DcbEventLog_Adapter.res`. The `read`, `append`, and `readStream` operations already receive tag information via the query parameter. The adapter can internally derive the partition key from the query's tags.

However, the `storageMaker` type may need a new parameter:

```rescript
type storageMaker = (~name: string, ~indexes: array<index>, ~partitionTag: DcbTag.partitionTag, ~opts: ...) => storage
```

This tells the adapter which tag field to use as the partition key.

#### AWS Adapter (`reventless-aws`)

Changes in `DcbEventLogStorage_DynamoDb_Runtime.res`:

1. **Partition key derivation**: Replace `id: "dcb"` with `id: "${partitionTag.key}:${tagValue}"` extracted from the event's tags
2. **Read operation**: Extract the partition tag value from the query's tags, use as partition key
3. **Conditional append**: Scoped to one partition — can use DynamoDB `TransactWriteItems` for atomicity
4. **Cross-entity queries** (if needed): Scatter-gather across partitions via GSI or scan

#### Handling Cross-Entity Queries via Scatter-Gather

Some decision models may need events from multiple entities (e.g., "is this item ID unique across all items?", "does the order reference a valid product?"). With primary tag partitioning, these queries can no longer hit a single partition. Instead they require a **scatter-gather** pattern.

##### What Is Scatter-Gather?

Scatter-gather is a distributed query pattern where:

1. **Scatter**: The query is dispatched in parallel to multiple partitions (or shards, or nodes)
2. **Gather**: The results from each partition are collected, merged, deduplicated, and sorted into a single result set

In the context of DCB EventLog with primary-tag partitioning:

```
Query: "all ItemCreated events" (no primary tag filter)

Scatter phase:
  ├─ Partition "itemId:item-001"  →  [event@pos-3, event@pos-7]
  ├─ Partition "itemId:item-002"  →  [event@pos-5]
  ├─ Partition "itemId:item-003"  →  [event@pos-1, event@pos-9]
  └─ ... (N partitions)

Gather phase:
  1. Collect all results           →  [pos-3, pos-7, pos-5, pos-1, pos-9, ...]
  2. Deduplicate by position       →  (remove any overlap from multi-tag events)
  3. Sort by position              →  [pos-1, pos-3, pos-5, pos-7, pos-9]
  4. Return merged result
```

##### Scatter-Gather Implementation Approaches

**Approach A: GSI-Based Scatter-Gather (Recommended)**

Use a Global Secondary Index that spans all partitions:

```
GSI "by_eventType":  hashKey = eventType,  rangeKey = position
```

When a query lacks the primary tag (cross-entity), the adapter queries this GSI instead of the base table. The GSI's hash key is the event type, so it naturally groups events by type across all entities. DynamoDB distributes GSI partitions independently from the base table, so this doesn't recreate the hot-partition problem — each event type gets its own GSI partition.

```
Cross-entity query:   GSI query on eventType="ItemCreated"
                      → Returns all ItemCreated events, sorted by position
                      → Single GSI partition per event type
                      → No scatter needed — the GSI already aggregates

Multi-type query:     Parallel GSI queries per event type
                      → [query(eventType="ItemCreated"), query(eventType="ItemDeleted")]
                      → K-way merge on position (existing infrastructure)
```

This is efficient because:
- Each event type maps to one GSI partition — no fan-out
- The existing k-way merge (`mergeSortedEvents` in the runtime) handles multi-type queries
- No application-level scatter logic needed — DynamoDB's GSI does the aggregation

**Approach B: Explicit Partition Enumeration**

When no GSI covers the query, the adapter must enumerate partitions:

1. Maintain a **partition registry** (a DynamoDB item or separate table listing all known partition keys)
2. On cross-entity query, read the registry to get all partition keys
3. Scatter the query to each partition in parallel
4. Gather and merge results

```rescript
// Pseudocode for explicit scatter-gather
let scatterGather = (query, partitionKeys) => {
  // Scatter: parallel queries to each partition
  let results = await Promise.all(
    partitionKeys->Array.map(pk => queryPartition(pk, query))
  )
  // Gather: merge, deduplicate, sort
  results
  ->Array.flat
  ->deduplicateByPosition
  ->sortByPosition
}
```

This is less efficient because:
- Requires maintaining a partition registry (extra write on first event per entity)
- Fan-out is proportional to the number of entities — can be thousands of parallel queries
- Each query consumes RCU independently — cost scales linearly with partition count
- Latency is bounded by the slowest partition response (tail latency)

**Approach C: Streaming Scatter-Gather (for Large Result Sets)**

For queries that return large result sets (e.g., replaying all events for a migration), an eager scatter-gather materializes everything in memory. A streaming variant avoids this:

1. Open a paginated stream to each partition
2. Use the existing **k-way merge** infrastructure to lazily merge streams by position
3. Each partition's stream fetches pages on demand (backpressure-aware)

```
Stream merge (lazy):
  Stream(partition-1)  ─┐
  Stream(partition-2)  ─┤── k-way merge by position ──→  merged stream
  Stream(partition-3)  ─┘

  Each stream paginates independently.
  Merge advances only the stream with the smallest current position.
  Memory usage: O(N) where N = number of partitions (one page buffer each).
```

The runtime already implements this pattern in `mergeSortedEvents` (lines 344-373 of `DcbEventLogStorage_DynamoDb_Runtime.res`), using bounded queues and `Stream.paginateEffect`. It would need to be adapted from merging GSI query streams to merging partition query streams, but the core algorithm is identical.

##### Performance Characteristics of Scatter-Gather

| Metric | Single Partition (current) | Scatter-Gather (cross-entity) | Single Partition Lookup (same-entity) |
|--------|---------------------------|-------------------------------|---------------------------------------|
| **Latency** | Single query RTT | Max(all partition RTTs) — tail latency | Single query RTT |
| **Throughput** | Limited by one partition | Parallelized across partitions | Per-entity partition limit |
| **RCU cost** | 1 query | N queries (one per partition) | 1 query |
| **Memory** | Result set size | Sum of all partition results (eager) or O(N) page buffers (streaming) | Result set size |
| **Ordering** | Guaranteed (single source) | Requires merge sort | Guaranteed (single partition) |

##### When Scatter-Gather Is Acceptable

Cross-entity queries in DCB are inherently rare. The DCB model is designed around **entity-scoped decision models** — a command targets a specific entity, and the decision model needs only that entity's events. Cross-entity needs fall into a few categories:

| Use Case | Frequency | Better Solution |
|----------|-----------|-----------------|
| **Uniqueness check** ("is this name taken?") | Per-create command | Dedicated uniqueness read model (updated by EventCollector). The read model provides O(1) lookup; no need to query the event log. |
| **Cross-entity validation** ("does the referenced product exist?") | Per-command with reference | Query the referenced entity's partition directly (if its ID is known from the command). This is a targeted single-partition read, not scatter-gather. |
| **Global replay** (migration, analytics) | Rare, offline | Streaming scatter-gather is acceptable — latency doesn't matter for batch operations. Or use DynamoDB export to S3 for bulk processing. |
| **Audit / debugging** ("show all events for last hour") | Rare, manual | GSI on `eventType` + `position` handles this efficiently. |

**Key insight**: Most apparent "cross-entity" needs can be decomposed into either (a) a read model query or (b) a targeted single-partition read using a known entity ID. True scatter-gather — querying all partitions without knowing which ones to target — is almost always a sign that a read model should exist for that query pattern.

##### Recommendation

**Use GSI-based scatter-gather (Approach A) as the fallback for cross-entity queries.** This requires no partition enumeration, leverages DynamoDB's built-in distribution, and integrates with the existing k-way merge infrastructure. Document that:

1. Entity-scoped queries (with primary tag) are the fast path — direct partition lookup
2. Cross-entity queries (without primary tag) use a GSI fallback — still efficient for event-type-scoped queries
3. True cross-partition scatter (no event type, no tags) falls back to table scan — same as current behavior, but now distributed across partitions rather than concentrated in one
4. For recurring cross-entity query patterns, a dedicated read model is the recommended approach

### Migration Path

1. **Phase 1 — Add `partitionTag` concept**: Extend `DcbTag` with partition tag annotation. Update `storageMaker` to accept it. No runtime behavior change yet — adapter still uses `"dcb"` as partition key.

2. **Phase 2 — New adapter implementation**: Build `DcbEventLogStorage_DynamoDb_V2` that uses primary-tag partitioning. Run alongside V1 for testing. No data migration needed — new deployments use V2, existing deployments stay on V1.

3. **Phase 3 — Migration tool**: For existing deployments, provide a migration utility that reads all events from the V1 single-partition table and writes them to a V2 partitioned table. Since events are immutable and append-only, this is a one-time operation.

4. **Phase 4 — Deprecate V1**: After validation, mark the single-partition adapter as deprecated.

---

## 6. Impact on Conditional Append Atomicity

The primary tag partitioning strategy enables a significant improvement to conditional appends.

### Current (Single Partition, Non-Atomic)

```
1. Read events matching query         → DynamoDB Query on GSI
2. Check: any events after position?  → Application logic
3. Write new events                   → DynamoDB BatchWriteItem
   (Race window between steps 1 and 3)
```

### Improved (Per-Entity Partition, Atomic via DynamoDB Transactions)

```
1. TransactWriteItems:
   - ConditionCheck: no item with partition=entity, position > headPosition matching query
   - Put: new events with partition=entity, position=generated
   (Atomic — DynamoDB guarantees all-or-nothing within 100 items)
```

DynamoDB transactions support up to **100 items per transaction** (25 per `TransactWriteItems` call, but can be batched). For typical DCB operations producing 1-5 events, this is well within limits.

**Benefit**: Eliminates the retry loop in `StateChangeSlice_Callback.res`. The conditional append either succeeds or fails atomically — no race window, no need for 3 retries.

**Caveat**: DynamoDB transactions are 2x the cost of individual operations. For workloads where the retry rate is low (< 5%), the current non-atomic approach may be more cost-effective. The transaction-based approach should be optional.

---

## 7. Impact on Other Cloud Providers

| Cloud Provider | Current Design (single partition) | Primary Tag Partitioning |
|---------------|-----------------------------------|--------------------------|
| **AWS DynamoDB** | Works but hot partition limits throughput | Scales horizontally, enables transactions |
| **Azure Cosmos DB** | 20GB partition limit — blocks at scale | Each entity partition stays small, well within limits |
| **GCP Firestore** | Works but poor write distribution | Natural subcollection model: `dcbEventLogs/{entityId}/events/{position}` |
| **GCP Bigtable** | Hot row key prefix | Distributed row keys: `entityId#position` |

Primary tag partitioning **solves the Cosmos DB 20GB limit** identified in `azure-cloud-provider-analysis.md` and aligns naturally with Firestore's subcollection model identified in `gcp-cloud-provider-analysis.md`.

---

## 8. Risk Assessment

### Low Risk
- **Core interface compatibility**: The `read(~query, ~after?)` and `append(events, ~condition?)` signatures don't change
- **In-memory adapter**: Trivial to update (or keep as-is — it has no partition concept)
- **Backward compatibility**: V1 (single partition) and V2 (primary tag) can coexist as separate adapter implementations

### Medium Risk
- **Primary tag selection**: Choosing the wrong primary tag leads to uneven partition distribution. Mitigate by requiring explicit annotation (`@s.matches(DcbTag.partition)`) and documenting selection criteria.
- **Cross-entity query performance**: Rare but possible. Mitigate with GSI fallback and clear documentation.
- **Migration complexity**: Existing deployments need a data migration tool. Mitigate by making V2 opt-in for new deployments first.

### High Risk
- **Decision models spanning multiple entities**: If a decision model genuinely needs events from multiple unrelated entities, primary tag partitioning forces scatter-gather reads or a different approach entirely. This is a design-level concern — the DCB spec documentation should clarify that entity-scoped decision models are the intended pattern.

---

## 9. Summary

| Aspect | Current (Single Partition) | Recommended (Primary Tag) |
|--------|--------------------------|---------------------------|
| **Partition key** | `"dcb"` (fixed) | `"<tagKey>:<tagValue>"` (per entity) |
| **Write throughput** | Limited by single partition | Scales with entity count |
| **Read pattern** | GSI query → single partition | Direct partition lookup (common case) |
| **Ordering** | Global total order | Per-entity order (sufficient for all consumers) |
| **Conditional append** | Non-atomic read-then-write | Atomic DynamoDB transaction (optional) |
| **Cosmos DB compatibility** | Blocked at 20GB | Each partition well within limits |
| **Firestore compatibility** | Unnatural flat model | Natural subcollection model |
| **Core interface changes** | N/A | None (adapter-level only) |
| **Spec changes** | N/A | New `partitionTag` annotation |
| **Migration** | N/A | One-time append-only copy |

---

## 10. Relationship to Multi-Clause DCB Queries

The [Multi-Clause DCB Queries plan](../plans/done/multi-clause-dcb-queries-plan.md) (now implemented) addressed a complementary concern: how `StateChangeSlice_Callback` **constructs queries** for cross-entity decision models. This analysis addresses how the storage layer **executes** those queries. The two concerns interact directly and should be considered together.

### How They Connect

The multi-clause implementation (now complete) uses automatic schema-driven query construction via `DcbTag.buildQueryFromCommand`. The query mode is determined by inspecting the command schema at runtime:

- **Scalar tagged fields only** (e.g., `itemId: @s.matches(DcbTag.string) string`): All tags AND'd in one clause — targets one entity
- **Tagged array fields present** (e.g., `productId: array<@s.matches(DcbTag.string) string>`): Each tag becomes a separate OR clause — targets multiple entities

When `PlaceOrder({orderId: "ord-1", productId: ["prod-1", "prod-2"]})` has a tagged array field, the callback automatically produces:

```
[
  {tags: [{key: "orderId", value: "ord-1"}]},
  {tags: [{key: "productId", value: "prod-1"}]},
  {tags: [{key: "productId", value: "prod-2"}]},
]
```

Under **single-partition** storage (current), all three clauses hit the same `id="dcb"` partition via GSI lookups — the existing k-way merge handles this.

Under **primary-tag partitioning** (recommended here), each clause targets a different partition:

| Clause | Partition |
|--------|-----------|
| `orderId: "ord-1"` | `"orderId:ord-1"` |
| `productId: "prod-1"` | `"productId:prod-1"` |
| `productId: "prod-2"` | `"productId:prod-2"` |

This is exactly the **scatter-gather pattern** described in Section 4.1. The adapter dispatches each clause to its target partition in parallel, then merges results — the k-way merge infrastructure already supports this.

### Impact on Conditional Append Atomicity

Section 6 describes how per-entity partitions enable atomic DynamoDB transactions for conditional appends. However, cross-entity queries span multiple partitions. The implications:

- **The append itself targets one partition** — new Order events go to `"orderId:ord-1"`. The decision model reads from multiple partitions, but the write is still single-partition.
- **The condition check must cover all read partitions** — if a new `CatalogProductSynced` event appears between the read and write, the decision model used stale data. The condition `{query, after: headPosition}` must verify no new events appeared in ANY of the queried partitions since the read.
- **DynamoDB transactions can handle this** — `TransactWriteItems` supports `ConditionCheck` on items across partitions (up to 100 items, all within the same table). The append can atomically verify conditions on the Order partition AND the CatalogProduct partitions.
- **If the number of clauses exceeds DynamoDB's 100-item transaction limit**, the non-atomic retry approach remains as a fallback. For typical cross-entity commands (< 10 referenced entities), transactions are sufficient.

### Implementation Ordering

Multi-clause queries have already been implemented on the current single-partition storage. The remaining work is primary-tag partitioning at the adapter level:

1. ~~**Multi-clause queries can be implemented first**~~ — **Done.** `DcbTag.buildQueryFromCommand` and `StateChangeSlice_Callback` now handle automatic schema-driven query construction. All clauses hit GSIs on the same `"dcb"` partition.
2. **Primary-tag partitioning is the next step**. The adapter's `read` function already receives `array<queryItem>` — it just needs to route each item to the correct partition instead of the fixed `"dcb"` partition.
3. When partitioning is in place, cross-entity queries automatically benefit from distributed partition reads — no additional integration work needed.

The hybrid example (`online-shop-hybrid`) already uses multi-clause queries on the current single-partition storage, and will benefit from improved scalability when primary-tag partitioning ships.

### Summary

| Concern | Multi-Clause Queries (implemented) | Partitioning Improvement (not yet implemented) |
|---------|---------------------|-------------------------|
| **Layer** | Spec + Callback (query construction) | Adapter (query execution) |
| **What changes** | `DcbTag.buildQueryFromCommand` auto-detects tagged arrays; Callback splits tags into OR clauses | Adapter routes queries to entity-specific partitions |
| **Dependency** | None on partitioning — works on single partition | None on multi-clause — single-clause queries also benefit |
| **Combined effect** | Cross-entity queries + per-entity partitions = scatter-gather across targeted partitions with k-way merge |
| **Conditional append** | Multi-clause condition must check all queried partitions | DynamoDB transactions enable atomic cross-partition condition checks |
