/**
Marks a `float` field as a percentage, expressed **0–100**.

## Why 0–100 and not 0–1

Both conventions are defensible in the abstract, so the tie is broken by the
consumer that already exists: the dashboard gauges a field with this semantic
against fixed bounds of 0 and 100, and formats `42.0` as `"42%"`. Under a 0–1
convention every value would render as a rounding error near zero — a gauge
pinned at empty and a label reading `"0.42%"`.

That failure is quiet, and it is quiet in the worst way: the numbers are
*present* and *wrong*, and the layer at fault is not the one showing the symptom.
Agreeing with the renderer costs nothing; disagreeing costs an afternoon.

A fraction is still perfectly good arithmetic — it just multiplies by 100 before
it becomes this type.

## The grammar

A finite number in `[0, 100]`. Fractions are allowed: `99.95` is a percentage.

@example
```rescript
@schema type state = {
  productId: string,
  taxRate: @s.matches(Reventless.Percent.schema) float,
}
```
*/

/** The percentage's representation. Transparent `float`: the marker refines an
    existing numeric field rather than replacing it, so nothing stored changes. */
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
