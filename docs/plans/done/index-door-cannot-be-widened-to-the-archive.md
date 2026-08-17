# Plan: the by-index door answers, and an elevated caller can widen it

**Date:** filed 2026-08-17, **DONE 2026-08-18**.
**Status.** Done, and the premise it was filed under was wrong in the direction
that made the work easier. It was filed as a widening gap — a door that narrowed
retirement with no way to ask past it. Measuring it first found the door does not
answer **on any backend**, for a different reason on each, so there was no
behaviour to preserve and the signature could be chosen on the merits.
**Stack:** `reventless/core` (the shared derivation), `reventless/local`,
`reventless/aws`, `rescript/pulumi-aws`. No new deps.
**Relates to:** [dynamodb-narrows-every-door.md](dynamodb-narrows-every-door.md)
(which named this as the asymmetry it was leaving),
[retired-state-flag-annotation.md](retired-state-flag-annotation.md) (the rule),
[retired-row-resolvable-by-reference.md](../retired-row-resolvable-by-reference.md).

## What was actually wrong

Three defects, stacked, each hiding the one under it:

| | before | after |
|---|---|---|
| AWS SDL | `XByCategoryId(id: ID!, first, after, last, before): XConnection!` | keyed on the column, `includeRetired` offered |
| AWS resolver | reads `args.categoryId` — **never declared**, so the value could not be passed | reads the argument the field declares |
| AWS response | returns DynamoDB's `{items, nextToken}` against a field promising a Connection | returns `{edges, pageInfo}` |
| local SDL | `XByCategoryId(categoryId: String!): [String]` | identical to the AWS one |
| local resolver | returns whole rows against `[String]` ⇒ `INTERNAL_SERVER_ERROR` on **every call** | returns a Connection |
| ordinary `@index` read model | resolver on AWS, no SDL field at all | `indexQueries` populated, so the field exists |

Verified before touching anything, against the seeded local shop: a shopper
calling `Catalog_ProductByCategoryId(categoryId: "cat-1")` got
`{"errors":[{"message":"Unexpected error."}],"data":{"...":[null]}}`, and
`includeRetired` was rejected outright as an unknown argument.

**Two emitters were the cause.** The field was derived independently in
`GraphQL_FragmentGenerator` (for AppSync) and in the local adapter, and they
agreed on neither name (`XByOwner` vs `XByByOwner` for `@index("byOwner")`),
argument, nor return type. Each also disagreed with the resolver behind it, which
is why neither backend's door worked.

## What was done

**One derivation, called by every backend.** `deriveIndexQueryField` /
`indexQueryFieldName` / `indexKeyField` live in `GraphQL_FragmentGenerator` and
are now the only place any of the three strings is computed — the local adapter,
the local admin stub, `QueryDbResolvers_AppSync` and `QueryDbResolvers_Lambda`
all call them. Four hand-rolled copies of the `stripLeadingBy` logic are gone.

The signature, on every backend:

```graphql
XBy<Index>(<keyField>: String!, <sortField>: String, first: Int, after: String,
           last: Int, before: String, includeRetired: Boolean): XConnection!
```

- **`<keyField>` is the column, not the index name.** For `@index("byOwner") ownerId`
  the field is named after the index and keyed on `ownerId`, which is what every
  resolver already filtered on.
- **`<sortField>` only when the index has one.** The AppSync sort template has
  read this argument all along against an SDL that never offered it.
- **`includeRetired`** is what the plan was filed for. The three resolvers had
  implemented the widening already; none could receive it.
- The AppSync defensive skip is gone, replaced by a list covering every declared
  argument — each has a job other than matching a column, so any one of them
  reaching the generic filter loop would filter on an attribute no row carries.

## Acceptance — met, executed rather than asserted

Against the seeded local shop, `p1` archived among four products in `cat-1`:

| caller | `includeRetired` | rows |
|---|---|---|
| shopper | — / `true` | `p2, p3, p4` (asking does not help a non-exempt caller) |
| merchandiser | — / `true` | `p2, p3, p4` (an operator role is not an elevated one) |
| admin | — | `p2, p3, p4` (elevation alone does not lift it) |
| admin | `true` | `p1, p2, p3, p4` |

Paging round-trips: `first: 2` → `p1, p2`, `hasNextPage`, and the returned
`endCursor` fetches `p3, p4`. And the property the rule turns on — a shopper
asking `first: 2` gets **two live rows**, not a page of two thinned to one, because
the predicate is in the read rather than applied after it.

The AWS half was executed too, since AppSync's runtime cannot be reached from a
unit test: the generated JS keys on `args.categoryId`, applies the retirement
`FilterExpression` for a shopper, drops it for an admin who asked without turning
`includeRetired` into a `contains()` filter, and returns `{edges, pageInfo}`.

Full suite green: 3432 tests, 346 suites. `check:graphql` golden moved by exactly
one line, which is the door.

## Found on the way, fixed here

`AppSync_Resolver_FunctionsTest.mjs` called `queryByIndexSortFiltered`
**positionally**, and the `@owner` work in `5d083dae3` inserted `~ownerField`
ahead of `~sortField`. The sort key had been sliding into the owner slot since
that commit, so the file scoped the read by `status` while asserting it did not —
two tests red on the committed tree, in a package whose suite that change had not
re-run. This is the hand-written-`.mjs`-breaks-on-a-new-leading-argument trap, on
its second outing.

## Backward paging: refused, not ignored

The first cut declared `last`/`before` and silently ignored them, which is the
same defect as the rest of this plan in miniature — `last: 2` answered with the
first two rows is a different question answered without saying so. Both backends
now refuse it with one sentence:

> Backward pagination (last/before) is not supported on by-index connections;
> use first/after.

`listAllItemsConnection` already set this rule for a door whose read cannot walk
backwards — *"fail loud rather than silently returning the forward page"* — and
the reasoning is about the answer, not about DynamoDB. It is refused on **both**
backends rather than only on the one that cannot do it: the local door pages on
positional offsets and could walk backwards, but a door that paged backward
in-process and quietly returned the forward page once deployed is exactly the
per-backend divergence this whole field was rebuilt to remove.

The arguments stay in the SDL. One that came and went with the index's shape
would make adding a sort key a breaking schema change and force clients to
feature-detect — the same argument `includeRetired` and the reference door are
emitted unconditionally for. On AppSync the refusal is `util.error(…,
'UnsupportedPagination')` before the key condition is built; locally it is
`GraphQL_CallerError.badUserInput`, whose own comment says it exists to mirror
what AppSync surfaces, so the caller reads a real message and a `BAD_USER_INPUT`
code rather than yoga's masked "Unexpected error".

Executed on both: `first: 2` answers `q1, q2`, while `last: 2`, `before: "0"` and
the two together are each refused, in-process and in the generated AppSync JS.

## Left open

Nothing this plan implies. Making the by-index door genuinely backward-pageable
needs a seekable cursor (a sort key to cut one from) rather than DynamoDB's
forward-only continuation token, which is one change about cursors — shared with
the AppSync list door, which refuses `last`/`before` for the same reason — rather
than one about this door.
