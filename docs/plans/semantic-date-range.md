# Plan: `DateRange` and the Calendar/Scheduler capability

**Date:** 2026-07-31
**Status:** Core steps 1–3 landed and verified (2026-08-01). Step 4 (the UI reader half) remains
a separate plan in reventless-ui, per the split below. Written against the released `Money`
implementation and the UI's current span resolution, both read rather than assumed.

**Landed (reventless-core):**
- **Step 1–2** — `reventless/spec/src/semantic/DateRange.res`: the `@schema {start, end_ @as("end")}`
  record (each part keeps its `dateTime` marker), a `schema` shadow carrying `Semantic.Id.dateRange`,
  and the value-object ops `validate` / `make` / `duration` / `contains` / `overlaps` / `format`.
  End-exclusive `[start, end)` lives only in `contains`/`overlaps`; the ordering rule lives only in
  `validate` and is **not** enforced at decode (sury 11-alpha record-refinement pin — D2), documented
  in the module.
- **Step 3** — a **requested delivery window** on the hybrid example's order (`PlaceOrder` command +
  `OrderPlaced` event + `Orders` view + projection + seed). Added additively, per the adoption table.
  The command/event field is an **optional field** (`deliveryWindow?: DateRange.t`, `imageUrl`-style
  omittable input); the view *state* stays `option<DateRange.t>`.
- **Verification** — `DateRangeTest` (21), the `SuryToJsonSchemaTest` emission block (field is
  `object` + `dateRange` marker + both parts keep `format: "date-time"`), the hybrid ordering GWT
  suite, and a **live local round-trip**: the SDL generates `deliveryWindow` as an optional nested
  input (`Ordering_PlaceOrderDeliveryWindow {start,end}`) and output (`Ordering_OrderDeliveryWindow`);
  a real `Ordering_PlaceOrder` carrying `{start,end}` is accepted and the Orders view returns it,
  while an order that omits the arg returns `deliveryWindow: null`.

