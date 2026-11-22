# Plan: state-entry dates a view can query

> **Status:** Plan · in progress ([QDS1](#4-steps) to [QDS5](#4-steps) done; [QDS6](#4-steps) done locally, the `alpha` stack open; [QDS8](#4-steps) built, its run on `alpha` open). Written 2026-11-21 from the analysis
> [state-entry dates as queryable fields](../analysis/state-entry-dates-as-queryable-fields.md),
> *the analysis*, whose recommendations are taken as this plan's decisions ([§3](#3-decisions)).
>
> **Questions and short answers:**
>
> 1. *What does it build?* **Plain fields derived from a lifecycle trail, kept by the machinery:**
>    when a row first and last entered each state, how often, and when it entered the state it is
>    in. They are readable over GraphQL, and filterable and sortable by range for the states a view
>    opts into ([§4](#4-steps)).
> 2. *What does an app write?* **One annotation on its trail field**, `@trail({index: [Placed,
>    Shipped]})`, for the states it wants on the server; deriving needs nothing
>    ([QDD2](#3-decisions)).
> 3. *Can a query combine a state and its date?* **Yes.** An opted-in trail adds an index keyed by
>    the lifecycle field and sorted by when the row entered its state, so "in Placed, longest there
>    first" is a key lookup and a range ([QDS5](#4-steps)).
> 4. *What does it leave alone?* **The trail's shape and who writes it, business-time fields, and
>    the shop's `placedAt`**, which stays until its orders have another name ([QDD6](#3-decisions)).
>
> **Relates to:** [the analysis](../analysis/state-entry-dates-as-queryable-fields.md) ·
> [lifecycle-trail-on-a-state-view.md](../plans/done/lifecycle-trail-on-a-state-view.md) (done; its
> [§7](../plans/done/lifecycle-trail-on-a-state-view.md#7-migration-in-the-shipped-examples) is the
> question this answers) ·
> [the list ordering and filtering analysis](../analysis/autoui-list-ordering-and-filtering.md#richer-filter-primitives).
>
> **Ids:** `QDD` (queryable dates, decision) in [§3](#3-decisions), `QDS` (step) in [§4](#4-steps).

---

## 1. In plain words

A view that declares a lifecycle trail records on each row which states it reached and when. A
query cannot sort or filter by anything inside that list, so an app that wants its rows sorted by
when they were placed writes a `placedAt` field beside the trail, and no other state can be sorted
or filtered by at all.

After this plan, the machinery writes beside the trail a few plain fields it derives from it, in
the same pass and from the same time: for each state, the first and the latest time the row entered
it and how many times; for the row, when it entered its current state. A client reads them without
walking the trail. For the states a view names in one annotation, the server filters them by range
and sorts by them, and a list of one state comes back ordered by how long its rows have been in it.

## 2. What there is today

- The trail is appended in `Projection.applyOverlays`, from the envelope's time, on every write path:
  the local builders and callbacks, the deployed JSON path (`rewriteJsonAction`) and the AWS
  state-view entry point ([Projection.res](../../reventless/core/src/Projection.res)). The same pass
  composes `displayName`.
- `QueryDb_Operations.injectCompositeIndexAttrs` already writes attributes the framework makes
  (`_pk`/`_sk` of a composite index) on every save
  ([QueryDb_Operations.res](../../reventless/core/src/components/QueryDb/QueryDb_Operations.res)).
- `deriveServerCapability` builds the filter and sort surface from field annotations; a field with
  `range: true` gets `<f>From`/`<f>To`, today only `@subId` and `@compositeSubId`
  ([GraphQL_FragmentGenerator.res](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res)).
  The SQLite resolver turns every filter field into one `WHERE` joined by `AND`, ranges included
  ([QueryDbStorage_Sqlite.res](../../reventless/local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res)).
- An `@index` becomes a DynamoDB GSI (`hashKey = idField ?? index`, `rangeKey = subIdField`);
  `indexConfig.derived` marks one the framework adds. Nothing counts GSIs against the cap of 20.

## 3. Decisions

The analysis's recommendations, taken.

| # | Question | Decision |
|---|---|---|
| **QDD1** | First or latest visit? | Both are derived. The unqualified name is the latest visit (`enteredPlaced`), which answers "since when in that state" for every state alike; the first visit is named (`enteredPlacedFirst`). From the analysis's [SEQ1](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD2** | Where is the opt-in written? | On the trail field: `@trail({index: [Placed, Shipped]})` puts those states' fields on the server and adds the lifecycle index; `@trail({index: true})` adds only the lifecycle index. (The analysis wrote `@trail(index=[…])` and a bare `@trail(index)`; neither parses as a ReScript attribute payload, so the record payload `@owner` and `@retired` already take is used, as [QDS3](#4-steps) allowed.) Deriving and reading need no annotation. [SEQ2](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD3** | Are durations stored? | No. A client computes them from the derived dates; a stored duration waits for an app that sorts by one. [SEQ3](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD4** | Rows stored before the change? | They are derived on their next write, and `pnpm run views:rederive` backfills every row from its trail, on a deployed stack's DynamoDB tables and on a local SQLite store ([QDS8](#4-steps)). [SEQ4](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD5** | Can a row be named by a derived date? | No. `@displayName` points at declared fields. [SEQ5](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD6** | A filter relative to now? | No new operator; a client sends an absolute bound. [SEQ6](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD7** | How are they stored? | As synthetic top-level attributes: `_entered_<State>`, `_entered_<State>_first`, `_visits_<State>`, `_entered_current`. With them `_trail`, one value on every row whose trail has an entry, which the per-state indexes are keyed by ([QDS5](#4-steps)). Every backend can filter and index a top-level attribute. From the analysis's [SEF2](../analysis/state-entry-dates-as-queryable-fields.md#sef2-where-they-live-on-the-row). |
| **QDD8** | What does the API call them? | Camel case without the underscore, in one table both the SDL and every resolver read: `enteredPlaced`, `enteredPlacedFirst`, `visitsPlaced`, `enteredCurrent`. Reading is an object beside the trail, `<trailField>Entered { placed { latest first visits } current }`. [SEF3](../analysis/state-entry-dates-as-queryable-fields.md#sef3-capability-and-the-graphql-surface). |
| **QDD9** | When are they written? | On every write of a row with a trail, not only on a transition: they are a pure function of the trail, so recomputing is cheap, and a row whose typed state dropped the synthetic attributes on the way through an update gets them back. |
| **QDD10** | What does a sort by a state's date do with a row that never entered the state? | Sorting or filtering by a state's date covers the rows that entered it; a row that never did is left out, on every backend, as the sparse index does. `enteredCurrent` covers every row with a trail. A count (`visits<State>`) compares as a number. |

## 4. Steps

**QDS1 Derive.** `Lifecycle.Trail.derive(trail)` in spec returns, per state, `{first, latest,
visits}` and `current`, a pure function of the trail. `applyOverlays` writes the result as the
attributes of [QDD7](#3-decisions) right after it records, on every pass ([QDD9](#3-decisions)).
First, list every write path that appends a trail and confirm each goes through `applyOverlays`;
one that does not gets the same call.
*Done when* `LifecycleTrailTest` asserts the attributes after a create, a transition, a reopen (two
visits to `Placed`) and an update that changes no state, on the builder, the callback and the JSON
path; and the AWS state-view entry point's test asserts them on a saved item.
*Done* 2026-11-21. The trail is appended on four paths: the state-view builder and callback and
the read-model callback (`rewriteAction`), and the AWS state-view entry point (`rewriteJsonAction`);
all four go through `applyOverlays`. A typed state cannot hold the attributes (sury drops them when
it decodes the row back), so `QueryDb_Operations` writes them again from the trail at every typed
save; `Lifecycle.Trail.writeDerived` is the one function both call. It also removes attributes the
trail no longer holds.

**QDS2 Read.** `SchemaType.trailShape` gains the `<trailField>Entered` object of
[QDD8](#3-decisions), one field per lifecycle state, and every backend's row reader fills it from the
synthetic attributes. The attributes themselves stay out of the SDL.
*Done when* a GraphQL test on the in-memory backend reads `trailEntered { placed { latest first
visits } current }` for a reopened row, and the SDL snapshot shows the type.
*Done* 2026-11-22. The object is a field resolver on the view's type, as `_change` is, rather
than a step in each backend's row reader: one resolver locally (in-memory, SQLite and Postgres
alike) and one APPSYNC_JS field resolver on AWS, attached by both the DynamoDB and the Postgres
resolver sets, which answers without a data source call. Both read the same attributes
(`Lifecycle.Trail.readEntered` locally). The SDL types are `<Type><Trail>Entered` (one nullable
entry per state, keyed `placed`, and `current`) and `<Type><Trail>Visits { latest first visits }`;
the field is nullable, and absent when the trail is `@internal`. A state whose key would be
`current` is refused at generation. The hybrid example's `domain-api.graphql` golden carries the
three views' types.

**QDS3 The annotation.** `@trail` joins the ppx vocabulary with an optional `index` argument: a
list of lifecycle constructors, or nothing for the lifecycle index alone ([QDD2](#3-decisions)).
`StateAnnotations` parses it into the spec; a constructor the lifecycle does not declare is a ppx
error that names the declared ones. If the payload syntax cannot carry constructors, the nearest
spelling the vocabulary already uses (a list of strings) is taken and the decision updated.
*Done when* the ppx tests cover a list, a bare `@trail(index)`, and an unknown state.
*Done* 2026-11-22, spelled `@trail({index: [Placed, Shipped]})` and `@trail({index: true})`
([QDD2](#3-decisions)); the constructors stay constructors. The spec carries it as the optional
`trailIndex: array<string>` (empty for the lifecycle index alone). Beside the plan's three cases,
the ppx refuses `@trail` on a field not typed `Reventless.Lifecycle.Trail.t<…>` and a second
`@trail` on one record; the unknown-state check runs where the lifecycle is declared in the same
file, as `@retired`'s does. `@trail` joins the annotations a union field refuses.

**QDS4 Filter and sort.** `deriveServerCapability` pushes, for each opted-in state, `entered<State>`,
`entered<State>First` and `visits<State>` with `range: true`, and `enteredCurrent` for any opted-in
trail; the lifecycle field becomes filterable by `Eq`. Each name sorts. The in-memory, SQLite and
Postgres resolvers map the API names to the attributes through the table of [QDD8](#3-decisions).
*Done when* on each of the three, one request filters `lifecycleEq: Placed` with `enteredCurrentTo`
and sorts by `enteredCurrent`, and returns the rows the test expects in order, across two pages.
*Done* 2026-11-22. The table of [QDD8](#3-decisions) is the capability's own `stored` map (API name →
attribute), filled by `deriveServerCapability` from `Lifecycle.Trail.queryNames` and read through
`storedName` by the in-memory spec, the SQLite push-down and the Postgres push-down, for filters,
the order and the cursor alike. The lifecycle filter is `<lifecycle>Eq: String`, like every other
enum filter. A declared field named like a derived one is refused at generation. The request ran on
all three; Postgres against a throwaway `postgres:16-alpine` (the test still skips without
`PG_URL`). Two existing rules carry over unchanged: every backend compares values as text, so a
`visits` range compares `"10"` below `"9"`; and a row with no date for the named state sorts first
ascending on the in-memory and SQLite backends and last on Postgres, as any absent field does. The
DynamoDB resolver reads the map in [QDS5](#4-steps).
*Fixed* 2026-11-22, after [QDS5](#4-steps). The capability names its numeric fields (`numeric`) and
the names that cover only rows carrying them (`reached`). A numeric field's range, order and cursor
compare as numbers on every backend, declared numeric fields included; ordering by a state's date
leaves out the rows without it ([QDD10](#3-decisions)). Absent values of declared fields sort as
before.

**QDS5 DynamoDB.** An opted-in trail adds derived GSIs: one per opted-in state on `_entered_<State>`
(sparse: a row that never entered the state is not in it), and the lifecycle index, key the lifecycle
field, sort key `_entered_current`. A request whose filter names the lifecycle field queries the
lifecycle index with `From`/`To` as the key condition; another opted-in state's range becomes a
`FilterExpression`. The deploy counts a table's GSIs and refuses more than 20, naming the annotations
that added them.
*Done when* the DynamoDB adapter tests run the request of [QDS4](#4-steps) as a `Query` on the lifecycle index,
and a component with too many indexes fails its deploy check with the count.
*Done* 2026-11-22. The indexes are derived in core, not by the ppx: `ReadModel.trailIndexes` reads
`trailIndex` off the state schema, and `QueryDb_Builder` hands the declared and the derived indexes
to the storage and the resolvers together. The plan left the per-state index's partition key open,
and a date cannot be one (a Query needs equality on it). The save now also writes `_trail = "1"` on
every row whose trail has an entry, and each per-state index is keyed `_trail` and sorted by
`_entered_<State>`, so a row that never entered the state is absent from it. The lifecycle index is
`_lifecycle`. The list door picks a Query from the request: `<lifecycle>Eq` keys the lifecycle
index, with `enteredCurrentFrom`/`To` as its sort-key condition and `orderBy: enteredCurrent`
read in index order, either direction; failing that, a range on or an order by `entered<State>`
keys that state's index. What the key condition answers leaves the FilterExpression, every other
filter stays in it, and the rest is a Scan as before. A caller the `@owner` index scopes keeps
that Query; an exempt one may take the trail's. Cursors carry which read minted them, and one
replayed on another read is refused. The count check sits in the DynamoDB storage maker and names
each index's annotation (`@index`, `@owner`, `@trail`). The Postgres resolver set on AWS no longer
gives a derived index a by-index door the SDL lacks, which the `@owner` index had been getting too.
Tested on the generated resolver run in jest and compiled by AppSync's `EvaluateCode`; not yet
against a live table. Each per-state index, and each lifecycle state, is one partition, so a view
writing past a partition's throughput would need it sharded.

**QDS6 The shop opts in.** Orders gets `@trail({index: [Placed, Shipped, Cancelled]})`, Products
`@trail({index: [Listed, Archived, Discontinued]})`, Categories `@trail({index: [Listed,
Archived]})`: every state, since the first visit to `Listed` is when a row joined the catalog.
`placedAt` stays ([QDD5](#3-decisions)).
*Done when* the shop's GraphQL answers "orders in Placed for more than three days, oldest first" on
the local platform and on the `alpha` stack, where the seed's runs on several days spread the trails
([online-shop-seed-over-days.md](done/online-shop-seed-over-days.md)).
*Local half done* 2026-11-22. The three views carry the annotation; the GSIs per table are Orders 5
(`_owner`, `_lifecycle`, `_entered_Placed`, `_entered_Shipped`, `_entered_Cancelled`), Products 5
(`categoryId`, `_lifecycle`, `_entered_Listed`, `_entered_Archived`, `_entered_Discontinued`) and
Categories 3. On the local platform (memory
backend, the `full` set seeded, read as an elevated caller), `lifecycleEq: Placed` with
`enteredCurrentTo` three days back returns no rows: one local seed run dates every trail within
the same second. With a bound inside that second the same request pages Placed orders oldest
first (`ord-001`, `ord-004`, `ord-006`, then `ord-009`, `ord-010`, `ord-011`), and
`enteredShippedFrom` seven days back sorted by `enteredShipped` returns shipped orders in entry
order. `enteredListedFirst` sorts products and categories by when they joined the catalog, and
ordering by `enteredArchived` or `enteredDiscontinued` returns only the one product the seed
archived and the one it discontinued ([QDD10](#3-decisions)). The seed reopens no order, so a
second visit is not seen there. *Open:* the three-day request on the `alpha` stack, after the push.

**QDS7 Docs.** The doc page's section
[Recording When a Row Reached Each State](../../packages/doc/docs-app/components/stateviewslice.md#recording-when-a-row-reached-each-state)
gains the derived fields, `@trail({index: …})` and the lifecycle index; the vocabulary reference the
annotation; the list ordering analysis a pointer under
[Richer filter primitives](../analysis/autoui-list-ordering-and-filtering.md#richer-filter-primitives).
The docs also record a limit: each per-state index and each lifecycle state is one DynamoDB
partition, so a view writing past a partition's throughput (about 1000 writes/s; throttling shows in
CloudWatch) would need a shard count on `@trail`. Sharding keys the index by `hash(id) mod N`, a read
queries all N and merges them, and a rebuild re-keys the rows.
*Done when* the docs build, and their links check.

**QDS8 Backfill.** A row saved before [QDS1](#4-steps) carries its trail and none of the derived
attributes, so the indexes of [QDS5](#4-steps) leave it out until its next write, and the rows that
have sat longest in a state are the ones nothing writes again. `views:rederive` writes them from the
trail with the same `Lifecycle.Trail` functions a save uses. On AWS (`ReventlessSeedAws_Rederive`,
run from the deployment's platform project like `seed:reconcile`) it finds a stack's view tables by
their tags (`reventless:platform`, `reventless:environment`, `reventless:role=QueryDb`), scans each,
and sends an `UpdateItem` that sets or removes only the derived attributes, conditioned on
`size(<trail>) = <length when read>`; a row written in between already got them from its save and
is skipped. On SQLite (`LocalViewsRederive`, from platform-local) the update is conditioned on the
row's stored text being unchanged. The trail field is found by its shape (a non-empty array of
`{state, at}`), since a table does not name its schema. A dry run is the default; `-- --apply`
writes; a second run finds nothing.
*Done when* unit tests cover the update a row gets, a second run changing nothing and a row written
during the run being skipped, on DynamoDB and SQLite; and on the `alpha` stack the dry run counts
the rows, `--apply` writes them, and the three-day request of [QDS6](#4-steps) answers.
*Built* 2026-11-22. The `alpha` dry run picked `Categories-812337e` (9 rows, 8 to change),
`Products-0ba6849` (26, 25) and `Orders-10f6a39` (79, 78) by their tags. *Open:* `--apply` on
`alpha`, then the request of [QDS6](#4-steps).

## 5. Out of scope

- **Range filters on declared fields** (`@scanRange`), which the list analysis proposes. This plan
  gives ranges to the derived fields and to the lifecycle index's sort key only.
- **Stored durations** ([QDD3](#3-decisions)).
- **Dropping `placedAt` from the shop.** It names the orders; that is a decision for the example
  once its orders have another name.
- **Counting per day on the server.** A client counts the rows it reads.
