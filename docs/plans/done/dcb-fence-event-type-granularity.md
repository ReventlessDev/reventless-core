# Plan: Per-(tag, event-type) DCB Fence Granularity

**Status**: Adapter fix + unit tests **implemented & green** (2026-06-23). Design: per-type
`pos#<eventType>` fence attributes, **with the create guard folded into the fence** (separate
`create#` rows retired).

Done (committed `a20646f31` on `alpha`, not pushed):
- [`DcbEventLogStorage_DynamoDb_Runtime.res`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) —
  per-type `buildConditionalFenceUpdate` / `buildUnconditionalFenceUpdate` /
  `buildFenceConditionCheck`, folded create guard in `buildConditionalTransactItems`
  (`create#`/`createGuard*` helpers deleted), per-type bumps in `appendUnconditional`.
- [`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res) —
  45 tests green (incl. Issue 4 subset-type check, folded guard, produced-not-consumed gate).
  Full AWS suite 133 green, zero-warning build (root).
- **Talk pages** rewritten (per-type + folded guard): the internals page, AWS + local adapter
  pages; doc-site swept for stale `lastPosition`/`create#` prose. See § Documentation.
- **Alpha sentinel rows wiped (2026-06-23)** — superseded by a **full catalog reset** of the
  live hybrid table set (`CatalogDcbEventLog-c0509c2` events + `create#` guards + fences, and
  read models `Products-07b7f5f`/`ProductDemand-4d2a936`/`AvailableProducts-93d2633`/
  `CatalogActivity-a01f9c6`) — all emptied to unblock the wedged product. Note: the new code
  ignores any stale scalar `lastPosition` (it reads `pos#*`), so a post-deploy wipe is cleanup,
  not a correctness requirement.

Remaining (carved out — this plan is complete):
- **Deploy** — push `alpha` so CI redeploys the `catalog-aws` Lambda. Until then the live site
  runs the old scalar-fence code and the Issue 4 deadlock can recur on mixed-attribute edits.
  (Normal release flow, not a code task.)
- **Live DynamoDB integration test** — moved to
  [Backlog/dcb-fence-granularity-integration-test.md](../Backlog/dcb-fence-granularity-integration-test.md)
  (needs DynamoDB Local; the existing suite is marked PENDING REWRITE at its header).
**Analysis**: [dcb-consistency-check-issues.md](../../analysis/dcb-consistency-check-issues.md) — Issue 4 (upgraded severity).
**Sibling plans**: [dcb-fence-scope-alignment.md](../dcb-fence-scope-alignment.md) (Issue 1, cross-partition secondary tags), [dcb-hot-tag-fence-contention.md](dcb-hot-tag-fence-contention.md).

## Symptom (live, 2026-06-23)

Changing a **Product Name** on the deployed hybrid platform
(`online-shop-hybrid-platform-aws-alpha`, product `12f8c090-e077-44e0-bf0b-da0b5aba6680`)
fails permanently:

```
Conflict: Transaction cancelled, please refer cancellation reasons for specific reasons
[None, ConditionalCheckFailed] (Conflict)
```

The 2-item shape is `[put(ProductNameChanged), cond(fence#productId)]`: the event Put
succeeds (`None`), the `productId` consistency-fence Update fails its conditional check.

Unlike Issue 1 (cross-partition, needed two partitions), this reproduces **with zero
concurrency** and is **permanent** — every retry fails identically.

## Root cause — Issue 4, under-rated

The hybrid Catalog models Product with **one event type per attribute**, and a separate
StateChangeSlice per attribute, all partitioned by the **same** `productId` tag, each
reading a **subset** of the product's event types:

| Slice | reads (consumed) | produces |
|---|---|---|
| `AddProduct` | `ProductAdded` | `ProductAdded` |
| `ChangeProductName` | `ProductAdded`, `ProductNameChanged` | `ProductNameChanged` |
| `ChangeProductDescription` | `ProductAdded`, `ProductDescriptionChanged` | `ProductDescriptionChanged` |
| `ChangeProductPrice` | `ProductAdded`, `ProductPriceChanged` | `ProductPriceChanged` |

All four bump **one** fence: `fence#productId:<id>` — its `lastPosition` is the position
of the **latest write of any type** to that product. But each slice computes its OCC
`after` from **only the event types its query lists**
([`StateChangeSlice_Callback.res`](../../../reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L298)).

Walk-through (`pos(X)` = position of event X):

1. Product created → `fence#productId:P = pos(ProductAdded)`.
2. Price changed → `fence#productId:P = pos(ProductPriceChanged)` (call it `Pp`).
3. `ChangeProductName` reads `[ProductAdded, ProductNameChanged]` → `after = pos(ProductNameChanged) = Pn`, and `Pn < Pp` (the price write is invisible to its query).
4. Conditional fence Update asserts `lastPosition <= :after` → `Pp <= Pn` → **false** → `ConditionalCheckFailed`.
5. Retries re-read, but the read **never** sees the price event, so `after` stays `Pn`. All 3 retries fail identically → surfaced `Conflict`.

The product is now **wedged to whichever attribute was last edited**: only the slice whose
produced type matches the most-recent write can advance (its `after` reaches the fence);
every other attribute slice is permanently blocked until the fence row is reset.

### Why it passes every test and local dev

The **local** in-memory/SQLite backends evaluate the append condition with true DCB query
semantics — `matchesQuery` filters by **event type**
([`DcbEventLogStorage_InMemory.res:13-14,51-58`](../../../reventless/reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res#L13)) —
so a `ProductPriceChanged` never matches `ChangeProductName`'s query and never conflicts.
Only the DynamoDB **fence approximation** collapses event type into a single position. This
is exactly the Issue 3 backend divergence; fence-shape bugs are invisible to GWT/local E2E.

### Relationship to the Issue 1 fix

[dcb-fence-scope-alignment](../dcb-fence-scope-alignment.md) fixed the cross-partition
*secondary*-tag case (PlaceOrder/`productId`) by bumping `fence#T` only when `T` is the
event's **partition** tag. That does not help here: `productId` **is** the partition tag for
all four Product slices, so all four legitimately bump `fence#productId:P`. The remaining
divergence is purely **event-type granularity within one partition** — the per-`(tag,
event-type)` fence the prior plan listed as a deliberate **non-goal** ("finer than needed").
That conclusion was wrong for entities modeled with one event type per attribute.

## Goal

Make the DynamoDB OCC check mirror the read query's event-type filter, so the fence
conflicts **iff** an event *of a type the slice reads*, carrying the partition tag, was
appended after the slice's `after` — matching the local backends exactly.

- Eliminate the permanent false `ConditionalCheckFailed` for subset-event-type slices
  sharing a partition tag (Product attribute slices).
- Preserve genuine OCC: a concurrent write of a type the slice **does** read still conflicts;
  same-entity create races still caught (the `after=None` create guard is already type-keyed).
- No `StateChangeSlice` author-contract change; no spec/example changes. The fix is
  **adapter-local** — `cond.query` already carries per-clause `eventTypes`, and produced
  types come from `events`, so `buildConditionalTransactItems` has everything it needs.
- Keep composite/cross-partition (Issue 1 / Issue 13) behaviour correct.

## Non-goals

- Hot-tag throughput / fence sharding ([dcb-hot-tag-fence-contention](dcb-hot-tag-fence-contention.md)).
- Migrating existing fence rows — fences are derived state; an alpha fence-row **wipe** is
  acceptable (cf. memory: prefer wipe over migration in alpha).
- Per-clause `after` (Issue 6) — orthogonal; the global head stays.

## Design — flattened per-type fence attributes

Keep **one fence item per partition-tag value** (`id="fence#<key>:<value>", position="FENCE"`),
but replace the single scalar `lastPosition` with **one attribute per event type**:

```
fence#productId:P  { id, position:"FENCE",
                     "pos#ProductAdded": <Pa>,
                     "pos#ProductNameChanged": <Pn>,
                     "pos#ProductPriceChanged": <Pp>,
                     "pos#ProductDescriptionChanged": <Pd> }
```

On a conditional append of events `E*` with condition `{query, after}`, for a single-tag
partition-scoped clause `{tags:[T], eventTypes:[C1…Cn]}`:

- **Check** (no false conflict): for each consumed type `Ci`, assert
  `attribute_not_exists(#posCi) OR #posCi <= :after`, AND-ed across `C1…Cn`.
- **Bump**: `SET #posP = :new` for each **produced** event type `P` carried by `E*` whose
  partition tag is `T`.

Correctness: slice `S` conflicts iff some event of a type in `S.consumedTypes`, tagged `T`,
landed after `S.after`. A writer producing `P` bumps `pos#P`. If `P ∈ S.consumedTypes` and a
`P`-event landed after `after` → `pos#P > after` → conflict. If `P ∉ S.consumedTypes`, `S`
never checks `pos#P` → no false conflict. This is exactly the local backend's
`event_type IN (…) AND tag matches` semantics.

### Why flat attributes, not a nested `lastPositions` map

A nested map (`SET lastPositions.#P = :new`) hits DynamoDB's "document path … no parent"
error when the fence item doesn't exist yet, and you can't both create the parent map and
set a child path in one `UpdateExpression`. **Top-level `pos#<type>` attributes have no
parent-path problem** — `SET #posP = :new` works whether or not the item exists, and
`attribute_not_exists(#posCi)` cleanly models "no event of this type seen". One item per
partition tag (good for the 100-item `TransactWriteItems` cap), just more attributes on it.

Use `ExpressionAttributeNames` for every `pos#<type>` (the `#` and arbitrary type strings are
safest behind a name placeholder). Event-type names are PascalCase identifiers, so collisions
across `pos#` keys can't happen.

### Fold the create guard into the fence (replaces the `create#` rows)

The separate per-`(eventType, partition value)` **create guard** (`create#…#…` rows, gated on
`attribute_not_exists(lastPosition)`) exists **only** because the old fence was a single scalar:
the Issue 2 fix rejected "gate the partition fence on `attribute_not_exists(lastPosition)`"
because a scalar `lastPosition` is shared across event types, so it false-conflicts a slice that
reads a *subset* of a partition's types (Issue 4). **Per-type attributes remove that objection** —
`attribute_not_exists(pos#<type>)` is type-scoped, true iff no event of that type exists,
regardless of what other types wrote to the same fence row. So the create guard folds into the
fence and the `create#` rows go away:

- At `after=None`, the **partition-tag** fence becomes a conditional `Update` (not the old
  unconditional idempotent-fallback bump). Its condition is the AND over **(consumed types ∪
  produced types)** of `attribute_not_exists(pos#<type>)`; it bumps `pos#<producedType>`. Two
  concurrent first-writers of the same `(producedType, partition)` collide on
  `attribute_not_exists(pos#<producedType>)` → exactly one commits.
- **The produced-type arm is load-bearing and must not be dropped.** The OCC read check covers
  *consumed* types; the create-race guard needs the *produced* type. When a slice produces a type
  it does **not** consume, `attribute_not_exists(pos#<producedType>)` is the *only* thing
  preventing a double-create — it must be unioned in explicitly even though it is not a consumed
  type. (This is the one subtlety the separate `create#` row made structurally impossible to
  forget; folding trades that safety for a gated test — see Test plan #1.)
- Subset-type safety is preserved: a slice consuming `[X]` at `after=None` on a partition that
  already has `Y` events checks `attribute_not_exists(pos#X)` — true even though `pos#Y` exists —
  so it is **not** falsely blocked (the exact case the `create#` row was protecting, now handled
  by the per-type attribute).
- `create#…` rows are **no longer written**. Existing rows on alpha are orphaned and wiped with
  the fence-row wipe (Deploy / data). One row kind fewer, one fewer transaction item at create.

## Implementation sketch

All in
[`DcbEventLogStorage_DynamoDb_Runtime.res`](../../../reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res):

1. **Attribute helper** — `fenceTypeAttr = (eventType) => "pos#" ++ eventType`.
2. **`buildConditionalFenceUpdate`** → take the clause's consumed `eventTypes`, the **produced**
   event types this append bumps for that tag, and `~after`. Emit:
   - `updateExpression: "SET " ++ producedTypes->map(SET #posP = :newP) joined`
     (one `:new`/name pair per produced type; in practice usually one),
   - `conditionExpression:` the AND over the **guard set** of per-type clauses:
     - at `after=Some`, guard set = consumed types; clause = `(attribute_not_exists(#posCi) OR #posCi <= :after)`.
     - at `after=None`, guard set = **consumed types ∪ produced types**; clause =
       `attribute_not_exists(#posT)`. The produced-type members are the folded create guard
       (see Design) — never drop them.
3. **`buildFenceConditionCheck`** (read-only, non-partition single tags kept from Issue 1) →
   same consumed-type AND condition, no bump. (No produced types here — a `ConditionCheck` tag is
   one the append does not write, so there is no create race to guard.)
4. **`buildUnconditionalFenceUpdate`** (`appendUnconditional` seed/replay + bump items) →
   `SET #posP = :new` per produced type carried by the event (partition tags only, per Issue 1 /
   Issue 9). No condition — seeding is the no-OCC path.
5. **Delete `buildCreateGuardUpdate` + the `createGuardId`/`createGuardSortKey` helpers and the
   `after=None` create-guard branch** of `buildConditionalTransactItems`. Their role moves into
   the partition-tag fence's `after=None` conditional Update (step 2). No more `create#` items.
6. **`buildConditionalTransactItems`** — thread each clause's `qi.eventTypes` into the
   update/check builders, and pass `events`' produced types (grouped by partition tag value)
   into the partition-tag bumps. The partition-tag / cross-partition / composite
   **classification stays exactly as today** (Issue 1 rules); what changes is (a) the
   *expression contents* gain event-type scoping and (b) the partition tag at `after=None` is now
   a conditional Update (folded guard) rather than an unconditional bump + separate `create#` row.
7. **`fromItem` / read path** — unchanged. Fences are write-side only; reads never touch them.
   The `pos#` attributes live on `fence#` items which event reads already exclude
   (`attribute_exists(event)` scan guard, base-table/GSI partition reads skip `fence#` ids).

### Interactions to verify

- **Composite (multi-tag) clauses** — keep current check+bump on each composite tag, but scope
  the condition to the clause's `eventTypes` for consistency. Audit: only `RecordProductDemand`
  (online-shop-dcb) uses a composite read; its event tags == query tags, single produced type —
  so per-type scoping is a no-op for it. Confirm before shipping.
- **Cross-partition (`@crossPartition`) tags** — every carrier bumps the fence (Issue 13).
  With per-type attributes, a carrier bumps `pos#<its produced type>`; a cross-partition reader
  checks its consumed types. Verify the course-subscription shape still conflicts correctly.

## Test plan

1. **Unit (transaction shape)** — extend
   [`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res):
   - `ChangeProductName` append (consumed `[ProductAdded, ProductNameChanged]`, produced
     `ProductNameChanged`) emits a fence Update whose condition references **only**
     `pos#ProductAdded` and `pos#ProductNameChanged` (never `pos#ProductPriceChanged`), and
     bumps **only** `pos#ProductNameChanged`.
   - **Folded create guard:** at `after=None`, the partition-tag item is a conditional `Update`
     gated on `attribute_not_exists(pos#<type>)` for the **consumed ∪ produced** type set, and
     **no `create#…` item is emitted**. Rewrite the existing `create#` test block accordingly.
   - **Produced-not-consumed guard (the con #1 gate — REQUIRED):** a slice that produces a type
     it does not consume, at `after=None`, still emits `attribute_not_exists(pos#<producedType>)`
     in the fence condition. Red→green: assert the produced type is present in the condition even
     though it is absent from the clause's `eventTypes`. This is the double-create hole the
     separate row made impossible — it must be covered before shipping the fold.
   - Composite clause keeps check+bump, scoped to its consumed type.
2. **Live DynamoDB integration** (the failing path; local backends don't use fences) — extend
   [`dcb-dynamodb-atomic-append-integration-test`](dcb-dynamodb-atomic-append-integration-test.md):
   - Create product `P`; change **price**, then change **name** → **Ok** (currently the
     permanent `Conflict`). Regression guard for this bug.
   - Interleave name/description/price changes in any order → all Ok; the entity never wedges.
   - Two concurrent `ChangeProductName` for the same `P` → exactly one Ok, one retries/conflicts
     (genuine same-type OCC preserved).
   - **Folded-guard create race:** two concurrent first-writers of the same `(producedType,
     partition)` → exactly one Ok, one conflicts (replaces the old `create#`-row create-race
     scenario). Plus the subset-type case: a first-write of type `X` on a partition that already
     has type `Y` events is **not** false-conflicted.
3. **GWT** — no fence assertions (adapter-level); existing `_GWT` decide coverage unchanged.
   Keep example tests `_GWT`-only per repo convention.
4. **Zero-warning build** + `pnpm test` across `reventless-aws` and dependents. PPX/ppx-binary:
   no schema-shape change, so no reventless-ppx republish needed.

## Deploy / data

- **Alpha sentinel-row wipe** of the Catalog DCB table after the fixed Lambda lands — old
  `fence#*` rows carry the scalar `lastPosition` from the current behaviour (the new code reads
  `pos#*`), and old `create#*` rows are now orphaned (the guard is folded into the fence). Wipe
  **both** prefixes (BatchWriteItem on `fence#*` and `create#*` ids) to avoid stale-scalar
  interplay and leftover clutter. Note the fence-scope-alignment plan already flagged "Catalog
  DCB tables not wiped yet" — fold all wipes into the same `pulumi up` follow-up.
- Same partition-scoped semantics must be reflected in the **local** backends?
  No — `DcbEventLogStorage_InMemory`/`_Sqlite` are already correct (true query semantics); this
  fix only brings **DynamoDB up to** their behaviour.

## Documentation — talk pages to update

The explanatory ("talk") pages on the doc site describe the **scalar fence + separate create
guard** model; they must be rewritten to the **per-type fence with folded create guard**:

- [`packages/doc/docs-framework/internals/dcb-consistency-checks.md`](../../../packages/doc/docs-framework/internals/dcb-consistency-checks.md)
  — the primary page. Update **Stage 3 — The conditional append** (the fence item is now
  `pos#<eventType>` attributes, not a scalar `lastPosition`); the **"How each query tag becomes a
  fence item"** table (conditions are per-consumed-type AND-clauses); the **"When the read found
  nothing — creation guards"** subsection (rewrite: the guard is now `attribute_not_exists(pos#…)`
  on the partition fence, no `create#` row); and the worked-example fence tables. State the
  one-event-type-per-attribute deadlock (Issue 4) as the motivating example, and that this
  realigns DynamoDB with the local backends' true query semantics.
- [`packages/doc/docs-infrastructure/aws/adapters/dcbeventlog.md`](../../../packages/doc/docs-infrastructure/aws/adapters/dcbeventlog.md)
  — adapter-level description of the fence sentinels / create guard; same per-type + folded-guard
  rewrite.
- [`packages/doc/docs-framework/architecture/dcb.md`](../../../packages/doc/docs-framework/architecture/dcb.md)
  — check its fence references; update any that describe the scalar model.
- [`packages/doc/docs-infrastructure/local/adapters/dcbeventlog.md`](../../../packages/doc/docs-infrastructure/local/adapters/dcbeventlog.md)
  — the local backend is unchanged, but verify any AWS-vs-local contrast wording still matches
  (it should now read "AWS per-type fences mirror the local true-query semantics").
- Grep the rest of `packages/doc/` for `lastPosition`, `create#`, "creation guard", and
  "per-tag fence" so no stale scalar-model prose survives. No internal plan/phase/stage refs in
  published pages (repo convention).

## Cost — does this explode row count?

**No.** Event-type granularity is added as bounded extra **attributes** on the existing one
fence item per partition-tag value — not as new rows. The naive alternative (a separate
`fence#<key>:<value>#<eventType>` row per type) is what would explode both row count and
transaction-item count; the flattened-attribute design deliberately avoids it.

| Design | Fence rows | Items per append txn | WCU per fence op |
|---|---|---|---|
| Naive per-(tag, type) rows | × (event-types per partition) | × (consumed types per tag) — pushes the 100-item cap | unchanged |
| **Chosen: `pos#<type>` attributes** | **unchanged (1 per tag value)** | **unchanged (1 per tag)** | **unchanged** |

- **Row count** — identical. `fence#productId:P` stays one item; it carries
  `pos#ProductAdded`, `pos#ProductNameChanged`, … instead of a scalar `lastPosition`. The
  attribute count is **statically bounded** by the entity's event-type count (4 for Product)
  and cannot grow at runtime.
- **Write cost (WCU)** — unchanged. Writes meter per **1 KB of item size**, rounded up. A
  fence item with ~4 position strings is ~260 bytes → still **1 WRU (2 transactional)**, the
  same bucket as the scalar version. Crossing 1 KB would need hundreds of event types on one
  partition.
- **Transaction-item count (100-item cap, Issue 11)** — unchanged: still one fence item per
  partition tag in the `TransactWriteItems`. This is the reason for flattening over per-type
  rows.
- **Storage** — +a couple hundred bytes per fence item; a rounding error next to the
  append-only event log (which every `ALL` GSI re-stores forever).
- **Expressions** — the condition grows to an AND over the clause's consumed types (2–3), a
  longer expression *string*, not more WCU; far under the 4 KB expression limit.

Net delta ≈ zero: same rows, same WCU, same transaction size, trivially more bytes per fence
item — in exchange for correctness.

## Decisions

- **Create guard: folded into the fence** (2026-06-23). Per-type `attribute_not_exists(pos#…)`
  subsumes the separate `create#` rows; they are no longer written. Gated on the
  produced-not-consumed double-create test (Test plan #1). Drop `buildCreateGuardUpdate` and the
  `create#`/`CREATE` sentinel helpers.
- **Scalar `lastPosition`: dropped, not dual-written.** The alpha sentinel-row wipe makes a
  rollback hedge moot; carrying both would just be dead bytes and confusing prose.

## Open questions

- Confirm `RecordProductDemand` is the only composite-read slice (re-audit `reventless-core` +
  both example platforms) before applying per-type scoping to the composite branch.
