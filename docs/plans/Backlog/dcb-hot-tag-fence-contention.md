# Plan: Mitigate Hot-Tag Fence Contention in DCB Append

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — Performance assessment, hot-tag bullet
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)

## Problem

The fence-based atomic append serializes every conditional write through one DynamoDB item per touched tag value. For tag values with skewed write distribution — `category=electronics`, `status=active`, a popular product — that fence becomes a single hot partition.

DynamoDB caps a single partition at ~1000 WCU/sec. A `TransactWriteItems` consumes 2 WCU per item, and each fence update is one item. So the structural ceiling on conditional writes touching tag value X is ~500 transactions/sec per fence regardless of how the rest of the table is provisioned.

Concurrent writers contending on the same fence trigger `TransactionConflict` (mapped to `Transient` and retried inside `Effect.retry`). Bursts cascade: the retry burst itself becomes contention, latency climbs, the slice's outer 3-retry loop ([`StateChangeSlice_Callback.res:152-159`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L152-L159)) starts bottoming out and surfacing `conflict: retries exhausted` errors at the command bus.

The unconditional bumps for `extraEventTags` ([`Runtime.res:657-660`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L657-L660)) make this worse: every event tagged with hot value X bumps that fence, even when X was not part of the writer's query. So a slice that only cares about `orderId` but writes events tagged `customerId=hotCustomer` contributes to the `customerId=hotCustomer` fence's contention.

## Triggering evidence (2026-07-07) — first real hot-fence workload

A downstream **deploy-time sync workload** is the concrete case this plan's Step 1
was waiting on. It fans out one per-entity append command per synced item (many per
deploy) into a single DCB event log, and every command in the burst carries the same
small set of **low-cardinality scope tags** (a deployment's `environment`, platform
name, and plugin name are identical across the whole fan-out). So a handful of fences
are bumped by *every* command in the burst — the exact `extraEventTags`
unconditional-bump amplifier described above. Observed live:

```
append failed, retries exhausted: DCB append failed: Transaction cancelled …
  [None, TransactionConflict, TransactionConflict, TransactionConflict, …]   (×many)
```

at the command bus — precisely the "outer 3-retry loop bottoms out →
`conflict: retries exhausted`" cascade in the Problem section. The low-fan-out
commands in the same deploy (one platform, few plugins) commit fine; the high-fan-out
per-entity commands do not. This is real profiling data, not a synthetic benchmark.

**Which mitigation fits:** the hot fences here are pure scope/lookup tags, not
per-command consistency keys — so **§2 (selective fence bumping, mark them
`#LookupOnly`)** or **§3 (declare the consistency tag set = just the per-entity id)**
is higher-leverage than §1 sharding. The per-command consistency boundary is the
entity id; the shared scope prefix never needs a fence.

## Goals

- Lift the per-tag-value throughput ceiling by an order of magnitude in the worst case.
- Preserve atomicity and correctness — fence comparisons must still detect concurrent writes that would violate DCB invariants.
- Bounded cost increase per command: ideally 0–N additional fence items (configurable), not a doubling.
- No change to the `StateChangeSlice` slice contract.

## Non-goals

- Eliminate contention entirely. With a single conditional update per writer, some serialization is fundamental — this plan is about widening the throughput ceiling, not removing it.
- Auto-detect "hot" tags at runtime. Heat is workload-specific; require a static declaration (see Approach §1).
- Dynamic resharding of fences in production. Shard count per tag is fixed at table-creation time (or app-config time). Resharding requires a migration.

## Approach

Three composable mitigations, ordered by impact and complexity.

### 1. Fence sharding via composite sort key

Replace the single fence `id="fence#<key>:<value>", position="FENCE"` with N shards `id="fence#<key>:<value>", position="FENCE#<shard>"` where `shard ∈ [0, N)`.

**Write path:** the writer picks one shard at random and updates only that shard's `lastPosition`. With N shards, contention drops by ~N× under uniform random selection.

**Read path:** the conditional check now needs to verify that **no** shard was bumped past `:after`. That requires N parallel `ConditionExpression`s in the same `TransactWriteItems`:

```
SET lastPosition = :new on shard K
ConditionExpression on shards 0..N-1: attribute_not_exists(lastPosition) OR lastPosition <= :after
```

`TransactWriteItems` allows one Update per item with one ConditionExpression. So the writer issues:
- 1 update on the chosen shard (the actual bump)
- N-1 condition-only checks on other shards via `ConditionCheck` items (zero-cost reads, condition-only, no write)

Total items per fence: N (was 1). Within the 100-item transaction cap, N is bounded — for a typical 1-event/1-tag command with N=4, that's 4 fence items + 1 event = 5 items. For multi-tag commands with many shards, the cap is reached faster.

**Net effect:** ~N× write throughput per hot fence at cost of ~N× per-call DynamoDB items. Best for tags with one or two values that dominate.

### 2. Selective fence bumping (drop unconditional bumps for marked tags)

Today, every event tag triggers a fence bump — conditional if in `cond.query`, unconditional otherwise. Introduce a per-tag-key declaration that opts out of unconditional bumps:

```rescript
@dcbTag(~consistencyMode=#LookupOnly) categoryId: string
```

