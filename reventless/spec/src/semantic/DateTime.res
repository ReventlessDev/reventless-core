/**
Marks a `string` field as an ISO-8601 instant.

## The grammar

Sury's `S.isoDateTime`, and nothing added — the same rule the branded scalars
follow. `S.datetime` is the other binding and is not this one: it *transforms* to
`Js.Date.t`, changing the field's runtime type, where this keeps the string the
projection wrote.

## UTC only

`S.isoDateTime` accepts a `Z` instant and rejects an offset — `2026-03-02T09:00:00+01:00`
and a bare `2026-03-02T09:00:00` both fail. That is stricter than RFC 3339 and it
is the strictness worth adopting: every instant the framework produces comes from
`Message.nowAsISOString`, which is always `Z`. "Instants are stored in UTC" is a
fact a reader can rely on; "we accept whatever offset arrived" pushes the zone
question onto every consumer.

An inbound feed carrying a supplier's local offset converts at the boundary,
which is what an `InboundTranslation` slice is for — `Date.fromString` then
`toISOString`. Forgetting it is now a rejection rather than a row nobody can sort.

`SchemaType`/`SuryToJsonSchema` surface the marker as `format: "date-time"` on
the field's JSON Schema, which the AutoUI date heuristics key off (CalendarView,
TimelineView, date-axis charts).

A date with no instant in it — a birth date, a due date — is `CalendarDate`, not
this. Storing one as an instant creates the midnight bug.

@example
```rescript
@schema
type state = {
  orderId: string,
  placedAt: Reventless.DateTime.t,
  shippedAt: option<Reventless.DateTime.t>,
}
```
*/
/** The instant's representation. Transparent `string`: the marker refines an
    existing field rather than replacing it, so nothing stored changes, and
    `placedAt: meta.time` keeps compiling. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

// Sury's rule, held once. `fromString` runs it rather than restating it, and
// `schema` is built from `fromString`, so there is exactly one grammar here.
let grammar: S.t<string> = S.isoDateTime

/** Validate a raw string as a UTC ISO-8601 instant, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  switch raw->S.parseOrThrow(~to=grammar) {
  | value => Ok(value)
  | exception _ => Error(`expected a UTC ISO-8601 instant, got ${Semantic.showString(raw)}`)
  }

/** The sury schema for an instant field. Use with `@s.matches(Reventless.DateTime.schema)`,
    or write the field's type as `Reventless.DateTime.t` and let sury-ppx resolve it. */
let schema: S.t<t> =
  S.string->Semantic.refined(~id=Semantic.Id.dateTime, ~check=fromString)

/** A sury string schema annotated as an instant, without the grammar.

    @deprecated Use `schema`, which carries the same marker and checks the value. */
let string: S.t<string> =
  S.string->Semantic.mark(~id=Semantic.Id.dateTime)

/** Whether a field schema carries the date-time marker. */
let isDateTime = (fieldSchema: S.t<unknown>) => fieldSchema->Semantic.has(~id=Semantic.Id.dateTime)

/** An instant as milliseconds since the epoch — `NaN` if it does not parse. The
    one place an instant becomes a number, so every comparison here and in
    `DateRange` is expressed against a single parse. */
let millis = (instant: t): float => instant->Date.fromString->Date.getTime

/** Whether one instant is strictly earlier than another. */
let isBefore = (a: t, b: t): bool => millis(a) < millis(b)

/** Order two instants, oldest first. */
let compare = (a: t, b: t) => Float.compare(millis(a), millis(b))

/** The instant as text, to the minute, in UTC — `"2026-03-02 09:00"`.
    Locale-independent, the way `Money.format` and `Duration.format` are: the
    same value reads the same in every log line and every test. A value that is
    not the shape the grammar admits reads back unchanged. */
let format = (instant: t): string =>
  String.length(instant) >= 16
    ? String.slice(instant, ~start=0, ~end=10) ++ " " ++ String.slice(instant, ~start=11, ~end=16)
    : instant
