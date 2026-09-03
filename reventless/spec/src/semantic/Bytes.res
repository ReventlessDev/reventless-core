/**
Marks a numeric field as a count of bytes: finite, whole, zero or greater.

`float` rather than `int` because ReScript's `int` is int32, which caps a byte
count just under 2 GiB; wholeness is recovered by the grammar below. The wire is
a JSON number either way.

@example
```rescript
@schema type state = {
  documentId: string,
  size: @s.matches(Reventless.Bytes.schema) float,
}
```
*/

/** The count's representation. Transparent `float`; see the note above on why
    it is not `int`. */
type t = float

external unsafe: float => t = "%identity"
external toFloat: t => float = "%identity"

/** Validate a number as a byte count, saying why when it is not one. */
let fromFloat = (raw: float): result<t, string> =>
  if !Float.isFinite(raw) {
    Error(`a byte count must be a finite number, got ${Float.toString(raw)}`)
  } else if raw < 0.0 {
    Error(`a byte count cannot be negative, got ${Float.toString(raw)}`)
  } else if Math.floor(raw) !== raw {
    Error(`a byte count is a whole number of bytes, got ${Float.toString(raw)}`)
  } else {
    Ok(raw)
  }

/** The sury schema for a byte-count field. Use with `@s.matches(Reventless.Bytes.schema)`. */
let schema: S.t<t> = S.float->Semantic.refined(~id=Semantic.Id.bytes, ~check=fromFloat)

/** Binary, because a byte count is what a filesystem reports. */
let step = 1024.0
let units = ["B", "KB", "MB", "GB", "TB", "PB"]

/** The count as text — `"512 B"`, `"1.5 KB"`, `"2 MB"`. Locale-independent, the
    way `Money.format` is, so one value reads the same everywhere. */
let format = (b: t): string => {
  let last = Array.length(units) - 1
  let rec reduce = (value: float, index: int): (float, string) =>
    value < step || index >= last
      ? (value, units->Array.getUnsafe(index))
      : reduce(value /. step, index + 1)
  let (value, unit) = reduce(b, 0)
  // One decimal, and only when it says something: 2097152 is "2 MB", not "2.0 MB".
  Float.toString(Math.round(value *. 10.0) /. 10.0) ++ " " ++ unit
}
