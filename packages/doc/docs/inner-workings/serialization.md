---
title: Serialization
date: 2024-08-20
draft: true
---

## Sury-PPX

[Sury](https://github.com/DZakh/rescript-schema) is the currently used library for de-/serialization using a [PPX](../rescript-syntax.md#ppx).

### `@schema` annotation

The sury-ppx library will automatically generate a schema for annotated types. The schema is accessible via the generated `<typeName>_schema` value of type `S.t<typeName>`.

The framework uses these generated schemas internally with functions like:
- `S.parseJsonOrThrow(schema)` for decoding JSON to ReScript types
- `S.reverseConvertToJsonOrThrow(schema)` for encoding ReScript types to JSON

#### Example

```rescript
@schema
type command =
  | CreateCustomer({name: string, email: string})
  | UpdateCustomer({customerId: string, name: string})

@schema
type event =
  | CustomerCreated({customerId: string, name: string, email: string})
  | CustomerUpdated({customerId: string, name: string})

@schema
type error =
  | InvalidEmail(string)
  | CustomerNotFound(string)
```

The `@schema` annotation automatically generates schemas:
- `command_schema: S.t<command>`
- `event_schema: S.t<event>`
- `error_schema: S.t<error>`

These schemas are used by the framework for serialization/deserialization of commands, events, and errors across service boundaries.

:::warning
Any type which is referenced from inside an annotated type needs to either be a built-in type or another annotated type. The compiler will error otherwise.
:::
