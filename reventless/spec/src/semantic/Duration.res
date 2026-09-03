/**
Marks an `int` field as a length of time, in **seconds** — whole, zero or
greater. Zero is a real duration.

Seconds because that is the unit `format` reads; milliseconds would render as
weeks. A scalar rather than `{value, unit}` so the type stays additive on the
wire. `int` is safe here — int32 seconds is 68 years.

@example
```rescript
@schema type state = {
  jobId: string,
  runtimeSeconds: @s.matches(Reventless.Duration.schema) int,
}
```
*/

/** The duration's representation, in seconds. Transparent `int`. */
type t = int

external unsafe: int => t = "%identity"
external toInt: t => int = "%identity"

/** Validate a number of seconds as a duration, saying why when it is not one. */
let fromInt = (raw: int): result<t, string> =>
  if raw < 0 {
    Error(`a duration cannot be negative, got ${Int.toString(raw)} seconds`)
  } else {
    Ok(raw)
  }

/** The sury schema for a duration field, in seconds.
    Use with `@s.matches(Reventless.Duration.schema)`. */
let schema: S.t<t> = S.int->Semantic.refined(~id=Semantic.Id.duration, ~check=fromInt)

let scales = [(86400, "d"), (3600, "h"), (60, "m"), (1, "s")]

/** The duration as text, largest unit first and zero units dropped — `3660` is
    `"1h 1m"`, `0` is `"0s"`. Locale-independent, the way `Money.format` is. */
let format = (d: t): string => {
  let remaining = ref(d < 0 ? 0 : d)
  let parts = []
  scales->Array.forEach(((size, suffix)) => {
    let count = remaining.contents / size
    if count > 0 {
      parts->Array.push(Int.toString(count) ++ suffix)
      remaining := remaining.contents - count * size
    }
  })
  Array.length(parts) == 0 ? "0s" : parts->Array.join(" ")
}
