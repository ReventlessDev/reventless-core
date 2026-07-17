/**
Module type for aggregate and read model identifiers.

Every Reventless component declares its own `Id` module satisfying this type.
The abstract `type t` prevents accidentally mixing identifiers from different
aggregates at compile time.

@example
```rescript
// Category.res
module Id = Id.String
```
*/
module type T = {
  /** The opaque identity type. Sealed so IDs from different aggregates cannot be mixed. */
  @schema
  type t

  /** The input form accepted by `make` (e.g. `string`, `int`, or a record). */
  type input

  /** Construct a typed ID from its input representation. */
  let make: input => t

  /** Construct a typed ID from a plain string (used by adapters and routing layers). */
  let makeFromString: string => t

  /** Convert a typed ID back to its string representation. */
  let toString: t => string

  /** Compare two IDs. Required for sorted data structures and range queries. */
  let cmp: (t, t) => Ordering.t
}

/**
A transparent string-based `Id.T` implementation.

`StringPure.t = string`, so IDs can be written as plain string literals in
test code without casting. Use `Id.String` (the sealed version) in production
module specs.

@example
```rescript
// In test specs where literal strings are convenient:
module TestCategorySpec = {
  module Id = Id.StringPure
  let name = "Category"
  // Id.make("cat-1") == "cat-1"
}
```
*/
module StringPure = {
  @schema
  type t = string
  type input = string
  external make: t => t = "%identity"
  external makeFromString: string => t = "%identity"
  external toString: t => t = "%identity"
  let cmp: (t, t) => Ordering.t = String.compare
}

/**
A sealed string-based `Id.T` implementation for use in production aggregate specs.

Unlike `StringPure`, the `t` type is abstract, preventing accidental cross-aggregate
ID mixing. Use `Id.StringPure` in tests when string literals are needed.

@example
```rescript
// Category.res
module Id = Id.String
let name = "Category"
```
*/
module String: T = StringPure
