---
title: ID
---

# Id

**In plain words:** an id names one entity, and `Id.Make` gives each kind of entity an id type of its own. An `OrderId.t` then cannot be passed where a `CustomerId.t` is expected; the compiler refuses it. On the wire it is still a plain string, so adopting it changes no stored data.

The `Id` module defines the identifier type for an aggregate, a read model or a view, and how values of that type are created. Every spec's `Id` sub-module satisfies the `Id.T` module type.

## `Id.T` — The Module Type

`Id.T` is the interface that all ID modules must satisfy. It defines:
- `type t` — the abstract identifier type
- `let makeFromString: string => t` — creates an ID from a string
- `let toString: t => string` — converts an ID back to a string (for serialization)

Functor parameters that accept an ID module are typed as `module Id: Id.T`.

## `Id.Make` — One Type per Identity

An **identity** is named by its **key**: `orderId`, `customerId`, `productId`. Declare each one once, in its own file, usually in the chapter of the entity it names:

```rescript
// src/Order/OrderId.res
include Reventless.Id.Make({
  let key = "orderId"
})
```

Each application of `Make` is a new type. Use it wherever that entity's id appears:

```rescript
// Aggregate/Order.res — the order stream is keyed by it
module Id = OrderId

@schema
type command = Place({customerId: CustomerId.t, productIds: array<ProductId.t>})
```

```rescript
// StateView/Orders.res — rows are keyed by it
module Key = OrderId

@schema
type state = {orderId: OrderId.t, customerId: CustomerId.t}
```

What the type buys, beyond the compiler check:

- **The key comes from the type, not the field name.** `buyer: CustomerId.t` is an id: GraphQL types it `ID`, and in a DCB slice it is tagged `customerId`, the same tag its producers write. An explicit `@dcbTag("k")` still wins.
- **References are derived.** A typed field with no `@ref` references the one view in its plugin keyed by that identity. Where several are, `@ref` chooses.
- **Mix-ups are checked.** A field named for one identity but typed as another (`orderId: CustomerId.t`) is reported by the DCB scope check, and so is an untyped `*Id: string` once its identity is declared in the plugin.

Declare the identity in its own file rather than inside the aggregate (`module Id = Make(...)` in `Order.res`). Two aggregates that mention each other would otherwise depend on each other, which ReScript does not allow. An identity another plugin also uses belongs in the plugin's published `*-spec` package, which then depends on `reventless-spec`.

## `Id.String` — Abstract, but Shared

`Id.String` is what a spec gets when it declares no `Id`. Its type `t` is abstract, so a bare string is not an `Id.String.t`:

```rescript
let itemId: Id.String.t = Id.String.makeFromString("item-123")

// This does NOT compile — string is not Id.String.t
let wrong: Id.String.t = "item-123"
```

It keeps ids apart from strings, **but not from each other**: every spec that uses `Id.String` shares the one type, so a product's id passes where a category's is expected. Use `Id.Make` when that distinction matters.

## `Id.StringPure` — Transparent (for Tests)

`Id.StringPure` is identical to `Id.String` but its type is `type t = string`: string literals can be used directly as ids.

```rescript
module TestItemSpec = {
  module Id = Id.StringPure
  // ...
}

let testId: TestItemSpec.Id.t = "item-abc"
```

It is also the default row key of a StateView (`module Key`), so a view that declares no identity keeps plain `string` keys. In tests for typed specs, make ids from literals once per file: `let oid = OrderId.make`, then `oid("o1")`.

## Converting Ids

Keep the typed id wherever the value is part of a document, meaning a command, an event or a row. There the id's schema carries it, and it is a string on the wire anyway. Convert only where the framework routes by string:

| Where | Convert with |
|---|---|
| An extension or extension point's routing id (`PublishEvent`, `PublishAggregateCommand`) | `toString` / `makeFromString` |
| An automation's or outbound translation's to-do key | `toString` |
| A published contract whose consumers cannot hold the type | `toString` |
| An external value entering the domain (an imported SKU) | `makeFromString` |
| A service call, a log line | `toString` |
| A read model keyed by a different entity's id | `Target.Id.makeFromString(source->Source.Id.toString)` |

Each conversion marks a seam where the types stop guarding the value, so a conversion anywhere else is worth a second look.
