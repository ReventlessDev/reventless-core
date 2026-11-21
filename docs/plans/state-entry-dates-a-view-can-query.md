# Plan: state-entry dates a view can query

> **Status:** Plan · in progress ([QDS1](#4-steps) and [QDS2](#4-steps) done). Written 2026-11-21 from the analysis
> [state-entry dates as queryable fields](../analysis/state-entry-dates-as-queryable-fields.md),
> *the analysis*, whose recommendations are taken as this plan's decisions ([§3](#3-decisions)).
>
> **Questions and short answers:**
>
> 1. *What does it build?* **Plain fields derived from a lifecycle trail, kept by the machinery:**
>    when a row first and last entered each state, how often, and when it entered the state it is
>    in. They are readable over GraphQL, and filterable and sortable by range for the states a view
>    opts into ([§4](#4-steps)).
> 2. *What does an app write?* **One annotation on its trail field**, `@trail(index=[Placed,
>    Shipped])`, for the states it wants on the server; deriving needs nothing
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
| **QDD2** | Where is the opt-in written? | On the trail field: `@trail(index=[Placed, Shipped])` puts those states' fields on the server and adds the lifecycle index; a bare `@trail(index)` adds only the lifecycle index. Deriving and reading need no annotation. [SEQ2](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD3** | Are durations stored? | No. A client computes them from the derived dates; a stored duration waits for an app that sorts by one. [SEQ3](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD4** | Rows stored before the change? | They are derived on their next write; a rebuild recomputes every row from its trail. [SEQ4](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD5** | Can a row be named by a derived date? | No. `@displayName` points at declared fields. [SEQ5](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD6** | A filter relative to now? | No new operator; a client sends an absolute bound. [SEQ6](../analysis/state-entry-dates-as-queryable-fields.md#5-open-questions). |
| **QDD7** | How are they stored? | As synthetic top-level attributes: `_entered_<State>`, `_entered_<State>_first`, `_visits_<State>`, `_entered_current`. Every backend can filter and index a top-level attribute. From the analysis's [SEF2](../analysis/state-entry-dates-as-queryable-fields.md#sef2-where-they-live-on-the-row). |
| **QDD8** | What does the API call them? | Camel case without the underscore, in one table both the SDL and every resolver read: `enteredPlaced`, `enteredPlacedFirst`, `visitsPlaced`, `enteredCurrent`. Reading is an object beside the trail, `<trailField>Entered { placed { latest first visits } current }`. [SEF3](../analysis/state-entry-dates-as-queryable-fields.md#sef3-capability-and-the-graphql-surface). |
| **QDD9** | When are they written? | On every write of a row with a trail, not only on a transition: they are a pure function of the trail, so recomputing is cheap, and a row whose typed state dropped the synthetic attributes on the way through an update gets them back. |

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

**QDS4 Filter and sort.** `deriveServerCapability` pushes, for each opted-in state, `entered<State>`,
`entered<State>First` and `visits<State>` with `range: true`, and `enteredCurrent` for any opted-in
trail; the lifecycle field becomes filterable by `Eq`. Each name sorts. The in-memory, SQLite and
Postgres resolvers map the API names to the attributes through the table of [QDD8](#3-decisions).
*Done when* on each of the three, one request filters `lifecycleEq: Placed` with `enteredCurrentTo`
and sorts by `enteredCurrent`, and returns the rows the test expects in order, across two pages.

**QDS5 DynamoDB.** An opted-in trail adds derived GSIs: one per opted-in state on `_entered_<State>`
(sparse: a row that never entered the state is not in it), and the lifecycle index, key the lifecycle
field, sort key `_entered_current`. A request whose filter names the lifecycle field queries the
lifecycle index with `From`/`To` as the key condition; another opted-in state's range becomes a
`FilterExpression`. The deploy counts a table's GSIs and refuses more than 20, naming the annotations
that added them.
*Done when* the DynamoDB adapter tests run the request of [QDS4](#4-steps) as a `Query` on the lifecycle index,
and a component with too many indexes fails its deploy check with the count.

**QDS6 The shop opts in.** Orders gets `@trail(index=[Placed, Shipped, Cancelled])`, Products and
Categories `@trail(index=[Archived])`. `placedAt` stays ([QDD5](#3-decisions)).
*Done when* the shop's GraphQL answers "orders in Placed for more than three days, oldest first" on
the local platform and on the `alpha` stack, where the seed's runs on several days spread the trails
([online-shop-seed-over-days.md](done/online-shop-seed-over-days.md)).

**QDS7 Docs.** The doc page's section
[Recording When a Row Reached Each State](../../packages/doc/docs-app/components/stateviewslice.md#recording-when-a-row-reached-each-state)
gains the derived fields, `@trail(index=…)` and the lifecycle index; the vocabulary reference the
annotation; the list ordering analysis a pointer under
[Richer filter primitives](../analysis/autoui-list-ordering-and-filtering.md#richer-filter-primitives).
*Done when* the docs build, and their links check.

## 5. Out of scope

- **Range filters on declared fields** (`@scanRange`), which the list analysis proposes. This plan
  gives ranges to the derived fields and to the lifecycle index's sort key only.
- **Stored durations** ([QDD3](#3-decisions)).
- **Dropping `placedAt` from the shop.** It names the orders; that is a decision for the example
  once its orders have another name.
- **Counting per day on the server.** A client counts the rows it reads.
