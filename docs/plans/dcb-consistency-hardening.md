# Plan: DCB Consistency-Check Hardening (roadmap)

**Status**: Proposed — derived from analysis [dcb-consistency-check-issues.md](../analysis/dcb-consistency-check-issues.md) (2026-06-20)
**Nature**: umbrella roadmap. Sequences the open correctness, cost, and robustness items from the analysis. Net-new work is detailed inline; items already covered by a focused plan are referenced, not duplicated.

## Phasing rationale

Order = correctness → verification harness → durable cost wins → robustness guards → profile-gated tuning. Verification (Phase 1) comes early because nothing else here can be *trusted* without a real-DynamoDB test of the fence path — local backends don't use fences, so unit tests only assert transaction *shape*, not DynamoDB *behaviour*.

| Phase | Item | Analysis ref | Class | New work? | Existing plan |
|---|---|---|---|---|---|
| 0 | Fence-scope = read-scope | Issue 1 | Correctness | shipped | [dcb-fence-scope-alignment](dcb-fence-scope-alignment.md) |
| 1 | DynamoDB integration test | Issue 3 | Verification | partly | [dcb-dynamodb-atomic-append-integration-test](Backlog/dcb-dynamodb-atomic-append-integration-test.md) |
| 2 | `after=None` create-race | Issue 2 | Correctness | **yes** | — (detailed below) |
| 3 | Drop unused per-tag GSIs | Perf/cost lever #1 | Cost | **yes** | — (detailed below) |
| 4 | Decision-model cache | Perf/cost lever #2 | Cost | no | [dcb-decision-model-projection-cache](Backlog/dcb-decision-model-projection-cache.md) |
| 5 | Robustness guards | Issues 4, 5, 6, 9 | Robustness | **yes** | — (detailed below) |
| 5 | Opt-in strong reads | Perf/cost lever #3 | Cost | **yes** | — (detailed below) |
| 6 | Hot-tag sharding / selective bump | Issue 10 | Throughput | no | [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) |
| 6 | Monotonic positions | Issue 7 | Cleanup | no | [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) |

---

## Phase 1 — DynamoDB integration test (Issue 3) — **prerequisite**

Stand up the existing [dcb-dynamodb-atomic-append-integration-test](Backlog/dcb-dynamodb-atomic-append-integration-test.md) plan against real DynamoDB or LocalStack. Add the fence-scope regression scenarios as the first cases so Phase 0's fix is verified end-to-end and every later phase has a harness:

1. Sync `P5`; order `O1[P5]` → Ok; order `O2[P5]` (diff customer + orderId) → **Ok** (Issue 1 regression).
2. Same product, two concurrent orders → both Ok (no `productId` contention).
3. Concurrent re-sync of `P5` between an order's read and append → conditional `productId` check **still conflicts** (OCC preserved).
4. Place an order for customer `C`, then `ChangeEmail(C)` → Ok (customerId no longer poisons the customer slice).

Gate: Phases 2–3 must add their scenarios here before merge.

## Phase 2 — Close the `after=None` create-race (Issue 2) — **net new**

**Goal**: two concurrent first-writers to the same entity must not both succeed.

**The tension (must resolve first).** The naive fix — at `after=None`, make the partition-tag fence a conditional `Update` gated on `attribute_not_exists(lastPosition)` — reintroduces the exact false conflict that motivated the unconditional fallback: a slice that reads a *subset* of the event types on a shared partition (e.g. reads only `NameChanged` on a `productId` partition that already has a `ProductAdded`) sees zero matching events, `after=None`, and its `attribute_not_exists` fails because a *different* event type already created `fence#productId`. This is Issue 4 (per-tag, not per-(tag, event-type) fences) resurfacing.

**Decision to make (pick one; recommend B then A if needed):**

