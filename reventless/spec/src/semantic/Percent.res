/**
Marks a `float` field as a percentage, expressed **0–100**, not 0–1.

The scale is what every consumer gauges and formats against, so a fraction
multiplies by 100 before it becomes this type. A finite number in `[0, 100]`;
fractions are allowed — `99.95` is a percentage.

@example
```rescript
@schema type state = {
  productId: string,
  taxRate: @s.matches(Reventless.Percent.schema) float,
}
```
*/

/** The percentage's representation. Transparent `float`: the marker refines an
    existing numeric field, so nothing stored changes. */
type t = float

external unsafe: float => t = "%identity"
external toFloat: t => float = "%identity"

/** Validate a number as a percentage, saying why when it is not one. */
let fromFloat = (raw: float): result<t, string> =>
  if !Float.isFinite(raw) {
    Error(`a percentage must be a finite number, got ${Float.toString(raw)}`)
  } else if raw < 0.0 || raw > 100.0 {
    Error(
      `a percentage runs from 0 to 100, got ${Float.toString(raw)}. ` ++
      `This scale is 0–100, not 0–1 — a fraction multiplies by 100 first.`,
    )
  } else {
    Ok(raw)
  }

/** The sury schema for a percentage field. Use with `@s.matches(Reventless.Percent.schema)`. */
let schema: S.t<t> = S.float->Semantic.refined(~id=Semantic.Id.percent, ~check=fromFloat)

/** The percentage as text — `"42%"`, `"99.95%"`. Locale-independent, the way
    `Money.format` is. */
let format = (p: t): string => Float.toString(p) ++ "%"
