# State-entry dates as queryable fields: what a read model would derive from its lifecycle trail

> **Status:** Analysis · no implementation. Written 2026-11-21, read against the code on `alpha` the
> same day. Its recommendations were taken the same day as the decisions of the plan
> [state-entry dates a view can query](../plans/state-entry-dates-a-view-can-query.md). It takes up the question the
> [lifecycle trail plan](../plans/done/lifecycle-trail-on-a-state-view.md) left open in its
> [§7](../plans/done/lifecycle-trail-on-a-state-view.md#7-migration-in-the-shipped-examples): a
> date that lives only in a trail cannot name, sort or range-filter rows. It extends the
> [list ordering and filtering analysis](autoui-list-ordering-and-filtering.md#further-opportunities)
> with ranges and with dates the framework derives.
>
> **Questions and short answers:**
>
> 1. *Can a view drop a field like `placedAt` and keep the trail as its only record of entering a
>    state, losing nothing?* **Not today; yes once the framework derives the date as a field.**
>    A read model does not index inside an array, so naming, sorting and filtering need a scalar
>    ([§2](#2-what-there-is-today)). The framework can write that scalar in the pass that appends
>    to the trail, from the same time ([SEF1](#sef1-derived-per-state-fields)).
> 2. *Is deriving it cleaner than the app writing it?* **Yes.** The app declares the lifecycle and
>    the trail and writes no time field for a transition; the derived field cannot drift from the
>    trail, and every state gets one, not only the one the app thought of
>    ([§3](#3-the-capability)).
> 3. *Would that allow sorting and filtering by every state's date?* **Yes, for each state the
>    view opts in.** Each derived field enters the capability like a declared one
>    ([SEF3](#sef3-capability-and-the-graphql-surface)); indexing all of them is not free on every
>    backend ([SEF5](#sef5-indexes-and-what-they-cost)).
> 4. *Can the server filter and sort by a state's date and the state together?* **Yes, in one
>    query.** An index keyed by the lifecycle field and sorted by the derived
>    entered-current-state-at field answers "rows in state S, longest there first" and "in S since
>    before T" as a key lookup and a range on the sort key
>    ([SEF4](#sef4-the-lifecycle-index-state-and-time-in-state-together)).
>
> **Relates to:** [lifecycle-trail-on-a-state-view.md](../plans/done/lifecycle-trail-on-a-state-view.md) (done) ·
> [autoui-list-ordering-and-filtering.md](autoui-list-ordering-and-filtering.md) ·
> [online-shop-seed-over-days.md](../plans/done/online-shop-seed-over-days.md) (done) ·
> the doc page [Recording When a Row Reached Each State](../../packages/doc/docs-app/components/stateviewslice.md#recording-when-a-row-reached-each-state).
>
> **Ids:** SEF the capability's parts ([§3](#3-the-capability)), SEQ open questions
> ([§5](#5-open-questions)).

---

## 1. In plain words

A view that declares a lifecycle trail gets, on every row, the list of states the row reached and
when. The machinery writes it from each event's own time; the projection never touches it. But the
list is an array, and a query can only sort and filter by a row's plain fields. So an app that wants
its orders sorted by placement keeps a `placedAt` field beside the trail, written by hand from the
same time, and every other state (shipped, cancelled, archived) can be shown but never sorted or
filtered by.

This analysis proposes that the machinery also keep, beside the trail, a few plain fields derived
from it: when the row first and last entered each state, when it entered the state it is in now,
and how often it entered each. They are written in the same pass, from the same time, on every
backend. A view then sorts and filters by any state's date like by any field, and an app writes no
time field for a transition.

## 2. What there is today

- **The trail.** `Lifecycle.Trail.t<'state>` is an array of `{state, at, afterGap?}`
  ([Lifecycle.res](../../reventless/spec/src/types/Lifecycle.res)). `Trail.record` appends an
  entry; `Projection.applyOverlays` calls it only when the lifecycle value changes, with `at` the
  envelope's time, never a clock ([Projection.res](../../reventless/core/src/Projection.res)). The
  same pass composes `displayName`. The AWS state-view entry point does the same from `meta.time`
  and writes nothing when the time is empty
  ([StateViewSliceEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/StateViewSliceEntryPoint_Ops.res)).
- **Its GraphQL shape.** `SchemaType.trailShape` emits an object type whose `state` reuses the
  lifecycle enum ([SchemaType.res](../../reventless/core/src/components/Api/SchemaType.res)).
- **Filter and sort.** `deriveServerCapability`
  ([GraphQL_FragmentGenerator.res](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res))
  derives one capability from `@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`, `@scan`
  and `@scanSort`. Every filterable field gets `<f>Eq`; only `@subId` and `@compositeSubId` get
  `<f>From`/`<f>To`. An `@index` field is filterable by equality and sortable, with no range. The
  ordering is one field (`<T>OrderBy { field, direction }`).
- **Indexes.** An `@index` becomes an `indexConfig`; on DynamoDB a GSI with `hashKey = idField ??
  index` and `rangeKey = subIdField`. `indexConfig` already has `derived?` for an index the
  framework adds (as for `@owner`). Core counts no indexes; DynamoDB caps a table at 20 GSIs, noted
  only in the backlog plan for `@searchable`.
- **Nothing reads a trail's contents.** No code computes a state's first or latest entry, a time in
  state or a visit count. The trail plan's non-goals include "no query surface of its own".
- **Data to try it on.** The shop's seed can run on several days
  ([online-shop-seed-over-days.md](../plans/done/online-shop-seed-over-days.md)), so its trails are
  spread out on a stack seeded that way; a single local run places and ships within minutes.

## 3. The capability

### SEF1. Derived per-state fields

For a view with a trail over lifecycle `L`, the machinery keeps on each row, for each state `S` of
`L` the row has entered:

- **first entry of S** and **latest entry of S** (instants),
- **visits to S** (a count),

and once per row:

- **entered current state at** (an instant): the `at` of the trail's last entry.

They are written in `applyOverlays`, right after `Trail.record`, from the same `at`; a row that
never entered `S` has no value for it. On replay they come out the same, because the trail does. A
row stored before the change gets them on its next transition, or on a rebuild
([SEQ4](#5-open-questions)).

### SEF2. Where they live on the row

Two spellings:

1. **Synthetic top-level attributes**, like the composite index keys `_name_pk`/`_name_sk`:
   `_entered_Placed` (the latest visit), `_entered_Placed_first`, `_visits_Placed`, `_entered_current`. Every
   backend can index or filter a top-level attribute, and the AWS adapter already writes synthetic
   attributes.
2. **A nested object** `entered: {Placed: {first, latest, visits}, …}`. Reads better over the API,
   but DynamoDB indexes only top-level attributes.

**Recommendation:** store them as synthetic top-level attributes (1), and present them over GraphQL
as a typed object beside the trail ([SEF3](#sef3-capability-and-the-graphql-surface)), so storage and
API each get the shape that suits them.

### SEF3. Capability and the GraphQL surface

- **Reading.** An `<Parent><Trail>Entered` object with one field per state, each `{first, latest,
  visits}`, plus `enteredCurrentAt`. A client that only reads gets the dates without walking the
  array.
- **Filtering.** For each opted-in state, `enteredPlacedFrom`/`enteredPlacedTo` (latest visit) and,
  for the first visit, `enteredPlacedFirstFrom`/`…To`; `enteredCurrentFrom`/`…To`; `visitsPlacedFrom`
  for "entered more than once".
- **Sorting.** The same names as values of `<T>OrderField`.
- **Capability.** `deriveServerCapability` pushes them like declared fields, with `range: true`, so
  every client that reads the capability sees them without a special case.

### SEF4. The lifecycle index: state and time in state together

A query a work list asks constantly: rows in state `S`, longest there first; or rows in `S` since
before `T`. With an index whose key is the lifecycle field and whose sort key is
`_entered_current`, both are one key lookup and a range on the sort key. On DynamoDB that is a
Query, not a Scan; on in-memory, SQLite and Postgres any predicate works and the index is only a
speed-up. The same index serves "everything in `S`", sorted by arrival.

Today's vocabulary is close: `@index` on the lifecycle field with `@indexSubId` on the sort field
names such an index. Three things are missing: a derived field cannot carry `@indexSubId`, an index's
sort key gets no `From`/`To`, and the lifecycle field is not filterable unless annotated. A
trail-level spelling would say it once: `@trail(index)` on the trail field adds the lifecycle index as
a `derived` index.

A filter on one state's date while the row is in another ("in `Cancelled`, first placed last week")
pairs this index's key with a filter on another derived field: a Query plus a FilterExpression on
DynamoDB, a plain predicate elsewhere.

### SEF5. Indexes and what they cost

Each derived field a view may be sorted or filtered by on the server is, on DynamoDB, either a GSI
or a Scan with a filter, the same choice `@index` and `@scan`/`@scanSort` make today. Per state there
are up to three candidates (first, latest, visits); a five-state lifecycle is fifteen, against a cap
of 20 GSIs per table.

- **Derived always, indexed by opt-in.** The fields cost storage only. The trail annotation names the
  states to index, `@trail(index=[Placed, Shipped])`, and the lifecycle index of
  [SEF4](#sef4-the-lifecycle-index-state-and-time-in-state-together) is one more.
- **Sparse indexes.** A row that never entered `S` has no `_entered_S`, so a GSI on it holds
  only rows that did; "everything ever cancelled" is cheap.
- **Range filters** on any date, derived or declared, are the `@scanRange` the list analysis
  proposes; this capability needs them on index sort keys as well.

### SEF6. Durations

The time between two states (placed to shipped) is a difference of two derived fields. A client can
compute it from the fields it reads. Sorting a list by it on the server needs it stored; a
`@trail(duration=(Placed, Shipped))` would write it in the same pass ([SEQ3](#5-open-questions)).

### SEF7. What stays as it is

- **Business time.** The derived fields are the recorded time of the transition. A date the business
  states, or one entered after the fact, is a field the app declares. Nothing backdates an event.
- **Views without a trail.** Nothing is derived; nothing reconstructs a trail from fields that look
  like timestamps.
- **The trail itself.** Unchanged in shape and in who writes it.

## 4. What it lets an app drop

The shop's Orders keeps `placedAt` as its `@displayName`, its `@summary` and its only sortable
date. With [SEF1](#sef1-derived-per-state-fields) to [SEF5](#sef5-indexes-and-what-they-cost), the
sort and the filter move to the derived `Placed` date, and a field written from `meta.time` beside
a trail becomes something to flag. The name does not move by itself: `@displayName` points at a
field, and an order needs another one, or `@displayName` learns to name a derived date
([SEQ5](#5-open-questions)).

## 5. Open questions

- **SEQ1. Latest or first, by default?** The trail records every visit. **Recommendation:** derive
  both; a client names which. The unqualified name (`enteredPlaced…`) is the latest visit, which
  answers "since when in that state" for every state alike, and `…First…` the first. *Revisit if*
  most queries ask for the first visit.
- **SEQ2. Where is the opt-in written?** **Recommendation:** on the trail field,
  `@trail(index=[…])`, so the states are named once next to the lifecycle they belong to, rather than
  on synthetic fields an author never sees. *Revisit if* an app needs different index projections per
  state.
- **SEQ3. Are durations stored?** **Recommendation:** not by default; clients compute them from the
  derived dates. Add `@trail(duration=…)` when an app needs a server sort by one. *Revisit if* lists
  sorted by a duration outgrow one page.
- **SEQ4. Rows stored before the change.** **Recommendation:** derive on the next transition and
  offer a rebuild that recomputes from the trail, as replay already would. *Revisit if* a deployed
  table is too large to rebuild.
- **SEQ5. Can a row be named by a derived date?** **Recommendation:** no; a name points at a declared
  field, and a date is a poor name in a reference list anyway. The app that drops a time field gives
  its rows another name first. *Revisit if* several apps want it.
- **SEQ6. A filter relative to now ("in S for more than three days").** **Recommendation:** no new
  operator; a client sends an absolute bound (now minus three days) on `enteredCurrent…To`. *Revisit
  if* stored queries must keep meaning "three days before whenever they run".
