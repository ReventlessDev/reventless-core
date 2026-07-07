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

> **Superseded by the root-cause correction below (2026-07-07).** On tracing the
> live workload through the *current* runtime, the hot fences are **not** loose
> "scope tags" bumped by the (long-removed) `extraEventTags` path — they are the
> **individual members of a `@compositePartitionTag` key**, each getting its own
> fence. The right fix is a single composite fence per composite-partition entity,
> not a per-tag opt-out annotation. §2/§3 do not address this mechanism. See
> "Root-cause correction" below; it replaces the §1/§2/§3 recommendation for this
> workload.

## Root-cause correction (2026-07-07) — composite-partition per-member fencing

The Problem section above (and §2/§3) was written against an older runtime whose
`extraEventTags` path bumped a fence for *every* secondary event tag. **That path no
longer exists** — analysis Issue 1's narrowing removed the blanket secondary-tag
bump; today the only unconditional bumps (`bumpTags` in
[`buildConditionalTransactItems`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)) are partition tags, composite-query tags, and
cross-partition carriers. So the stale mechanism cannot be the culprit, and the
§1/§2/§3 mitigations (all aimed at that mechanism) would not touch the hot path.

**Actual mechanism.** The live workload's `SyncResource` / `SyncPlatform` / … slices
(downstream `platform-inspector`) declare a **`@compositePartitionTag`** key over
`{environment, platformName, pluginName, componentName, resourceName}`. Tracing one
`SyncResource` command through the current runtime:

- **Storage** writes each event under **one** base-table `id` = the full composite
  value (`derivePartitionKey` → `DcbTag.getCompositePartitionKeyValue`). High
  cardinality — one item per real resource. ✓
- **Decision read** — `DcbTag.buildQueryFromCommand` emits **one composite (multi-tag)
  clause** `[{tags: [environment, platformName, pluginName, componentName, resourceName]}]`,
  which `executeQueryItemStream` routes to `queryByCompositeTagsStream` on the
  `tag_composite` GSI — an **exact-match** on the full 5-part key. ✓
- **Fence** — that same multi-tag clause is classified as a *composite query* clause,
  so `buildConditionalTransactItems` pushes a **conditional fence Update on every
  member tag**: `fence#environment:<v>`, `fence#platformName:<v>`,
  `fence#pluginName:<v>`, `fence#componentName:<v>`, `fence#resourceName:<v>`. The
  `eventPartitionTags` `Composite` branch (`| Some(Composite(_)) => event.tags`)
  reinforces this — it treats every member as a partition tag for the bump path too.

So **fence scope (5 per-member fences) is far wider than read scope (one exact
composite match)** — an over-fencing bug that violates the Phase 0 fence-scope =
read-scope invariant. In a deploy fan-out that syncs N resources under the same
`environment` / `platformName` / `pluginName`, the three low-cardinality prefix
members are conditionally written by **every** command in the burst →
`fence#environment:prod` et al. go hot → `TransactionConflict` → the slice's 3-retry
loop bottoms out → `retries exhausted` at the command bus. It is also **semantically
wrong**: two *distinct* resources that merely share a prefix (same environment) needlessly serialize,
even though they are different entities under different composite `id`s.

**Fix — IMPLEMENTED (2026-07-07), code-only, no PPX / no republish.** Collapse the
per-member fences into a **single composite fence** — but **only when `partitionTag`
is `Composite`**:

1. `eventPartitionTags`' `Composite` branch returns a *single synthetic composite
   tag* (`{key: "<reserved>", value: compositeTagKey(memberTags)}`, mirroring the
   `tag_composite` GSI value the read already uses) instead of all member tags.
2. In `buildConditionalTransactItems`, when `partitionTag` is `Composite`, the
   composite query clause maps to that one synthetic composite fence (check+bump at
   `after=Some`; `attribute_not_exists` create guard at `after=None`) rather than
   one Update per member. `producedTypesFor` / `partitionTypesByTag` already key off
   `eventPartitionTags`, so they stay internally consistent with the synthetic tag.

Effect: one fence per composite entity — as high-cardinality as the entity itself, so
no hot low-cardinality members — and fence scope now equals the exact composite read
scope, removing the false conflicts between distinct composite entities. `tag_composite`
stays `ALL` (Phase 3), so composite reads are unaffected.

