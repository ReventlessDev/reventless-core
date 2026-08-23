# Plan: `@owner` provisions an index, and the list door reads it

**Date:** 2026-08-23<br/>
**Status:** Steps 1, 2 and 4 are **done** (2026-08-23) — the index is derived,
the list resolver branches on it, and both warnings say something true. Step 3
was extracted to
[Backlog/retirement-folded-into-the-owner-index.md](Backlog/retirement-folded-into-the-owner-index.md):
no spec in the repo declares `@owner` and `@retired` together, so it has no
beneficiary yet. Step 5 is deferred by design. Remaining before this closes:
Acceptance 1, 2 and 4, which need an authenticated call against the deployed API.

**Verified on alpha 2026-08-23**, deploy `4b643e1f1`: the `_owner` GSI is
`ACTIVE` on `Orders-10f6a39` with the `ALL` projection; all 151 pre-existing rows
answer through it (DynamoDB backfilled them on index creation — **no reseed
needed**, and the *Backfill and migration* section below is corrected
accordingly); the deployed resolver carries the Query branch, the cursor path
tag and the sort skip; and no `@owner … keys no index` warning appears in the
deploy log. Cost: one 522s `UpdateTable`, one-time. Still unverified end-to-end
through an authenticated GraphQL call — Acceptance 1, 2 and 4.<br/>
**Relates to:**
- [done/aws-scan-connection-cursor-roundtrip.md](done/aws-scan-connection-cursor-roundtrip.md)
  — the window, and the `{t, n}` cursor this plan must keep compatible.
- [Backlog/aws-fulllist-ordered-index-promotion.md](Backlog/aws-fulllist-ordered-index-promotion.md)
  — the *elevated* half of the same problem (constant-PK GSI, whole-table ordering).
  Stays backlogged; shares the cursor path-tag and the keyset-cursor design below.
- [owner-enforcement-gaps-on-appsync.md](owner-enforcement-gaps-on-appsync.md) —
  where `ownerField` is resolved and which doors consume it.
- [active-role-narrows-the-token.md](active-role-narrows-the-token.md) — a
  narrowed token changes `_exempt`, which after this plan selects a *different
  physical read*, not just a different predicate.
- [Backlog/denied-query-returns-empty.md](Backlog/denied-query-returns-empty.md),
  [../analysis/autoui-list-ordering-and-filtering.md](../analysis/autoui-list-ordering-and-filtering.md).

---

## The finding

`QueryDbResolvers_AppSync.res` warns, at deploy time, that an `@owner` field
which is not the key of an index will make owner-scoped reads Scan and filter,
and it tells the author to add an `@index` on that field.

**Following the warning changes nothing.** `@index` provisions a GSI and emits a
*separate* SDL door (`indexQueryFieldName` → `<single>By<Index>`); the list
resolver is built unconditionally from `listAllItemsConnection`
(`QueryDbResolvers_AppSync.res:335-353`), which has no index branch, and no
generated client calls the by-index door. The author pays an index write per
projection write and the warned-about Scan continues untouched. The `@retired`
warning a few lines below has the same gap.

That is the thing to fix: not the pages, which the window already fixed, but the
fact that the most frequent read in any deployed application — *the rows that
belong to me* — is served by a table Scan with an authorization predicate bolted
on as a post-read sieve.

**Why it is a sieve and not a key.** `listAllItemsConnection` builds one
FilterExpression out of four sources that share nothing but a destination: the
`@owner` narrowing, the `@retired` narrowing, `requireAttribute`, and the
caller's own `filter` argument. Only the last is a per-request predicate. The
first three are invariants fully known at deploy time — the resolver is generated
knowing the owner field's name, the retirement field and its retiring states, and
the required attribute. An invariant known at deploy time belongs in the key.

