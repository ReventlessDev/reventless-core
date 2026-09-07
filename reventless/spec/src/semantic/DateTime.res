/**
Marks a `string` state field as an ISO-8601 date-time.

Sury has no string-typed datetime format (`S.datetime` transforms to `Js.Date.t`,
changing the field's runtime type), so this mirrors the `DcbTag.string`
precedent: a `S.t<string>` carrying sury metadata that downstream schema walkers
detect. `SchemaType`/`SuryToJsonSchema` surface it as `format: "date-time"` on
the field's JSON Schema, which the AutoUI date heuristics key off (CalendarView,
TimelineView, date-axis charts).

Use on a producer/storage timestamp a projection writes into its state — most
commonly a `meta.time`-derived field such as `placedAt` / `shippedAt`:

@example
```rescript
@schema
type state = {
  orderId: string,
  placedAt: @s.matches(Reventless.DateTime.string) string,
}
```
*/

/** A sury string schema annotated as an ISO-8601 date-time field.
    Use with `@s.matches(Reventless.DateTime.string)`. */
let string: S.t<string> = S.string->Semantic.mark(~id=Semantic.Id.dateTime)

/** Whether a field schema carries the date-time marker. */
let isDateTime = (fieldSchema: S.t<unknown>) => fieldSchema->Semantic.has(~id=Semantic.Id.dateTime)
