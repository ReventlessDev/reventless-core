# Plan: a state view records when it reached each state, not just which one it is in

**Status.** 2026-09-08. **Done.** The relative links below are written from
`docs/plans/done/`.

**Goal.** One declared field on a state view carries the row's lifecycle trail —
each state it entered and when — filled by the projection machinery rather than
by the domain, so a view answers "when did this reach that" without a field per
state and without a line of per-domain code.

**Relates to:**

- [`docs/plans/done/semantic-date-time.md`](./semantic-date-time.md) — **builds on it.**
  An entry's instant is a `Reventless.DateTime.t`, written bare, which is the
  spelling that plan's step 5 introduces. Its D4 also retires the `""` sentinel,
  and §1 below is what a domain declares once that admission is made.
- [`docs/plans/done/lifecycle-model-harvest.md`](./lifecycle-model-harvest.md)
  — derives each command's `allowedStates` / `targetState` from the GWT corpus.
  That is the lifecycle as *declared*; this is the lifecycle as *travelled*.
- [`docs/plans/lifecycle-transition-annotation.md`](../lifecycle-transition-annotation.md)
  — `@transition` names the edges. Nothing yet records that a row took one.

---

## Why

A state view records the state a row is **in**. It does not record when the row
got there, and the information is not missing from the system — it arrives on
every event envelope as `meta.time` and the projection drops it.

Domains work around this one field at a time. `Orders` declares `placedAt` and
`shippedAt`, both filled by hand in
[`Orders_Projection.res`](../../examples/online-shop-hybrid/ordering/src/Order/StateViewStream/Orders_Projection.res):

```rescript
| OrderShipped({orderId}) => [
    Update(orderId, state => {...state, lifecycle: Shipped, shippedAt: meta.time}),
  ]
| OrderCancelled({orderId}) => [Update(orderId, state => {...state, lifecycle: Cancelled})]
```

Three things are wrong with that shape, and the third is the one that matters.

**It is one field per state, written by hand.** Three states, two fields, and the
asymmetry is not a decision anyone made — `OrderCancelled` has `meta.time` in
scope on the line above and discards it.

**It is forgotten when a state is added.** A new state needs a new field, a schema
change and a projection edit, and nothing fails if all three are skipped. The
lifecycle grows; the record of it does not.

**And it is missing for exactly the states nobody thinks about.** Cancellations,
rejections, `@retired` withdrawals. `Products` and `Categories` carry `@retired
Archived` and `@retired Discontinued` and no timestamp at all, so the one question
a reader asks about a withdrawn row — when was it withdrawn — has no answer in the
read model. The states with dates are the happy ones, because the happy path is
what someone was thinking about when they wrote the projection.

The event log already holds every one of these answers. What is missing is a place
to put them and a rule that puts them there.

## 1. The shape: an ordered trail of the domain's own states

An entry pairs **the view's own lifecycle variant** with the instant it was
reached:

```rescript
type entry<'state> = {state: 'state, at: Reventless.DateTime.t}
type t<'state> = array<entry<'state>>
```

`at` is the semantic type, written bare — the ppx resolves `X.t` → `X.schema`, so
there is no `@s.matches` here and no second spelling of the grammar. It emits
`format: "date-time"` and refuses anything that is not an instant, on the write
path as well as the read path.

That refusal is why this shape has **no sentinel problem**. `shippedAt: ""` exists
because a per-state field must hold *something* before the state is reached, and
`""` is what a domain reaches for; a refined `DateTime` rejects it, which is the
admission `semantic-date-time`'s D4 forces and pays for with `option<…>`. A trail
has nothing to admit: a state the row has not reached has no entry. The absence is
the record, and there is no value to invent for it.

so `Orders` carries `array<entry<lifecycle>>` and a state is `Placed`, checked by
the compiler. A trail of *strings* was the first thing written down here and it is
wrong: it gives up the one guarantee the lifecycle already has. `"Shiped"` would
compile, project, serialise and read as a state nobody declared, and the read
model's whole vocabulary would be beyond the reach of an exhaustive match. The
domain declares its states once; nothing downstream of that should be spelling
them again.

On the wire an entry is `{"state": "Placed", "at": "…"}`, where `state` emits the
same enum the lifecycle field emits — one vocabulary, published once, so a
consumer reading the trail and a consumer reading the current state are reading
the same values.

### Why not put the instant on the state's own constructors

The obvious-looking alternative is to give the lifecycle variant a payload:

```rescript
type lifecycle = Placed({at: string}) | Shipped({at: string}) | Cancelled({at: string})
```

It is typed, and it is the wrong place for the data. The current state is the
field every surface **groups, filters, colours and orders by**, and it can only do
that while two rows in the same state hold the same value. With a payload they
never do: `Shipped({at: t1})` and `Shipped({at: t2})` are different values, so
grouping by state, comparing to a state, and `state == Shipped` all stop working
and become pattern matches — in `decide`, in every guard, in every projection, and
in every consumer that reads the field. The states a command declares in
`allowedStates` / `@transition` would name constructors that now carry data, and
the enum published on the schema would become a union.