**Why this is scoped to `Composite` only (do NOT generalise).** A *simple*-partition
slice can also emit a composite (multi-tag) read that is **not** a composite partition
— e.g. `RecordProductDemand` (`@partitionTag productId` + a `{productId, orderId}`
pair read). There `productId` is a *real* storage partition another slice may read by,
so its member fence must keep bumping independently. The genuine M:N reads
(`PlaceOrder`'s `@ref productIds`) are already fanned into single-tag cross-partition
clauses by `buildQueryFromCommand`, so they never hit the composite path. Gating the
collapse on `partitionTag = Composite` touches only the true composite-partition case
and leaves every online-shop read path byte-for-byte identical.

**Implementation (shipped 2026-07-07).** Two edits in
[`DcbEventLogStorage_DynamoDb_Runtime.res`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res):
(1) a `compositeFenceTagKey` / `makeCompositeFenceTag` helper + the `eventPartitionTags`
`Composite` branch now returns `[makeCompositeFenceTag(event.tags, spec)]` (bump path);
(2) `buildConditionalTransactItems` rewrites each multi-tag query clause to a single
synthetic composite fence tag **when `partitionTag = Composite`** (check path), so the
existing Simple-partition machinery fences it as one entity. The read path
(`readStream`) is untouched — it keeps the member tags and its `tag_composite` GSI
lookup. `@crossPartition` carriers are unaffected (handled by `crossPartitionEventTags`).

**Tests (green).**
- Unit (`DcbEventLogStorage_DynamoDb_RuntimeTest.res`, +5 cases; AWS suite 200 green):
  a `Composite`-partition append builds **exactly one** composite fence item — a
  conditional Update at `after=Some`, an `attribute_not_exists` create guard at
  `after=None` — and **no** per-member fence; the `Simple`-partition composite-pair
  case (RecordProductDemand shape) still check+bumps every member (regression guard,
  pre-existing test, unchanged).
- Integration (Phase 1 harness, +2 cases, green against DynamoDB Local): two
  first-writers to *different* composite entities sharing the `environment`/`platform`/
  `plugin` prefix **both succeed** (the hot-fence regression); two first-writers to the
  *same* composite key still serialize — the second conflicts (OCC preserved). The
  full integration suite is **13/13 green**: the same change also updated the
  `H.setFence` harness to the per-type `pos#<eventType>` fence model (writing the
  attribute a real conditional append checks) and gave the two conflict-expecting
  scenarios explicit `eventTypes`, fixing the two previously-red cases that still
  encoded the old scalar-`lastPosition` model.

**Risk**: low–medium — confined to `DcbEventLogStorage_DynamoDb_Runtime.res` and gated
on `Composite`; the `Simple`-partition composite-read regression guard is in place.

**Live confirmation (passive, not a code requirement).** This change makes **no
table/GSI schema change** — unlike Phase 3's projection down-project, it only changes
*which* fence items get written. On an existing alpha table the fix is backward-tolerant:
event rows are untouched (they were already stored under the composite `id`), old
per-member `fence#environment:…` rows become orphaned but **inert** (the new code never
reads or writes them), and the first conditional append seeds the
`fence#__dcb_composite__:…` row on demand (`attribute_not_exists` → passes). So **no wipe
is required for correctness.** A wipe is optional cleanup — it drops the dead per-member
rows and gives a pristine table to validate against; per repo convention (wipe alpha over
migration) it's the clean way to do that. The only genuinely-remaining step is to **deploy
and re-observe** the `platform-inspector` deploy-sync burst on the next alpha release to
confirm the `retries exhausted` cascade is gone — passive confirmation of behaviour the
integration suite already proves against a real DynamoDB engine.

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

**DONE 2026-07-07 (single composite fence); committed `c2a123195`.** The root-cause
trace (see "Root-cause correction") pinned the hot fences to **composite-partition
per-member fencing**, not the stale `extraEventTags` path §2/§3 were written for. The
fix — a **single composite fence gated on `partitionTag = Composite`**, code-only, no
PPX/republish — is shipped in `DcbEventLogStorage_DynamoDb_Runtime.res` and proven
end-to-end: the integration suite (13/13 green against a real DynamoDB engine) reproduces
the exact regression — distinct composite entities sharing a low-cardinality prefix no
longer conflict — and the AWS unit suite (200) pins the transaction shape. No table/GSI
change and backward-tolerant, so **no alpha wipe is required**; the only follow-up is
passive live confirmation on the next alpha deploy (re-observe the `platform-inspector`
deploy-sync burst — see "Live confirmation" above).

§1/§2/§3 are retained above as reference but are **superseded for this workload**:
- §1 (sharding) — still the right tool for a genuinely-hot *single* consistency key;
  not needed here (the composite fence is high-cardinality once collapsed). If a *different*
  hot-fence shape ever surfaces, open a fresh evidence-gated item rather than reopening this.
- §2/§3 (selective / opt-in fencing via PPX) — address a mechanism that no longer
  exists; would not fix the composite-partition case.
