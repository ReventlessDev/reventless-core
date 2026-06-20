# DCB Consistency-Check Issues (DynamoDB fence model) — Analysis

**Date**: 2026-06-20
**Scope**: correctness/robustness issues in the DCB optimistic-concurrency check enforced by the AWS `DcbEventLogStorage` adapter's per-tag fence sentinels. Companion to the historical options doc [dcb-dynamodb-consistency-check.md](dcb-dynamodb-consistency-check.md); this file is the live inventory.
**Related**: plans [dcb-fence-scope-alignment.md](../plans/dcb-fence-scope-alignment.md), [dcb-eventlog-primary-tag-partitioning.md](../plans/done/dcb-eventlog-primary-tag-partitioning.md), [dcb-strong-consistency-single-tag-reads.md](../plans/done/dcb-strong-consistency-single-tag-reads.md), [dcb-hot-tag-fence-contention.md](../plans/Backlog/dcb-hot-tag-fence-contention.md), [dcb-monotonic-position-generation.md](../plans/Backlog/dcb-monotonic-position-generation.md)

## How the check works (one paragraph)

A `StateChangeSlice` reads its decision model via `dcbEventLog.readStream(~query)`, folds it into `(state, headPosition)`, decides, then appends with `{query, after: headPosition}`. The DynamoDB adapter enforces the condition with **per-tag-value fence sentinels**: an item at `id="fence#<key>:<value>", position="FENCE", lastPosition=<pos>`. A conditional append rides one `TransactWriteItems` carrying the event Puts plus, per query tag, a fence operation gated on `attribute_not_exists(lastPosition) OR lastPosition <= :after`. Conflicts surface as `TransactionCanceledException` → `Conflict`. The **local** backends (`DcbEventLogStorage_InMemory`/`_Sqlite`) do **not** use fences — they evaluate the condition in-process against the actual event list (true DCB query semantics). That difference is the source of several items below.

