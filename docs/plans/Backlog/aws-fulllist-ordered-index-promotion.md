# Plan: Globally-ordered full-list connections via index promotion (AWS)

**Date:** 2026-07-23

**Status:** Backlog — not started. This is the durable form of "Fix 4" extracted from
[../aws-scan-connection-cursor-roundtrip.md](../done/aws-scan-connection-cursor-roundtrip.md),
which shipped the Scan-path cursor fixes (Fixes 1–3) and the interim warning. That plan
made the full-list Scan connection *paginate* correctly; this plan makes it *order*
correctly across pages — and, as a consequence, page **backward**.

**Relates to:**
- [../aws-scan-connection-cursor-roundtrip.md](../done/aws-scan-connection-cursor-roundtrip.md)
  — the parent plan. Its Fix 2 (backward-paging rejection) and Fix 4 interim (sharpened
  `@scanSort` warning) are the two hooks this plan resolves.
- [../../analysis/autoui-list-ordering-and-filtering.md](../../analysis/autoui-list-ordering-and-filtering.md)
  — documents the per-page-sort caveat (lines 134-136) and the id-tiebreak cursor
  contract (line 132) this plan must match.

---

## When to pull this from Backlog

This is **demand-driven, not speculative** — build it only when a concrete read model
hits *all* of these at once:

1. **Large** — its Connection genuinely spans more than one page under a realistic
   `first` (a single Scan page already sorts correctly; the bug needs ≥ 2 pages).
2. **Sorted by a non-key attribute** — `orderBy` on a field that is *not* an
   `@id`/`@subId`/`@index` sort key (those already route to a Query and order correctly
   today).