**Framework change this surfaced (not in the original plan):** making the command/event field an
optional field (`?`) rather than `option<>` exposed that `Behavior_GWT`'s `AssertionCore` compared
emitted vs expected events with raw ReScript structural equality, which distinguishes an
optional field that is present-but-`undefined` (a decider's `?` passthrough) from an absent key —
even though both serialize identically. Fixed by comparing events on their **encoded (wire) form**
(`encEvents`), which is true event identity; a strictly weaker equality, verified against every GWT
consumer in the repo (examples + `reventless/gwt` own suite + `reventless/local`) with no regressions.
**Repos:** `reventless-core` **and** `reventless-ui`. Like `Money` and unlike the branded scalars,
this one needs UI work — and more of it, because the thing being replaced is not a field renderer but
a *record-level role* that six call sites already consume.
**Analysis:** §7.2 (the capability contribution), §12 step 4 (the sequencing), and the semantic table's
date-span row — in the repo that owns the cross-repo semantic-type analysis.
**Builds on:** [done/semantic-money-and-currency.md](./done/semantic-money-and-currency.md) — the
composite template, and its **D2** (a record-level refinement miscompiles) which this type collides
with head-on — and [done/semantic-branded-scalars.md](./done/semantic-branded-scalars.md), whose
`Duration` is what a range's length should be.

## What this replaces: a name guess wearing a declaration's clothes

`AutoSemantics.resolve` derives a `dateSpan` role from field *names*: among the fields that are
date-like, the first whose lowercased name starts with `start`, and the first that starts with `end`.
That pair then feeds calendar, timeline, gantt, scheduler, approvals and the dashboard's time axis.

The gantt mode's own registration states the ambition and misses it in the same sentence — it is
offered only where the span "DECLARES an end … and that is a declared signal, not a guess." It is a
guess. The declaration is what this plan adds.

Three failure modes follow from the guess, and all three are silent:

- **Two intervals in one view mispair across each other.** The resolution takes the *first* `start*`
  and the *first* `end*` independently, so a row with `startsAt`/`endsAt` beside
  `startBillingAt`/`endBillingAt` can produce a bar drawn from one interval's start to the other's
  end. No error, a plausible chart, and a duration nobody can reproduce.
- **An interval not named `start`/`end` is invisible.** `checkIn`/`checkOut`, `from`/`to`,
  `placedAt`/`shippedAt` — all ranges by meaning, none by prefix. The view silently degrades to a
  lone-start calendar, or offers no time mode at all.
- **A `start*` field that belongs to no interval pairs with whatever `end*` is nearby.** `startedAt`
  on an audit row is a point, not a range's opening.

A type removes all three at once, because the pairing stops being inferred: the two instants are one
value, and a view either has that value or does not.

## The shape

```rescript
@schema
type t = {
  start: @s.matches(DateTime.string) string,
  @as("end") end_: @s.matches(DateTime.string) string,
}
```

Wire form `{"start": "2026-03-02T09:00:00Z", "end": "2026-03-02T11:00:00Z"}` — two ISO-8601 instants,
standard at the boundary, exactly as `Money` puts the ISO currency code there. Each part keeps the
`dateTime` marker, so a walker that already understands `DateTime` sees the parts as well as the
whole, and a consumer that only knows about date-times is not blinded by the composite.

`end_` with `@as("end")` because the UI's own `GanttChart.task` already spells it that way; if the
plain field name turns out to compile, drop the escape rather than keeping both. The `@as` is what
fixes the *wire* form either way, and the wire form is the part that is permanent.

**End exclusive.** A range is `[start, end)`: `09:00–11:00` and `11:00–13:00` are adjacent, not
overlapping, and a day grid that lays out all-day ranges does not need an off-by-one-millisecond
convention invented per consumer. This is a decision, not a default — `overlaps` and `contains` are
written once against it and are the only places it appears.

### The decision this plan turns on: is `end` optional

`Money`'s equivalent question was how closed `Currency` is. Here it is whether a range may be
half-open in the *unknown* sense — started, not yet finished.

1. **Both ends required.** A range is two points. An in-progress interval is modelled as it already
   is: a `DateTime` start field, optionally beside an `option<DateRange.t>` that appears when the
   thing finishes. `duration`, `overlaps`, `contains` and every layout are total.
2. **`end` optional.** One field expresses both states. Every operation on a range becomes partial,
   and every consumer has to decide what an endless bar means — which is exactly what today's gantt
   heuristic does when it substitutes `end = start` and silently draws a milestone.
3. **Two types** (`DateRange` and `OpenRange`). Honest and nobody wants it; the second type would be
   declared once and then everything would take the first.

**Recommend 1.** The point of the type is that a consumer holding it needs no further question
answered, and option 2 hands back the question in a different shape. Note what it costs, so the
choice is reversible with evidence rather than by preference: a domain whose interval genuinely has
no end until it closes must keep a start field beside the range, and *that* is the case to watch for
in the first application that adopts this. If it turns up twice, option 2 was right.

### What the type does *not* get, and why it must be said out loud

`start <= end` is a **record-level** invariant — it relates two fields, so unlike `Money`'s wholeness
it cannot be pushed down onto one of them. That is precisely the placement D2 found broken: sury
11.0.0-alpha.4 miscompiles a refinement wrapping a record schema, and the pin has not moved since.

So the ordering rule lives in `validate`/`make` returning `result`, and **the schema does not enforce
it at decode.** `DateRange` is the first semantic type in this library whose invariant is not
enforced at the boundary — `Money` rejects a fractional minor unit on the way in, and this will
accept a range that ends before it starts if one is ever written. Say it in the module doc, not only
here: a reader who assumes parity with `Money` will assume wrong.

Two riders:

- **Attempting to reproduce D2 from plain JS does not work**, so do not conclude from a green JS
  probe that it is fixed. Reconstructing the ppx's `S.schema(s => ({...s.m(…)}))` emission through
  sury's JS API produces a record that fails to parse *even unrefined*, so the experiment cannot
  distinguish the bug from the reconstruction. Verify with a ReScript spike at implementation time.
- When sury does fix it, the rule moves into the schema and `validate` stays as its single
  definition — the same relationship `Money.validateAmount` has with `amountSchema`.

## What this costs a deployment — and it is not what the composites' reputation says

`Money` had to rewrite an existing `price: float`, which is *structural breaking*: stored events stop
decoding and projections must be rebuilt. **`DateRange` inherits that only if it collapses an existing
`start*`/`end*` pair.** Introduced as a *new optional field*, it is additive and costs a log nothing,
because an absent optional decodes to `None` for events written before it existed.

That gives two adoption paths with genuinely different risk, and they should not be conflated:

| Adoption | Log cost |
|---|---|
| New `option<DateRange.t>` field on an event or view | Additive. No upcaster, no rebuild. |
| Collapse an existing `start*`/`end*` pair into one range field | Structural breaking. Upcaster + full projection rebuild, gated on the schema-versioning substrate. |

Whoever schedules the collapse against a log that must survive is blocked on that substrate, not on
anything here. The type itself is available to a new field immediately.

## Steps

**1 — `DateRange` in the semantic library.** `reventless/spec/src/semantic/DateRange.res`, following
`Money`'s template: the `@schema` record, then a `schema` that shadows the derived one with
`Semantic.mark(~id=Semantic.Id.dateRange)`. Add `dateRange` to `Semantic.Id`.

**2 — the operations that make it a value object.** `validate` (the one statement of the ordering
rule, returning `result` with a message that shows both instants), `make` returning `result`,
`duration : t => Duration.t` — the composite composing with one of the branded scalars, in whole seconds because
that is what `Duration` is — plus `contains`, `overlaps` and `format`. `overlaps` and `contains` are
where end-exclusivity lives; nowhere else may re-decide it.

Parsing is `Date.parse` on the ISO instant. A range whose strings do not parse is a decode-time
problem the `DateTime` marker does not currently catch either, so do not invent a second validation
layer here — state the limitation with the ordering one.

**3 — an example that declares one.** Additively, per the table above: an `option<DateRange.t>` field
on the hybrid example, not a collapse. The example carries no `start*`/`end*` pair today —
`placedAt`/`shippedAt` are two event timestamps and the heuristic does not even pair them — so there
is nothing to collapse without inventing it first.

A delivery window on an order is the honest candidate: it is a genuine domain fact, it is optional by
nature (it exists once a delivery is scheduled), and it gives the scheduler mode an events slot with
a resource ref already beside it. Touch the command, the event, the view, the behaviour and the seed
data set — `Money` step 4's list, minus the retype cascade, because nothing that already exists
changes type.

**4 — the reader half, planned in the UI repo.** Unlike `Money`, whose UI work was two steps of one
plan, this one replaces a *record-level role* that six modules already consume, so it is planned where
that code lives: `autoui-date-range-declared-span.md` in reventless-ui. What this plan owes it is a
contract, not a design:

| What the UI reads | Fixed by |
|---|---|
| the wire shape `{"start": …, "end": …}`, two ISO-8601 instants | the shape above — and it is what the UI's primary rung keys on, so that rung does not wait on a release |
| the `dateRange` marker on the field | step 1, reaching the UI as `x-reventless-semantic` |
| end-exclusive `[start, end)` | the shape section — a layout that re-decides it will disagree with `overlaps` |
| both ends present | the decision this plan turns on; if it flips, the UI's accessor gains a case |

Two things worth stating here because they constrain what the type may become, not merely how it is
rendered. **The UI must not widen its existing `dateTime` semantic into this one** — widening would
make every existing date-time field start decoding as an object, which is `Money`'s step-5 lesson in
its exact form. And **a declared range has to outrank the name pair while the name pair survives**, so
this type is additive to every application that already gets a span by naming its fields `start*` and
`end*`. Neither is negotiable from this side; both are reasons the type looks the way it does.

The ordering rule is restated once in the UI, because a form marks a field invalid before submit and
the UI validates without importing this type. That is a genuine second statement of one fact across
the repo boundary — worth noting rather than pretending otherwise, and worth revisiting if the count
ever goes above one.

## Verification

- **A field typed `DateRange` emits `dateRange`** — `SuryToJsonSchemaTest`, alongside the assertion
  that the field's JSON Schema `type` is now `object`, the way the `money` emission is asserted rather
  than described.
- **The two instants keep their own `dateTime` markers**, so a walker that only understands
  date-times still sees the parts. This is the property that lets the reader's shape rung work without
  the composite marker, so it is not incidental.
- **`duration`, `contains`, `overlaps`** including the end-exclusive boundary (a range ending exactly
  where the next begins does not overlap it) and a zero-length range, which is legal.
- **`validate` refuses a reversed range**, and a test asserts that **decode does not** — the
  limitation stated as an expectation, so it fails loudly when sury's record refinement is fixed and
  the rule can move into the schema.
- **The example round-trips through a live local platform, seed included** — the GraphQL input object
  and output object for the range, a command carrying one, and the seeded rows arriving in a view a
  time mode can lay out. `Money`'s verification is the model; its one gap (nobody looked at the
  rendered card) is worth not repeating, because a scheduler laying bars out wrongly is visible only
  in a browser.

