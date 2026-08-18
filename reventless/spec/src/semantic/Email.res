/**
Marks a `string` field as an email address.

## Why a type rather than a name

An `email` field already renders as a mailto link today, because the UI guesses
from the field's *name*. The guess is the whole problem: `contact`, `owner` and
`notifyTo` hold addresses and are not guessed, `emailTemplate` is guessed and is
not an address, and nothing anywhere checks that what was written is one. A type
says it, and the check comes with it.

## The grammar

Sury's `S.email`, and nothing added. This is a case where the framework has no
opinion worth having: address syntax is somebody else's specification, and a
second regex here would only be a way to disagree with it.

Note that a syntactically valid address is not a deliverable one — nothing here
sends a probe. This rejects what is not an address, which is the part a boundary
check can honestly do.

@example
```rescript
@schema type command =
  | InviteMember({
      teamId: @s.matches(DcbTag.string) string,
      email: @s.matches(Reventless.Email.schema) string,
    })
```
*/

/** The address's representation. Transparent `string`: the marker refines an
    existing field rather than replacing it, so nothing stored changes. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

// Sury's check, held once. `fromString` runs it rather than restating it, and
// `schema` is built from `fromString`, so there is exactly one grammar here.
let grammar: S.t<string> = S.email

/** Validate a raw string as an email address, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  switch raw->S.parseOrThrow(~to=grammar) {
  | value => Ok(value)
  | exception _ => Error(`expected an email address, got ${Semantic.showString(raw)}`)
  }

/** The sury schema for an email field. Use with `@s.matches(Reventless.Email.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.email, ~check=fromString)
