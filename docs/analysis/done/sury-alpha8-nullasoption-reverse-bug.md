# Sury 11.0.0-alpha.8 — `@s.matches(nullAsOption)` reverse transform dropped when nested in `array<record>`

**Status:** ✅ **FIXED in `sury@11.0.0-alpha.10`.** Present in `11.0.0-alpha.8`
and `11.0.0-alpha.9` (re-verified against alpha.9 on 2026-07-04 — same repro,
same failure). Verified fixed on alpha.10: with the `ResolvedOutputsTest` fixture
reverted to `sortKey: None`, every nested `array<record>` round-trip now parses
back symmetrically (47→48 passing). A **separate** facet also surfaced here — a
plain-`None` optional field serialising to `undefined` and rejected as non-jsonable
inside a `JSON`-typed enclosing field on encode — which alpha.10 does **not** fix;
it is split out to
[`sury-alpha10-undefined-optional-in-json.issue.md`](./sury-alpha10-undefined-optional-in-json.issue.md)
(3 `ResolvedOutputsTest` cases stay `test.skip`-ped) — which appears to be the
same as the already-open upstream **#311**. Migration:
[`sury-11-migration.md`](../plans/sury-11-migration.md). Original upstream report:
**[#284](https://github.com/DZakh/sury/issues/284)** (closed, fixed in alpha.10).

## Summary

A field carrying a `@s.matches(S.nullAsOption)` schema (so a ReScript
`option<string>` serialises to `string | null`) **round-trips correctly at the
top level**, but **fails to parse** when the same schema is reached through
`array<record>` nested inside an outer object *and* the field lives in a
**multi-variant** union. On the reverse (parse) direction sury reverts the field
to its plain declared type (`string | undefined`) and rejects the `null` it just
produced on encode.

- Encode (typed → JSON) is correct at every depth: `None` → `null`.
- Decode/parse (JSON → typed) only applies the `nullAsOption` transform at
  shallow depth. Deeper, it expects `string | undefined` and throws on `null`.

## Environment

- `sury@11.0.0-alpha.8` **and `@11.0.0-alpha.9`** (both reproduce), matching
  `sury-ppx`, `rescript@12.3.0`, Node 22.

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

// A) top-level union — round-trips
let jA = one.resourceInfo->S.decodeOrThrow(~from=resourceInfoSchema, ~to=S.json)
// jA = {"TAG":"StorageKeys","partitionKey":"id","sortKey":null}
let _ = jA->S.parseOrThrow(~to=resourceInfoSchema)   // OK

// B) array<record> in object — encode OK, parse THROWS
let jB = many->S.decodeOrThrow(~from=wrapperSchema, ~to=S.json)
// jB = {"resources":[{"name":"r","resourceInfo":{"TAG":"StorageKeys","partitionKey":"id","sortKey":null}}]}
let _ = jB->S.parseOrThrow(~to=wrapperSchema)
// THROWS: Failed at ["resources"]["0"]["resourceInfo"]["sortKey"]:
//         Expected string | undefined, received null
```

## Observed vs expected

| | Encode output | Parse back |
|---|---|---|
| A (top-level union) | `sortKey: null` | ✅ `None` |
| B (`array<record>` in object) | `sortKey: null` | ❌ throws `Expected string \| undefined, received null` |

Expected: B parses symmetrically to its own encode output (as A does).

## Ingredients required to trigger

Removing any one of these makes the bug disappear (verified):

1. `@s.matches(S.nullAsOption)` on an `option` field (must be on the **type**,
   after the colon — the ReScript ppx ignores it before the field name).
2. The field lives inside a **multi-variant** union. A single-variant union does
   **not** reproduce.
3. The union is reached through a **record inside `array<…>` inside an object**
   (`wrapper.resources[i].resourceInfo`). A one-level union, or a union directly
   in `array` without the record wrapper, does not reproduce.

## Impact on reventless

`reventless-interop`'s `resolvedOutputs` schemas embed
`resources: array<Resource.t>`, where `Resource.resourceInfo` is exactly this
multi-variant union with a `nullAsOption` `sortKey`. On alpha.8 a cross-stack
import of a resource with **no sort key** (`None`) fails to decode. This is a
real (if narrow) deploy-time path, not just a test artifact.

A second, related alpha.8 strictness change also surfaces here: a nested `None`
**plain** optional field (e.g. `eventMapper?`) serialises to `undefined` and is
rejected as non-jsonable inside a `JSON`-typed enclosing field on encode
(`Expected undefined | JSON, received {… undefined …}`). alpha.4's
`reverseConvertToJsonOrThrow` tolerated / omitted these.

## Workaround in place (pending upstream fix)

In `ResolvedOutputsTest.res`: the shared `resource` fixture uses `sortKey: Some(_)`
(so the resolvedOutputs structure round-trips are still exercised), the blocked
`None`-at-depth case is pinned as `test.todo`, and the 3 tests hitting the
`undefined`-in-`JSON` facet are `test.skip`-ped with a note. Revert the fixture to
`None`, convert the todo to a real test, and un-skip once sury ships the fix.
