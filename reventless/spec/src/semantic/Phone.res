/**
Marks a `string` field as a phone number in E.164 form.

## Why E.164, and only E.164

A phone number written the way a person says it out loud — `(030) 12 34 56`,
`+49 30 123456`, `0049-30-123456` — is three different strings for one number,
so a log full of them cannot be searched, deduplicated or dialled reliably. E.164
is the one form that is unambiguous internationally, and it is the form the
`tel:` link this field renders as actually wants.

That makes this the one branded scalar that is likely to *reject* input a form
would otherwise have accepted, and it should: the alternative is storing an
un-dialable string permanently. Normalising a local number into E.164 needs a
default country the framework does not know, so that belongs to the caller,
before the command.

## The grammar

`+`, then a country digit 1–9, then up to 14 more digits — at most 15 in total,
which is the E.164 limit. No spaces, no punctuation, no leading zero after the
`+`.

@example
```rescript
@schema type command =
  | SetContactPhone({
      customerId: @s.matches(DcbTag.string) string,
      phone: @s.matches(Reventless.Phone.schema) string,
    })
```
*/

/** The number's representation. Transparent `string`; see `Email.t`. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

let e164 = /^\+[1-9]\d{0,14}$/

/** Validate a raw string as an E.164 number, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  if e164->RegExp.test(raw) {
    Ok(raw)
  } else {
    Error(
      `expected a phone number in E.164 form — "+" then up to 15 digits, as in "+4930123456" — got ${Semantic.showString(
          raw,
        )}. Spaces, dashes and brackets are not part of the stored form.`,
    )
  }

/** The sury schema for a phone field. Use with `@s.matches(Reventless.Phone.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.phone, ~check=fromString)
