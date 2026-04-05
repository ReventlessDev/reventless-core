---
title: ID
date: 2024-08-13
draft: false
---

# Id

The `Id` module defines the identifier type for an aggregate or read model, and how values of that type are created. Every spec includes an `Id` sub-module that satisfies the `Id.T` module type.

## `Id.T` — The Module Type

`Id.T` is the interface that all ID modules must satisfy. It defines:
- `type t` — the abstract identifier type
- `let makeFromString: string => t` — creates an ID from a string
- `let toString: t => string` — converts an ID back to a string (for serialization)

Functor parameters that accept an ID module are typed as `module Id: Id.T`.

## `Id.String` — The Default (Abstract)

`Id.String` is the default ID implementation. Its type `t` is **abstract** — it is not equal to `string` from outside the module. This prevents accidentally using bare strings where an ID is expected.

```rescript
// Create an Id.String value
let itemId: Id.String.t = Id.String.makeFromString("item-123")

// This does NOT compile — string is not Id.String.t
let wrong: Id.String.t = "item-123"
```

Use `Id.String` for production code. The abstraction prevents stringly-typed bugs where any string could be passed as an ID.

## `Id.StringPure` — Transparent (for Tests)

`Id.StringPure` is identical to `Id.String` but its type is `type t = string` — transparent, not abstract. This means string literals can be used directly as IDs without calling `makeFromString`.

```rescript
// In tests — string literals work directly
let testId: Id.StringPure.t = "test-item-123"
```

Both `Id.String` and `Id.StringPure` satisfy `Id.T`, so either can be used as a functor argument. Use `Id.StringPure` in test spec modules where you need string literals as IDs. Use `Id.String` in production spec modules.

## Example: Why Abstraction Matters

```rescript
// Production spec uses Id.String (abstract)
module ItemSpec = {
  module Id = Id.String
  // ...
}

// Prevents this mistake in application code:
let handle = (id: ItemSpec.Id.t) => {
  // id is not a string here — must use Id.toString(id) to get the string
  let idStr = id->ItemSpec.Id.toString
  // ...
}

// Test spec uses Id.StringPure (transparent)
module TestItemSpec = {
  module Id = Id.StringPure
  // ...
}

// In tests, string literals work directly:
let testId: TestItemSpec.Id.t = "item-abc"
```