## Issue inventory

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | Fence-scope broader than read-scope → false `ConditionalCheckFailed` | High (was live) | **Fixed 2026-06-20** (`2ecbd8599`) |
| 2 | `after=None` performs no conflict check (create-race hole) | High | **Fixed 2026-06-20** (per-type create guard) |
| 3 | Local backend ≠ AWS backend consistency semantics (test gap) | High | Open — needs integration test |
| 4 | Fences are per-tag-value, not per-(tag, event-type) | Medium | Known / partial |
| 5 | Composite (GSI) read requires an exact full-tag-set match | Medium | Latent |
| 6 | Single global `after` across a multi-clause OR query | Medium | Partial (mitigated for non-partition tags by #1) |
| 7 | Position ordering ties broken by UUID; stringified-ms fragility | Low–Med | Tracked (`dcb-monotonic-position-generation`) |
| 8 | Composite/scan reads are eventually consistent | Low–Med | Known |
| 9 | `appendUnconditional` still bumps all event tags | Low | Open (invariant inconsistency) |
| 10 | Hot-tag fence ceiling; 3-retry exhaustion surfaces as `Conflict` | Med (load) | Tracked (`dcb-hot-tag-fence-contention`) |
| 11 | 100-item `TransactWriteItems` cap is a hard cliff | Low | Known |
| 12 | Tagless scan read can choke on fence items | Low | Latent / low-confidence |

---

## Issue 1 — Fence-scope broader than read-scope (FIXED 2026-06-20)

### Symptom

On the deployed hybrid example (`online-shop-hybrid`), **Place Order** failed with:

```
Conflict: Transaction cancelled, please refer cancellation reasons for specific reasons
[None, None, ConditionalCheckFailed, None, None] (Conflict)
```

The `ConditionalCheckFailed` at item index 2 is a **`productId` consistency fence**.

**Reproduction signature:** the *first* order of any given product succeeds; *every subsequent* order containing that product fails — even from a different customer and `orderId`. The 5-item / index-2 shape matches a 2-product order:
`[put(OrderPlaced), cond(orderId), cond(productId₁)✗, cond(productId₂), uncond(customerId)]`.

### Root cause

Two scopes that must coincide didn't:

| | Scope |
|---|---|
| **Decision-model read** of a single-tag clause `T` | events in **partition `T`** — base-table query on `id="<key>:<value>"` ([`executeQueryItemStream`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) single-tag branch → `queryByPartitionKeyStream`). Sees only events whose **partition tag** is `T`. |
| **Fence bump** for tag `T` | **every** event carrying tag `T`, from any partition (`collectEventTags` + conditional updates over `collectQueryTags`). |

Events are partitioned by their **primary tag** ([primary-tag partitioning](../plans/done/dcb-eventlog-primary-tag-partitioning.md)), so a tag that is *secondary* on one event type but *primary* on another splits across partitions while sharing one fence.

Walk-through (`OrderPlaced` partitions by `orderId`; `CatalogProductSynced` by `productId`):

1. Sync `P5` → bumps `fence#productId:P5 → S5`.
2. First order of `P5` (`O1`): read of partition `productId:P5` returns `CatalogProductSynced(S5)` only → `after=S5`; check `S5 <= S5` ✓. `OrderPlaced(O1)` lands in partition `orderId:O1` and **bumps `fence#productId:P5 → P1 > S5`**.
3. Second order of `P5` (`O2`): read of partition `productId:P5` *still* sees only `CatalogProductSynced(S5)` → `after=S5`; check `fence#productId:P5 (P1) <= S5` ✗ → `ConditionalCheckFailed`. The read can never catch up — the event that advanced the fence is in a different partition.

The `@noDcbTag customerId` fix and the `PlaceOrder.res` comments assumed sibling `OrderPlaced` events leak into the `productId` read (GSI semantics). They don't — the single-tag read is a base-table *partition* query. `customerId` was removable (`@noDcbTag`); `productId` is not (the slice genuinely reads `CatalogProductSynced` by it).

### Fix (shipped)

Align fence-bump scope with read scope. In `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildConditionalTransactItems`):

- A **single-tag** query clause whose tag is **not** the written event's partition tag emits a read-only **`ConditionCheck`** (assert `lastPosition <= :after`, no bump) instead of a conditional `Update`. Partition tags keep check+bump.
- **Composite (multi-tag) clauses keep check+bump on all tags** (option B — see plan for why composite is left alone).
- Unconditional bumps are restricted to partition tags (+ composite query tags), so secondary tags like `customerId` are never fenced.

Verified with red→green unit tests on the built `TransactWriteItems` shape in `DcbEventLogStorage_DynamoDb_RuntimeTest.res`. Remaining: live DynamoDB integration test (Issue 3) and an alpha `fence#*` row wipe on deploy (stale `fence#productId:*` rows still hold high positions from the old behaviour). Plan: [dcb-fence-scope-alignment.md](../plans/dcb-fence-scope-alignment.md).

---

## Issue 2 — `after=None` performs no conflict check (create-race hole)

When the decision-model read returns zero decoded events, `appendConditional` emits **no** conditional check — only unconditional fence bumps (the `cond.after == None` branch). Two concurrent first-writers to the same entity (e.g. two `CreateOrder` for the same id) both pass and both append → duplicate creation events. The local backend, by contrast, treats "any event matching the query exists" as a conflict even at `after=None`, so it *would* reject the second — making this both a correctness hole **and** a backend divergence (Issue 3).

The `after=None`→unconditional fallback was introduced deliberately to dodge a cross-slice false conflict on shared `*Id` tags (the long comment that used to live in `appendConditional`). **Issue 1's fix removes that original reason** — a non-partition shared tag is no longer fenced — so the fallback can likely be tightened to an `attribute_not_exists(lastPosition)` check **on the partition tag only**, closing create-races without reintroducing the shared-tag problem.