The arithmetic the window hides: for a table of *N* rows where the caller owns
*k*, a `Limit = first` read returns `first × k/N` rows. The window makes that
`min(k_in_window, first)` at a cost of up to 1 MB read per page. Both are
O(table). A Query on an owner-partitioned index is O(the caller's rows).

The pattern to generalise is already in the repo: an `@index({group, authTable})`
routes assignment-scoped reads to their own GSI Query through
`authorizeIndexedAccess`, and it is the one access shape of the three that does
not degrade.

---

## Scope

**In:** `@owner` provisions a GSI; the generated list resolver picks `Query` or
`Scan` from `_exempt`; the two inert warnings become accurate. (Retirement
folding into that index's sort key was in scope and moved out — see Step 3.)

**Out, deliberately:**
- The **constant-PK ordered GSI** for elevated whole-table lists — that is
  [Backlog/aws-fulllist-ordered-index-promotion.md](Backlog/aws-fulllist-ordered-index-promotion.md),
  and it is the case DynamoDB is worst at (single-partition GSI, throttles on
  exactly the write-hot tables that need it) *and* the rarest query. Do not pull
  it in.
- **Partitioning the base table by owner** (`@id customerId` + `@subId orderId`).
  Cheapest at runtime, most invasive at design time, and it needs client work
  this plan does not: the generated list door is what AutoUI calls, not the
  sub-id connection. It is modelling guidance, not framework work.
- **A Postgres QueryDb read path.** `QueryEnginePostgres.res` already pushes
  owner and retirement scope into the `WHERE` before the `LIMIT` and gets every
  combination right; that is a backend decision on its own merits
  ([aws-postgres-rds-adapter.md](aws-postgres-rds-adapter.md)), not a fix for
  this.

---

## Step 1 — derive the owner index in the PPX ✅ done

`collect_index_configs` (`packages/reventless-ppx/src/ppx/StateAnnotations.ml:762`)
is the single place index configs are built from field annotations, and
`generate_config` calls it for every `@schema` state record. Add a derived config
there when the record carries an `@owner` field:

| Property | Value | Why |
|---|---|---|
| `index` | `_owner` | Leading underscore is already the synthetic-attribute convention (`_<name>_pk` / `_<name>_sk`); it cannot collide with an author's index name, which comes from a string payload. |
| `idField` | the `@owner` field | The partition key. One field — the resolvers already take `Owner.fieldNames(...)->Array.get(0)`. |
| `type_` | `infer_dynamo_type` of that field | Same call the named-index path makes. |
| `subIdField` | the `@subId` / `@compositeSubId` field if the record declares one, else `id` | Gives the caller's rows a total, stable order and a keyset cursor that matches the in-memory and Postgres tiebreak. |
| `projectionType` | `ALL` | See below. |
| `derived` | `true` (new field on `indexConfig`) | Marks it as carrying no SDL door. |

**Suppress the config when the owner field already carries an `@index`** — the
author's index wins, and its name is what the resolver must then target.

**`projectionType: ALL`, not `INCLUDE`.** A narrow projection over the `@summary`
fields is the obvious cost mitigation and it is wrong here: a DynamoDB filter
expression on a GSI can only reference *projected* attributes, and the list door
pushes the caller's `filter`, `requireAttribute` and the retirement predicate
down as filters over arbitrary columns. Worse, the connection returns the row
itself, so a non-projected attribute comes back missing and resolves a non-null
SDL field to null — the failure `requireAttribute` exists to prevent. Narrowing
the projection is a per-view opt-in for later (Open decisions), not the default.

**Opt-out, not opt-in.** Today the safe thing requires an annotation nobody knows
to write. Invert it: derive by default, and let a view known to be small decline
with `@owner({index: false})`. `get_index_options` already parses a record
payload; `@owner`'s payload parsing is the new part.

**A new `derived` flag has three consumers to teach:**
- `GraphQL_FragmentGenerator.res:906` — skip derived configs when emitting
  `<single>By<Index>` fields. A door keyed on `customerId` that any caller may
  name is noise at best; the SDL must not grow one per view.
- `Platform.res:1429` (local) — skip them in `registerAdminItemsAndIndexResolvers`
  for the same reason.
- `QueryDbResolvers_AppSync.res:354` — skip them in `resolversByIndex`; this plan's
  Step 2 is the only thing that reads the derived index.
- **A fourth, found while doing it:** `QueryDbResolvers_GraphQL.res:795` emits the
  by-index SDL fields *and* their resolvers for the local backend. Left alone it
  would have put a door in the local SDL that the deployed one does not have —
  the divergence the shared `deriveIndexQueryField` exists to prevent. The filter
  is `Reventless.ReadModel.isDerivedIndex`, applied in all four places.

`QueryDbStorage_DynamoDb.globalSecondaryIndexes` needs no change — it provisions
whatever configs it is handed. `attributes` (`:32`) does: with `subIdField = "id"`
it emits a second `{name: "id", type_: "S"}` and Pulumi rejects duplicate
attribute definitions. **Dedupe by name.**

Sqlite's local storage builds `json_extract` indexes from the same array and will
simply gain one, which is the correct outcome there too.

---

## Step 2 — the list resolver branches on `_exempt` ✅ done

In `listAllItemsConnection` (`AppSync_Resolver_Functions.res:799`) the owner
clause currently computes `_exempt` inline and pushes `#owner = :owner` into
`parts`. Lift the identity preamble to the top of `request` and choose the
operation from it:

```js
const req = _exempt
  ? { operation: 'Scan',  limit: _budget, nextToken: _window }
  : { operation: 'Query', index: '_owner',
      query: { expression: '#owner = :owner', expressionNames: { '#owner': '<field>' },
               expressionValues: { ':owner': util.dynamodb.toDynamoDB(_sub) } },
      limit: _budget, nextToken: _window,
      scanIndexForward: !_descending };
```

Both target the same DynamoDB data source, so this is one branch inside one
resolver: **no second field, no second data source, no client change.**

Four things have to move with it:

1. **The window budget stops applying to the owner predicate.**
   `pageWindowBudget(~filtered="parts.length > 0")` exists because a filter cuts
   rows after `Limit`. On the Query branch the owner predicate is a *key
   condition*, so `filtered` must be computed from the parts that remain —
   retirement (until Step 3), `requireAttribute`, and the caller's `filter`. With
   none of those, `limit = _first + _from` and a page is exactly `first` rows.
2. **The identity preamble must keep its branch order.** Provider-first: an
   IAM-signed service caller has no `sub` for a reason that has nothing to do
   with being anonymous, and lands on the Scan branch as it does today.
3. **Cursor path tagging.** The `{t, n}` cursor shape survives — an AppSync
   `Query` returns a `nextToken` the same way a `Scan` does, and
   `connectionPageResponse` is unchanged. But a token minted on one branch is not
   valid on the other, and the two branches are now selectable *by the same
   caller* across requests: an active-role switch mid-pagination flips
   `_exempt`. Tag the cursor with its path and refuse a mismatch with a named
   error rather than silently answering a different question. Use the same
   one-byte discriminator
   [Backlog/aws-fulllist-ordered-index-promotion.md](Backlog/aws-fulllist-ordered-index-promotion.md)
   specifies, so the two plans do not mint incompatible tags.
4. **`orderBy` on the Query branch.** When `orderBy.field` is the derived index's
   sort key, `scanIndexForward` orders globally across the caller's rows and the
   schwartzian JS sort must be skipped — sorting a page that is already ordered is
   the one way to *break* the order. Any other sort field keeps the per-window JS
   sort, which is now a sort over the caller's own rows rather than an arbitrary
   window of the table.

**Backward paging was refused in this step, and no longer is** (2026-08-23, after
a Prev button on a deployed list turned out to be a live error). The `{t, n}`
cursor names a position *inside* a window, and a window is re-read from its own
token — which forward paging already relies on to resume mid-window. Backward is
the same move reversed: re-read the window `before` names and cut `[n - first, n)`.
That needs no keyset cursor and no index, and works on both branches unchanged
because it never touches the operation. What Step 5 still buys is the part this
cannot do — see **The window boundary** below.

Residual, and worth stating in the resolver's own comment: a *user* filter still
lands in a FilterExpression on top of the key condition, so a scoped caller
searching their own rows can still get a short page. It is now bounded by their
row count, not the table's.

---

## Step 3 — fold retirement into the same key → Backlog

Extracted whole to
[Backlog/retirement-folded-into-the-owner-index.md](Backlog/retirement-folded-into-the-owner-index.md)
on 2026-08-23, on a finding this plan did not anticipate: **no spec in the repo
declares `@owner` and `@retired` together**, and this step only does anything for
one that does.

`@owner` is on `Orders` alone, which does not retire; `@retired` is on
`Categories`, `Products`, `AvailableProducts` and `Customers`, none of which is
owned. So the step would have added a computed composite-key mechanism, an index
replacement and a mandatory projection replay, exercised by tests alone — and
would have silenced none of the three retirement warnings the alpha deploy
emits, because all three are on unowned views.

The limit is structural, not accidental: a retirement flag has two or three
values, which makes it a poor partition key on its own and useful only as the
leading component of a sort key inside a partition something else supplies.
`@owner` is what supplies one. A retired view with no owner is the constant-PK
problem in
[Backlog/aws-fulllist-ordered-index-promotion.md](Backlog/aws-fulllist-ordered-index-promotion.md),
not this one.

---

## Step 4 — make the warnings true ✅ done

The `isIndexed` check goes quiet by construction for every owned view that did not
opt out. Both warnings now say something true:

- **The owner warning** fires only for `@owner({index: false})`, and states what
  that costs instead of prescribing an `@index` that is now redundant.
- **The retirement warning** no longer says "add an `@index` on that field". That
  was the same defect the owner warning had, and worse advice here: a GSI
  partitioned on a two- or three-valued flag funnels the table through one
  partition, and the list door reads neither it nor the by-index door it
  provisions. It now states the cost and splits on whether the view is owned —
  naming the fold for a view that has a partition to fold into, and saying
  plainly that no index helps for one that does not.
- It fires **whatever the field keys**, unlike the owner check. An `@index` on a
  retirement field does not make this read cheaper, so suppressing on one would
  silence a cost still being paid. `@scan` does not satisfy it either.
- `warnIfNoElevatedGroups` is unaffected.

This step is what closes the finding. It is listed last because a warning
rewritten before the routing exists would be the same defect in the other
direction.

---

## Step 5 — backward paging on the owner Query (deferred, but designed here)

`queryItemsWithSortConditions` already proves the pattern within one partition:
`isBackward` → `#sk < :cursor` → `scanIndexForward` flip → `reverse()`, with a
base64 keyset **value** cursor and the `+1` overshoot for
`hasNextPage`/`hasPreviousPage`. The derived owner index is a partition pinned by
`_sub` with a totally-ordered sort key, which is precisely that shape.

Most of what this was for shipped without it: `before` is served today by
re-reading its window. What is left is the window boundary, and real `last`.

### The window boundary — the residual, and what each fix costs

A page is a slice of a **window**, and windows chain one way: the token that opens
W1 comes from reading W0, and from W1 there is no way back to W0. So a previous
page that begins in an earlier window is unreachable, and `hasPreviousPage` says
so rather than promising it.

**It is a scaling limit, not a live defect.** A window ends at DynamoDB's 1 MB
page or the read budget (1000 examined rows when a filter is pushed down; the
budget grows with the page otherwise). Measured on alpha 2026-08-23: Products 64
rows / 18 KB, Orders 151 / 29 KB, Customers 23, Categories 8 — every view fits in
one window, `t` stays null, and Prev already reaches page 1 from anywhere. At
Products' ~283 bytes/row the boundary is ~3,700 rows unfiltered, or 1,000 examined
rows with a filter.

Three ways to close it, when a view gets there:

1. **Client-side cursor trail** (host shell). The client walked forward through
   those windows and holds every token; Prev pops the stack and re-issues a plain
   forward `first`/`after`. Complete, unbounded, every backend and every door, no
   server or schema change. The trail is client state, so a pasted deep link or a
   reload wants it persisted in the URL or session storage. **The only
   proportionate fix for an UNOWNED view**, which is the case that will hit this
   first.
2. **A back-pointer in the cursor** — `{t, n, b}` with `b` the previous window's
   token, which the server does know at the moment it closes a window.
   **Rejected:** it reaches exactly one window back. Serving from `b`, the server
   no longer knows what preceded `b`, so the chain breaks after one hop, and the
   general form is a *stack* of hundreds-of-bytes tokens carried in the cursor and
   growing linearly with paging depth — option 1 relocated, and worse.
3. **This step** (keyset over an ordered key) — exact, unbounded, and it delivers
   real `last` as a side effect. Small for an **owned** view: the index and its
   total sort key exist, and the sibling above is a working implementation to
   copy. For an unowned view it needs a partition to Query, which is
   [Backlog/aws-fulllist-ordered-index-promotion.md](Backlog/aws-fulllist-ordered-index-promotion.md)
   — the big one, and the case DynamoDB is worst at.

**Decision (2026-08-23): do nothing yet.** The boundary is thousands of rows away
on every view here and the door no longer lies about it. When one approaches it,
take 1 for unowned views and 3 for owned ones. Pull this step independently if
real `last`/`before` is ever wanted on an owned view — it is cheap there, and the
Step 2 path tag is what makes adding a third cursor shape safe.

---

## Backfill and migration

**Corrected 2026-08-23, against the alpha deploy.** This section originally said
existing rows were invisible to the derived index "until they are rewritten", and
required Steps 1 and 2 to ship in separate releases with a touch-pass between.
That is **wrong for this index** and right only for Step 3's. Both halves matter,
so both are stated:

**Steps 1–2 need no backfill.** `UpdateTable` adding a GSI makes DynamoDB
populate it from the existing items that carry its key attributes — the copy is
part of the index reaching `ACTIVE`, not something the projection has to
re-drive. Both of this index's keys pre-exist on every row: the `@owner` field,
because the view already declared it, and `id`, because it is the table's own
partition key. Measured on `Orders-10f6a39` (151 rows, 23 owners): the index came
back `ACTIVE` with `Backfilling` absent, and a `Query` on it returned every row
the table scan did, with the full `ALL` projection. The two steps therefore ship
together safely, which is what this repo did.

**Step 3 does need one.** Its composite sort key `<liveFlag>#<sortField>#<id>` is
a *synthetic attribute written at projection time* by
`injectCompositeIndexAttrs`. No existing row carries it, so no existing row
enters that index at creation, and there is nothing for DynamoDB to copy. That is
the case the original wording describes: an un-backfilled row is not slow, it is
*absent*. Replay the projection (or touch-pass the table) **before** the read
that depends on the new key goes live — and note Step 3 also *replaces* the
index, so it pays the creation latency below a second time.

The general rule the two cases share: **a derived index needs a backfill exactly
when it keys on an attribute the projection did not already write.**

- **Creating the index is slow, and it is a one-time cost.** Measured: `~
  aws:dynamodb:Table Orders updated (522s) [diff: +globalSecondaryIndexes
  ~attributes]` — 8m42s on a 151-row table, taking the ordering plugin's deploy
  from 186s to 759s. It is control-plane latency, not row volume; Pulumi's
  `aws:dynamodb:Table` blocks until the index is `ACTIVE`. Subsequent deploys see
  no diff on the table. Budget it once per table that newly gains the index —
  concurrent across *different* tables, so N tables cost roughly one wait, not N.
- Adding a GSI is an in-place `UpdateTable`, not a table replacement, so it does
  not collide with
  [Backlog/dynamodb-key-schema-migration.md](Backlog/dynamodb-key-schema-migration.md).
  DynamoDB creates one index at a time per table; a deploy that adds the derived
  index to many tables is fine (one each), a deploy that also changes another
  index on the *same* table is not.
- **Sparse by construction is a property, not a hazard**: a row with no owner
  attribute is absent from the index, which is exactly what `#owner = :owner`
  answers today.
- **Check the owner field's cardinality before trusting this.** An owner-keyed
  GSI is well distributed when owners are users. It is a hot partition when one
  "owner" is a tenant holding most of the estate.

---

## Files

- `packages/reventless-ppx/src/ppx/StateAnnotations.ml` — `collect_index_configs`
  (derive), `@owner` payload parsing (opt-out).
- `reventless/spec/src/components/ReadModel.res` — `derived` on `indexConfig`.
- `reventless/core/src/components/Api/GraphQL_FragmentGenerator.res` — skip
  derived configs when emitting by-index doors.
- `reventless/core/src/components/QueryDb/QueryDb_Operations.res` — computed
  live-flag component in the composite sort key (Step 3).
- `rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` —
  `listAllItemsConnection` operation branch, budget, cursor tag, sort skip.
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — pass the
  derived index name to the list resolver; skip it in `resolversByIndex`; rewrite
  both warnings.
- `reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb.res` — dedupe
  `attributes` by name.
- `reventless/local/src/Platform.res` — skip derived configs in
  `registerAdminItemsAndIndexResolvers`.
- Reference, do not change: `queryItemsWithSortConditions` (the keyset pattern),
  `QueryEnginePostgres.res` (the push-down done right).

---

## Testing

1. **PPX codegen tripwires** — a state with `@owner` and no `@index` emits one
   derived config keyed on that field, with the `@subId` field as sort key when
   one exists and `id` when none does; `@owner({index: false})` emits none; an
   `@owner` field that already carries `@index` emits exactly one config, the
   author's.
2. **SDL tripwire** — the derived index adds **no** query field. This is the
   regression that would otherwise land silently: a `<single>By<Owner>` door
   appearing in a published SDL is a schema change nobody asked for.
3. **Table-config test**, mirroring `QueryDbGsiTtlTest.res` — the derived GSI is
   provisioned with `ALL` projection, and `attributes` carries no duplicate name
   when the sort key is `id`.
4. **Resolver eval round-trip**, mirroring `QueryDbListResolverTest.res` and the
   fixtures in `AppSync_RetirementNarrowingTest.res` — evaluate the generated
   request/response against a mock `util`:
   - scoped caller → `operation: 'Query'`, `index: '_owner'`, key condition on
     the owner value, **no** owner clause in any FilterExpression;
   - elevated caller and the IAM identity with no `sub` → `operation: 'Scan'`,
     byte-identical to today;
   - a scoped caller with no user filter gets `limit === first + _from`, not the
     1000-row window;
   - a cursor minted on the Scan branch, replayed on the Query branch, is
     **refused** by the path tag;
   - `orderBy` on the index sort key sets `scanIndexForward` and leaves items
     untouched; `orderBy` on any other field still sorts in JS.
5. **Owner-scoping conformance** — extend the existing (identity, view, expected
   rows) table rather than adding a parallel one, and assert it passes on both
   branches. The defect class this plan is closest to
   ([owner-enforcement-gaps-on-appsync.md](owner-enforcement-gaps-on-appsync.md))
   was invisible precisely because each path was individually correct.

---

## Acceptance

Against a deployed stack, not only in-process.

1. A scoped caller owning 1 of several hundred rows lists the view with
   `first: 50` and receives 1 row on page 1, `hasNextPage: false`, and no blank
   page anywhere in the sequence.
2. The same read's CloudWatch consumed-capacity for that request is proportional
   to the caller's rows, not to the table — measurably below the same read taken
   before the change on the same data.
3. An elevated caller's list is unchanged in shape, order and cost.
4. A caller who switches active role mid-pagination gets a named cursor error,
   not a page from the other branch.
5. A row written before the index existed is returned by the scoped list after
   the backfill, and — verified deliberately, because it is the failure mode —
   is **absent** before it. The order of those two observations is the test.
6. Deploy logs carry no `@owner … is not the key of any index` warning for any
   view that did not opt out.

---

## Open decisions

- **Narrow projections.** `ALL` is the safe default; a per-view
  `@owner({projection: "INCLUDE"})` over the `@summary` fields would cut the
  write amplification, but only for a view whose filter surface and selection set
  both stay inside the projection. Is that checkable at deploy time from the
  capability the generator already derives? If it is, the opt-in is safe; if it
  is not, do not offer it.
- **Sort key when the view declares no `@subId`.** `id` gives a total order and a
  stable cursor. Whether that order is *useful* to a reader is a different
  question, and a `@ownerSort` field-level marker may be the better answer than
  defaulting to `id` forever.
- **Does active-role narrowing change which rows a scoped read returns?** A
  narrowed token carries one group, so a multi-role admin acting as an ordinary
  user is correctly non-exempt. Unverified against a live pool, and it matters
  more after this plan than before it: exemption now selects a physical read.
  Confirm before Step 2 ships.
- **Can the warning be made quantitative?** It knows the annotations; it does not
  know the row count. A view small enough for a Scan is a real case, and neither
  the deploy nor the author can currently tell which one they have.
