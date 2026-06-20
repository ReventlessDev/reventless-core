# DCB Fence-Scope vs Read-Scope Mismatch — Analysis

**Date**: 2026-06-20
**Status**: Diagnosis complete; **core fix implemented + unit-tested 2026-06-20** (option B for composite). Live DynamoDB integration test + alpha fence-row wipe pending — see plan `docs/plans/dcb-fence-scope-alignment.md`
**Related**: [dcb-dynamodb-consistency-check.md](dcb-dynamodb-consistency-check.md), plans [dcb-eventlog-primary-tag-partitioning.md](../plans/done/dcb-eventlog-primary-tag-partitioning.md), [dcb-strong-consistency-single-tag-reads.md](../plans/done/dcb-strong-consistency-single-tag-reads.md), [dcb-hot-tag-fence-contention.md](../plans/Backlog/dcb-hot-tag-fence-contention.md)

## Symptom

On the deployed hybrid example (`online-shop-hybrid`), **Place Order** fails with:

```
Conflict: Transaction cancelled, please refer cancellation reasons for specific reasons
[None, None, ConditionalCheckFailed, None, None] (Conflict)
```

The `ConditionalCheckFailed` at item index 2 is a **`productId` consistency fence** inside the DCB atomic-append `TransactWriteItems`.

**Reproduction signature (testable):** the *first* order of any given product succeeds; *every subsequent* order containing that same product fails with this Conflict, even from a different customer and a different `orderId`. In a demo where products are re-ordered, almost every Place Order breaks.

The 5-item / index-2 shape matches a 2-product order:
`[put(OrderPlaced), cond(orderId), cond(productId₁)✗, cond(productId₂), uncond(customerId)]`.

## Root cause: fence-scope is broader than read-scope

The DCB atomic append enforces optimistic concurrency with **per-tag-value fence sentinels**. Two scopes are supposed to coincide but don't:

| | Scope |
|---|---|
| **Decision-model read** of a single-tag clause `T` | events in **partition `T`** — base-table query on `id = "<key>:<value>"` ([`executeQueryItemStream` single-tag branch](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L981-L987) → [`queryByPartitionKeyStream`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L781-L811)). Sees only events whose **partition tag** is `T`. |
| **Fence bump** for tag `T` | **every** event carrying tag `T`, from any partition ([`collectEventTags`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L547-L562), and conditional updates over [`collectQueryTags`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L528-L545)). |

Because events are partitioned by their **primary tag** ([primary-tag partitioning](../plans/done/dcb-eventlog-primary-tag-partitioning.md)), a tag that is *secondary* on one event type but *primary* on another splits across partitions while sharing one fence.

### Concrete walk-through (PlaceOrder)

Specs: [`PlaceOrder.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res), [`PlaceOrder_Behavior.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder_Behavior.res).

- `OrderPlaced` has `@partitionTag orderId` → stored under `id = "orderId:<O>"`, also tagged `productId` (secondary) and `customerId`.
- `CatalogProductSynced` has only `productId` → stored under `id = "productId:<P>"`.
- PlaceOrder's query (via [`buildQueryFromCommand`](../../reventless/reventless-spec/src/components/DcbTag.res#L649-L657), array field `productIds` ⇒ one **single-tag** clause per tag): `{orderId:O}`, `{productId:P5}`, …

1. **Sync** `P5` → append bumps `fence#productId:P5 → S5`.
2. **First order** of `P5` (`O1`): read of partition `productId:P5` returns `CatalogProductSynced(S5)` only → `after = S5`. Conditional check `fence#productId:P5 (S5) <= S5` ✓. `OrderPlaced(O1)` appended into partition `orderId:O1`, **bumps `fence#productId:P5 → P1 > S5`**.
3. **Second order** of `P5` (`O2`, any customer): read of partition `productId:P5` *still* returns only `CatalogProductSynced(S5)` — `OrderPlaced(O1)` lives in partition `orderId:O1`, invisible to a `productId:P5` base-table query → `after = S5`. Conditional check `fence#productId:P5 (P1) <= S5` ✗ → `ConditionalCheckFailed`.
4. The slice's 3 retries ([`StateChangeSlice_Callback`](../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L147-L262)) each re-read the same stale `after = S5`, fail identically, then surface `Conflict`.

