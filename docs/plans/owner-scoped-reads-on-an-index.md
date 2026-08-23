# Plan: `@owner` provisions an index, and the list door reads it

**Date:** 2026-08-23<br/>
**Status:** Not started. The defect that motivated it is already papered over —
[done/aws-scan-connection-cursor-roundtrip.md](done/aws-scan-connection-cursor-roundtrip.md)
shipped the read window on 2026-08-23, so a scoped list no longer serves blank
pages. This plan removes the reason the window was needed.<br/>
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
`Scan` from `_exempt`; retirement folds into that index's sort key; the two inert
warnings become accurate.

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

## Step 1 — derive the owner index in the PPX

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

`QueryDbStorage_DynamoDb.globalSecondaryIndexes` needs no change — it provisions
whatever configs it is handed. `attributes` (`:32`) does: with `subIdField = "id"`
it emits a second `{name: "id", type_: "S"}` and Pulumi rejects duplicate
attribute definitions. **Dedupe by name.**

Sqlite's local storage builds `json_extract` indexes from the same array and will
simply gain one, which is the correct outcome there too.

---

## Step 2 — the list resolver branches on `_exempt`

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

**Backward paging stays refused in this step.** A Query *can* page backward, but
the `{t, n}` cursor is DynamoDB's forward-only continuation token; real
`last`/`before` needs the keyset value cursor of Step 5. Keep the
`UnsupportedPagination` guard on both branches until then, so the door does not
advertise a capability the cursor cannot honour.

Residual, and worth stating in the resolver's own comment: a *user* filter still
lands in a FilterExpression on top of the key condition, so a scoped caller
searching their own rows can still get a short page. It is now bounded by their
row count, not the table's.

---

## Step 3 — fold retirement into the same key

`@retired` degrades the same way and reuses the same index. Make the derived
index's sort key a composite `<liveFlag>#<sortField>#<id>`, so "live rows of
owner X, ordered by f" becomes `#pk = :owner AND begins_with(#sk, '0#')` — still a
key condition, still an exact page. The elevated `includeRetired: true` path
drops the `begins_with` and reads the whole partition.

`QueryDb_Operations.injectCompositeIndexAttrs` (`:49`) already writes synthetic
composite attributes from `skFields`, so the mechanism exists — but it
concatenates *raw string fields*, and the live flag is a derived value (a boolean
field inverted, or a state name tested against the retiring set). That is the new
part: a computed component in a composite key, not a copied one.

The sparse-index alternative — write a `_live` attribute only on non-retired rows
and let the GSI omit the rest — is cheaper and cannot serve `includeRetired` at
all, so it would need the Scan back as its archive path. Prefer the composite.

Do this **after** Step 2 is verified, not with it: it changes the key schema of an
index that will by then hold data, and the two failures would be
indistinguishable.

---

## Step 4 — make the warnings true

After Steps 1–3 the `isIndexed` check goes quiet by construction for every view
that did not opt out. What is left to write is the honest form of both warnings:

- The owner warning fires only for `@owner({index: false})`, and should say what
  that costs rather than prescribing an `@index` that is now redundant.
- The retirement warning names the composite key, not a separate `@index`.
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

Pull this when a client actually asks the server to page backward. Until then the
client-side cursor trail is adequate, and the path tag from Step 2 is what makes
adding a third cursor shape safe later.

---

## Backfill and migration

A GSI indexes only rows carrying both key attributes, so **existing rows are
invisible to the derived index until they are rewritten.** This is the whole
correctness risk in the plan: after Step 2 a scoped caller reads the index, and
an un-backfilled row is not "slow", it is *absent*.

- On alpha, the standing convention applies — wipe and replay the projection.
- Anywhere with real data, a touch-pass over the table is required **before** the
  resolver branch is deployed. Deploy Step 1 (provisioning), backfill, *then*
  Step 2 (routing). They must not ship in one release.
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
