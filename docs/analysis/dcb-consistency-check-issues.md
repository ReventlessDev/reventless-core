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
| 13 | No single-tag **cross-partition** (secondary-tag) read | Capability gap | **Implemented 2026-06-21** ([Phase 7 plan](../plans/done/dcb-phase7-cross-partition-reads.md); source, mjs/CI pending ppx republish) |
| 14 | Query clauses carry the full consumed-type list (incl. types that can't carry the tag) | Low–Med | Open — drop vacuous (type,tag) combos; residual over-match = Issue 13 |

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

Scope note: `appendUnconditional` (seeding/import/replay) deliberately does **not** write create guards — it is the no-OCC path (**OCC = optimistic concurrency control**: read the decision model, decide, then append *conditionally* — only if nothing has changed since the read — rather than holding a lock; the per-tag fences are exactly this conditional check). Async slices were already serialized upstream by the FIFO command topic (`messageGroupId = entity id`); the guard closes the hole for the **default sync** path, which has no upstream serialization.

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

## Issue 5 — Composite (GSI) read requires an exact full-tag-set match — **FIXED (2026-06-20, build-time warning)**

`tag_composite` is `compositeTagKey(`*all*` event tags)`, and a composite query builds its key from *its* tags. So a query `{A,B}` matches only events tagged **exactly** `{A,B}` — an event that also carries a `C` tag is silently missed by the read, while its per-tag fences still move. Any future change that adds a tag to a multi-tag event would quietly break composite-read slices. Works today only because `RecordProductDemand`'s event tags equal its query tags. Worth a build-time assertion or a doc warning on multi-tag events.

**Fix (shipped 2026-06-20).** Added `DcbValidation.validateCompositeReads`, run in `Dcb_Builder` against the producer tag-key map (the same `tagKeysByEventType` built for Issue 14). For each slice whose command builds a composite read (all-scalar, ≥2 tags — array commands read per-element OR, so they're skipped), it warns when a consumed type's *produced* tag set is a **strict superset** of the query tags — exactly the silent-miss case (the composite read finds only exact-match events). Non-fatal `log.warn` (today's slices are aligned, so nothing fires; it catches a tag added to a multi-tag event later). Tests: 5 in `DcbValidationTest.res` (superset → warn, exact-match → no warn, single-tag/array/empty → no warn). Core suite green (428). The strict-subset direction is handled by Issue 14 narrowing (the type is dropped from the clause, not read).

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

## Issue 12 — Tagless scan read can choke on fence items (low-confidence) — **FIXED (2026-06-20)**

`scanWithFilter` with no `eventTypes` returns **all** table items, including `fence#…` sentinels (which have no `event`/`data` attributes); `fromItem` would throw on them. The `eventTypes` filter normally excludes fences (they lack the `event` attribute), and `appendConditional` rejects tagless *conditions* — but a tagless *read* path exists. Needs confirmation of whether any slice can issue a tagless, type-less read; if so, fence items should be filtered out in the scan path.

**Fix (shipped 2026-06-20).** Confirmed the read path is reachable (a clause with no tags falls back to scan; with no `eventTypes` the scan is unfiltered) though not exercised by current slices — DCB commands always carry the partition entity id as a tag, so scans route to partition/composite reads in practice; hence "low-confidence". Hardened defensively anyway: the filter-building was extracted into a pure `buildScanFilter` (shared by `scanWithFilter` and `scanWithFilterStream`) that **always** asserts `attribute_exists(event)`, so `fence#…` sentinels are never returned regardless of the event-type filter. This also fixes a latent degenerate case — an empty `eventTypes` list previously emitted a broken `()` group; it now yields just the fence guard. Tests: 3 in `DcbEventLogStorage_DynamoDb_RuntimeTest.res` (tagless guard, empty-list guard, type-filter AND-ed after the guard); AWS suite green (126).

---

## Issue 13 — No single-tag cross-partition (secondary-tag) read (capability gap)

### The limitation

After [primary-tag partitioning](../plans/done/dcb-eventlog-primary-tag-partitioning.md), `executeQueryItemStream` maps a single-tag clause to a **base-table partition lookup**:

```
| Some([tag]) => queryByPartitionKeyStream(table, `${tag.key}:${tag.value}`, …)
```

That returns only events whose **primary/partition** tag is `tag` (the events physically stored under `id="<key>:<value>"`). An event carrying `tag` as a **secondary** tag lives in a *different* partition (keyed by *its* primary tag) and is **not** returned. So a single-tag clause cannot read "every event tagged `T`" — only "every event *partitioned by* `T`". The per-tag `tag_<key>` GSIs that could answer the cross-partition form were disconnected by the partitioning change (`queryBySingleTag`/`queryBySingleTagStream` now have zero callers — see Perf lever #1 / [`dcb-consistency-hardening`](../plans/dcb-consistency-hardening.md) Phase 3) and the framework exposes no other path to it.

This is currently *intentional*: single-tag reads being partition-scoped is exactly what keeps **read-scope = fence-scope** (Issue 1). But it blocks a class of DCB decisions that is not exotic — it's the **canonical** DCB shape.

### Worked example — course subscription (why it's needed)

The textbook DCB example. A `StudentSubscribed` event carries two tags and enforces two invariants on subscribe. The event can be partitioned by only **one** tag — say `courseId` — so the *other* tag (`studentId`) must be declared cross-partition to be readable across all the `courseId:*` partitions it lives in.

The annotation lives on the **command** and the produced **`event`** (consistently — like `@partitionTag`), never on `consumedEvent` (which carries no tag annotations). The command's tags build the read query; the produced event's tags drive partitioning, GSI indexing, and fence scope:

```rescript
// command — its tagged fields build the read query
@schema type command =
  | SubscribeStudent({
      @partitionTag courseId: string,      // → clause [courseId] — partition read
      @crossPartition studentId: string,   // → clause [studentId] — cross-partition read
    })

// produced event — partitioning, GSI indexing, fence scope
@schema type event =
  | StudentSubscribed({
      @partitionTag courseId: string,
      @crossPartition studentId: string,
    })

// SubscribeStudent(S1, C1) builds its decision model from two single-tag clauses
// (each tag fans out to its own clause — not AND'd into one composite pair):
//   (a) course C1 is not full          → read StudentSubscribed where courseId  = C1
//   (b) student S1 is not over-enrolled → read StudentSubscribed where studentId = S1
```

How each clause resolves, and why the annotation is load-bearing:

- **(a) read by `courseId:C1`** — `courseId` is the partition tag, so this is a base-table partition query → returns all of the course's subscriptions. ✓ (No scope annotation needed: a tag read by its *own* partition is already partition-scoped.)
- **(b) read by `studentId:S1`** — `studentId` is declared `@crossPartition`, so the read routes to the `tag_studentId` GSI, which indexes the tag across *every* `courseId` partition → returns all of the student's subscriptions. ✓
- **Without the annotation** `studentId` defaults to `PartitionScoped`: read (b) hits the **empty** `studentId:S1` base-table partition (these events physically live under `courseId:*`), sees **zero** subscriptions, and the over-enrolment check silently always passes. ✗ The annotation is exactly what turns (b) from a silent no-op into a real invariant.
- **Fence (the consistency half):** because `studentId` is cross-partition, *every* `StudentSubscribed` bumps `fence#studentId:S1` (not just events partitioned by `studentId`, of which there are none); `courseId` is the partition tag, so every write already bumps `fence#courseId:C1`. So a concurrent subscribe for the same student **or** the same course conflicts at append — read-scope = fence-scope on **both** axes. (See "Fence scope must match read scope" below for why this must follow the annotation.)

Flipping the partition to `studentId` just swaps which tag needs the annotation. Any event that ties **two entities** in an M:N relationship (subscription, reservation, assignment, membership, transfer) has this shape: the decision must read by *both* tags, but the event can be partitioned by only one — so **one of the two reads is inherently a cross-partition secondary-tag read.** Composite (`tag_composite`) does not help: `{studentId:S1, courseId:C1}` matches the *single* exact pair, not "all of student S1's subscriptions" (and exact-match only — Issue 5).

A read model / projection keyed by `studentId` is eventually consistent and lives outside the append transaction, so it cannot back an OCC decision model — it's a query-side convenience, not a substitute.

### Why the scope must be declared, not inferred

The natural objection: a secondary-tag read *is* inherently cross-partition, and the framework can already tell that a tag is not the partition tag of a given event type — so why not auto-promote any secondary-tag read to a cross-partition one instead of requiring `@crossPartition`?

Because detecting "this tag isn't the partition tag" is not the same as knowing the slice *wants* cross-partition semantics — and guessing wrong is expensive and silent. The counterexample already lives in the example plugins: **`PlaceOrder`**.

- `OrderPlaced` is partitioned by `orderId` and carries `productId` as a *secondary* tag; `CatalogProductSynced` is partitioned by `productId`.
- `PlaceOrder` has a clause that reads by `productId` — to check availability from `CatalogProductSynced`, for which `productId` **is** the partition tag, so a partition-scoped read is exactly right.
- `OrderPlaced` *also* carries `productId`, so "tag ≠ partition tag ⇒ cross-partition" would auto-promote it. But `PlaceOrder` does **not** want to fold in every other order for that product — `PlaceOrder_Behavior` deliberately ignores sibling orders; it *tolerates* the over-read, it doesn't want it.

So the same tag key is "the partition tag I want" for one consumed type and "a secondary tag I'm ignoring" for another. From types and tags alone there is no way to distinguish *"I want this cross-partition fold"* (an order-cap slice) from *"I tolerate the over-read"* (`PlaceOrder`). That is an **intent**, not a fact the framework is missing.

And the reads are the cheap half. The decisive reason is the **fence**, because read-scope and fence-scope must match (the Issue 1 fix):

- Auto-promoting `productId` to cross-partition would force **every `OrderPlaced` append to bump `fence#productId`**. Every order for a popular product would then serialize on a single fence (≈ the 500-txn/s/fence ceiling, Issue 10) and pay extra transactional WCU — a catastrophic, silent write bottleneck on exactly the hottest entities, imposed on a slice that never asked for it.
- Scope cannot be per-reader either: the fence is bumped by **writers**, not readers. If one slice wants `productId` cross-partition, *every* `productId` writer must broaden its fence — which changes contention for `PlaceOrder` too. So scope is necessarily a **global property of the tag key** (this is why it "must agree across every event type that carries it"), and declaring it opts the whole system's writers into the hotter fence.

Hence the default is `PartitionScoped` — cheap, narrow fence, secure-by-default — and a tag opts **in** to `CrossPartition`, recording the intent *and* accepting the global fence-contention cost. Inverting the default (secondary ⇒ cross-partition, opt *out*) is the wrong cut: it would make the high-contention path the default and silently degrade existing slices like `PlaceOrder`. The annotation doesn't tell the framework something it can't compute; it records a cost trade-off the framework must not guess.

### Solution sketch

The capability and its consistency story must move together. Three coupled parts:

**1. Per-tag scope declaration.** Let a tag opt into cross-partition semantics at the schema level via a dedicated `@crossPartition` field annotation (mirroring `@partitionTag` — no arguments; the PPX emits a `DcbTag.crossPartition` matcher). Default stays `PartitionScoped` (today's behaviour, for tags carrying no such annotation). The scope is a property of the *tag key* and must agree across every event type that carries it, or the fence scope below is ambiguous.

**2. Read routing.** A single-tag clause on a `CrossPartition` tag routes to the per-tag `tag_<key>` GSI (which indexes the tag across *all* partitions) instead of the base-table partition query. This **requires the GSI to exist** — directly in tension with Phase 3's full removal, and the reason that phase is on hold. Projection choice is a cost knob: `ALL` returns full items in one query (cheaper reads, costlier writes/storage); `KEYS_ONLY` halves storage/write amplification but needs a follow-up `BatchGetItem` to fold state.

**3. Fence scope must match read scope.** This is the subtle part. Issue 1's fix made `fence#T` be bumped **only** by events *partitioned by* `T`. If a slice now reads `T` cross-partition, it sees events for which `fence#T` is *not* maintained → OCC would miss a concurrent secondary-`T` writer (no conflict raised). So for a `CrossPartition` tag the fence must again be bumped by **every** event carrying it (primary *or* secondary) — the broad pre-Issue-1 behaviour, but now applied *only* to tags declared cross-partition. Partition-scoped tags keep the narrow Issue 1 rule. In short: **fence-bump scope is driven by the same per-tag scope flag as read routing**, so read-scope = fence-scope is preserved per tag rather than globally.

**Consistency note.** GSI reads are eventually consistent (a fundamental DynamoDB constraint — Issue 8), so a cross-partition decision read can be stale. That is acceptable: the strongly-consistent fence check at append time catches any conflict the stale read missed, costing at most a retry — identical to how composite reads behave today.

**Cost / risk.** A `CrossPartition` tag is bumped by every carrier, so its fence is hotter (Issue 10) — pairs naturally with fence sharding. It also reintroduces the per-(tag, event-type) over-serialization of Issue 4 on that tag (every carrier bumps it), which for an M:N tag is usually the *desired* serialization. The migration cost is a GSI/table change, so it should be sequenced with (or instead of) Phase 3 rather than after a removal.

**Bottom line:** the cleanest realisation re-uses precisely the `tag_<key>` GSI infrastructure Phase 3 would otherwise drop. If cross-partition secondary-tag reads are on the roadmap, Phase 3 should down-project to `KEYS_ONLY` (or keep `ALL`) rather than remove — and the read/fence routing above is the work that turns the retained index into a real capability.

### Performance & cost

Cross-partition reads are not just *another* tag read — they change the cost shape, because an M:N event pays the cost on **both** of its tags and the read is unbounded in the entity's *degree* (how many partners it relates to). Ranked, against the same billing multipliers as the §Performance-analysis section below (transactional write = 2×, strong read = 2×, `ALL` GSI = +1 full-item write + 1× storage per carrier, storage never shrinks):

1. **Unbounded cross-partition decision read — the headline cost, now paid twice.** A `CrossPartition` clause folds *every* event with that tag value across all partitions: for course subscription, "all of student S1's subscriptions" is O(courses S1 is in) and "all of course C1's subscriptions" is O(students in C1). A single `SubscribeStudent` pays **both** (it reads by `studentId` *and* `courseId`), each O(degree), each per command, each **eventually consistent** (GSI — cannot opt into strong reads, so cost-lever #3 doesn't apply to these clauses) and **uncached**. For a hot entity (a 300-student course) this read alone dwarfs the write. This is the same "unbounded read" term as the partition-scoped case, but one M:N command incurs it on two high-cardinality axes instead of one small partition.
2. **GSI storage multiplier — now a *needed* GSI, so the projection choice is the real $ knob.** The cross-partition tag's `tag_<key>` GSI must exist; with `ALL` it re-stores the **entire event history forever** (append-only, never shrinks) for every carrier of that tag. This is the same multiplier as Perf lever #1 — except here it buys a capability rather than being waste, so the lever becomes `ALL` vs `KEYS_ONLY` rather than keep-vs-drop. `KEYS_ONLY` stores only `(id, position, tag key)` — typically a small fraction of a full event — cutting the durable storage bill and the large-item write replication, at the price of a second read phase (below).
3. **Cross-partition fencing — more WCU and a hotter fence.** Reverting Issue 1's narrowing for a `CrossPartition` tag means **every** carrier bumps `fence#<tag>` (transactional, 2× WCU), not just events partitioned by it. An M:N write therefore drives **two** fences (e.g. `fence#studentId:S1` *and* `fence#courseId:C1`), each contended by *all* writers touching that student or that course → each is a candidate for the ~500-transactions/sec/fence ceiling (Issue 10). Popular entities (a trending course) make their fence a write bottleneck; pairs naturally with fence **sharding** (which lifts the ceiling at +N× WCU). It also re-introduces Issue 4's per-(tag, event-type) over-serialization on that tag — but for an M:N invariant that serialization is usually *desired* (it's what the invariant needs).
4. **Transaction size.** Each `CrossPartition` tag adds one fence op to the append's `TransactWriteItems`; an M:N event adds two, pushing sooner against the 100-item cap (Issue 11) for high-tag-count commands.
5. **`ALL` vs `KEYS_ONLY` read/write trade-off.** `ALL`: one GSI Query returns full items → cheapest *reads* (single eventually-consistent pass at 0.5 RCU/4 KB) but the costliest *writes/storage* (full-item replication of all history). `KEYS_ONLY`: cheap writes/storage, but each decision read is GSI-Query-for-keys **+** `BatchGetItem` against the base table (extra round trips and RCU). The crossover is set by the read:write ratio and event size — `KEYS_ONLY` wins for write-heavy / large-event tags, `ALL` for read-heavy / small-event tags.

**Worked example — one `SubscribeStudent` (`StudentSubscribed` tagged `studentId`+`courseId`, both `CrossPartition`, ~1 KB event), with `ALL` GSIs:**

| Component | Units (≈) |
|---|---|
| `StudentSubscribed` base put — transactional | 2 WRU |
| → GSI propagation: `tag_studentId`, `tag_courseId` (`ALL`, ~1 KB each) | 2 WRU |
| `fence#studentId:S1` + `fence#courseId:C1` conditional Updates (transactional, <1 KB) | 4 WRU |
| **Total write** | **≈ 8 WRU** |
| Decision read — fold S1's subscriptions (deg ≈ 5) + C1's subscriptions (deg ≈ 300), eventually consistent, ~1 KB items | ≈ **150 RRU** |

The write is bounded and modest; the **read dominates and scales with course size**. (Per-write WRU is similar under `KEYS_ONLY` for ~1 KB events — the GSI item is still <1 KB → 1 WRU — so `KEYS_ONLY`'s win here is **storage** and large-event writes, not small-event WRU. The read, conversely, gets a `BatchGetItem` tax under `KEYS_ONLY`.)

**Mitigations specific to Issue 13:**

- **Bounded existence/count reads for capacity invariants.** Most M:N rules are thresholds ("≤ 10 courses", "≤ 30 students"). The decision needs a *count*, not the full fold — a `Limit: N+1` Query ("is there an (N+1)-th?") caps the read at N+1 keys regardless of true degree. Combined with `KEYS_ONLY`, a capacity check becomes O(threshold), not O(degree) — the single biggest read-cost lever for this pattern, and it turns item #1 from unbounded into bounded.
- **Decision-model cache (Phase 4) has outsized value here.** Because the read is O(degree) and grows, caching the fold at `(query, headPosition)` and reading only the delta is a larger win than for partition-scoped slices. Strong synergy.
- **`KEYS_ONLY` projection** for the durable storage bill (item #2), accepting the BatchGet read tax — or skip it where the bounded count read (above) already removes the need for full items.
- **Fence sharding** (Issue 10) for the hot M:N fences (item #3), profile-gated.

**Net:** the *capability* cost is dominated by an unbounded, twice-paid, eventually-consistent, uncached read — so it is mostly a **read-cost** problem, and the highest-leverage mitigations are framework-level (bounded count reads + the decision-model cache), not infra. The infra knob is `ALL`-vs-`KEYS_ONLY`, which trades storage/write against read round-trips. None of this changes the slice contract — but it does mean a naive cross-partition slice on a high-degree entity can be expensive, and should be steered toward count-bounded reads.

---

## Issue 14 — Query clauses carry the full consumed-type list (tags not paired to their event types)

**Status: FIXED (2026-06-20).** `buildQueryFromCommand` now takes an optional `~tagKeysByEventType` map (event type → its *produced* tag-key set), threaded from `Dcb_Builder` — which knows every producer's `eventSchema` — down through `StateChangeSlice.make` → `_Callback`. Each clause drops event types whose produced tag set cannot carry the clause's tag(s) (`narrowEventTypesForTags`); the map is built from the producer schemas (`DcbTag.extractTagKeysByEventType` + `mergeTagKeysByEventType`), never from a consumer's `consumedEventSchema`. Pure dead-clause removal — vacuous clauses match nothing, so results are unchanged; `OrderPlaced` is **retained** under a `productId` clause (legitimate secondary-tag carrier = Issue 13, not narrowed away). Tests: 4 in `DcbTagTest.res` (including the `(CatalogProductSynced, orderId)` drop + `OrderPlaced`-under-`productId` retention); full core suite green (423). Internals doc Stage 1 example updated. The reference material below is retained for context.

### Symptom

`DcbTag.buildQueryFromCommand` attaches the slice's **entire** consumed-event-type list to **every** clause it builds — it never pairs a tag with the specific event types that actually carry it ([`DcbTag.res` `buildQueryFromCommand`](../../reventless/reventless-spec/src/components/DcbTag.res)). So `PlaceOrder` (consumed `OrderPlaced({orderId})` | `CatalogProductSynced({productId})`) produces:

```
[ { eventTypes: [OrderPlaced, CatalogProductSynced], tags: [orderId:ord-1]   },
  { eventTypes: [OrderPlaced, CatalogProductSynced], tags: [productId:prod-1] },
  { eventTypes: [OrderPlaced, CatalogProductSynced], tags: [productId:prod-2] } ]
```

The first clause asks for a `CatalogProductSynced` tagged `orderId` — an event that by construction never carries an `orderId` tag.

### Mechanism

A clause matches an event when *its type is in `eventTypes`* **AND** *the event carries all the clause's tags* (literally `event_type IN (…) AND EXISTS(tag…)` in the local backend, [`DcbEventLogStorage_Sqlite.res:93-115`](../../reventless/reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_Sqlite.res#L93)). Two consequences fall out of the over-broad type list:

1. **Vacuous combinations (harmless).** `CatalogProductSynced` never carries `orderId`, so the `orderId` clause can only ever match `OrderPlaced` — the `CatalogProductSynced` entry is dead weight, never producing wrong results.
2. **Active over-match (has teeth).** The symmetric case is not vacuous: the `productId` clauses also list `OrderPlaced`, and `OrderPlaced` **does** carry `productId` as a secondary tag. So on a backend that evaluates the query literally, a `productId` clause also returns *sibling orders'* `OrderPlaced` events. `PlaceOrder_Behavior` documents and defends against exactly this (its `placedOrderIds` tracks every returned `OrderPlaced` so `decide` can ask about *this* order specifically).

### Backend divergence

This is where it bites (cf. Issue 3): the two backends evaluate the same query differently.

- **Local (in-memory / SQLite)** — evaluates the clause literally, so the `productId` clauses **do** return sibling `OrderPlaced` events.
- **DynamoDB** — a single-tag clause is a base-table *partition* read on `id="productId:prod-1"`; `OrderPlaced` lives in `orderId` partitions, so it is **never** returned, and `eventTypes` is ignored entirely for tag reads.

Same query, different result sets — masked only because the behaviour is written to tolerate the larger (local) set. So this is **not a correctness bug** (decisions come out right: vacuous clauses match nothing, the live over-match is defended in the behaviour and partition-scoped away on DynamoDB), but it is a real imprecision: it over-specifies the query, leans on tag-matching + behaviour defensiveness to stay correct, and widens the local/AWS gap. Adjacent to Issue 4 (per-tag vs per-(tag, event-type)) and the architecture doc's "query covers the full event schema" open item.

### Solution sketch — drop only the vacuous combinations; the rest is Issue 13

A first instinct is to narrow each clause to the types the *decision* needs — restricting clause `K` to consumed types whose **consumed-schema variant** declares a field tagged `K`. **This is unsound.** Omitting a tag from a consumed variant states what `evolve` needs as *data*, not which tags the slice queries by. A slice can legitimately read a type by a tag without ever touching that tag's value in the fold — e.g. "≤ 5 orders per product" counts `OrderPlaced` per `productId` with `evolve: | OrderPlaced(_) => count + 1`, so its consumed `OrderPlaced` declares no `productId` even though the `productId` clause **must** read `OrderPlaced` to count it. Consumed-field narrowing would silently drop that read. (Credit: this hole was caught in review.)

The sound, minimal fix drops only the **vacuous** combinations — a (type, tag) pairing where the type *cannot* carry the tag. Include a consumed type in clause `K` iff that type's **full produced tag set** — looked up in the shared event-log event schema, which the framework already knows — contains `K`:

```
[ { eventTypes: [OrderPlaced],                      tags: [orderId:ord-1]   },
  { eventTypes: [OrderPlaced, CatalogProductSynced], tags: [productId:prod-1] },
  { eventTypes: [OrderPlaced, CatalogProductSynced], tags: [productId:prod-2] } ]
```

Clause 1 loses `CatalogProductSynced` (it can never carry `orderId`), but clause 2 **keeps** `OrderPlaced` — the stored `OrderPlaced` does carry `productId`. This removes pure noise without ever dropping a read a slice might want; since vacuous clauses match nothing, results cannot change.

**What this does and doesn't resolve.** It eliminates the vacuous combinations (safe, unambiguous). It does **not** eliminate the *active* over-match: clause 2 still asks to read `OrderPlaced` by `productId`. But that residual is not an imprecision to be narrowed away — it is a **legitimate cross-partition secondary-tag read**, i.e. exactly Issue 13. Once the vacuous combinations are gone, every remaining (type, tag) where the type carries the tag as a *secondary* is a cross-partition read request, and the local/AWS divergence on it (local returns sibling `OrderPlaced`; DynamoDB partition-scoping does not) is the Issue 13 gap — to be solved there (serve it via the per-tag GSI + cross-partition fencing), not by contorting query construction.

Until Issue 13 lands, a slice that does **not** want those cross-partition reads — like `PlaceOrder`, which only checks availability — must keep tolerating the over-read in its behaviour; `PlaceOrder_Behavior` already does (its `placedOrderIds` ignores sibling orders). That tolerance is a behaviour responsibility, not a query bug. There is no way, from types and tags alone, to tell "I want this cross-partition read" (the order-cap slice) from "I tolerate it" (`PlaceOrder`) — distinguishing them needs the per-tag scope flag of Issue 13.

**Risk**: low. Dropping vacuous clauses cannot change results. The builder needs each consumed type's full produced tag set (today `buildQueryFromCommand` gets only the consumed type *names* + the command's tags), so the shared event schema must be threaded in. Red→green test: assert no built clause lists a type whose produced tag set lacks the clause's tag (e.g. no `CatalogProductSynced` under an `orderId` clause), and that `OrderPlaced` is **retained** under a `productId` clause.

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

- **P1 — Decision-model cache / snapshots.** Cache folded state keyed by `(query, headPosition)`; next command reads only events *after* the cached head → O(history) becomes O(delta). Biggest lever for warm/hot entities. Already filed: [`dcb-decision-model-projection-cache`](../plans/dcb-decision-model-projection-cache.md). Warm-Lambda reuse makes even an in-process LRU worthwhile.
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
