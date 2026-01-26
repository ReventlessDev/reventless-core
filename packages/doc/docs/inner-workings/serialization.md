---
title: Serialization
date: 2024-08-20
draft: false
---

## Sury

[Sury](https://github.com/DZakh/rescript-sury) is the serialization library used by Reventless for JSON encoding and decoding using a [PPX](../rescript-syntax.md#ppx).

## Basic Usage

### `@schema` annotation

The library automatically generates schema functions for annotated types. The framework relies on these schemas and uses them internally for serialization and deserialization.

#### Basic Types
```rescript
@schema
type userId = string

@schema
type count = int
```

#### Records
```rescript
@schema
type countsState = {
  id: string,
  count: int,
}

@schema
type referencesState = {
  id: string,
  inc: int,
}
```

## Common Patterns

### Variants

Simple variants for enums:
```rescript
@schema
type effect = Allow | Deny
```

Complex variants with data:
```rescript
@schema
type command =
  | Heartbeat
  | Connect(pluginDefinition)
  | Disconnect
  | Activate
  | Deactivate

@schema
type event =
  | UnknownPluginDetected
  | Connected(pluginDefinition)
  | Disconnected(pluginDefinition)
  | Activated(pluginDefinition)
  | Deactivated(pluginDefinition)
```

### Key Annotations

#### Custom JSON field names with `@as`
```rescript
@schema
type principal = {
  @as("AWS") aws?: string,
  @as("Service") service?: string,
}
```

#### Unboxed variants with `@unboxed`
```rescript
@schema @unboxed
type actions = | @as("*") AllActions | Action(string)
```

## Framework Integration

:::info Framework Internal
This section describes how Reventless uses Sury schemas internally. Most developers won't need to use these functions directly.
:::

### Generated Schema Functions

For each [`@schema`](packages/reventless/src/components/Counter/Counter_Callback.res:1) annotated type, Sury generates:
- A schema object (e.g., `countsStateSchema`)
- Encoding/decoding functions accessible through [`Message.encode`](packages/reventless/src/components/Counter/Counter_Callback.res:61) and [`Message.decode`](packages/reventless/src/components/Counter/Counter_Callback.res:47)

### Serialization Usage

The framework uses these patterns for serialization:

```rescript
// Encoding data to JSON
let json = state->Message.encode(countsStateSchema)

// Decoding JSON to typed data
switch jsonData->Message.decode(countsStateSchema) {
| {id, count} => // Handle decoded data
| exception _ => // Handle decode errors
}
```

### Practical Example

From the Counter component:
```rescript
@schema
type countsState = {
  id: string,
  count: int,
}

// Usage in callback handler
counts->Array.filterMap(state =>
  switch state->Message.decode(countsStateSchema) {
  | {id, count} if count == 0 =>
    // Process completed counter
    Some(processCounterEvent(id, count))
  | {id, count} =>
    // Log current state
    Js.log(`Counter ${id} at ${count->Int.toString}`)
    None
  | exception _ =>
    Js.log("Failed to decode counter state")
    None
  }
)
```

:::warning
Any type referenced from inside an annotated type needs to either be a built-in type or another annotated type. The compiler will error otherwise.
:::
