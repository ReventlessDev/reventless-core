# Plan: DCB Consistency-Check Hardening (roadmap)

**Status**: Proposed — derived from analysis [dcb-consistency-check-issues.md](../analysis/dcb-consistency-check-issues.md) (2026-06-20)
**Nature**: umbrella roadmap. Sequences the open correctness, cost, and robustness items from the analysis. Net-new work is detailed inline; items already covered by a focused plan are referenced, not duplicated.

## Phasing rationale

Order = correctness → verification harness → durable cost wins → robustness guards → profile-gated tuning. Verification (Phase 1) comes early because nothing else here can be *trusted* without a real-DynamoDB test of the fence path — local backends don't use fences, so unit tests only assert transaction *shape*, not DynamoDB *behaviour*.

| Phase | Item | Analysis ref | Class | New work? | Existing plan |
|---|---|---|---|---|---|
| 0 | Fence-scope = read-scope | Issue 1 | Correctness | shipped | [dcb-fence-scope-alignment](dcb-fence-scope-alignment.md) |
| 1 | DynamoDB integration test | Issue 3 | Verification | **done** | [dcb-dynamodb-atomic-append-integration-test](done/dcb-dynamodb-atomic-append-integration-test.md) |
| 2 | `after=None` create-race | Issue 2 | Correctness | **yes** | — (detailed below) |
| 3 | Drop unused per-tag GSIs | Perf/cost lever #1 | Cost | **yes** | — (detailed below) |
| 4 | Decision-model cache | Perf/cost lever #2 | Cost | **core done** | [dcb-decision-model-projection-cache](dcb-decision-model-projection-cache.md) |
| 5 | Robustness guards | Issues 4, 5, 6, 9, 12 | Robustness | **yes** | — (detailed below) |
| 5 | Drop vacuous query-clause type combos | Issue 14 | Cleanup | **done** | — (Phase 5 below) |
| 5 | Opt-in strong reads | Perf/cost lever #3 | Cost | **yes** | — (detailed below) |
| 6 | Hot-tag sharding / selective bump | Issue 10 | Throughput | no | [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) |
| 6 | Monotonic positions | Issue 7 | Cleanup | no | [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) |
| 7 | Cross-partition secondary-tag reads | Issue 13 | Capability (future) | **yes** | — (detailed below) |

---

## Phase 1 — DynamoDB integration test (Issue 3) — **DONE (2026-06-20)**

Implemented per [dcb-dynamodb-atomic-append-integration-test](done/dcb-dynamodb-atomic-append-integration-test.md). The fence path now has end-to-end behavioural coverage against a real DynamoDB engine (DynamoDB Local via Docker), proving Phase 0's fix and giving every later phase a harness.

**What shipped**:
- `reventless/reventless-aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res` (+ `DcbIntegrationHarness.res` for `CreateTable`/`DeleteTable`/fence helpers).
- `docker-compose.dynamodb-local.yml` + `scripts/run-integration-tests.sh` (boots the sidecar, waits, runs, tears down; **skips cleanly when Docker is absent** so it's safe in CI's existing continue-on-error step and on dev machines).
- Root `jest.integration.config.js` + `jest.integration.setup.cjs` (points the SDK at the local engine via `AWS_ENDPOINT_URL_DYNAMODB` — **no binding changes**). Wired to the real `pnpm run test:integration`; default `pnpm test` stays engine-free (integration dir is `testPathIgnorePatterns`-excluded).
- **Polyfill**: added `structuredClone` to `jest.setup.cjs` (mirrors the existing `crypto` polyfill). The AWS SDK's error-response deserializer calls it; without it a real `TransactionCanceledException` surfaced as `"structuredClone is not defined"` and masked the conflict — i.e. the fence path was untestable in Jest's VM sandbox until this was added.

