# Plan: Align DCB Fence-Scope with Read-Scope

**Status**: In progress — core fix implemented + unit-tested (2026-06-20), composite handling resolved as **option B**. Remaining: live DynamoDB integration test + alpha fence-row wipe on deploy.
**Analysis**: [dcb-consistency-check-issues.md](../analysis/dcb-consistency-check-issues.md)
**Sibling plans**: [dcb-eventlog-primary-tag-partitioning.md](done/dcb-eventlog-primary-tag-partitioning.md), [dcb-strong-consistency-single-tag-reads.md](done/dcb-strong-consistency-single-tag-reads.md), [dcb-hot-tag-fence-contention.md](done/dcb-hot-tag-fence-contention.md)

## Implemented (2026-06-20)

In [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res):
- Extracted pure `buildConditionalTransactItems` (testable transaction shape, no IO).
- Added `eventPartitionTags` / `collectEventPartitionTags` (an event's partition tag = the only fence it may bump) and `buildFenceConditionCheck` (read-only fence assertion).
- New rule: a **single-tag** query clause whose tag is **not** the written event's partition tag becomes a `ConditionCheck` (assert `lastPosition <= :after`, no bump) instead of a conditional `Update`. Partition tags keep check+bump. **Composite (multi-tag) clauses keep check+bump on all tags (option B).** Unconditional bumps are restricted to partition tags (+ composite query tags), so secondary tags like `customerId` are never fenced.
- TDD red→green unit tests in [`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res): `productId` → ConditionCheck, `customerId` not fenced, composite tags stay Updates. Misleading comments updated in `PlaceOrder.res` and `StateChangeSlice_Callback.res`.

Composite decision: **option B**. Audit found one composite-query slice (`RecordProductDemand` in online-shop-dcb); its event tags equal its query tags, so it bumps both fences via its own conditional updates and relies on no secondary-tag bump. Option A (composite fence sentinel) deferred — only needed if a slice writes a >1-tag event but queries a subset of those tags, which no current slice does.

## Remaining

- **Live DynamoDB integration test** for the scenarios below — cannot run on local backends (they don't use fences); run against deployed/LocalStack DynamoDB.

## Done after-the-fact

- **Alpha fence-row wipe (2026-06-21)** — performed on `OrderingDcbEventLog-2a4f98f` only, after the Phase 7 entry-point + IAM fixes deployed (commit `8d29fc45c`) surfaced this gap on a manual PlaceOrder against `online-shop-hybrid-platform-aws-alpha`: the 2nd P1 order false-conflicted as predicted (CloudWatch logs showed `ConditionalCheckFailed` on a fence row bumped by the May-28 OrderPlaced for order `88bace…`, while the post-fix read could only reach the older `CatalogProductSynced` position). Wiped 15 `fence#*` rows via `BatchWriteItem`; immediate post-wipe retry returned `CommandAccepted`. **Catalog DCB tables not wiped yet** — `catalog-aws` still on the pre-fix Lambda code/IAM, so its DCB commands fail before reaching fences; wipe its `fence#*` rows immediately after the same `pulumi up` lands there.

## Problem

A DCB consistency fence is only meaningful when its **bump scope equals the read scope** of the clause it guards. Today they diverge for any tag that is *secondary* (non-partition) on some appended event type:

- A single-tag read of `T` observes only **partition `T`** events (base-table query on `id="<key>:<value>"`).
- `fence#T` is bumped by **every** event tagged `T`, from any partition.

Result: once an event in a *different* partition bumps `fence#T`, a single-tag read of `T` can never reach that position, so the conditional check `fence#T.lastPosition <= :after` fails forever. Live instance: `online-shop-hybrid` PlaceOrder — the 2nd+ order of any product fails with `Conflict … [ConditionalCheckFailed] …`. See analysis for the full walk-through.

## Goals

- Eliminate the false-positive `ConditionalCheckFailed` for slices reading a shared secondary tag (PlaceOrder/`productId`).
- Preserve genuine OCC conflicts: two writers appending into the same partition, and a concurrent change to a read fact (e.g. a re-sync of the same product) must still conflict.
- Keep the composite/multi-tag GSI read path correct.
- No change to the `StateChangeSlice` author contract; ideally no spec changes in examples.

## Non-goals

- Hot-tag throughput (covered by [dcb-hot-tag-fence-contention.md](done/dcb-hot-tag-fence-contention.md)).
- Per-(tag, event-type) fences. Finer than needed and more items per transaction; the partition-scoped rule below is sufficient.
- Migration of existing fence rows. Fences are derived state; a wipe of the alpha EventLog/fence rows is acceptable (cf. memory: prefer wipe over migration in alpha).

## Core rule

**Bump `fence#<key>:<value>` only when `<key>` is the event's partition tag.** Then `fence#T` advances exactly when a partition-`T` event is appended — matching what a single-tag read of `T` observes.

Consequences for PlaceOrder:
- `OrderPlaced` (partition `orderId`) bumps `fence#orderId:<O>` only — not `fence#productId`, not `fence#customerId`.
- `fence#productId:P5` advances only on `CatalogProductSynced` (partition `productId`) appends.
- PlaceOrder's `productId` conditional check compares against a fence reflecting exactly its read ⇒ passes; a concurrent re-sync of `P5` still bumps `fence#productId:P5` past `after` ⇒ correctly conflicts.

The conditional check on `fence#orderId:<O>` still prevents double-placing the same order.

## Composite / multi-tag reads

A multi-tag clause reads via the `tag_composite` GSI; its read-scope is "events whose `tag_composite` equals this composite", which **can** be cross-partition. `appendConditional` currently decomposes a composite clause into per-single-tag conditional fences — under the core rule those single-tag fences may no longer move for cross-partition composite-matched events (under-fencing).

Pick one (decide during implementation, default **A**):

- **A — Composite fence sentinel.** Maintain `fence#composite:<compositeKey>` analogous to the `tag_composite` index. A composite clause's conditional check guards the composite fence; an append bumps `fence#composite:<k>` when the event's tag set yields composite `<k>`. Fence-scope then equals composite read-scope. +1 fence item per composite clause.
- **B — Scope the rule to single-tag query tags only.** Keep composite clauses on the existing per-tag fences (current behaviour) and apply the partition-tag rule only where the read is partition-scoped. Smaller change, but leaves composite reads on the old (broader) fences — acceptable only if no current slice depends on cross-partition composite OCC. Audit before choosing.

## Implementation sketch

All in [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res):

1. Thread the event's partition tag into fence-bump construction. `toItem`/`derivePartitionKey` already know the partition tag ([`derivePartitionKey`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L32-L53)); expose "the partition tag of event E" so bump builders can filter.
2. `collectEventTags` → `collectEventPartitionTags`: for each event, emit only its partition tag/value (used by `appendUnconditional` and `extraEventTags` in `appendConditional`).
3. `appendConditional` conditional updates: still built from `collectQueryTags`, but a conditional fence on query tag `T` is only sound if `T` is a partition tag of the events the slice could read on `T`. For PlaceOrder both `orderId` and `productId` are partition tags of *some* read event type (`OrderPlaced`, `CatalogProductSynced` resp.), so both keep conditional fences — and both now move only on their own partition's appends. Verify the rule with the GWT/integration tests below rather than special-casing.
4. `appendUnconditional` (seed/replay): bump only partition-tag fences so seeded `CatalogProductSynced` still advances `fence#productId` (needed for availability reads) without touching unrelated fences.
5. If **A**: add composite-fence Put/Update helpers and a `fence#composite:` key; wire into the composite branch of read/append.

Update the misleading comments in [`PlaceOrder.res:13-29`](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res#L13-L29) and [`StateChangeSlice_Callback.res:36-42`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L36-L42) (they describe GSI-leak semantics the read path doesn't have).

## Test plan

1. **Adapter integration (DynamoDB, the failing path)** — extend `dcb-dynamodb-atomic-append-integration-test`:
   - Sync `P5`; place order `O1[P5]` → Ok. Place order `O2[P5]` (different `orderId`, different `customerId`) → **Ok** (currently fails). Regression guard for this bug.
   - Place order `O1[P5]` twice (same `orderId`) → second is rejected/idempotent (double-place still caught).
   - Concurrent re-sync of `P5` between a PlaceOrder read and append → conditional fence on `productId` **still conflicts** (genuine OCC preserved).
   - Two concurrent orders sharing `P5` → both Ok (no contention via `productId`).
2. **Composite path** (whichever of A/B chosen): a slice with a genuine multi-tag clause — concurrent writers matching the composite still conflict; non-matching don't.
3. **GWT** — `PlaceOrder_GWT` already covers decide logic; add no fence assertions there (fences are adapter-level). Keep example tests `_GWT`-only per repo convention.
4. **Zero-warning build** + `pnpm test` across affected packages.

## Open questions

- Choose composite strategy **A** vs **B** after auditing current multi-tag DCB clauses in `reventless-core` + examples.
- Does any in-memory/SQLite backend ([`DcbEventLogStorage_InMemory.res`](../../reventless/reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res), `_Sqlite`) replicate the per-tag-fence semantics? If so, apply the same partition-scoped rule so local dev matches AWS.
- Alpha data: confirm wipe of existing fence rows rather than migrating.
