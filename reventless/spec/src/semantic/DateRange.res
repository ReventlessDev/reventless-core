/**
A span of time: two ISO-8601 instants, a start and an end, as one value.

## Why the pair is the value, not two fields beside each other

Before this type a span was a *guess*. A view that wanted a calendar, a timeline
or a gantt bar asked which fields were date-like and took the first named
`start…` and the first named `end…`, independently. Three things go wrong and
all three are silent: two intervals in one row mispair across each other (a bar
drawn from one interval's start to the other's end); an interval named anything
else — `checkIn`/`checkOut`, `from`/`to` — is invisible; and a lone `started…`
point pairs with whatever `end…` is nearby. Making the two instants one value
removes the pairing question: a consumer either holds the span or it does not.

The parts keep their own `dateTime` marker, so a walker that only understands
date-times still sees them, and the whole carries `dateRange` besides. That is
the same layering `Money` uses — the amount keeps being a number, the composite
adds the meaning the number cannot carry.

## `[start, end)` — end exclusive

A range runs from `start` up to but not including `end`. `09:00–11:00` and
`11:00–13:00` are adjacent, not overlapping, and an all-day grid needs no
off-by-one-millisecond convention invented per consumer. This is a decision, not
a default: `overlaps` and `contains` are the only places it is written, and no
layout may re-decide it.

## Why the ordering rule is not enforced at decode

`start <= end` relates two fields, so — unlike `Money`'s wholeness, which is a
property of one field and rides on that field's schema — it is a *record-level*
invariant. sury 11.0.0-alpha.4 miscompiles a refinement wrapping a record schema
(it hoists the result object above the field reads, so parse and serialize throw
`Cannot access 'v0' before initialization`), and the pin has not moved. So the
rule lives in `validate`/`make` and **the schema does not enforce it at decode**.

This is the first semantic type in this library whose invariant the boundary does
not check: `Money` rejects a fractional minor unit on the way in; `DateRange`
will accept a range that ends before it starts if one is ever written. A reader
who assumes parity with `Money` assumes wrong. When sury fixes the record
refinement the rule moves into the schema and `validate` stays as its single
definition — the relationship `Money.validateAmount` has with `amountSchema`.

Parsing is `Date.fromString` on each instant. A range whose strings do not parse
is a decode-time problem the `DateTime` marker does not currently catch either,
so there is no second validation layer here — a reversed *parseable* range is
what `validate` catches, and an unparseable one is out of both their scope.

## How a field declares it

The field's declared type *is* `DateRange.t`, and sury-ppx resolves it to this
module's `schema`:

```rescript
@schema type state = {
  orderId: string,
  deliveryWindow: option<Reventless.DateRange.t>,
}
```

which serializes as `{"start": "2026-03-02T09:00:00Z", "end": "2026-03-02T11:00:00Z"}`.

**Introduced as a new optional field it is additive** — an absent optional
decodes to `None` for events written before it existed, so no upcaster and no
projection rebuild. It costs a log something only if it *collapses* an existing
`start*`/`end*` pair, which rewrites the wire shape the way `Money` rewrote
`price: float`. That collapse belongs to whoever builds the upcaster.
*/

@schema
type t = {
  /** The instant the range opens, inclusive. */
  start: @s.matches(DateTime.string) string,
  /** The instant the range closes, **exclusive** — the range does not contain
      it. `@as("end")` puts `end` on the wire (where the UI's own `GanttChart`
      already spells it that way); `end_` is the source spelling because `end`
      is awkward as a bare ReScript field. */
  @as("end") end_: @s.matches(DateTime.string) string,
}

/** The sury schema for a date-range field, carrying the `dateRange` semantic.

    Shadows the schema sury-ppx derived from the type above: the derived one is
    the shape, and this adds the marker the shape cannot carry. The ordering rule
    is deliberately *not* refined in here — see the module doc. */
let schema: S.t<t> = schema->Semantic.mark(~id=Semantic.Id.dateRange)

/** An instant as milliseconds since the epoch — `NaN` if it does not parse. The
    one place a range's strings become numbers, so end-exclusivity and the
    ordering rule are all expressed against a single parse. */
let millis = (instant: string): float => instant->Date.fromString->Date.getTime

/**
Validate a range's ordering, saying why when it is reversed.

The single statement of the `start <= end` rule; `make` is derived from it, and
`schema` will be once sury's record refinement is fixed. An unparseable instant
is not caught here (see the module doc) — a reversed range means two instants
that both parse, the earlier one second.
*/
let validate = (range: t): result<t, string> =>
  millis(range.start) > millis(range.end_)
    ? Error(
        `a range ends before it starts: ${range.start} is after ${range.end_}. ` ++
        `A range is [start, end) — the start is the earlier instant.`,
      )
    : Ok(range)

/** Build a validated range from its two instants. `end` is exclusive. */
let make = (~start: string, ~end_: string): result<t, string> => validate({start, end_})

/**
The range's length as a `Duration`, in whole seconds — the composite composing
with one of the branded scalars.

Total: a valid range has a non-negative length, and a zero-length range is
zero seconds. Truncated to whole seconds because that is what `Duration` is.
*/
let duration = (range: t): Duration.t =>
  Duration.unsafe(Math.trunc((millis(range.end_) -. millis(range.start)) /. 1000.0)->Float.toInt)

/**
Whether an instant falls within the range — at or after `start`, strictly before
`end`. End-exclusive, so the instant that opens the next adjacent range is *not*
contained by this one. One of the two places `[start, end)` is decided.
*/
let contains = (range: t, instant: string): bool => {
  let t = millis(instant)
  t >= millis(range.start) && t < millis(range.end_)
}

/**
Whether two ranges share any instant. End-exclusive: `09:00–11:00` and
`11:00–13:00` are adjacent and do *not* overlap. The other place `[start, end)`
is decided — a layout that re-decides it will disagree with this.
*/
let overlaps = (a: t, b: t): bool =>
  millis(a.start) < millis(b.end_) && millis(b.start) < millis(a.end_)

/**
The range as text: the two instants with an en dash between them —
`"2026-03-02T09:00:00Z – 2026-03-02T11:00:00Z"`.

Locale-independent, matching the rest of the framework's formatters: the same
value reads the same in every log line and every test. A calendar-style
rendering is the presentation layer's job.
*/
let format = (range: t): string => `${range.start} – ${range.end_}`