3. **Can't be reshaped** — the need isn't better met by a purpose-built read model whose
   sort key *is* that attribute (the CQRS-native answer — see the prevalence note in
   [autoui-list-ordering-and-filtering.md](../../analysis/autoui-list-ordering-and-filtering.md#L134)),
   nor by the `first: N` client-side-sort stopgap (adequate up to a few thousand rows).

Evidence at time of writing (2026-07-23): **`@scanSort` has zero usages** across every
read model and example in the repo — the path this plan optimizes is currently exercised
by nobody, so there is no live demand. Until (1)–(3) all hold for a real component,
prefer a purpose-built read model or accept per-page ordering.

**Re-scope check before starting:** if the qualifying table is *also* write-hot or very
large, the single-partition GSI in the design below will throttle (it is weakest exactly
where the multi-page case is most likely). That case needs the sharded-Lambda variant
(§5) — a bigger project — so confirm the table fits a single-partition GSI first, or plan
for the shard from the outset.

---

## Goal

Serve `orderBy` on a full-list DynamoDB connection with **correct global order across
all pages**, replacing the current per-page schwartzian sort — and, because ordering
and backward paging are the same capability, deliver real `last`/`before` on the same
field at the same time.

Today `orderBy` on `listAllItemsConnection` is a per-page sort over one Scan page
([`AppSync_Resolver_Functions.res:485-505`](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L485));
`ScanIndexForward` does not apply to Scan, so paging a sorted list past page 1 reveals
an inconsistent global order. This **cannot** be corrected inside the Scan resolver for
arbitrarily large sets — a full-table sort needs every row in hand, which APPSYNC_JS
cannot accumulate.

---

## Background — why ordering and backward paging are one capability

A raw `Scan` has one pagination primitive: `LastEvaluatedKey` → `ExclusiveStartKey`, a
**forward-only** pointer, and no `ScanIndexForward`. It also returns hash-traversal
order — there is no *meaningful* order to be "previous" in. So on a Scan, global
ordering and backward paging are both impossible for the same root reason: no ordered,
reversible key.

Impose an order via an **index** and both fall out together:
`Query(index, ScanIndexForward = false)` with a keyset cursor on the sort key gives
correct global order **and** genuine `last`/`before`. The sibling resolver
`queryItemsWithSortConditions`
([line 122](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L122))
already proves the pattern *within one `id` partition* (`isBackward` → `#sk < :cursor`
→ `scanIndexForward` flip → `reverse()`, lines 150-152, 182). This plan extends the
same pattern to the **whole table**.

### Why the sibling pattern doesn't just transfer

`queryItemsWithSortConditions` pins a single `id` partition — its key expression is
`#id = :id AND <sk cond>`. A full-list connection spans the whole table, so there is no
partition key to pin. Index promotion here means more than "add a GSI sort key": it
needs a GSI whose **partition key is constant across every row**, collapsing the whole
table into a single Query-able, globally-ordered partition.

---

## Design

1. **Constant-PK (single-partition) GSI.** To promote sort field `f`, provision a GSI
   with **PK = a synthetic constant attribute** the projection writes on every row
   (e.g. `_all = "1"`) and **SK = a composite `f#id`**. The composite SK makes ordering
   **total** — duplicate `f` values (many rows sharing a `status`) are disambiguated by
   the `id` tiebreak, so keyset pagination never skips or repeats a row. This mirrors
   the in-memory/Postgres cursor, which already tiebreaks on `id`
   ([`autoui-list-ordering-and-filtering.md:132`](../../analysis/autoui-list-ordering-and-filtering.md#L132)).

2. **Ordered resolver — `queryAllItemsOrdered(~sortField)`.** A new sibling to
   `queryItemsWithSortConditions`, structurally identical but pinning the constant PK
   instead of `id`:

   ```js
   export function request(ctx) {
     const args = ctx.args;
     const isBackward = args.last != null;
     const orderDesc = ctx.args.orderBy?.direction === 'DESC';
     const expressionNames = { '#pk': '_all', '#sk': '<sortField>#id' };
     const expressionValues = { ':all': util.dynamodb.toDynamoDB('1') };
     let skCond;
     if (isBackward && args.before != null) {
       expressionValues[':cursor'] = util.dynamodb.toDynamoDB(decodeCursor(args.before));
       skCond = '#sk < :cursor';
     } else if (!isBackward && args.after != null) {
       expressionValues[':cursor'] = util.dynamodb.toDynamoDB(decodeCursor(args.after));
       skCond = '#sk > :cursor';
     }
     const expression = skCond ? '#pk = :all AND ' + skCond : '#pk = :all';
     const pageSize = isBackward ? (args.last ?? 50) : (args.first ?? 50);
     return {
       operation: 'Query',
       index: 'by_<sortField>_all',
       query: { expression, expressionNames, expressionValues },
       scanIndexForward: isBackward ? orderDesc : !orderDesc,
       limit: pageSize + 1,        // the +1 / slice / reverse hasMore trick, verbatim from the sibling
     };
   }
   ```

   The response is `queryItemsWithSortConditions`' response verbatim: keyset **value**
   cursor = `base64(item['<sortField>#id'])`, `hasNextPage`/`hasPreviousPage` from the
   `+1` overshoot. `ScanIndexForward` gives correct global order and honours backward
   paging — so promotion **resolves the parent plan's Fix 2** for promoted fields (the
   Scan-path backward-rejection guard only fires on non-promoted fields).

3. **Resolver becomes a dispatch.** Thread the promoted-field set into the generator
   (alongside the existing `~sortFields`) and pick the path per request:
   `orderBy.field` promoted → `queryAllItemsOrdered`; `orderBy.field` a non-promoted
   `@scanSort` → Scan + per-page sort (parent plan's Fixes 1–3, with the sharpened
   warning); no `orderBy` → the default Scan path. Because the ordered path uses a
   **value** cursor and the Scan path a **token** cursor, the two cursor shapes are not
   interchangeable — the dispatch must **reject a cursor from the wrong path**
   (`JSON.parse` of a value cursor fails; a token cursor fed to the Query decodes to a
   non-key string). A client must not switch `orderBy` mid-pagination; the mismatch
   errors rather than silently corrupting the page. Encode a one-byte path tag in each
   cursor so the guard is a cheap discriminator rather than a parse-failure heuristic.

4. **Provisioning is explicit opt-in.** Promotion **creates a GSI** (cost + write
   amplification + a hot single partition), so it should be intentional, not implicit
   on every `@scanSort`. Author opts in with an annotation (e.g. `@sortIndex` on the
   field, or reuse `@index` with a constant-PK projection); the generator then emits the
   GSI in the DynamoDB table config **and** the `queryAllItemsOrdered` resolver for that
   field. The parent plan's sharpened `@scanSort` warning is the nudge toward opting
   in — warning and promotion are two ends of the same lever.

5. **Hot-partition ceiling + escape hatch.** A constant-PK GSI funnels all reads and
   writes through one physical partition — fine for the typical AutoUI read model, but
   it throttles at scale. Mitigation is **write sharding** (PK = `id`-hash mod N), which
   turns one Query into an N-way scatter-gather merge. APPSYNC_JS can't loop or merge N
   streams, so the sharded variant belongs in a **Lambda resolver** (the same place the
   Postgres path already lives), not APPSYNC_JS. Scope the first cut to the
   single-partition GSI and track sharded-merge as its own follow-up.

6. **Backfill.** A GSI only indexes rows carrying **both** key attributes, so existing
   rows without `_all` (and the composite SK) are invisible until re-written. On alpha,
   a projection rebuild repopulates them (per the standing "wipe alpha EventLog over
   migration code" convention); a prod promotion needs an explicit backfill pass.

---

## Open decisions

- **Promotion annotation syntax** — a new field-level `@sortIndex`, or reuse `@index`
  with a constant-PK projection variant? The former is explicit about intent; the
  latter reuses existing GSI plumbing.
- **Constant-PK attribute name & value** — `_all = "1"` is a placeholder; confirm it
  can't collide with a real projected attribute and settle a reserved-name convention.
- **Composite SK encoding** — `f#id` separator choice and numeric zero-padding (the
  Scan per-page sort already zero-pads numerics to 22 chars; match it so lex order = sort
  order).
- ~~**Cursor path-tag format**~~ — **settled** by
  [../owner-scoped-reads-on-an-index.md](../owner-scoped-reads-on-an-index.md), which
  needed the same discriminator first: the cursor JSON carries `p`, one character —
  `s` the full-list Scan, `q` the owner-index Query. Absent reads as `s`, because every
  cursor minted before the tag existed came off a Scan. `cursorDecode` /
  `connectionPageResponse` / `cursorPathGuard` in `AppSync_Resolver_Functions.res` are
  the three halves. This plan's keyset **value** cursor takes the next letter (`o`) and
  must not reuse `s` or `q`.
- **Sharded-merge threshold** — when (if) to move a promoted field off the
  single-partition GSI onto the Lambda scatter-gather path.
- **Backfill mechanism for prod** — projection rebuild vs. a dedicated backfill Lambda.

---

## Files

- `rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` — new
  `queryAllItemsOrdered(~sortField)` function.
- The DynamoDB table resource (constant-PK GSI provisioning).
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — Scan-vs-Query
  dispatch + ordered-resolver selection.
- `reventless/core/src/components/Api/GraphQL_FragmentGenerator.res` — promotion
  annotation → server-capability threading.
- Reference (do not change): `queryItemsWithSortConditions` (the value-cursor Query
  pattern), `QueryDbListResolverTest.res` (round-trip test to mirror).

---

## Testing

Mirror the parent plan's approach on the ordered path:

1. **SDL/codegen tripwires** — a promoted field emits a `queryAllItemsOrdered` resolver
   and a constant-PK GSI in the table config; a non-promoted `@scanSort` field keeps the
   Scan resolver and the sharpened warning.
2. **Eval round-trip** — evaluate the generated `queryAllItemsOrdered` request/response
   against a mock `util`: forward two-page ordering is globally consistent; `after`
   round-trips the value cursor; `last`/`before` walks backward and `reverse()`s to
   forward order; a Scan-path (token) cursor fed to the Query path is **rejected** by the
   path-tag guard.
