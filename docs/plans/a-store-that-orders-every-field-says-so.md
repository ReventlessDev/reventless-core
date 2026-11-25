# Plan: a store that orders every field says so

> **Status:** 🔨 In progress. [OES1](#4-steps) and [OES2](#4-steps) built 2026-11-25, with their part
> of [OES5](#4-steps) (see each *As built*). Written 2026-11-23.
>
> **Questions and short answers:**
>
> 1. *What is wrong today?* **The sort surface is the same on every store, and it is DynamoDB's.**
>    `deriveServerCapability` puts into `OrderBy` only the fields an annotation names (`@id`,
>    `@subId`, `@compositeSubId`, `@index`, `@scanSort`), whatever store holds the read model
>    ([§2](#2-what-there-is-today)). Postgres, SQLite and the in-memory store could order a list by
>    any field, and are never asked.
> 2. *What is the second thing wrong?* **The schema says a field sorts even where the order holds
>    for one page only.** On DynamoDB an `@scanSort` field that is no index's sort key is sorted
>    within each read window, so the order breaks from the second page on; the published schema
>    still marks it `x-reventless-scanSort`, which a client reads as "the server sorts this"
>    ([§2](#2-what-there-is-today)).
> 3. *What does the plan change?* **A store says how it orders, and the read model's schema says
>    which fields the server orders the whole list by.** Each store declares its ordering
>    ([OED1](#3-decisions)); one function turns it and the annotations into the sort surface the
>    API, every resolver and the published schema use ([OED2](#3-decisions),
>    [OED4](#3-decisions)).
> 4. *What does a client do with it?* **It reads one list, `x-reventless-orders`, on the read
>    model's schema:** a field in it is sorted by the server across every page; a field not in it
>    is not, and the client sorts what it holds. A schema without the list comes from an older
>    platform, and the client keeps its own rule from the annotations ([OED4](#3-decisions)).
> 5. *What does it cost?* **On Postgres, a sort by an unindexed field reads the table and sorts
>    it**, which is fine for the read models an admin list shows; a large one gets an index later
>    ([§5](#5-out-of-scope)). DynamoDB's surface is unchanged.
>
> **Relates to:** [the list ordering and filtering analysis](../analysis/autoui-list-ordering-and-filtering.md#client-vs-server-and-what-decides-which)
> (its [per-window caveat](../analysis/autoui-list-ordering-and-filtering.md#caveat-aws-per-window-sort))
> · [the Postgres query-db adapter](done/aws-postgres-querydb-adapter.md) (done) ·
> [full-list ordered index promotion](Backlog/aws-fulllist-ordered-index-promotion.md) (backlog,
> DynamoDB's own cure) · [query capability annotations](../../packages/doc/docs-app/ui-configuration.md#29-query-capability--what-the-ui-can-filter-and-sort-by).
>
> **Ids:** `OED` (orders every field, decision) in [§3](#3-decisions), `OES` (step) in
> [§4](#4-steps).

---

## 1. In plain words

A list sorted by a field asks the server for `orderBy` on it. Today the server offers that only for
fields the app annotated, because DynamoDB can only order a table by its keys and its indexes. The
other stores the framework runs on order by any field with one `ORDER BY`, but the API never offers
it, so a client sorts the rows it fetched itself and cannot sort a list longer than what it fetched.

After this plan, a store says which way it orders. On Postgres, SQLite and the in-memory store every
plain field of a read model sorts on the server, with paging that stays in order. On DynamoDB
nothing changes in the API. And the read model's schema lists the fields the server orders the
whole list by, so a client knows, per field and per deployment, whether to ask the server or sort
the rows it holds.

## 2. What there is today

- **One surface for every store.** `deriveServerCapability` builds `sortFields` from the
  annotations alone
  ([GraphQL_FragmentGenerator.res](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res)),
  and `deriveConnectionOrderByType` turns them into `<Type>OrderField`. Four places call it with
  the same arguments: the SDL generator, the DynamoDB resolvers
  ([QueryDbResolvers_AppSync.res](../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)),
  the Postgres Lambda resolver
  ([PgQueryResolverEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/PgQueryResolverEntryPoint_Ops.res))
  and the local resolvers
  ([QueryDbResolvers_GraphQL.res](../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res)).
- **The stores can do more.** The Postgres engine orders by whatever `orderBy` names, as
  `ORDER BY (item->>'<field>')` with an id tiebreak
  ([QueryEnginePostgres.res](../../reventless/postgres/src/QueryEnginePostgres.res)). The SQLite
  store pushes the order down as `json_extract` and `ORDER BY`
  ([QueryDbStorage_Sqlite.res](../../reventless/local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res)),
  and the in-memory resolver sorts any field.
- **Postgres pages by the sorted value alone.** Its cursor carries the field's value, and the next
  page asks for `value > cursor`; rows that share the value at a page's edge are skipped. The
  in-memory store breaks ties by id, as
  [the analysis](../analysis/autoui-list-ordering-and-filtering.md#cursor-stability-across-the-two-backends)
  says.
- **DynamoDB's `@scanSort` holds per window.** A field that is no index's sort key is sorted within
  each read window; the platform warns at deploy (`validateScanSortAlignment`). The field is still
  in `OrderField` and still marked `x-reventless-scanSort`.
- **Which store holds a read model** is chosen per read model on AWS
  (`QueryDbBackend.isPostgresFor`, admin stores stay on DynamoDB) and by the platform locally.
- **The published schema** comes from `SuryToJsonSchema.deriveObjectSchema`, from the spec alone
  ([SuryToJsonSchema.res](../../reventless/core/src/components/Api/SuryToJsonSchema.res)). A
  trail's served names already travel on it as an offer the platform writes
  (`x-reventless-trail`), which is the shape this plan follows.

## 3. Decisions

| # | Question | Decision |
|---|---|---|
| **OED1** | Where is ordering known? | On the store. Each QueryDb store declares `ordering: Keys \| AnyField`: DynamoDB `Keys`, Postgres, SQLite and in-memory `AnyField`. The platform resolves it per read model from the store it picked, the way it resolves the store itself. |
| **OED2** | Who turns it into a sort surface? | `deriveServerCapability(~ordering, …)`, the one function the four callers already share. Each passes the ordering of the read model's store, so the SDL and the resolver that serves it cannot disagree. |
| **OED3** | Which fields does `AnyField` add? | Every top-level field of a scalar kind: text, number, integer, boolean, date, date-time, enum. Not arrays or objects, not `@hidden` fields, not fields stored encrypted, whose stored value does not sort as the value does. Annotated fields keep their place. |
| **OED4** | How does a client learn it? | The read model's published schema carries `x-reventless-orders`: the names the server orders the whole list by, trail dates included, written from the same capability. Present means complete; absent means an older platform, and a client falls back on the annotations. |
| **OED5** | DynamoDB's per-window `@scanSort`? | It stays in `OrderField`, so no query that runs today breaks, and is left out of `x-reventless-orders`, since its order holds for one window only. An `@scanSort` field that is an index's sort key is in the list. |
| **OED6** | Paging over any field | The cursor carries the value and the id; the next page asks for rows after the pair, and rows without the value come last in both directions. The same rule on Postgres, SQLite and in-memory, held by one parity suite. |
| **OED7** | The API differs by store | Accepted. A read model's `OrderField` lists more on a store that orders more; the SDL describes the deployment, as it already does for which read models exist. A client that pins the SDL pins it per deployment. |

## 4. Steps

**OES1 A store declares its ordering.** Waits for nothing. `ordering` on the QueryDb store's
operations, set by each store; the AWS platform's selection (`QueryDbBackend`) and the local
platform answer it per read model.
*Done when* a test reads `Keys` for a DynamoDB read model and an admin store on a Postgres
platform, and `AnyField` for a Postgres, SQLite and in-memory one.

*As built (2026-11-25):* the ordering is a value each store module declares (`ordering` beside
its `make`), not a field of the operations record: the SDL is generated at deploy time, before
any operations exist. The platform answers per read model through `QueryDb_Ordering.set`; on AWS
`QueryDbBackend_Ordering.forReadModel` picks Postgres's or DynamoDB's, and locally
`QueryDbBackend_Ordering.forBackend` picks SQLite's or the in-memory store's. A read model asked
before a platform answers gets `Keys`.

**OES2 One sort surface per store.** Waits for [OES1](#4-steps). `deriveServerCapability` takes
the ordering and adds the fields of [OED3](#3-decisions) for `AnyField`; the SDL generator and the
three resolvers pass it.
*Done when* the generated SDL of a shop read model on SQLite and on Postgres lists every scalar
field in `OrderField`, the same read model on DynamoDB lists what it lists today, and a query
ordering by an added field is answered on each `AnyField` store.

*As built (2026-11-25):* the SDL generator and the local resolver ask `QueryDb_Ordering` by the
read model's name; the DynamoDB resolvers pass DynamoDB's ordering and the Postgres Lambda
Postgres's. `OrderingCapabilityTest` holds both sort surfaces and the generated `OrderField`;
the SQLite parity suite orders by an unannotated field under the derived capability. Postgres
already ordered by whatever `orderBy` names; its own run waits for a database, with
[OES3](#4-steps). The GraphQL goldens moved: they come from the local platform, so each
`OrderField` there lists every plain field, and `Platform_Plugins` gained an `orderBy`.

**OES3 Paging stays in order.** Waits for [OES2](#4-steps). The cursor of [OED6](#3-decisions) on
Postgres and SQLite; in-memory already breaks ties by id and is checked to treat missing values the
same way.
*Done when* the parity suite pages a read model by a field with repeated and missing values, in
both directions, across page edges, and every store returns each row once in the same order.

**OES4 The schema says which fields the server orders.** Waits for [OES2](#4-steps).
`x-reventless-orders` on the published read model schema, from the capability of the read model's
store; on DynamoDB, the keys, the index sort keys, an indexed trail's dates and an `@scanSort` that
is a sort key ([OED5](#3-decisions)). Where the published schema is built before the platform has
chosen the store, the platform writes the list when it publishes the read model, as it writes the
rest of its offer.
*Done when* a test reads the list off a read model on each store, and a DynamoDB read model with a
per-window `@scanSort` lists the field in `OrderField` and not in `x-reventless-orders`.

**OES5 Docs.** With each step:
[query capability annotations](../../packages/doc/docs-app/ui-configuration.md#29-query-capability--what-the-ui-can-filter-and-sort-by)
says what each store sorts and what `x-reventless-orders` means;
[the GraphQL guide](../../packages/doc/docs-app/graphql-api-guide.md#7-filters-and-sorting-annotation-driven)
says `OrderField` depends on the store; the
[Postgres status page](../../packages/doc/docs-infrastructure/postgres-status.md#what-it-covers)
says a list sorts by any field and what that costs.
*Done when* the three say it and their links check.

**OES6 Seen on two stores.** Waits for [OES3](#4-steps) and [OES4](#4-steps). The shop's orders on
the local platform (SQLite) and on the Postgres compose stack: sorted by a field no annotation
names, paged past the first page in both directions, and the schema's list read back.
*Done when* each is seen and noted here.

## 5. Out of scope

- **Filters.** A store that orders every field also filters by every field; the same ordering
  value and a list beside `x-reventless-orders` could offer it. A plan of its own, once sorting has
  shown the shape.
- **Indexes on Postgres.** A sort by an unindexed field reads the read model's table and sorts it.
  An expression index for an `@index` field, or for a field a deployment sorts often, belongs to the
  Postgres adapter's own plan.
- **DynamoDB ordering every field.** That is
  [full-list ordered index promotion](Backlog/aws-fulllist-ordered-index-promotion.md), which stays
  in the backlog; this plan only stops the schema from claiming a per-window order holds for the
  whole list.
