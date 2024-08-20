---
title: Serialization
date: 2024-08-20
draft: true
---

## Decco

[Decco](https://github.com/rescript-labs/decco) is the currently used library for de-/serialization using a [PPX](../rescript-syntax.md#ppx).

### `@decco` annotation

The library will automatically generate an encoder- and decoder function for annotated types. The functions are named `<typeName>_encode` and `<typeName>_decode`.  
The framework relies on these functions to exist and uses them internally.

:::warning
Any type which is referenced from inside an annotated type needs to either be a built in type or another annoted type. The compiler will error otherwise.
:::
