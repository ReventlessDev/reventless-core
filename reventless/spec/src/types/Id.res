/**
Module type for aggregate and read model identifiers.

Every Reventless component declares its own `Id` module satisfying this type.
The abstract `type t` keeps ids apart from plain strings, but not from each
other: every alias of `Id.String` (which is what the ppx injects) is the same
type. Only `Id.Make` gives an entity an id type of its own.

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

Unlike `StringPure`, the `t` type is abstract, so an id is not a plain string. It is
sealed once, so every alias shares one type; use `Id.Make` for an id type per
entity. Use `Id.StringPure` in tests when string literals are needed.

@example
```rescript
// Category.res
module Id = Id.String
let name = "Category"
```
*/
module String: T = StringPure

/** An `Id.T` that names one entity, by its key (`orderId`). */
module type Identity = {
  include T with type input = string
  let key: string
}

/**
One distinct type per identity. Each application yields a fresh abstract `t`, so
an `OrderId.t` cannot be passed where a `CustomerId.t` is expected. A string on
the wire; the schema carries the `identity` semantic, which is how the runtime
knows which entity a field names whatever the field is called.

@example
```rescript
// src/Order/OrderId.res
include Reventless.Id.Make({let key = "orderId"})
```
*/
module Make = (
  K: {
    let key: string
  },
): Identity => {
  include StringPure
  let key = K.key
  let schema = schema->Semantic.mark(~id=Semantic.Id.identity, ~payload=IdentityOf({key: K.key}))
}
