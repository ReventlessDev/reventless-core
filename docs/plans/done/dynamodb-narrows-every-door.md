# Plan: the DynamoDB backend narrows the doors it says it narrows

**Date:** 2026-08-17
**Status.** DONE 2026-08-17 — both steps are in the tree and committed
(`d6a799b28`, `5d083dae3`), and the whole `reventless-aws` suite is green at 676
tests across 59 suites, 19 of them in `AppSync_RetirementNarrowingTest.res`. The
one item this plan scoped out — an elevated caller cannot widen the **index**
door, because no SDL emitter declares `includeRetired` there — went to its own
plan, [index-door-cannot-be-widened-to-the-archive.md](index-door-cannot-be-widened-to-the-archive.md),
**closed 2026-08-18**. Measuring it for the write-up already showed it was not
DynamoDB's alone: the local and Postgres resolvers read the argument too and also
never receive it, and the field is emitted by two paths that disagree on its
name, its arguments and its return type. Closing it found the rest — that the
door does not answer on *any* backend, each backend's SDL disagreeing with its
own resolver — which is why it was a plan of its own rather than a follow-on line.

**Step 1 (retirement) BUILT 2026-08-17.** All four doors narrow. The generated JS
was executed against rows outside the test suite, since asserting text proves the
guard is present and not that it decides correctly:

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

**Step 2 (ownership) BUILT 2026-08-17** — the by-ids and by-index doors now
apply `@owner`, and the two questions the Scope section left open are answered
rather than deferred:

- **A group-restricted index is exempt, deliberately.** `authorizeIndexedAccess`
  grants a caller who is in the named group *and* is the holder the auth table
  records for that index value. The rows it grants are by construction other
  people's — an order assigned to a fulfilment operator belongs to the customer
  who placed it — so ANDing `@owner` there returns nothing and revokes exactly
  the access the auth table exists to grant. An explicit per-index rule is the
  deployment's answer for that door; `@owner` is the default for doors with none.
  Retirement still applies on those doors: an archived row is withdrawn from
  everyone who has not asked, whoever owns it.
- **An owner-narrowed index page is the point, not a regression.** The list door
  has narrowed this way all along; an index door returning fewer rows is
  returning the caller's own, and a surface that expected more was reading rows
  it was never entitled to. The operational note is the one the file already
  makes for the list: an unindexed owner field means scan-and-filter, so pages
  shrink as the caller's share falls.

Executed against rows, not just asserted as text — `alice` owns o1 (live) and o3
(archived), `bob` owns o2:

| caller | by-ids result | by-index FilterExpression |
|---|---|---|
| alice | `o1` | `#owner = :owner AND (attribute_not_exists(#retired) OR …)` |
| alice + `includeRetired` | `o1` | — (asking does not help a scoped caller) |
| admin | `o1, o2` | retirement clause only |
| admin + `includeRetired` | `o1, o2, o3` | no filter |
| IAM service call | `o1, o2` | — |

**One defect found while proving it.** The index templates turn every
unrecognised argument into a `contains(#key, :key)` filter, so `includeRetired`
would have become a filter on an attribute no row carries — the door answering
nothing for the one caller it exists to serve. Unreachable through the API today
because the index field's SDL does not declare the argument, which is its own
asymmetry: **an index door narrows retirement unconditionally, and an elevated
caller has no way to widen it.** Adding `includeRetired` to the index SDL is the
obvious follow-on and is left out here, since it is a schema change with its own
lockstep. The argument is skipped defensively so that change cannot land on a
trap.
**Stack:** `rescript/pulumi-aws` (the APPSYNC_JS resolver templates),
`reventless/aws`. No new deps.
**Relates to:** [retired-state-flag-annotation.md](retired-state-flag-annotation.md)
(the rule this is measured against), [retired-row-resolvable-by-reference.md](../retired-row-resolvable-by-reference.md)
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

**Step 2 — ownership on by-ids and by-index, implemented after step 1.**
`batchGetItemsByIds` and the two `queryByIndex*Filtered` templates applied no
`@owner` predicate at all. That is the same shape of hole and a worse one: it is
one caller reading another caller's rows by naming an id or an index value,
where the retirement gap is a caller reading a row nobody's list would offer.
The comment already in `QueryDbResolvers_AppSync` — describing how the by-id
resolvers were once generated without owner scoping, "a list narrowed to the
caller beside a by-id read that hands over any row it is asked for" — was the
same sentence about a different door.

It was written up as deferred because of two open questions, and both are
answered above rather than still open: a group-restricted index is **exempt**
(its auth table exists to grant other people's rows, so ANDing `@owner` there
revokes exactly what it grants), and an owner-narrowed index page returning
fewer rows is the point rather than a regression.

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
exempt caller passing `includeRetired: true` gets it from `X(id:)` and `XsByIds`.
A read model without one emits templates identical to today's, so nothing that
does not declare a retirement can change behaviour.

**Met, with the index door's widening half struck out rather than claimed.** The
acceptance as first written said "gets it from all three"; at the time the index
door had no `includeRetired` in its SDL on any backend, so no caller could ask
there. It narrowed correctly, which is the half this plan is measured against.
The widening half — and, as it turned out, the door itself, which answered on no
backend — is [index-door-cannot-be-widened-to-the-archive.md](index-door-cannot-be-widened-to-the-archive.md),
closed the following day.
