/**
Marks an `int` field as a length of time, in **seconds**.

## Why a scalar, and why seconds are part of the type

The obvious richer design is `{value, unit}`. It is not available here, and the
reason is the reason this whole set of types is safe to add: a record is an
*object* on the wire, so adopting it would turn every field that used it into a
decode failure against events already written. These types are additive
precisely because they stay scalars. A duration that carries its unit is a
different type for a different plan, not a later version of this one — widening
this one would retroactively hand an upcaster obligation to every field that had
already adopted it.

Seconds, because that is what the renderer reads: it formats `3660` as
`"1h 1m"`. Milliseconds would be off by a factor of a thousand and would
render as weeks, which is the same class of silent wrongness `Percent` avoids by
matching its gauge.

`int` is right here where it was wrong for `Bytes`: int32 seconds is 68 years,
which no duration field needs to exceed.

## The grammar

A whole number of seconds, zero or greater. Zero is a real duration — an instant
timeout, a zero-length window.

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