Today the hole is masked only when the command topic FIFO-serializes commands per entity; any slice whose same-entity commands aren't serialized upstream is exposed.

**Confirmed 2026-06-20 (Phase 2A investigation):** only **async** DCB slices (`@@reventless.async`) are serialized — they route through `CommandTopicChannel_SQS_Async` (a FIFO queue) with `messageGroupId = safeGroupId(commandJson.id)`, and for DCB slice commands `commandJson.id` is the entity/partition id, so same-entity async creates can't run concurrently. The **default sync** slices route through `CommandTopicChannel_SQS_Sync`, a **standard (non-FIFO)** queue dispatched **inline** in the AppSync resolver Lambda — no per-entity serialization. So the create-race is **real on the default path**, and the `after=None` branch needs the code fix (Phase 2 option B / partition-tag `attribute_not_exists`), not just the FIFO guarantee.

**Fix direction**: at `after=None`, emit `attribute_not_exists(lastPosition)` as a conditional `Update` on the partition tag(s); keep non-partition single-tag reads as read-only `ConditionCheck` (`attribute_not_exists`); keep composite as-is. Add a red→green unit test (two concurrent `after=None` appends to the same partition — second must fail).

### Fix (shipped 2026-06-20 — Phase 2 of [dcb-consistency-hardening](../plans/dcb-consistency-hardening.md))

The partition-tag `attribute_not_exists` variant above was **rejected** because it reintroduces Issue 4: a slice reading only a *subset* of a partition's event types sees `after=None`, but `fence#<key>` already exists (created by a different event type), so it would false-conflict. Shipped **option B** instead — a **per-(eventType, partition value) create guard**:

- At `after=None` only, `buildConditionalTransactItems` emits one conditional `Update` per distinct `(event.eventType, partition tag value)`, on a sentinel `id="create#<eventType>#<key>:<value>", position="CREATE"`, gated on `attribute_not_exists(lastPosition)`. Two concurrent first-writers of the same entity collide on this guard → exactly one commits.
- Because the guard is **keyed by event type**, it never collides with a different type already on the partition — the subset-event-type slice gets its own guard and is not false-conflicted (sidesteps Issue 4). Verified by a dedicated integration scenario.
- `create#` is a distinct id prefix from event partition keys (`<key>:<value>`) and `fence#` sentinels, so event reads and fence checks never observe guards. Files: `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildCreateGuardUpdate` + the `after=None` branch of `buildConditionalTransactItems`). Tests: unit shape in `DcbEventLogStorage_DynamoDb_RuntimeTest.res`, behavioural (two concurrent first-writers → one wins; subset-type → no false conflict) in the Phase 1 integration suite.

Scope note: `appendUnconditional` (seeding/import/replay) deliberately does **not** write create guards — it is the no-OCC path. Async slices were already serialized upstream by the FIFO command topic (`messageGroupId = entity id`); the guard closes the hole for the **default sync** path, which has no upstream serialization.

---

## Issue 3 — Local backend ≠ AWS backend consistency semantics (test gap)

`DcbEventLogStorage_InMemory`/`_Sqlite` evaluate the append condition in-process with true DCB query semantics (`matchesQuery`, filtering on tags **and** event type, over the actual event list). AWS approximates this with per-tag-value fences. Consequences:

- Every fence-shape bug (Issue 1, and any future one) is invisible to GWT / local / in-memory E2E — which is exactly why the deployed bug never showed in tests.
- The two backends actively diverge on: `after=None` (local strict, AWS none — Issue 2), per-(tag,type) (AWS false-positives, local correct — Issue 4), and composite exact-match (Issue 5).

**Mitigation**: a real-DynamoDB (or LocalStack) integration test exercising the fence path — **shipped 2026-06-20** ([`dcb-dynamodb-atomic-append-integration-test`](../plans/done/dcb-dynamodb-atomic-append-integration-test.md), Phase 1 of the hardening roadmap). DynamoDB Local via Docker; the fence path now has behavioural coverage including the Issue 1 regression and OCC primitives.