The read can **never** catch up to the fence: the event that advanced `fence#productId:P5` is permanently in a different partition than the `productId:P5` read.

## Why prior fixes didn't catch it

The comments in [`PlaceOrder.res:13-29`](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res#L13-L29) and the `@noDcbTag customerId` fix ([2a1679737]) assume sibling `OrderPlaced` events **leak into the `productId` read** (GSI semantics) and merely need `orderId` to be discriminated. They don't leak in: the single-tag read is a base-table **partition** query, so cross-partition `OrderPlaced` is invisible to the read while still moving the fence. The mental model assumed read-scope = "any event with this tag"; the implementation is read-scope = "events in this partition".

`customerId` was removable via `@noDcbTag` because PlaceOrder doesn't read by customer. `productId` is **not** removable — the slice genuinely reads `CatalogProductSynced` by `productId` to check availability. So this instance can't be patched at the spec level the same way.

## The deeper invariant

A consistency fence is only meaningful when **fence-bump scope == read scope** for that tag value: the fence must move exactly when (and only when) a new event the read would have observed is appended. Today:

- **Single-tag (partition) reads**: read-scope = partition `T`. Fence-scope = all-tagged-`T`. Mismatch whenever `T` is a *secondary* tag on some appended event type ⇒ guaranteed false conflict on the 2nd+ such append.
- **Composite (multi-tag GSI) reads** ([`queryByCompositeTagsStream`](../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L855-L896)): read-scope = "events whose `tag_composite` equals this composite". `appendConditional` decomposes a composite clause into **single-tag** conditional fences, so its fence-scope is again per-tag — a *different* mismatch (potential under- or over-fencing). Any fix must keep this path correct.

## Fix direction (summary)

Align fence-bump scope with read scope:

- Bump a fence for tag `T` **only when `T` is the event's partition tag** — so `fence#T` tracks exactly the partition-`T` events a single-tag read of `T` observes. Under this rule, `OrderPlaced` (partition `orderId`) bumps `fence#orderId` only; `fence#productId:P5` moves only on `CatalogProductSynced` (partition `productId`) appends. PlaceOrder's `productId` conditional check then compares against a fence that reflects exactly what its read counted → no false positive, while a concurrent *re-sync* of `P5` is still correctly caught.
- Handle composite/multi-tag reads with a matching **composite fence** keyed to the composite read scope (or scope the partition-tag rule to single-tag query tags and keep composite clauses on the current fences). See the plan for the trade-off.

Full step-by-step, edge cases, and test plan: **`docs/plans/Backlog/dcb-fence-scope-alignment.md`**.

## Scope of impact

- Affects **any** DCB slice whose query includes a tag that is a *secondary* (non-partition) tag on an event type that also gets appended/visible on that tag. PlaceOrder/`productId` is the live instance; the same shape recurs wherever a slice reads a shared `*Id` it doesn't partition by.
- The hybrid example is the deployed casualty; the business repo consumes the same core adapter, so this is a framework fix, not an example-only patch.

### Why only AWS, never in tests

The local backends ([`DcbEventLogStorage_InMemory.res`](../../reventless/reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res), `_Sqlite`) do **not** implement the per-tag fence sentinel mechanism — they have no `fence`/`lastPosition` rows and enforce the append condition in-process against the actual events, which is inherently read-scoped. So `PlaceOrder_GWT`, local dev, and any in-memory/SQLite E2E pass cleanly; the false conflict is exclusive to the DynamoDB adapter. The regression test must run against the **DynamoDB** adapter (integration test), not the local backends, to reproduce it.
