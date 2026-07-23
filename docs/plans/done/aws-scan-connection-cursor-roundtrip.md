# Plan: Fix the AWS Scan connection cursor round-trip

**Date:** 2026-07-23

**Status:** Done (2026-07-23). Fixes 1–3 (Scan cursor round-trip, backward-paging
guard, empty/short-filtered-page boundary cursor) and Fix 4's interim warning shipped
to `listAllItemsConnection` and `validateScanSortAlignment`; all packages build
warning-free and the resolver tripwire + warning tests are green. The durable form of
Fix 4 (index promotion) is tracked separately in
[../Backlog/aws-fulllist-ordered-index-promotion.md](../Backlog/aws-fulllist-ordered-index-promotion.md).
A downstream consumer's interim `first: 1000` stopgap can now be dropped.

**Relates to:**
- [relay-server-compliance.md](relay-server-compliance.md) — introduced
  the Relay connection shape and **specified the intended cursor** at line 198:
  `base64(JSON.stringify({ nextToken, index }))`. The implementation made the
  cursor opaque but stopped embedding the DynamoDB token — that regression is this
  bug.
- [../../analysis/autoui-list-ordering-and-filtering.md](../../analysis/autoui-list-ordering-and-filtering.md)
  — documents the cross-backend cursor contract ("AWS encodes DynamoDB's
  `LastEvaluatedKey`"), which the current Scan resolver violates, plus the
  pre-existing per-page-only sort caveat.
- [appsync-listallitems-sort-runtime-compat.md](appsync-listallitems-sort-runtime-compat.md)
  — the APPSYNC_JS 1.0.0 runtime constraints that shape the generated resolver.

---

## Goal

Make the DynamoDB/AppSync full-list connection resolver
(`listAllItemsConnection`) paginate correctly: a client that reads `pageInfo.endCursor`
and passes it back as `after` must receive the **next** page, not a
`DynamoDBException: Invalid pagination token` error. The cursor the resolver emits
and the token its own request side consumes must be the **same** value.

Today they are not. This is a correctness regression on a Relay connection: every
list past the first DynamoDB Scan page is unreachable through the documented
`first`/`after` contract.

While fixing the cursor, three adjacent paging defects on the same resolver came to
light — backward args (`last`/`before`) advertised but ignored, filtered pages that
stall a resuming client, and per-page-only ordering. This plan folds durable or
honest fixes for all four into one change set (see the table under **The fix**); the
cursor round-trip is the centrepiece, the rest close the remaining gaps between what
the connection's SDL promises and what it delivers.

---

## Background — the smoking gun

The generated resolver is
`rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`, function
`listAllItemsConnection` (line 428). Its request and response disagree about what a
cursor is.

**Request** ([line 532-536](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L532))
feeds the client's `after` straight to DynamoDB as the Scan continuation token:

```js
const req = {
  operation: 'Scan',
  limit: (ctx.args.first ?? 50),
  nextToken: (ctx.args.after ?? null),   // expects `after` == a DynamoDB nextToken
};
```

In the AppSync JS DynamoDB resolver, `nextToken` is the opaque base64 encoding of
`LastEvaluatedKey`. So the request side is correct: it assumes `after` carries a
real DynamoDB token.

**Response** ([line 546-562](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L546))
builds the cursor as a synthetic **index string** and throws the real token away:

```js
const edges = items.map((item, i) => ({
  node: item,
  cursor: ctx.args.after ? ctx.args.after + '_' + i : '' + i,   // "0","1",… or "<after>_5"
}));
return {
  edges,
  pageInfo: {
    hasNextPage: !!ctx.result?.nextToken,                       // reads the real token — but only as a boolean
    hasPreviousPage: !!ctx.args.after,
    startCursor: edges.length > 0 ? edges[0].cursor : null,
    endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : null,  // the index — NOT ctx.result.nextToken
  },
};
```

The round-trip:

1. Client reads `endCursor` → gets an index like `"49"` (or `"49_3"` on later pages).
2. Client sends it back as `after`.
3. Request sets DynamoDB `nextToken: "49"`.
4. DynamoDB rejects `"49"` as an **Invalid pagination token**.

`ctx.result.nextToken` — the value the request side needs — is consumed only as a
boolean for `hasNextPage`, and its actual bytes are discarded. That is the entire
bug.

### Why it stayed latent

`limit: ctx.args.first ?? 50` caps a single Scan page. As long as a caller asked
for `first` ≥ the row count of the read model, all rows arrived in **one** page,
`hasNextPage` was `false`, and nobody ever needed to send `after` back. The bug
only bites when the result set exceeds one requested page and the client tries to
continue — exactly what the Relay `first`/`after` contract promises but this
resolver cannot honour.

### This resolver diverges from the correct pattern that already exists

Three implementations sit behind the same connection contract; only this one is
wrong.

| Path | Implementation | Cursor | Round-trips? |
|------|----------------|--------|-------------|
| Local read-model list | `reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` → shared `QueryDbListQuery.run` | base64 **value** cursor | ✅ |
| AWS Postgres list | `reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res` → `QueryEnginePostgres` → shared `QueryDbListQuery` | base64 **value** cursor | ✅ |
| AWS DynamoDB `{single}Items` (sort-key connection) | `AppSync_Resolver_Functions.res::queryItemsWithSortConditions` (line 122) | `util.base64Encode(skValue)` | ✅ |
| **AWS DynamoDB full-list** | `AppSync_Resolver_Functions.res::listAllItemsConnection` (line 428) | **index string** | ❌ |

The shared source of truth for value-cursor semantics is
`reventless/core/src/components/Api/QueryDbListQuery.res` (`encodeCursor`/`decodeCursor`
= base64 of a value, `buildConnection`/`run`). The local and Postgres backends both
delegate to it. The sibling DynamoDB resolver `queryItemsWithSortConditions` shows
the correct value-cursor pattern on DynamoDB itself.

`listAllItemsConnection` can't use a **value** cursor the way its siblings do: it's
a full-table **Scan** with no sort key to key on, so it must round-trip DynamoDB's
own per-page continuation token (`LastEvaluatedKey` / `nextToken`) instead. It
correctly reaches for that token on the request side and then fails to emit it on
the response side.

---

## The fix

This plan addresses **four** paging defects on `listAllItemsConnection`. The first is
the original cursor regression; the next three surfaced while auditing whether the
connection honours the full GraphQL paging contract its SDL advertises.

| # | Defect | Symptom | Fix locus |
|---|--------|---------|-----------|
| 1 | Forward cursor thrown away | `after` → `Invalid pagination token` past page 1 | resolver response + request |
| 2 | Backward args advertised but ignored | `last`/`before` silently return the forward first page | resolver request (guard) |
| 3 | Filtered pages stall resume | empty/short page ⇒ `endCursor: null` while `hasNextPage: true` ⇒ client restarts page 1 | resolver response |
| 4 | Ordering is per-page only | `orderBy` over a multi-page list yields wrong global order | index promotion + honest warning |

Fixes 1–3 are self-contained edits to the generated `listAllItemsConnection` body and
ship together. Fix 4 cannot be corrected inside a Scan resolver; its durable form is a
separately-stageable Query-backed path, and its interim step is to make the existing
deploy-time warning tell the truth. A consolidated request/response body after Fixes
1–3 appears at the end of this section.

**Scope — Scan path only.** All four defects live on the full-list **Scan** resolver.
The sibling **Query** connection resolver `queryItemsWithSortConditions`
([line 122](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L122))
— which backs the sub-id connection field (`{single}Items(id, …)`), a different
GraphQL field from the full-list field — already satisfies all four: (1) it round-trips
a `base64(sortValue)` value cursor; (2) it implements `last`/`before` natively
(`scanIndexForward` flip + `reverse()`); (3) it filters via **key conditions**, not a
`FilterExpression`, so it never emits an empty-but-continuable page, and its keyset
cursor resumes across the 1 MB cap unaided; (4) it Queries a real sort key, so it is
globally ordered within its partition. Nothing in this change set touches it — it is
the reference, not a target. The two resolvers back distinct fields, so their cursor
formats never mix (the one place they would — Fix 4's ordered path on the full-list
field — carries the path-tag guard described there).

### Fix 1 — Forward cursor round-trip

Emit the page's DynamoDB continuation token as the cursor, and decode it back on
the request. This restores the design `relay-server-compliance.md` line 198 already
specified.

A Scan yields **one** continuation token per page (it resumes at page boundaries,
not per item), so all edges in a page share that forward token; an item index is
folded in purely to keep each edge cursor opaque and unique (Relay clients may
dedupe by cursor). Only the token is consumed on resume.

### Response — encode the real token

```js
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  let items = ctx.result?.items ?? [];${/* sortBlock unchanged */''}
  // One Scan continuation token per page; encode it (with the item's page index for
  // a unique, opaque Relay cursor). The request side decodes `.token` back to the raw
  // DynamoDB nextToken. On the final page `next` is null — the cursor stays opaque and
  // hasNextPage is false, so a well-behaved client never resumes from it.
  const next = ctx.result?.nextToken ?? null;
  const edges = items.map((item, i) => ({
    node: item,
    cursor: util.base64Encode(JSON.stringify({ token: next, index: i })),
  }));
  return {
    edges,
    pageInfo: {
      hasNextPage: !!next,
      hasPreviousPage: !!ctx.args.after,
      startCursor: edges.length > 0 ? edges[0].cursor : null,
      endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : null,
    },
  };
}
```

### Request — decode `after` back to the token

```js
let after = null;
if (ctx.args.after != null && ctx.args.after !== '') {
  const parsed = JSON.parse(util.base64Decode(ctx.args.after));
  after = parsed.token ?? null;
}
const req = {
  operation: 'Scan',
  limit: (ctx.args.first ?? 50),
  nextToken: after,
};
```

Now `endCursor` on page N encodes page N's forward token; the client returns it as
`after`; the request decodes `.token` and hands DynamoDB exactly the continuation
token it issued. Round-trip closed.

### Fix 2 — Backward pagination (`last` / `before`)

The full-list connection field advertises all four Relay args — `first, after, last,
before` ([`GraphQL_FragmentGenerator.res:346`](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L346)) —
but the Scan resolver reads only `first`/`after`. A client sending `last`/`before`
gets the forward first page with **no error**: silent wrong data. (The sibling
sort-key connection `queryItemsWithSortConditions` genuinely supports backward paging,
lines 150-152 — this gap is specific to the Scan path.)

**Backward paging is impossible on a Scan — but not in general; the two are the same
capability as ordering (Fix 4).** DynamoDB gives a Scan exactly one pagination
primitive: `LastEvaluatedKey` → `ExclusiveStartKey`, a **forward-only** pointer. There
is no `ScanIndexForward` for Scan (that flag reverses *sort-key* order and a Scan has
no sort key), and no "previous key" — the token says where a page *ended*, never where
the one before it *started*. So the server cannot reconstruct "the N items before
cursor C" from C alone. The workarounds don't survive this context: embedding the
previous page-boundary token in each cursor only re-fetches a seen boundary (it can't
honour an arbitrary `last: N`, and breaks when the table changes); buffering the whole
table to slice its tail needs multi-page accumulation, which APPSYNC_JS forbids (no
loops/recursion). There is also no *meaningful* backward direction: a raw Scan returns
hash-traversal order, so "the previous page" is undefined when there is no order to be
previous in.

Impose an order via an **index**, though, and backward paging becomes well-defined and
cheap — `Query(index, ScanIndexForward = false)` with a keyset cursor on the sort key.
That is exactly what the sibling `queryItemsWithSortConditions` already does (`isBackward`
→ `#sk < :cursor` → `scanIndexForward` flip → `reverse()`, lines 150-152, 182) and what
**Fix 4's constant-PK GSI** extends to the full list. **Ordering and backward paging
are one capability:** promoting the sort field to an index yields correct global order
*and* real `last`/`before` together — which is why Fix 4 subsumes this guard for
promoted fields (on the Query path the guard never fires). In practice the gap also
rarely bites, because a forward-scrolling UI already holds the earlier pages' cursors
it walked through, so client-side "previous" needs no server round-trip; true
server-side `last`/`before` only matters for ordered deep-linking into a large list —
the case that needs Fix 4's index anyway.

Until that index exists, the honest fix is to **reject** backward args on the Scan path
rather than silently mislead:

```js
// Scan cannot page backward (ScanIndexForward is Query-only). Fail loud instead of
// silently returning the forward page. The ordered `{single}Items` connection
// (queryItemsWithSortConditions) supports last/before — direct backward callers there.
if (ctx.args.before != null || ctx.args.last != null) {
  util.error(
    'Backward pagination (last/before) is not supported on full-list connections; use first/after.',
    'UnsupportedPagination'
  );
}
```

APPSYNC_JS-safe (an `if` + `util.error`; no loop, no recursion).

**Cleaner-but-larger alternative:** stop advertising what the resolver can't do —
thread a `~forwardOnly` flag from the Scan-backed field generator
(`deriveConnectionQueryField`, `GraphQL_FragmentGenerator.res:346`) so a full-list
field emits only `first, after`. That diverges the full-list field's SDL from the
sort-key field's and touches the schema generator, so it sits outside this
resolver-scoped plan; the runtime guard is the durable minimum and can stay even after
the SDL is pruned.

### Fix 3 — Resumable empty / short filtered pages

A filtered `Scan` applies `limit` (and the hard 1 MB page ceiling) to rows
**scanned**, not rows **returned**. So a page can come back with `items: []` — or
fewer than `first` — while `ctx.result.nextToken` is still set (more to scan). After
Fix 1, an empty page yields `edges: []`, so `startCursor`/`endCursor` are `null`, yet
`hasNextPage` is `true`. A Relay client paging by `endCursor` then sends `after: null`,
restarts from page 1, and stalls or loops. Fix 1 makes this *more* reachable, because
correct forward paging is exactly what invites clients to page filtered lists.

The continuation token is **page-level**, not edge-level, so it exists even when the
page has no edges. Synthesize a token-only boundary cursor when edges are empty:

```js
const next = ctx.result?.nextToken ?? null;
const edges = items.map((item, i) => ({
  node: item,
  cursor: util.base64Encode(JSON.stringify({ token: next, index: i })),
}));
// A filtered/1MB-capped page can be empty or short while `next` is still set. The
// token is page-level, so synthesise a boundary cursor from it alone; the request
// side only ever reads `.token`, so `index: -1` is inert on resume. Lets a client
// page past a fully-filtered-out region instead of restarting from page 1.
const boundary = next
  ? util.base64Encode(JSON.stringify({ token: next, index: -1 }))
  : null;
```

with `pageInfo` falling back to `boundary` when there are no edges:

```js
startCursor: edges.length > 0 ? edges[0].cursor : boundary,
endCursor:   edges.length > 0 ? edges[edges.length - 1].cursor : boundary,
```

Non-empty short pages already resume correctly (their last edge carries `next`); only
the fully-empty-but-continuable page needs the synthetic boundary. When `next` is null
on an empty page (scan exhausted), `boundary` is null, `hasNextPage` is false, and the
client stops — correct.

### Fix 4 — Cross-page global ordering

`orderBy` is evaluated as a per-page schwartzian sort over one Scan page
([lines 485-505](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L485));
`ScanIndexForward` does not apply to Scan, so paging a sorted list past page 1 reveals
an inconsistent global order. Unlike 1–3 this **cannot** be corrected inside the Scan
resolver for arbitrarily large sets — a full-table sort needs every row in hand.

**Durable fix — index promotion (Query-backed ordered path).** Extracted to its own
plan: [Backlog/aws-fulllist-ordered-index-promotion.md](../Backlog/aws-fulllist-ordered-index-promotion.md).
In brief: promote the sort field to a **constant-PK GSI** (PK = a synthetic `_all`
attribute on every row, SK = composite `f#id`) so the whole table becomes one
Query-able, globally-ordered partition, then route ordered requests to a new
`queryAllItemsOrdered` resolver (`Query` + `ScanIndexForward`, keyset value cursor —
the `queryItemsWithSortConditions` pattern, table-wide). That change spans the resolver,
DynamoDB table provisioning, the resolver dispatch, the schema generator, and a GSI
backfill — beyond this resolver-scoped plan, hence the split. Because a Query with
`ScanIndexForward` orders *and* reverses, promotion also **subsumes Fix 2** for promoted
fields (the Scan-path backward guard only fires on non-promoted fields). The only part
that lands **here** is the interim warning below, which points authors at that plan.

**Interim — make the warning tell the truth.** `validateScanSortAlignment`
([`GraphQL_FragmentGenerator.res:235-258`](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L235))
already emits one deploy-time warning per `@scanSort` field not backed by an index,
but it frames the cost as *expensive* only. It should also state the **correctness**
consequence — that multi-page results are globally mis-ordered, not merely slow — so an
author accepting the caveat knows what they are accepting:

> `@scanSort field "<f>" is not the sort key of any table or GSI. Sort requests Scan
> the whole table and sort **per page**, so results past the first page are **not
> globally ordered** — and the Scan is expensive in production. Promote the field to an
> index sort key for correct, cheap ordering, or accept per-page ordering.

The interim step changes no runtime behaviour — it only sharpens the warning (and its
`GraphQL_SchemaInspectorTest.res` assertion) so the per-page limitation is an informed
choice, not a surprise.

### Consolidated request / response (Fixes 1–3)

Fix 4 leaves this body unchanged for non-promoted fields.

```js
export function request(ctx) {
  if (ctx.args.before != null || ctx.args.last != null) {
    util.error('Backward pagination (last/before) is not supported on full-list connections; use first/after.', 'UnsupportedPagination');
  }
  // ...filter / range / requireAttribute clauses unchanged...
  let after = null;
  if (ctx.args.after != null && ctx.args.after !== '') {
    const parsed = JSON.parse(util.base64Decode(ctx.args.after));
    after = parsed.token ?? null;
  }
  const req = { operation: 'Scan', limit: (ctx.args.first ?? 50), nextToken: after };
  if (parts.length > 0) {
    req.filter = { expression: parts.join(' AND '), expressionNames: names, expressionValues: values };
  }
  return req;
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  let items = ctx.result?.items ?? [];/* sortBlock unchanged */
  const next = ctx.result?.nextToken ?? null;
  const edges = items.map((item, i) => ({
    node: item,
    cursor: util.base64Encode(JSON.stringify({ token: next, index: i })),
  }));
  const boundary = next ? util.base64Encode(JSON.stringify({ token: next, index: -1 })) : null;
  return {
    edges,
    pageInfo: {
      hasNextPage: !!next,
      hasPreviousPage: !!ctx.args.after,
      startCursor: edges.length > 0 ? edges[0].cursor : boundary,
      endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : boundary,
    },
  };
}
```

### APPSYNC_JS 1.0.0 constraints to respect

The generated body runs under the APPSYNC_JS 1.0.0 sandbox (see the in-file notes
at line 282 and `appsync-listallitems-sort-runtime-compat.md`):

- **No `for`/`while` loops, no recursion, no `++`/`--`** — the change uses only
  `.map`, so this is fine.
- **No `String()`/`.toString()`** — use `'' + v` (unchanged; the new code adds no
  stringification).
- `util.base64Encode` / `util.base64Decode` **are** available (already used by
  `queryItemsWithSortConditions`, lines 124-125) — the fix reuses them.
- `util.error(message, type)` **is** available (already used at line 547) — Fix 2's
  backward-paging guard reuses it.
- `JSON.parse` / `JSON.stringify` are available (already used in the sort block,
  lines 500-504).
- **Confirm** whether `try/catch` is permitted before relying on it. The decode is
  written **without** a guard: a malformed `after` (see below) throws, which is
  acceptable because such a cursor never round-tripped anyway. If a soft failure is
  preferred, guard the parse — but only if `try/catch` passes runtime validation.

### Backward compatibility

Pre-fix cursors (`"49"`, `"49_3"`) **never** round-tripped — they always errored at
DynamoDB. So there is no working-cursor population to preserve, and no dual-decode
shim is warranted: after deploy, clients simply start over from page 1 (no `after`)
and every cursor from then on is a valid encoded token. A stale pre-fix cursor
passed as `after` will `JSON.parse`-fail (it is not base64 JSON) and error — the
same user-visible outcome as before the fix, not a new regression.

Fix 2 turns a previously-silent `last`/`before` call into a hard `UnsupportedPagination`
error. That is a behaviour change, but not a regression: those args never returned
correct backward results — they returned the forward first page, silently wrong. An
explicit error is strictly more honest, and no client that relied on the (broken)
silent behaviour was getting correct data to preserve.

### Out of scope (still)

- **The durable form of Fix 4** (Query-backed index promotion) is its own plan:
  [Backlog/aws-fulllist-ordered-index-promotion.md](../Backlog/aws-fulllist-ordered-index-promotion.md).
  Only its interim warning-sharpening lands here. Non-promoted `@scanSort` fields keep
  the documented per-page-order caveat.
- **True backward paging over a Scan** — Fix 2 rejects it rather than emulating it;
  clients needing backward paging use the ordered `{single}Items` connection. The
  SDL-pruning alternative (drop `last`/`before` from Scan-backed fields) is noted
  under Fix 2 as a follow-up.
- **The `>1000`-row DynamoDB page cap** is not a separate defect: with a correct
  cursor round-trip, an arbitrarily large estate pages through fine at any `first`.
  Fixing this cursor is precisely what removes the need for the downstream `first:
  1000` stopgap.

---

## Testing

The regression shipped because **nothing exercises `listAllItemsConnection`'s Scan
cursor round-trip.** The existing AWS tests only assert generated SDL shape
(`AppSync_AdapterTest.res`) and filter clauses (`QueryDbResolvers_AppSyncTest.res`);
the genuine multi-page round-trip tests live only on the local/Postgres side
(`QueryDbListResolverTest.res` lines 202-249, `QueryEnginePostgresListPageTest.res`).

Add two layers:

1. **Cheap tripwire (definitely feasible).** String assertions, in the style of
   `AppSync_AdapterTest.res`, over the generated `listAllItemsConnection` body:
   - **Fix 1:** cursors source from `ctx.result.nextToken` — the body contains
     `base64Encode(JSON.stringify({ token: ... }))` and the request contains
     `nextToken: after` fed from a decoded `after` — and does **not** contain the old
     index expression `ctx.args.after + '_' + i`.
   - **Fix 2:** the request guards `ctx.args.before`/`ctx.args.last` with a
     `util.error(..., 'UnsupportedPagination')`.
   - **Fix 3:** the response computes a `boundary` cursor and falls back to it for
     `startCursor`/`endCursor` when `edges.length === 0`.
   - **Fix 4 (interim):** `validateScanSortAlignment`'s warning string now contains
     the correctness phrasing ("not globally ordered"), asserted in
     `GraphQL_SchemaInspectorTest.res` (the existing test at line 656 that checks the
     warning fires — extend its message assertion).

   These alone would have caught the original regression and each new gap.

2. **Full eval round-trip (confirm feasibility).** Extract the generated `request`
   and `response` function bodies and evaluate them against a mock `util`
   (`base64Encode`/`base64Decode` via `Buffer`, `dynamodb.toDynamoDB`, and an `error`
   stub that throws), then simulate:
   - **Forward round-trip (Fix 1):** `request(ctx0)` with no `after` → assert
     `req.nextToken === null`. Feed `{ items: pageA, nextToken: 'TOK1' }` → `response`
     → read `pageInfo.endCursor`. `request(ctx1)` with `after = endCursor` →
     **assert `req.nextToken === 'TOK1'`** (the round-trip that currently fails). Feed
     `{ items: pageB, nextToken: null }` → assert `hasNextPage === false` and no
     `pageA`/`pageB` node overlap.
   - **Backward guard (Fix 2):** `request({ args: { before: 'x' } })` and
     `request({ args: { last: 5 } })` each **throw** via the `error` stub.
   - **Empty-page resume (Fix 3):** feed `{ items: [], nextToken: 'TOK2' }` →
     `response` → assert `endCursor` is non-null and `hasNextPage === true`;
     `request({ args: { after: endCursor } })` → **assert `req.nextToken === 'TOK2'`**
     (resume past a fully-filtered-out page). Then feed `{ items: [], nextToken: null }`
     → assert `endCursor === null` and `hasNextPage === false` (clean stop).

   This mirrors `QueryDbListResolverTest.res` for the DynamoDB backend. Confirm the
   core test harness can eval an APPSYNC_JS template string (a small `vm`/`eval`
   sandbox with the `util` mock); if not, ship layer 1 and track the eval harness
   as a follow-up.

---

## Rollout

1. Edit `listAllItemsConnection` request + response in
   `AppSync_Resolver_Functions.res` for Fixes 1–3 (single function; no signature
   change, no caller change — `QueryDbResolvers_AppSync.res` line 233 keeps calling it
   as-is).
2. Sharpen the `validateScanSortAlignment` warning string (Fix 4 interim) in
   `GraphQL_FragmentGenerator.res`.
3. Add the tripwire tests (and the eval round-trips if the harness supports them).
4. Rebuild; the resolver JS is regenerated at `pulumi up` for every read model that
   uses the full-list connection — no schema or data migration, purely resolver code.
   The warning change surfaces at the next deploy-time validation pass.
5. On deploy, connections page correctly at any `first`, filtered lists resume without
   stalling, and `last`/`before` fail loud instead of misleading; downstream consumers
   can drop oversized `first` stopgaps and page normally.
6. **Follow-up (separate plan):** Fix 4 durable — index promotion via a constant-PK
   GSI + a `queryAllItemsOrdered` dispatch, specified in
   [Backlog/aws-fulllist-ordered-index-promotion.md](../Backlog/aws-fulllist-ordered-index-promotion.md).
   Subsumes Fix 2's backward-paging guard for promoted fields.

---

## Files

- `rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` —
  `listAllItemsConnection` request (lines 532-536) + response (lines 546-562). **The
  fix** for defects 1–3 (forward cursor, backward guard, empty-page boundary).
- `reventless/core/src/components/Api/GraphQL_FragmentGenerator.res` —
  `validateScanSortAlignment` (lines 235-258), warning-string sharpening (Fix 4
  interim); and line 346, the SDL that advertises `last`/`before` (context for Fix 2's
  larger alternative).
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` (line 233) —
  caller; unchanged, listed for orientation.
- `reventless/aws/tests/QueryDbResolvers_AppSyncTest.res` /
  `reventless/aws/tests/AppSync_AdapterTest.res` — where the new resolver test(s) land;
  `reventless/local/tests/adapter/GraphQL_SchemaInspectorTest.res` (line 656) — the
  warning-message assertion for Fix 4.
- Reference implementations (do not change): `AppSync_Resolver_Functions.res::queryItemsWithSortConditions`
  (line 122, correct DynamoDB value cursor), `QueryDbListQuery.res` (shared
  value-cursor spec), `QueryDbListResolverTest.res` (the round-trip test to mirror).