Tags marked `LookupOnly` get GSI entries (so they're queryable) but are never used as DCB consistency primitives. Writers don't bump their fences. Readers querying them get current GSI state but no fence-backed atomicity guarantee.

**Use case:** tags that exist for query convenience (e.g. "find orders by category") but never appear in slice consistency-critical reads. The slice that owns the consistency boundary uses the entity ID tag; auxiliary tags for read models or cross-cutting queries don't need fences.

**Trade-off:** mis-classifying a tag breaks DCB for any slice that later wants to use it as a fence. Conservative default: tags require explicit opt-out (default = `Strict`).

### 3. Promote consistency-critical tags to a smaller fence set

Instead of fencing every event tag, fence only those declared as part of the slice's consistency boundary. This is essentially the inverse of (2): instead of opt-out via PPX, opt-in via slice declaration.

```rescript
// In a StateChangeSlice spec
let consistencyTags = ["productId", "warehouseId"]
```

The append builds fences only from `consistencyTags ∩ event.tags ∪ cond.query`. Other event tags (like `categoryId`, `createdBy`) get GSI entries but no fence write.

**Use case:** slices with broad event payloads where most fields are descriptive metadata, not consistency keys.

**Trade-off:** if two slices disagree about which tags are "consistency-critical" — Slice A treats `productId` as critical, Slice B doesn't — Slice B's writes won't trip Slice A's fences. Requires coordination across slices that share tags. PPX could enforce table-wide agreement.

## Steps

These are independent improvements; the plan ships them as separate PRs gated behind a single backlog item.

### Step 1 — Decide which mitigations to ship

Profile actual workloads first. The current implementation has no per-tag write metrics. Add CloudWatch metrics (or DynamoDB CloudWatch contributor insights) to identify which fences are hot in practice. Without that data, this plan is speculative.

If profiling shows a small number of hot fences (e.g. one per high-volume status enum), prefer §1 (sharding). If profiling shows wide diffuse contention from auxiliary tags, prefer §2 or §3 (selective fencing).

### Step 2 — Implement §2 (selective fence bumping) first

Lowest risk, lowest code churn. Adds a PPX annotation that defaults to current behaviour. Only marked tags change semantics. Backwards compatible.

- New PPX annotation `@dcbTag(~consistencyMode=#LookupOnly)` in [`reventless-ppx`](../../packages/reventless-ppx/).
- Pass the mode through to `Reventless.DcbTag.tag` as a new field (default `#Strict`).
- In [`appendConditional`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L619-L695): filter `extraEventTags` to drop `#LookupOnly` tags before building unconditional updates.
- Tests: confirm a `#LookupOnly` tag in an event doesn't appear in the `TransactWriteItems` payload.

### Step 3 — Implement §1 (fence sharding) for tags marked `#Hot`

Add a third mode `#Hot(shardCount)`. Writers pick a random shard; conditional checks span all shards via `ConditionCheck` items.

- Add `@dcbTag(~consistencyMode=#Hot(shardCount=4))` PPX form.
- Compute shard at write time: `Random.int(shardCount)`.
- Build N items per `#Hot` tag: 1 Update on chosen shard + (N-1) ConditionCheck on others.
- Surface a clear error if total items > 100.
- Tests: 4-shard fence under concurrent writers shows ~4× higher successful-commit rate than unsharded; conditional check still fails when ANY shard was bumped past `:after`.

### Step 4 — Defer §3 unless profiling justifies it

§3 (per-slice consistency tag set) is more invasive than §2. Hold until §1 + §2 prove insufficient.

### Step 5 — Document

Update [`docs/analysis/dcb-dynamodb-consistency-check.md`](../../analysis/dcb-dynamodb-consistency-check.md) §"Performance assessment" hot-tag bullet to point at the mitigations and explain when to reach for each. Update the DCB tag PPX docs in [`.claude/rules/app-developer.md`](../../../.claude/rules/app-developer.md) with the new `consistencyMode` payload.

## Open questions

- **Adaptive Capacity vs explicit sharding.** DynamoDB's adaptive capacity transparently splits hot partitions internally. For a single hot fence item, adaptive capacity helps until the partition's IOPS budget is fully reallocated — then the ceiling reasserts. Explicit sharding (§1) gives deterministic headroom. Worth measuring whether adaptive alone suffices for moderately hot fences before adding sharding code.
- **`ConditionCheck` cost.** A `ConditionCheck` in a `TransactWriteItems` consumes 2 RCU. For an N-shard hot fence, every conditional append pays 2(N-1) RCU on top of 2N WCU for the actual write+condition pair. Cost climbs nonlinearly in N — keep N small (4–8).
- **Slice-driven shard selection vs writer-driven.** Random shard selection at write time is simple but trades determinism. An alternative: hash the writer's `headPosition` to a shard, so retries land on the same shard. This makes contention worse on retry storms (already-conflicting writers re-collide). Random is probably correct.
- **Cross-table consistency.** This plan assumes one table per DCB log. A future plugin sharding events across multiple tables would need fence sharding per-table — orthogonal concern.

## Status

Not started, but **no longer speculative** — the Step 1 profiling prerequisite is
met by the 2026-07-07 deploy-sync evidence above (a real, reproducible production
workload with identified hot fences and the exact `retries exhausted` symptom).
Ready to implement §2/§3 (selective / opt-in fencing) against that workload when
scheduled; §1 sharding remains profile-gated for the broader case.
