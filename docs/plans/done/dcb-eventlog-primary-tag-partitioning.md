# DCB EventLog Primary Tag Partitioning Plan

> **Status: Done** — Implemented 2026-03-28. Based on analysis in `docs/analysis/dcb-eventlog-partitioning-improvement.md`.

**Goal**: Replace the fixed `id="dcb"` single-partition design with primary-tag partitioning (`id="<tagKey>:<tagValue>"`), where each entity gets its own DynamoDB partition. This is an in-place change to the existing adapter — no V2 modules, no migration.

**Why**: The single-partition design creates a DynamoDB hot partition bottleneck, blocks Azure Cosmos DB support (20GB partition limit), and prevents atomic conditional appends. See analysis sections 2-3 for full rationale.

---

## Design decisions

### Partition tag selection rules

The partition tag determines which tag value becomes the DynamoDB partition key. Selection is automatic based on how many tags exist in the DCB spec:

| Scenario | Behavior |
|----------|----------|
| **1 tag defined** | That tag is automatically the partition tag. No annotation needed. |
| **Multiple tags, one marked `DcbTag.partition`** | The marked tag is the partition tag. |
| **Multiple tags, none marked** | Build-time error — require explicit `DcbTag.partition` annotation when ambiguous. |

### No V2 / no migration

Since there's no migration path needed, this is a breaking change to the existing adapter. The `DcbEventLogStorage_DynamoDb_Runtime.res` is modified in place — `id="dcb"` becomes `id="<tagKey>:<tagValue>"`. No V2 modules, no coexistence.

---

## Step 1: Add `partitionTag` concept to DcbTag (reventless-spec)

**Files to change:**
- `reventless/reventless-spec/src/components/DcbTag.res` — add `type partitionTag = {key: string}` and `DcbTag.partition` schema matcher
- `reventless/reventless-spec/src/components/DcbTag.resi` — expose the new type

**Details:**
- Add `DcbTag.partition` as a schema matcher variant (like `DcbTag.string` but marks the field as the partition key)
- `DcbTag.partition` tagged fields still behave as normal tags for query construction — they additionally carry the "this is the partition key" metadata
- Add helper: `getPartitionTag: array<index> => partitionTag` that derives the partition tag from the indexes (auto-selects when only 1 tag, errors when multiple and none marked)
- Add helper: `getPartitionTagValue: (query, partitionTag) => option<string>` to extract the partition key value from a query

**Done when:** `DcbTag` exports `partitionTag` type, `DcbTag.partition` matcher, and derivation helpers.

---

## Step 2: Extend `storageMaker` to accept `partitionTag` (reventless-core)

**Files to change:**
- `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Adapter.res` — add `~partitionTag: DcbTag.partitionTag` parameter to `storageMaker` type
- `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Builder.res` — thread `partitionTag` through to the storage maker

**Details:**
- Current signature: `(~name: string, ~indexes: array<string>, ~opts: Pulumi.CustomResourceOptions.t) => storage`
- New signature: `(~name: string, ~indexes: array<string>, ~partitionTag: DcbTag.partitionTag, ~opts: Pulumi.CustomResourceOptions.t) => storage`
- The `read`, `append`, `readStream` operation signatures do NOT change — they already receive tag information via the query parameter

**Done when:** `storageMaker` accepts `partitionTag` and passes it to the adapter.

---

## Step 3: Update `Plugin.make` to propagate `partitionTag`

**Files to change:**
- `reventless/reventless-spec/src/components/Plugin.res` — add `partitionTag` to DCB-related spec/config types
- `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res` — extract `partitionTag` from spec and pass through

**Details:**
- The `partitionTag` originates from the plugin's DCB spec and must flow to the `storageMaker` call
- Follow the same pattern as `indexes` flows from spec → builder → storageMaker

**Done when:** A plugin spec can declare a partition tag and it reaches the storageMaker call.

---

## Step 4: Modify DynamoDB adapter for primary-tag partitioning (reventless-aws)

**Files to change:**
- `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` — change partition key derivation
- `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res` — accept and thread `partitionTag`

**Details:**

### Partition key derivation (Runtime, line 36)
- Replace `item->Dict.set("id", "dcb"->JSON.Encode.string)` with `item->Dict.set("id", "${partitionTag.key}:${tagValue}"->JSON.Encode.string)`
- Extract `tagValue` from the event's tags array using `partitionTag.key`

### Read operation
- Extract partition tag value from the query's tags via `getPartitionTagValue`
- If present: direct partition key lookup — no GSI needed for the primary tag filter
- If absent (cross-entity query): fall back to GSI-based query (same as current behavior)

### Append operation
- Derive partition key from the new events' tags using `partitionTag`

### Conditional append (atomic)
- Use DynamoDB `TransactWriteItems` for single-partition conditional appends
- Fall back to current non-atomic retry approach for cross-partition conditions or when transaction item count exceeds 100

### Cross-entity queries (scatter-gather)
- When query contains multiple clauses targeting different partitions (multi-clause DCB queries):
  - Dispatch each clause to its target partition in parallel
  - Use existing k-way merge (`mergeSortedEvents`) to combine results
- GSI fallback for queries without a partition tag value

**Done when:** Existing DCB EventLog tests pass with partition-key routing. Single-entity reads, cross-entity scatter-gather, and conditional appends all work.

---

## Step 5: Update in-memory adapter (reventless-in-memory)

**Files to change:**
- `reventless/reventless-in-memory/src/adapter/DcbEventLogStorage_InMemory.res` — accept `partitionTag` parameter

**Details:**
- Accept the `partitionTag` parameter to satisfy the updated `storageMaker` signature
- Optionally: partition the in-memory event array by tag value to simulate DynamoDB behavior and catch bugs that assume global ordering

**Done when:** In-memory adapter compiles with the updated `storageMaker` signature.

---

## Step 6: Update examples and tests

**Files to change:**
- `examples/online-shop-dcb/` — add `DcbTag.partition` annotation where needed (specs with multiple tags)
- `examples/online-shop-hybrid/` — same
- Existing test files — update for new partition behavior

**Details:**
- Specs with a single tag need no changes (auto-selected as partition tag)
- Specs with multiple tags need one field annotated with `DcbTag.partition`
- Verify cross-entity specs (multi-clause queries with tagged arrays) correctly scatter-gather

**Done when:** All example projects and tests pass.

---

## Non-goals

- **Migration tooling**: This is a breaking change. No V1→V2 migration utility.
- **Aggregate EventLog changes**: Only DCB EventLog is affected. Aggregate EventLogs already partition by entity ID.

---

## Key files reference

| File | Role |
|------|------|
| `reventless/reventless-spec/src/components/DcbTag.res` | Tag types, query construction, partition tag definition |
| `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Adapter.res` | Adapter interface, storageMaker type |
| `reventless/reventless-core/src/components/DcbEventLog/DcbEventLog_Builder.res` | Builder that wires storageMaker |
| `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res` | Deploy-time adapter |
| `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` | Runtime (partition key at line 36) |
| `reventless/reventless-in-memory/src/adapter/DcbEventLogStorage_InMemory.res` | In-memory adapter |