**Scenarios covered** (the four regression cases + OCC primitives):
1. Sync `P5`; order `O1[P5]` → Ok; order `O2[P5]` (diff customer + orderId) → **Ok** (Issue 1 regression). ✓
2. Same product, two concurrent orders → both Ok (no `productId` contention). ✓
3. A concurrent re-sync of `P5` advancing the fence past the order's read → conditional `productId` check **still conflicts** (OCC preserved). ✓ *(uses a deterministic `setFence` rather than racing a second append — same-millisecond writers can tie on UUID order, analysis Issue 7).*
4. Register customer `C`, place an order carrying `C` as a secondary tag, then `ChangeEmail(C)` → Ok (placing the order no longer poisons the customer slice). ✓
5. Fresh first-writer (`after=None`) seeds the fence. ✓
6. Two concurrent commits at the same `after` never both win (safety; raw layer may cancel both — the slice callback's 3-retry loop is what guarantees a single winner in prod). ✓
7. A chain of compatible commits all succeed. ✓
8. A failed fence condition aborts the whole multi-tag transaction (atomic rollback — the rejected event is not written). ✓

Tagless-rejection and 100-item-limit round-trips are already covered by the unit suite (`DcbEventLogStorage_DynamoDb_RuntimeTest.res`), so they are not duplicated here.

Gate: Phases 2–3 must add their scenarios to this suite before merge.

## Phase 2 — Close the `after=None` create-race (Issue 2) — **DONE (2026-06-20)**

Shipped **option B** (per-(eventType, partition) create guard). 2A investigation showed option A insufficient for the default sync path; B closes the hole there too and sidesteps Issue 4. Implementation in `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildCreateGuardUpdate` + the `after=None` branch of `buildConditionalTransactItems`). Verified: unit shape tests (4) in `DcbEventLogStorage_DynamoDb_RuntimeTest.res`; integration scenarios (two concurrent first-writers → at most one wins, no duplicate persisted; subset-event-type writer → no false conflict) in the Phase 1 suite (10 cases, green). Full details in analysis Issue 2 § "Fix (shipped 2026-06-20)". The reference material below is retained for context.

**Goal**: two concurrent first-writers to the same entity must not both succeed.

**The tension (must resolve first).** The naive fix — at `after=None`, make the partition-tag fence a conditional `Update` gated on `attribute_not_exists(lastPosition)` — reintroduces the exact false conflict that motivated the unconditional fallback: a slice that reads a *subset* of the event types on a shared partition (e.g. reads only `NameChanged` on a `productId` partition that already has a `ProductAdded`) sees zero matching events, `after=None`, and its `attribute_not_exists` fails because a *different* event type already created `fence#productId`. This is Issue 4 (per-tag, not per-(tag, event-type) fences) resurfacing.

**Decision to make (pick one; recommend B then A if needed):**

- **A — Rely on upstream FIFO per-entity serialization, document + test.** If `StateChangeSlice` commands for the same entity share a FIFO `messageGroupId` (verify in `CommandTopic`/SQS wiring), two same-entity creates can never run concurrently, so the hole is theoretical. Action: confirm the grouping, document the guarantee at `appendConditional`'s `after=None` branch, and add an integration test that drives two same-entity creates and asserts serialization. **Cheapest; do this first and confirm whether it fully closes the hole.**
- **B — Type-aware creation guard.** When the `after=None` writer's query restricts event types (the common case), emit a `ConditionCheck`/`Update` on a guard item keyed by the producing event type — e.g. `id="create#<eventType>#<key>:<value>"` gated on `attribute_not_exists` — so creation of *that* event type for *that* entity serializes without colliding with other types on the partition. Adds one item to first-writes only. Closes the hole even without FIFO, and sidesteps Issue 4.

**Phase 2A investigation result (2026-06-20): Option A is insufficient — escalate to B (or the partition-tag `attribute_not_exists` variant).** The DCB command-topic wiring ([`reventless-aws/.../Plugin.res`](../../reventless/reventless-aws/src/components/Plugin.res) → `CommandTopicChannel.SQS_Sync` for `DcbCommandTopicChannel`, `SQS_Async` for `DcbCommandTopicChannelAsync`):