---

## Issue 4 — Fences are per-tag-value, not per-(tag, event-type)

The fold computes `after` from *decoded* events only (events whose type isn't in the clause are dropped before the fold), but the fence is bumped by **every** event in that partition regardless of type. So in the `after=Some` case a slice reading type A on partition P conflicts with a concurrent writer of type B on the same P.

For same-entity lifecycles (`OrderPlaced`/`Shipped`/`Cancelled` on one `orderId`) this over-serialization is usually **desirable** (entity-level serialization is what you want). It only becomes a problem — false conflicts / extra retries — when two genuinely independent concerns share a partition-key value. Related: the `@dcbTag(~consistencyMode=#LookupOnly)` idea in the hot-tag plan would let authors opt a tag out of fencing entirely.

---

## Issue 5 — Composite (GSI) read requires an exact full-tag-set match

`tag_composite` is `compositeTagKey(`*all*` event tags)`, and a composite query builds its key from *its* tags. So a query `{A,B}` matches only events tagged **exactly** `{A,B}` — an event that also carries a `C` tag is silently missed by the read, while its per-tag fences still move. Any future change that adds a tag to a multi-tag event would quietly break composite-read slices. Works today only because `RecordProductDemand`'s event tags equal its query tags. Worth a build-time assertion or a doc warning on multi-tag events.

---

## Issue 6 — Single global `after` across a multi-clause OR query

`after` = the head position across **all** clauses/partitions, then compared per-tag. When clauses have very different head positions, a partition tag whose fence legitimately sits above another clause's max can false-conflict. Issue 1's fix neutralizes this for read-only (non-partition) tags via `ConditionCheck`, but partition tags in multi-clause queries still compare against the global head rather than a per-clause head. The principled form is a **per-tag `after`** (each fence checked against the head the read observed *for that tag's partition*). Lower priority now that the common case (PlaceOrder) is covered.

---

## Issue 7 — Position ordering ties; stringified-timestamp fragility

`generatePosition = ${ms}-${uuidv4}`. Same-millisecond writers get arbitrary lexical order, so `lastPosition <= :after` can occasionally false/miss under heavy concurrency (already noted in the historical doc, §"Position ordering breaks ties by UUID [PARTIAL]"). Also latent: positions are stringified millisecond timestamps, so lexical order == numeric order only while the digit count is stable (~until year 2286); a digit-count change would break ordering. Batch positions (`generatePositionForBatch`) pad the index to 3 digits — safe only because the 100-item `TransactWriteItems` cap keeps indices ≤ 99. Tracked: [`dcb-monotonic-position-generation`](../plans/Backlog/dcb-monotonic-position-generation.md).

---

## Issue 8 — Composite/scan reads are eventually consistent

Only single-tag base-table reads opted into strong consistency ([dcb-strong-consistency-single-tag-reads](../plans/done/dcb-strong-consistency-single-tag-reads.md)); composite (GSI) and scan reads stay eventually consistent — a fundamental DynamoDB constraint. Stale reads normally just cost a retry, but combined with Issue 2 (`after=None` with no check) the staleness can turn into a missed conflict rather than a retry.

---

## Issue 9 — `appendUnconditional` still bumps all event tags

The seeding/replay path ([`appendUnconditional`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)) still bumps **every** event tag (left unchanged by Issue 1's fix to preserve composite seed-visibility). This is inconsistent with the new partition-scope invariant: a multi-tag event seeded this way re-introduces cross-partition fence bumps. Seeding-only and low-risk (runtime order writes go through `appendConditional`), but a known inconsistency — revisit alongside a composite-fence design (option A) if ever adopted.

---

## Issue 10 — Hot-tag fence ceiling; retry exhaustion surfaces as `Conflict`

A single fence item caps at ~500 conditional transactions/sec for that tag value (DynamoDB ~1000 WCU/partition, 2 WCU/transaction item). Concurrent writers contend on the same fence; the slice's 3-retry loop ([`StateChangeSlice_Callback`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)) can bottom out under bursts and surface transient contention to the caller as a `Conflict`. Tracked: [`dcb-hot-tag-fence-contention`](../plans/Backlog/dcb-hot-tag-fence-contention.md) (fence sharding + selective bumping).

---

## Issue 11 — 100-item `TransactWriteItems` cap is a hard cliff

A command touching very many distinct tag values (e.g. an order with ~99+ products) exceeds the 100-item `TransactWriteItems` limit and is rejected with a clear error rather than chunked. Inherent to the all-in-one-transaction atomicity; acceptable, but a UX cliff worth documenting for high-cardinality commands.

---

## Issue 12 — Tagless scan read can choke on fence items (low-confidence)

`scanWithFilter` with no `eventTypes` returns **all** table items, including `fence#…` sentinels (which have no `event`/`data` attributes); `fromItem` would throw on them. The `eventTypes` filter normally excludes fences (they lack the `event` attribute), and `appendConditional` rejects tagless *conditions* — but a tagless *read* path exists. Needs confirmation of whether any slice can issue a tagless, type-less read; if so, fence items should be filtered out in the scan path.

---

## Performance analysis (consistency check)

Complements the historical perf assessment in [dcb-dynamodb-consistency-check.md](dcb-dynamodb-consistency-check.md) §"Performance assessment" / open-items table; this section is grounded in the current code and adds findings not tracked there.

### Cost of one consistency-checked command

`StateChangeSlice_Callback.handleSingleCommand` per command:

1. **Decision-model read** — for each query clause, a DynamoDB Query (single-tag → base table, strong-consistent; multi-tag → `tag_composite` GSI; tagless → Scan). `runFold` consumes the **entire** matching stream — there is no `Limit`, no projection, no cache — so this reads **every event matching the query**, full items, and `decode`s each (even ones whose type is then dropped).
2. **Transaction write** — one `TransactWriteItems` = event Puts + fence items. Every item (Put, Update, **and** ConditionCheck) consumes write capacity **doubled** because it's transactional. Plus GSI replication (below).
3. **On conflict, retry the whole cycle** (read + write) up to 3×.

So the consistency check's marginal cost over a plain append is dominated by **the read**, not the fences. The fence transaction adds bounded WCU (∝ distinct tag count) and contention; the read is the unbounded term.

### Where the cost goes (ranked)

1. **Unbounded decision-model read — O(events matching the query), every command, strong-consistent, full-item, uncached.** This is the headline cost. For a tag value that accumulates many events, RCU grows linearly with history and is paid on *every* command. Strong consistency doubles it again. (PlaceOrder itself is cheap here — its `productId` partitions hold only `CatalogProductSynced`, its `orderId` partition only this order — but any slice reading a high-cardinality tag pays.)
2. **GSI write amplification — and several GSIs are unused.** The table provisions one `tag_<key>` GSI **per tagged field** plus `tag_composite`, all `projectionType: ALL` ([`DcbEventLogStorage_DynamoDb.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res), indexes from [`Dcb_Builder.res`](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res)). An event with K tags replicates its **full item** to each of its K `tag_<key>` GSIs + `tag_composite` + base ≈ up to **K+2 full-size writes per event**. But the single-tag read path uses the **base table** (`queryByPartitionKeyStream`), not the per-tag GSIs — and `queryBySingleTag`/`queryBySingleTagStream` (the only callers of `tag_<key>`) have **zero callers**. So the per-tag `tag_<key>` GSIs are currently **write-amplification with no read benefit**.
3. **`TransactWriteItems` 2× WCU per item.** Inherent to transactional atomicity. Item count = events + (partition-tag Updates) + (non-partition ConditionChecks) + (composite Updates). Bounded by distinct tag count; capped at 100 (Issue 11).
4. **Strong-consistency reads = 2× RCU.** Single-tag decision reads always set `consistentRead: true`. This is a *latency/retry* optimization, not a correctness requirement — a stale read just triggers a fence-retry. So it's a tunable 2× read cost, currently always-on.
5. **Retry amplification.** A conflict re-runs read + write; 3 retries ⇒ up to 4× work. Note Issue 1 (now fixed) made this *guaranteed* 4× wasted read+write on every repeat order before surfacing a failure — so the fence-scope fix is also a real perf win on that path.
6. **Per-clause fan-out + decode CPU.** A command with P tags issues P+1 concurrent Queries (one fiber + `Queue(1)` each for the k-way merge) and `decode`s every event read, including type-mismatched ones dropped afterward. Minor vs RCU, but scales with history and tag count.

### Cost considerations ($)

Absolute $ depends on region and on-demand vs provisioned, but the **billing ratios are exact and durable**, so optimize against those. (On-demand, eu-west-1, approx: ~$1.4/M write request units, ~$0.28/M read request units, ~$0.28/GB-month storage — treat as order-of-magnitude.)

Billing-model multipliers that the consistency check triggers:

- **Transactional write = 2× a standard write.** Every fence item *and* every event Put rides `TransactWriteItems`, so the whole append is billed at 2×. Writes are metered per **1 KB** (rounded up).
- **Strongly consistent read = 2× an eventually consistent read.** The single-tag decision read always sets `consistentRead: true`. Reads are metered per **4 KB**.
- **Each `ALL`-projection GSI = +1 full-item write and +1× item storage**, for every item that carries that GSI's key. GSI propagation is billed at the standard (non-transactional) write rate.
- **Storage is append-only and never shrinks** — the event log grows forever, and every `ALL`-projection GSI multiplies the stored bytes of the whole history.
- **Retries multiply the entire command cost** by the attempt count.

**Worked example — one `PlaceOrder` (1 product, `OrderPlaced` tagged `orderId`+`customerId`+`productId`), assuming ~1 KB events and the current 3 per-tag GSIs + composite:**

| Component | Write request units (≈) |
|---|---|
| `OrderPlaced` Put — base table, transactional | 2 |
| → GSI propagation: `tag_orderId`, `tag_customerId`, `tag_productId`, `tag_composite` (ALL, ~1 KB each) | 4 |
| `fence#orderId` conditional Update (transactional, <1 KB) | 2 |
| `fence#productId` ConditionCheck (transactional, <1 KB) | 2 |
| **Total write** | **≈ 10 WRU** |

Plus the decision read: strong-consistent, ∝ events in the read partitions × item size (small for PlaceOrder; large for any hot-tag slice).

Where the money actually goes, and the biggest $ levers:

1. **Unused per-tag GSIs are ~30–60% of every write *and* a permanent storage multiplier.** In the example, 3 of the 4 GSI propagation units (`tag_orderId`/`tag_customerId`/`tag_productId`) back GSIs the read path never queries → ~3 of ~10 WRU per command are pure waste, and the same GSIs triple-store the entire event history forever (`ALL` projection). Removing them is the **single biggest durable $ win** — it hits every write and all retained storage. (Verify no out-of-adapter consumer first; GSI change needs a table migration — wipe+recreate is fine in alpha.)
2. **Decision-read RCU grows with history** for warm/hot tags and is paid per command; the decision-model cache turns O(history) read cost into O(delta). Scales with command rate × history length.
3. **Strong consistency doubles read RCU** on the common path; making it opt-in (rely on fence-retry for the rare stale read) halves it for slices that don't need it.
4. **Fence WCU** ∝ distinct tag count × 2 (transactional). Selective bumping / `#LookupOnly` tags trims it; Issue 1's fix already removed the secondary-tag bumps (e.g. `customerId`).
5. **Lambda compute** — the fold `decode`s every event read (including type-mismatched ones), so Lambda-ms cost also rises with history; the cache (#2) cuts this too.

Rule of thumb: **write/storage cost is dominated by GSI fan-out (lever #1); read cost is dominated by uncached full-history reads (lever #2).** Both are no-contract-change fixes.

### What the recent fix already changed (WCU-neutral-to-cheaper)

Issue 1's fix swapped non-partition query tags from conditional `Update` → `ConditionCheck` (same item count, ~same WCU) and **dropped** the secondary-tag unconditional bumps (e.g. `customerId`) → marginally fewer items. Its big win is eliminating the guaranteed 4× retry-storm-then-fail on the false-conflict path.

### Improvements — could / should

**Should (correctness-adjacent or clear cost win):**

- **P1 — Decision-model cache / snapshots.** Cache folded state keyed by `(query, headPosition)`; next command reads only events *after* the cached head → O(history) becomes O(delta). Biggest lever for warm/hot entities. Already filed: [`dcb-decision-model-projection-cache`](../plans/Backlog/dcb-decision-model-projection-cache.md). Warm-Lambda reuse makes even an in-process LRU worthwhile.
- **P1 — Drop or down-project the unused per-tag GSIs.** Verify no out-of-adapter consumer (EventCollector, admin, debugging) reads `tag_<key>`; if none, remove them or switch to `KEYS_ONLY`. Removes up to K full-item GSI writes per event. Needs a table migration (GSI changes), so batch with other schema work; safe to wipe+recreate in alpha.

**Could (workload-dependent, tunable):**

- **Bound existence/availability reads.** Slices that only need "does ≥1 matching event exist" (PlaceOrder's availability check) don't need to stream the whole partition — a `Limit:1` Query (or a projection of just the key) per such clause. Would require the slice/framework to express "existence" vs "fold". High ROI where a read tag has many events.
- **`ProjectionExpression` on decision reads.** RCU is charged by item size; the fold often needs only a few fields. Projecting just the decoded payload + `position` cuts RCU on large events (those with big payloads or many flattened meta/tag attributes).
- **Make strong-consistency opt-in per slice.** Default eventually-consistent + rely on the fence-retry for the rare stale read; reserve `consistentRead` for high-contention slices. Halves read RCU on the common path. (Inverse of the [strong-consistency plan](../plans/done/dcb-strong-consistency-single-tag-reads.md)'s blanket choice.)
- **Selective fence bumping (`#LookupOnly` tags)** — [`dcb-hot-tag-fence-contention`](../plans/Backlog/dcb-hot-tag-fence-contention.md) §2. Synergistic with Issue 1's fix (both reduce fence churn on read-only tags).
- **Fence sharding** — [`dcb-hot-tag-fence-contention`](../plans/Backlog/dcb-hot-tag-fence-contention.md) §1; profile-gated, only if a fence is actually hot (lifts the ~500 transactions/sec/fence ceiling at +N× WCU).

**Net:** the cheapest high-impact wins are **(a) the decision-model cache** and **(b) removing the unused per-tag GSIs** — one cuts read RCU, the other cuts write RCU, and neither changes the slice contract. Everything else is workload-gated tuning.

## Recommended next steps

1. ~~**Issue 2** — close the `after=None` create-race.~~ **Done 2026-06-20** — per-type create guard (see Issue 2 § Fix).
2. **Issue 3** — stand up the DynamoDB integration test; it's the only thing that exercises the fence path and gates trust in every other fix here.
3. **Issues 4–6** — guard/assert and document; revisit a per-tag `after` and composite-fence design (option A) only if a real slice needs it.
4. **Performance** — the two no-contract-change wins from §Performance analysis: the decision-model cache (read RCU) and removing the unused per-tag GSIs (write RCU). Verify GSI consumers first; batch the GSI change with a table migration.
5. Operational items (7, 8, 10, 11) are already tracked in their own backlog plans.
