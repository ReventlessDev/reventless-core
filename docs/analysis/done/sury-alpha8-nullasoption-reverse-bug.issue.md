<!--
Ready-to-post GitHub issue for https://github.com/DZakh/sury
Paste the "Title" as the issue title and everything under "Body" as the issue body.
Companion analysis: ./sury-alpha8-nullasoption-reverse-bug.md
-->

# Title

`nullAsOption` field inside a variant fails to round-trip when nested in `array`/`object` — encodes `null` but can't parse it back

# Body

## Summary

A record field whose schema is `S.nullAsOption` (ReScript `option<'a>` ⇄ `'a | null`) round-trips correctly at the top level, but **fails to parse** when the same field is reached through `array<record>` nested inside an outer object *and* the field lives in a **multi-variant** union.

The two directions disagree:

- **Encode** (typed → JSON) is correct at every depth: `None` → `null`.
- **Parse** (JSON → typed) only applies the `nullAsOption` transform at shallow depth. Deeper, it reverts the field to its plain declared type (`string | undefined`) and throws on the `null` that encode just produced.

So a value cannot be parsed back from its own serialized output.

## Environment

- `sury` **11.0.0-alpha.8 and 11.0.0-alpha.9** — both reproduce.
- `sury-ppx` matching version, `rescript@12.3.0`, `@rescript/runtime@12.3.0`, Node 22.

## Minimal reproduction

```rescript
let sortKeySchema = S.string->S.nullAsOption

@schema
type resourceInfo =
  | StorageKeys({partitionKey: string, sortKey: @s.matches(sortKeySchema) option<string>})
  | StreamSource({sourceUrn: string})
  | ApiResolver({typeName: string, fieldName: string})
  | NoInfo

@schema
type resource = {name: string, resourceInfo: resourceInfo}

@schema
type wrapper = {resources: array<resource>}

let one = {name: "r", resourceInfo: StorageKeys({partitionKey: "id", sortKey: None})}
let many = {resources: [one]}

// A) top-level union — round-trips fine
let jA = one.resourceInfo->S.decodeOrThrow(~from=resourceInfoSchema, ~to=S.json)
// jA = {"TAG":"StorageKeys","partitionKey":"id","sortKey":null}
let _ = jA->S.parseOrThrow(~to=resourceInfoSchema)   // OK

// B) array<record> in object — encode OK, parse THROWS
let jB = many->S.decodeOrThrow(~from=wrapperSchema, ~to=S.json)
// jB = {"resources":[{"name":"r","resourceInfo":{"TAG":"StorageKeys","partitionKey":"id","sortKey":null}}]}
let _ = jB->S.parseOrThrow(~to=wrapperSchema)
```

## Actual output

```
A) encoded: {"TAG":"StorageKeys","partitionKey":"id","sortKey":null}
A) parse: OK
B) encoded: {"resources":[{"name":"r","resourceInfo":{"TAG":"StorageKeys","partitionKey":"id","sortKey":null}}]}
B) parse: THROWS
   Failed at ["resources"]["0"]["resourceInfo"]["sortKey"]: Expected string | undefined, received null
```

## Expected

`B` parses symmetrically to its own encode output (as `A` does) — `sortKey: null` decodes back to `None`.

## Ingredients required to trigger

Removing any **one** of these makes the bug disappear (verified):

1. `S.nullAsOption` reached via `@s.matches` on an `option` field.
2. The field is in a **multi-variant** union. A single-variant union does **not** reproduce.
3. The union is reached through a **record inside `array<…>` inside an object** (`wrapper.resources[i].resourceInfo`). A one-level union, or a union directly in an `array` without the record wrapper, does **not** reproduce.

This suggests the reverse (parse) schema for `nullAsOption` isn't being propagated correctly through the combination of `union` + `array` + nested `object` at that depth.
