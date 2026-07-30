/**
Marks a numeric field as a count of bytes.

## Why `float` and not `int`

A byte count is a whole number and cannot be negative, so `int` is the type it
wants to be. It is the wrong one here anyway: ReScript's `int` is int32, and
sury enforces that, so an `int` byte count silently caps at 2,147,483,647 — just
under 2 GiB. A type whose stated job is file sizes cannot stop at 2 GB.

`float` is a JS number, exact for every integer up to 2^53 — nine petabytes,
which is enough. The discreteness `int` would have given for free is recovered
by checking it: the grammar below rejects a fractional byte count, so the type
still means what `int` meant, minus the ceiling.

The wire is unaffected either way — both are JSON numbers — so this is a source
choice, not a format one. A field genuinely bounded below 2 GiB can still be
declared `int` and left unmarked; this type is for the ones that are not.

## The grammar

A finite, whole number, zero or greater. Zero is a real byte count — an empty
object — so it is accepted.

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
