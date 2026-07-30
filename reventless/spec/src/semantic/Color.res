/**
Marks a `string` field as a colour, written as a hex triplet.

## Why hex only

A field carrying this semantic is rendered as a swatch by setting the value as a
CSS `background`. CSS accepts far more than a colour there — `url(…)`, gradients,
`var(…)` — so "any CSS colour" would make a colour field a way to write arbitrary
CSS into a log that cannot be edited afterwards. Hex is the form that is a
colour and nothing else, and it is what a colour picker emits anyway.

Named colours (`rebeccapurple`) and functional forms (`rgb(…)`, `oklch(…)`) are
rejected for the same reason, not because they are worse notation.

## The grammar

`#` then 3, 4, 6 or 8 hex digits — the shorthand, the shorthand with alpha, the
full triplet, and the triplet with alpha. Case is not significant.

@example
```rescript
@schema type command =
  | SetLabelColour({
      labelId: @s.matches(DcbTag.string) string,
      colour: @s.matches(Reventless.Color.schema) string,
    })
```
*/

/** The colour's representation. Transparent `string`; see `Email.t`. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

let hex = /^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/

/** Validate a raw string as a hex colour, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  if hex->RegExp.test(raw) {
    Ok(raw)
  } else {
    Error(
      `expected a hex colour such as "#1e90ff" or "#1e90ffcc", got ${Semantic.showString(
          raw,
        )}. Named colours and rgb()/oklch() forms are not accepted.`,
    )
  }

/** The sury schema for a colour field. Use with `@s.matches(Reventless.Color.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.color, ~check=fromString)