- **Async slices** (`@@reventless.async`) → `CommandTopicChannel_SQS_Async`, a **FIFO** queue with `messageGroupId = safeGroupId(commandJson.id)` ([`Util_SQS_Runtime.res:43`](../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res#L43)), and for DCB slice commands `commandJson.id` **is the entity/partition id** ([`StateChangeSlice_Callback.res:108`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L108)). So same-entity async creates **are** serialized — the hole is closed for them.
- **Sync slices (the default)** → `CommandTopicChannel_SQS_Sync`, a **standard (non-FIFO)** queue whose `publishJsonsAndWait` runs the handler **inline** in the AppSync resolver invocation (Single strategy) or fire-and-forgets to standard SQS (PerAggregate). Neither serializes per entity. Two concurrent first-writers to the same entity therefore both read `after=None` and both append — **the create-race is real on the default path.**

Action taken: documented the async/FIFO guarantee here and in analysis Issue 2. Remaining work = implement B (or partition-tag `attribute_not_exists`) with the red→green create-race integration test below, guarded by the subset-event-type false-conflict case.

**Files**: `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildConditionalTransactItems`, `after=None` branch).

**Tests (TDD, same red→green flow as Phase 0)**:
- Unit: at `after=None`, the built transaction asserts existence on the create guard (shape test) — red before, green after.
- Integration (Phase 1 harness): two concurrent creates of the same entity → exactly one succeeds; a subset-event-type slice on a shared partition does **not** false-conflict.

**Risk**: medium — touches the idempotency fallback. Guard with the subset-event-type integration case explicitly.

## Phase 3 — Drop / down-project the unused per-tag GSIs (cost lever #1) — **ON HOLD (2026-06-20)**

**Held pending a decision on cross-partition secondary-tag queries.** Prerequisite verified — `queryBySingleTag`/`queryBySingleTagStream` have zero callers and no `tag_*` index name is referenced outside the adapter (the per-tag GSIs were orphaned by `fc4c1f493` "primary-tag partitioning", which switched single-tag reads to base-table partition queries). But the choice between **full removal** and **`KEYS_ONLY` down-projection** turns on whether a *single non-partition (secondary) tag* read will ever be wanted:

- Today a single-tag read is a **base-table partition query** — it returns only events whose *primary/partition* tag is that tag. An event carrying the tag as a *secondary* tag lives in another partition and is **not** returned; there is no query path for a cross-partition secondary-tag read (the per-tag GSIs were the old mechanism, now disconnected). This is also load-bearing for Issue 1: single-tag reads being partition-scoped is what keeps read-scope = fence-scope. A cross-partition secondary-tag read would reintroduce that mismatch.
- **Full removal** forecloses re-adding such a read without a GSI rebuild *and* a fence-model reconciliation. **`KEYS_ONLY`** keeps the index (queryable via keys + `BatchGetItem`) while still cutting most of the write/storage cost.

Decision deferred — revisit once secondary-tag query needs are clear. The capability, a canonical worked example (course subscription) and a solution sketch that re-uses the per-tag GSI are in [analysis Issue 13](../analysis/dcb-consistency-check-issues.md#issue-13--no-single-tag-cross-partition-secondary-tag-read-capability-gap). The full-removal plan below remains the reference if that path is chosen.

**Goal**: cut ~30–60% of per-write WCU and the permanent storage multiplier on the event log.

**Finding**: the table provisions one `tag_<key>` GSI **per tagged field** plus `tag_composite`, all `projectionType: ALL` ([`DcbEventLogStorage_DynamoDb.res:19-30`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb.res#L19-L30); index list built in [`Dcb_Builder.res:135-154`](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res#L135-L154)). The single-tag read path uses the **base table** (`queryByPartitionKeyStream`); composite reads use `tag_composite`. The per-tag GSIs' only readers — `queryBySingleTag` / `queryBySingleTagStream` — have **zero callers**. So they are write-amplification + storage multiplier with no read benefit.

**Steps**:
1. **Verify no out-of-adapter consumer** queries `tag_<key>` GSIs: grep the whole repo (EventCollector, admin, MCP, QueryDb, debugging tooling) for `tag_`/index-name usage and direct `QueryCommand` with `indexName`. Confirm the EventTopic stream consumer reads the base-table stream, not a GSI.
2. **Remove the per-tag GSIs** from the index list in `Dcb_Builder.res` — keep only `tag_composite` (still needed by composite reads). Equivalently, leave the *attributes* but stop creating the GSIs.
3. Delete the now-dead `queryBySingleTag` / `queryBySingleTagStream` and the unused `tag_<key>` attribute writes in `toItem` if nothing else reads them (keep `tag_composite`).
4. **Migration**: removing GSIs requires a table change → wipe+recreate the alpha DcbEventLog tables (prefer wipe over migration per repo convention; coordinate with the Phase 0 fence-row wipe).

**Tests**: unit-assert the generated `globalSecondaryIndexes` no longer include per-tag GSIs; integration smoke (Phase 1) that single-tag and composite reads still work post-change.

**Risk**: low-medium — purely removing unused infra, but a table migration. Sequence after Phase 1 so reads are covered.

**Optional softer variant**: if a future cross-partition secondary-tag read is anticipated, switch the per-tag GSIs to `KEYS_ONLY` instead of removing — still cuts most of the storage/WCU while retaining queryability.

## Phase 4 — Decision-model cache (cost lever #2) — **CORE DONE (2026-06-20)**

Per [dcb-decision-model-projection-cache](dcb-decision-model-projection-cache.md): the slice now folds from a cached `(decisionState, readHead)` and reads only events after the cached head → O(history) read cost becomes O(delta), cutting the per-event `decode` CPU. No slice-contract change.

**What shipped** (Steps 1–3 + Step 6 docs): a sealed in-process LRU ([`reventless-core/src/util/Lru.res`](../../reventless/reventless-core/src/util/Lru.res)) wired into `StateChangeSlice_Callback` (capacity 100, per slice, per warm Lambda). Cache hit → delta read; conflict → re-seed so each retry is also a delta read; terminal failure → invalidate. Tests: `tests/util/LruTest.res` + three projection-cache scenarios in `tests/dcb/DcbStateChangeSliceTest.res` (full reventless-core suite green at 419, local DCB suite green at 35).

**Key design correction** over the plan's original pseudocode: the cache stores the *decided-on state and the read head* — **not** the produced events folded in, and **not** `append`'s returned position. Folding produced events is impossible (`evolve` takes `consumedEvent`, `decide` produces `event` — distinct types), and `append` returns the batch *base* on DynamoDB vs. the batch *max* in-memory (so `~after=position` would re-read the batch tail on DynamoDB). Caching `(decisionState, readHead)` sidesteps both — the next command's delta read picks up our just-appended events itself (their position is always `> readHead`). Correctness still rests entirely on the conditional-append fence.

**Deferred follow-ups**: Step 4 (per-slice capacity knob — needs `projectionCacheCapacity` threaded through `StateChangeSlice.Spec` + PPX auto-injection) and Step 5 (CloudWatch hit/miss metrics). Hardcoded 100 is the interim default.

## Phase 5 — Robustness guards & opt-in strong reads

Small, mostly independent items; land opportunistically.

- **Opt-in strong consistency (cost lever #3)** — add a per-slice flag (default eventually-consistent, rely on fence-retry for the rare stale read; opt into `consistentRead` only for high-contention slices). Halves decision-read RCU on the common path. Files: `executeQueryItemStream` / `readStream` already thread `~strongConsistency`; expose it up through the slice config. **Net-new.**
- **Issue 5 — composite exact-match guard.** Build-time assertion (or doc warning) that a multi-tag event's tag set exactly matches any composite query that reads it; adding a tag silently breaks composite reads today. **Net-new.**
- **Issue 4 — per-(tag, event-type) over-serialization.** Document the entity-level serialization semantics; only pursue per-type fences if a real slice suffers (also unblocks Phase 2 option B). Mostly docs.
- **Issue 6 — per-tag `after`.** Note as a deeper design item; each fence checked against the head observed for *its* partition rather than the global head. Defer unless a multi-clause slice shows false conflicts.
- **Issue 9 — `appendUnconditional` bumps all tags.** Align with the partition-scope invariant if/when a composite-fence design (option A) lands; today it is seeding-only and benign.
- **Issue 12 — tagless scan + fence items.** Confirm whether any tagless, type-less read can occur; if so, filter `fence#…` items in the scan path.
- **Issue 14 — drop vacuous query-clause type combinations. — DONE (2026-06-20).** `buildQueryFromCommand` now takes an optional `~tagKeysByEventType` map (event type → produced tag-key set), threaded from `Dcb_Builder` (which knows every producer's `eventSchema`) through `StateChangeSlice.make` → `_Callback`. Each clause keeps a consumed type only if that type's **full produced tag set** carries the clause's tag(s) (`narrowEventTypesForTags`); the map is built via `DcbTag.extractTagKeysByEventType` + `mergeTagKeysByEventType` from the *producer* schemas, never a consumer's `consumedEventSchema`. Pure dead-clause removal — vacuous clauses match nothing, so results unchanged; a type carrying the tag as a *secondary* (e.g. `OrderPlaced` under `productId`) is **retained** (legitimate cross-partition read = Phase 7 / Issue 13). Tests: 4 in `DcbTagTest.res` (core suite green at 423; local + example builds green). Was net-new.
  - **Docs follow-up — DONE.** Updated the published [internals/dcb-consistency-checks](../../packages/doc/docs-framework/internals/dcb-consistency-checks.md) Stage 1 `PlaceOrder` example: the `orderId` clause now lists only `OrderPlaced`; the `productId` clauses keep both types; added the note that clauses list only types whose produced tag set carries the clause's tag.

## Phase 6 — Profile-gated throughput & cleanup

Already planned, run on evidence:
- [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) — selective bumping (§2, cost-saver, can ship early) then sharding (§1, profile-gated).
- [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) — half-day cleanup, land any time someone is in `Runtime.res`.

## Phase 7 — Cross-partition secondary-tag reads (capability, future) — **net new**

**Goal**: support reading a single tag *across* partitions — i.e. reading an event type by a tag it carries as a *secondary* (non-partition) tag. Today a single-tag read is partition-scoped, so this is impossible; it's the canonical DCB shape for any M:N decision (course-subscription capacity, "≤ N orders per product", reservations). Full motivation, worked example, solution sketch, and cost analysis: [analysis Issue 13](../analysis/dcb-consistency-check-issues.md#issue-13--no-single-tag-cross-partition-secondary-tag-read-capability-gap).

**Why it's its own (deferred) phase, and how it couples to Phase 3.** The clean realisation **re-uses the per-tag `tag_<key>` GSI that Phase 3 would otherwise drop** — so the two are entangled: pursuing Phase 7 means Phase 3 must down-project to `KEYS_ONLY` (or keep `ALL`), not remove. **The decision "is a cross-partition read ever wanted?" gates Phase 3's form.** That is exactly why Phase 3 is currently on hold.

**Shape of the work** (three coupled parts, from the analysis):
1. **Per-tag scope flag** (`@dcbTag(~scope=#CrossPartition)`, default `#PartitionScoped`) — the single control surface; also resolves the Issue 14 residual (it's what tells the builder a secondary-tag clause is *wanted*, not just tolerated).
2. **Read routing** — a `#CrossPartition` single-tag clause reads the per-tag GSI instead of the base-table partition.
3. **Fence scope follows read scope** — a `#CrossPartition` tag is fence-bumped by *every* carrier (not just events partitioned by it), or OCC misses concurrent secondary-tag writers; partition-scoped tags keep the narrow rule.

**Cost note**: read-dominated and paid on *both* tags of an M:N event (O(entity degree), eventually-consistent, uncached). Highest-leverage mitigations are framework-level — `Limit:N+1` count-bounded reads for capacity invariants and the Phase 4 decision-model cache — not infra. See analysis Issue 13 § Performance & cost.

**When to do it**: profile-/evidence-gated — only when a real slice needs a cross-partition read. Until then it stays a future capability, and slices that merely *tolerate* over-reads (e.g. `PlaceOrder`) handle it in their behaviour.

## Suggested execution order

1. ~~**Phase 1** (verification harness + Phase 0 regression cases)~~ — **done 2026-06-20**.
2. ~~**Phase 2** (create-race close)~~ — **done 2026-06-20**. 2A confirmed the hole is real on the default sync path; shipped option B (per-type create guard).
3. **Phase 3** (drop unused per-tag GSIs) — biggest durable $ win, no contract change. **On hold**: its form (full-remove vs `KEYS_ONLY`/keep) is gated by the Phase 7 decision below.
4. ~~**Phase 4** (decision-model cache) — biggest read-cost win.~~ — **core done 2026-06-20** (Steps 1–3 + docs); per-slice capacity knob + metrics deferred.
5. **Phase 5** items opportunistically — the safe Issue 14 vacuous-clause cleanup is **done (2026-06-20)**; remaining items (opt-in strong reads, Issues 4/5/6/9/12) land opportunistically. **Phase 6** on profiling evidence.
6. **Phase 7** (cross-partition reads) — only when a real slice needs it; making that call first unblocks Phase 3.