- **A — Rely on upstream FIFO per-entity serialization, document + test.** If `StateChangeSlice` commands for the same entity share a FIFO `messageGroupId` (verify in `CommandTopic`/SQS wiring), two same-entity creates can never run concurrently, so the hole is theoretical. Action: confirm the grouping, document the guarantee at `appendConditional`'s `after=None` branch, and add an integration test that drives two same-entity creates and asserts serialization. **Cheapest; do this first and confirm whether it fully closes the hole.**
- **B — Type-aware creation guard.** When the `after=None` writer's query restricts event types (the common case), emit a `ConditionCheck`/`Update` on a guard item keyed by the producing event type — e.g. `id="create#<eventType>#<key>:<value>"` gated on `attribute_not_exists` — so creation of *that* event type for *that* entity serializes without colliding with other types on the partition. Adds one item to first-writes only. Closes the hole even without FIFO, and sidesteps Issue 4.

**Files**: `DcbEventLogStorage_DynamoDb_Runtime.res` (`buildConditionalTransactItems`, `after=None` branch).

**Tests (TDD, same red→green flow as Phase 0)**:
- Unit: at `after=None`, the built transaction asserts existence on the create guard (shape test) — red before, green after.
- Integration (Phase 1 harness): two concurrent creates of the same entity → exactly one succeeds; a subset-event-type slice on a shared partition does **not** false-conflict.

**Risk**: medium — touches the idempotency fallback. Guard with the subset-event-type integration case explicitly.

## Phase 3 — Drop / down-project the unused per-tag GSIs (cost lever #1) — **net new**

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

## Phase 4 — Decision-model cache (cost lever #2)

Execute the existing [dcb-decision-model-projection-cache](Backlog/dcb-decision-model-projection-cache.md) plan: fold from a cached `(query, headPosition)` and read only events after the cached head → O(history) read cost becomes O(delta), and cuts the per-event `decode` CPU. Warm-Lambda reuse makes even an in-process LRU worthwhile. No slice-contract change.

## Phase 5 — Robustness guards & opt-in strong reads

Small, mostly independent items; land opportunistically.

- **Opt-in strong consistency (cost lever #3)** — add a per-slice flag (default eventually-consistent, rely on fence-retry for the rare stale read; opt into `consistentRead` only for high-contention slices). Halves decision-read RCU on the common path. Files: `executeQueryItemStream` / `readStream` already thread `~strongConsistency`; expose it up through the slice config. **Net-new.**
- **Issue 5 — composite exact-match guard.** Build-time assertion (or doc warning) that a multi-tag event's tag set exactly matches any composite query that reads it; adding a tag silently breaks composite reads today. **Net-new.**
- **Issue 4 — per-(tag, event-type) over-serialization.** Document the entity-level serialization semantics; only pursue per-type fences if a real slice suffers (also unblocks Phase 2 option B). Mostly docs.
- **Issue 6 — per-tag `after`.** Note as a deeper design item; each fence checked against the head observed for *its* partition rather than the global head. Defer unless a multi-clause slice shows false conflicts.
- **Issue 9 — `appendUnconditional` bumps all tags.** Align with the partition-scope invariant if/when a composite-fence design (option A) lands; today it is seeding-only and benign.
- **Issue 12 — tagless scan + fence items.** Confirm whether any tagless, type-less read can occur; if so, filter `fence#…` items in the scan path.

## Phase 6 — Profile-gated throughput & cleanup

Already planned, run on evidence:
- [dcb-hot-tag-fence-contention](Backlog/dcb-hot-tag-fence-contention.md) — selective bumping (§2, cost-saver, can ship early) then sharding (§1, profile-gated).
- [dcb-monotonic-position-generation](Backlog/dcb-monotonic-position-generation.md) — half-day cleanup, land any time someone is in `Runtime.res`.

## Suggested execution order

1. **Phase 1** (verification harness + Phase 0 regression cases) — unblocks trust in everything else.
2. **Phase 2A** (confirm FIFO, document, test) — cheapest correctness close; escalate to 2B only if the hole is real.
3. **Phase 3** (drop unused per-tag GSIs) — biggest durable $ win, no contract change.
4. **Phase 4** (decision-model cache) — biggest read-cost win.
5. **Phase 5** items opportunistically; **Phase 6** on profiling evidence.