The state is *what* the row is; when it got there is a fact *about* the row's
history. Keeping the second in the trail leaves the first exactly as it is — no
existing match, annotation, projection or published contract changes.

### Ordered, not keyed by state

Appended to, and **not** `dict<state, instant>`, for one decisive reason: a
lifecycle revisits states. `OrderReopened` puts an order back into `Placed` a
second time, and a map has to choose between the first visit and the last — a
choice no reader of the map can see was made, and the wrong one half the time. The
order of the entries is itself a fact about the row, and it is the fact a map
throws away.

The trail opens with the state the row was created in, appended by the same rule
as every later entry. A trail whose first entry is missing would make "where did
this start" unanswerable for exactly the rows that started somewhere unusual.

## 2. Who writes it: the machinery, not the domain

The projection already writes `lifecycle: Shipped` and already holds `meta.time`.
The rule is expressible without the domain writing anything:

> When an `Update` changes the value of the view's lifecycle field, append
> `{state: <the new value>, at: meta.time}` to the trail.

Everything that rule needs is already declared. Which field is the lifecycle field
is named by `@lifecycle` or by the field's own name — the same declaration
`allowedStates` and `targetState` resolve against. What the value changed *to* is
in the record the update produced. When it happened is on the envelope.

This is the whole point of the plan. A per-domain helper the projection calls
(`Trail.append(state, meta.time)`) would still be a line every domain has to
remember on every transition, which is the current problem with two fewer
characters. The rule belongs where the update is applied.

**A creation writes the first entry by the same rule** — there is no prior value,
so the field "changed" and the entry is appended.

## 3. Declared per view, not switched on for everyone

The domain declares the field; the machinery fills it:

```rescript
@live(true) @schema
type state = {
  …
  lifecycle: lifecycle,
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
}
```

One line, once, naming the state type it is a trail of, and it never changes again
as states are added — which is the property that makes this worth building at all.

**Phase 0 verified the declaration compiles to a schema, and it does.** sury-ppx
derives `entrySchema: S.t<'state> => S.t<entry<'state>>` for the parameterised
record and resolves the field's declared type `Trail.t<lifecycle>` to
`Trail.schema(lifecycleSchema)` by its own `X.t` → `X.schema` convention. So the
line above is the whole of the domain's work: no `@s.matches`, no annotation, and
no change to reventless-ppx. Neither fallback (a `@trailed` marker, a per-view
entry type) was needed, and a trail of strings — the thing §1 rejects — was never
reached for.

Automatic for every stateful view was considered and is rejected: it would change
the shape — and the published GraphQL contract — of every existing read model
without anyone asking for it, and a view whose lifecycle is uninteresting would
pay storage for a trail nothing reads. Declaring the field is cheap; a silent
contract change is not.

The declaration also gives consumers something to find. A field of a **declared
type** is discoverable in the emitted schema, which is what lets a reader of the
schema know a trail is there rather than guessing from a field's name.

## 4. Growth, and where it is capped

An append-only array on a hot row grows without bound. Two facts make this smaller
than it looks: lifecycle enums are small, and a transition is a business event
rather than a tick. An order has three or four entries for its whole life.

It is still a decision to make deliberately rather than to discover in production:

- **Keep everything** — recommended default. Bounded in practice by the domain.
- **Cap at N, dropping the oldest** — rejected as the default. It destroys the one
  property the trail has that a per-state field does not: the head says where the
  row started.
- **Cap at N, dropping the middle** — the honest cap if one is needed: keep the
  first entry and the most recent N-1, and mark the gap so a reader is not told the
  row went straight from its first state to its recent ones.

Ship the first. Write the third down as the escape hatch, with the marker in the
type from the start so adding it later is not a contract change.

## 5. Rebuild and replay

The trail is derived from events and the envelope's own time, so a rebuild
reproduces it exactly. Nothing here may read a clock: a projection that stamped
`Date.now()` would produce a different trail on every replay, and the difference
would be invisible until someone compared two rebuilds.

## 6. Test obligations

- A row created, advanced and completed: entries in order, one per transition.
- **A reopened order**: `Placed` appears twice, with different instants, in the
  order they happened. This is the case a map cannot hold and the reason the shape
  is what it is.
- An update that does not touch the lifecycle field appends nothing.
- A rebuild from the same log produces an identical trail.
- A view with no trail field projects exactly as it does now.

## 7. Migration in the shipped examples

- **`Orders`** declares the trail, and `OrderCancelled` needs no projection edit to
  gain its date — the rule supplies it.
- **`Products` / `Categories`** declare the trail and get dates for their
  `@retired` states, which have never had any.

### Retiring the fields the trail replaces

The point of the trail is that per-state timestamp fields stop being necessary,
and they should go. Not all at once, and not all of them.

**`shippedAt` retires with the trail.** It is an `option<Reventless.DateTime.t>`
whose only readers ask when the order shipped, which is what the trail's `Shipped`
entry says.

