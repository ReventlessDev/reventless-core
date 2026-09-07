/**
Marks a `string` field as a calendar day — `2026-03-02`, with no instant in it.

## Why this is not a `DateTime`

A birth date, a due date, an invoice date, an `effectiveFrom` — the value has no
time of day, and storing one as an instant creates the midnight bug: a renderer
that localizes `2026-03-02T00:00:00Z` shows *March 1st* to every reader west of
Greenwich. That is a wrong date on a screen produced by a correct renderer, and
no annotation can repair it, because the value itself has lost the distinction.

## The grammar

Sury's `S.isoDate`: `2026-03-02` accepts, `2026-13-02`, `09:00:00`,
`2026-03-02T09:00:00Z` and the empty string all reject. It emits
`format: "date"`, the standard JSON Schema keyword a consumer already reads.

## Why `CalendarDate` and not `Date`

`reventless-spec` compiles with `-open RescriptCore`, and its own modules resolve
unqualified inside the package — so a `Date.res` here would shadow the stdlib
`Date` for every file in it. The wire vocabulary id stays the short `"date"`;
only the module name carries the qualifier.

@example
```rescript
@schema
type state = {
  invoiceId: string,
  issuedOn: Reventless.CalendarDate.t,
}
```
*/

/** The day's representation. Transparent `string`, like the rest of the branded
    scalars: the marker refines an existing field rather than replacing it. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

// Sury's rule, held once. `fromString` runs it rather than restating it, and
// `schema` is built from `fromString`, so there is exactly one grammar here.
let grammar: S.t<string> = S.isoDate

/** Validate a raw string as an ISO-8601 calendar day, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  switch raw->S.parseOrThrow(~to=grammar) {
  | value => Ok(value)
  | exception _ => Error(`expected a calendar date (YYYY-MM-DD), got ${Semantic.showString(raw)}`)
  }

/** The sury schema for a calendar-date field. Write the field's type as
    `Reventless.CalendarDate.t` and sury-ppx resolves it. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.date, ~check=fromString)

/** Whether a field schema carries the calendar-date marker. */
let isCalendarDate = (fieldSchema: S.t<unknown>) => fieldSchema->Semantic.has(~id=Semantic.Id.date)
