# Plan: the DynamoDB backend narrows the doors it says it narrows

**Date:** 2026-08-17
**Status.** Step 1 BUILT 2026-08-17, uncommitted. All four doors narrow; 12 new
assertions in `AppSync_RetirementNarrowingTest.res` and the 669 existing
`reventless-aws` tests are green. The generated JS was also executed against rows
outside the test suite, since asserting text proves the guard is present and not
that it decides correctly:

| caller | single door | by-ids door (p1 archived, p2 live, one pre-annotation) |
|---|---|---|
| shopper | archived → `null`, live → row | `p2, old` |
| admin, no `includeRetired` | `null` | `p2, old` |
| admin, `includeRetired: true` | row | `p1, p2, old` |

Two things the tests caught that review had not:

- The first cut emitted `const _live = () => true` into every template, so a view
  declaring **no** retirement no longer produced the code it used to. Now the
  absence of a retirement is the absence of every term — preamble and predicate
  both — and a view without one is byte-identical to before.
- The retirement lookup sat *below* the by-id, by-ids and by-index resolvers in
  `QueryDbResolvers_AppSync`, so threading it through failed to compile. It moved
  up beside `ownerField`, which is where the same file's own comment says the
  owner lookup had to move after the same mistake.

**Step 2 (ownership) remains unimplemented** — see Scope.
**Stack:** `rescript/pulumi-aws` (the APPSYNC_JS resolver templates),
`reventless/aws`. No new deps.
**Relates to:** [done/retired-state-flag-annotation.md](done/retired-state-flag-annotation.md)
(the rule this is measured against), [retired-row-resolvable-by-reference.md](retired-row-resolvable-by-reference.md)
(where the gap surfaced).

## Why

`.claude/rules/app-developer.md` states the enforcement half of `@retired` as:

> non-exempt callers get retired rows withheld from the list query, the
> single-entity / by-ids / by-index doors, and the live change frame's payload

The local and Postgres backends do that. The DynamoDB backend does it for the
list and nowhere else. Measured against the templates each resolver is generated
from:

| door | template | owner scoping | retirement |
|---|---|---|---|
| list | `listAllItemsConnection` | ✅ FilterExpression | ✅ FilterExpression |
| single | `getItemById` | ✅ post-read | ❌ |
| single + sort key | `queryByIdSort` | ✅ post-read | ❌ |
| by-ids | `batchGetItemsByIds` | ❌ | ❌ |
| by-index | `queryByIndexFiltered` / `…SortFiltered` | ❌ | ❌ |

So on a DynamoDB deployment an archived row is readable in full by anyone who can
name its id, and the annotation that was supposed to withdraw it withdraws it
from one door of five. The rule is not aspirational — it is what the other two
backends do, and it is what the doc tells an app author they are getting.

**Goal.** Every door the rule names narrows on DynamoDB, by the same predicate,
with the same reading of an absent attribute.

**Non-goal — changing the predicate.** `OwnerScope.decideRetired` stays the one
place that decides who may widen. This is about doors that never asked it.

---

## Scope, and what is deliberately left

**Step 1 — retirement, implemented here.** The four doors above gain the
narrowing the list already has: a retired row is withheld unless the caller is
exempt *and* passed `includeRetired`, with `attribute_not_exists` keeping a row
written before the annotation visible.

**Step 2 — ownership on by-ids and by-index, written up and not implemented.**
`batchGetItemsByIds` and the two `queryByIndex*Filtered` templates apply no
`@owner` predicate at all. That is the same shape of hole and a worse one: it is
one caller reading another caller's rows by naming an id or an index value,
where the retirement gap is a caller reading a row nobody's list would offer.

It is not implemented here for two reasons, and neither is "it is fine". A
by-index door narrowed by owner may return an empty page where a deployment's UI
expects rows, which is a behaviour change with a blast radius this plan has not
measured. And a group-restricted index already runs its own `authorizeIndexedAccess`
pipeline against an auth table, so the two rules meet there and which wins wants
deciding rather than discovering. **This should be the next change**, and the
comment already in `QueryDbResolvers_AppSync` — describing how the by-id
resolvers were once generated without owner scoping, "a list narrowed to the
caller beside a by-id read that hands over any row it is asked for" — is the
same sentence about a different door.

---

## Shape

Two mechanisms, chosen per door by what the operation allows rather than by
preference:

- **`GetItem` / `BatchGetItem` have no `FilterExpression`**, so the guard is a
  post-read predicate in `response`, exactly as `ownerScopedResultResponse`
  already is for the single door. A refused row answers `null` (single) or is
  dropped from the array (by-ids) — not an error, on the reasoning
  `ownerScopedResultResponse` documents: an error confirms the row exists to a
  caller who may not read it.
- **`Query` (the index doors) takes a `FilterExpression`**, so the clause is
  pushed into the read beside the client's own filters, matching
  `listAllItemsConnection`. Narrowing after the read would be visible in
  `limit`: a page of 50 would arrive holding fewer than 50 live rows.

The exemption test is the one `listAllItemsConnection` bakes: elevated group
membership (or an unidentified caller, which the owner rule already treats as
`_exempt`) **and** `ctx.args.includeRetired === true`. Elevation alone does not
lift it — an archive that is always underfoot is not an archive.

Absent attribute ⇒ not retired, in both mechanisms: `attribute_not_exists(#f) OR
…` in the expression, and `row[f] == null ||` in the post-read guard. A row
written before the annotation landed is not retired, which is the reading every
other adapter takes and the one that keeps a view from emptying on the day the
annotation ships.

## Steps

1. `getItemById` / `queryByIdSort` — post-read retirement guard beside the owner
   one, sharing its `_exempt` prelude rather than computing a second one.
2. `batchGetItemsByIds` — the same guard as a filter over the returned array.
   The template becomes parameterised (it takes only `tableName` today), so its
   two call sites pass the retirement through.
3. `queryByIndexFiltered` / `queryByIndexSortFiltered` — the retired clause ANDed
   into the FilterExpression they already build.
4. Wire the four from `QueryDbResolvers_AppSync`, which already reads
   `retiredField` / `retiredValues` for the list.
5. Tests: the emitted SDL/template text asserted per door — that a template with
   no retirement is byte-identical to today's, and that one with a retirement
   carries the guard in the right half (request vs response).

## Acceptance

A read model with `@retired`, deployed on DynamoDB: a non-exempt caller gets
nothing from `X(id:)`, `XsByIds` and `XBy<Index>` for a retired row, and an
exempt caller passing `includeRetired: true` gets it from all three. A read model
without one emits templates identical to today's, so nothing that does not
declare a retirement can change behaviour.