"Nothing else consults it" was written here and is **not quite true**, and the
correction is the one thing this retirement costs. `AutoLifecyclePath` in the UI
stamps a date on each lifecycle step by *field-name convention* — state `Shipped`
→ field `shippedAt` — so with the field gone the Shipped step renders without its
date until the UI learns to read the trail instead. Nothing breaks: an unstamped
step is a step the strip already draws, and the data is in the trail waiting. The
UI side is UI-repo work and is not blocked by anything here.

**`placedAt` is a decision, not a cleanup.** It carries `@displayName` and
`@summary`, and those are not lifecycle questions — they are what the order is
*named* by and what a list may column. Three things go with the field and do not
come back from inside an array:

- **A name.** An annotation points at a field. There is no spelling for "the `at`
  of the entry whose state is `Placed`", and an order whose id is a uuid has
  nothing else to be called.
- **Sorting.** A list ordered by placement date is a query against a scalar
  column. A read model does not index inside a nested array.
- **Range filters.** "Placed last week" is the same problem.

So retiring it means answering naming, sorting and filtering first — either by
teaching those three to address a trail entry, or by keeping exactly one instant
per view as a real field and letting the trail carry every other state. The second
is cheaper and is what this plan assumes until someone builds the first. Either
way it is its own piece of work, and doing it by deleting the field and seeing
what breaks would take the list's own name with it.

## 8. Non-goals

- No query surface of its own. The trail is a field of the state view and is read
  the way every other field is.
- No audit trail. That answers who did what to which fields; this answers when a
  row reached a state, and conflating them would make the cheap thing expensive.
- No inference. A view that declares no trail has none, and nothing anywhere
  reconstructs one from timestamps that happen to look right.

## 9. What shipped

`Reventless.Lifecycle` (`reventless/spec/src/types/Lifecycle.res`) holds both
halves: `fieldName`, the single rule for which field is a record's lifecycle, and
`Trail`, the declared type plus its schema marker. `Plugin_Structure` now
delegates to `fieldName` rather than restating the rule, so the field a trail
entry records against and the field a command's declared edge is written in terms
of cannot disagree.

The rule itself lives in `Projection.rewriteAction`, beside the `@displayName`
overlay it now shares a JSON round trip with. **Four paths apply it**, and the
count is the point — the displayName overlay had shipped to only two of them:

| Path | Entry point |
|---|---|
| Local platform / in-process slice | `StateViewSlice_Builder`, `StateViewSlice_Callback` |
| Read models (incl. deployed) | `ReadModel_Callback` |
| Deployed state-view slice | `StateViewSliceEntryPoint_Ops.makeJsonEventsHandler` |
| GWT harnesses | `Projection_GWT`, `MultiSourceProjection_GWT` |

Four decisions the build made that the plan did not anticipate:

- **The deployed state-view slice needed its own hook.** It assembles JSON-level
  operations instead of going through the typed rewrite — the same gap that once
  left `displayName` unset on AWS. `rewriteJsonAction` closes it at the action,
  not at save, because only the action has a before-state to compare against.
  It reads the producer time off the envelope JSON rather than through the
  `asMeta` cast, which admits `undefined`; no producer time means no entry rather
  than an instant the read path would refuse.
- **The GWT harnesses apply the trail and nothing else.** `displayName` lives in
  the state schema and not in the record, so composing it there would produce a
  state no `thenStateWithId` expectation could spell. That is `rewriteTrail`.
- **The harness stamps one fixed producer time**, so the distinct-instant cases —
  the reopened order above all — are unit tests of the rule
  (`reventless/core/tests/projection/LifecycleTrailTest.res`) rather than GWTs.
  Every example GWT still asserts the trail's *contents and order*.
- **Multi-state actions get no trail entry.** Pairing a before-row with an
  after-row needs the sub-id, which is not resolved until the action is applied,
  and pairing by position would credit one row's transition to another. Stated in
  `Projection.res` where the decision is; no shipped view is affected.

The trail declares itself with the **shared** `Semantic` marker
(`Semantic.Id.lifecycleTrail`) rather than a metadata id of its own. That marker
is the one the JSON Schema walk emits, so a private id would have left the trail
indistinguishable on the wire from any other array of objects, and recognising it
would have come down to matching a field called `trail` by name. It costs one
re-application: `SchemaType.trailShape` walks the entries by shape and so skips
`fromSury`'s semantic dispatch, which is the drop a test now catches.

On the wire the entry's `state` emits the record's **own** lifecycle enum —
`Ordering_OrderTrail.state: Ordering_OrderLifecycle!`, not a second copy under
the trail's field path. `SchemaType.fromSuryObject` is the one place a record's
properties are walked, so it resolves the lifecycle field there and walks the
trail's `state` under that field's name; `seenTypes` then dedupes the enum to one
definition. That is §1's "one vocabulary, published once", checked by the golden.

`afterGap?: bool` is on the entry from the start, unused, so §4's middle-dropping
cap is an implementation rather than a contract change.