The reader half's acceptance — that every existing name-paired span keeps resolving untouched, and
that a two-interval fixture stops mispairing — belongs to the UI plan and is stated there.

## Out of scope

- **Recurrence (`RRULE`)** and anything else from iCalendar. A recurring availability is a rule that
  generates ranges, not a range.
- **Time zones beyond the offset carried in the instant.** A range that must be interpreted in a
  named zone (`Europe/Vienna`) is a different type with a zone beside it; the analysis lists IANA
  zones as their own item for that reason.
- **The collapse of existing `start*`/`end*` pairs anywhere.** Additive adoption only, per the table
  above; the collapse belongs to whoever builds the upcaster, not to this plan.
- **`GeoPoint`.** The third composite, and the one that supersedes a name pair the same way — but it
  shares none of this plan's decisions.
- **The `isCapable` rework.** Step 6 contributes a constructor to it; it does not rebuild it.

## Follow-ups

- **Revisit the ordering check when sury's record refinement is fixed.** The move is mechanical and
  the `validate`-is-the-single-definition shape is already what makes it mechanical.
- **`Duration` as a stored field rather than a derived one.** A range knows its length, so storing
  both is two statements of one fact — but a query that filters on length cannot compute it. Decide
  the first time something filters.
- **An open-ended range**, if the required-end decision turns out to cost more than it saves. The
  evidence to watch for is named in the decision above.
