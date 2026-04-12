# Plan: ByIdConnection Pagination Harmonization

## Overview

Replace the DynamoDB-native `ByIdConnection` query pattern with a fully Relay-compatible shape. The changes are:

1. Fix pluralization (`y` → `ies`) in `Api_Naming`
2. Rename the entity-scoped query from `EntityNameById` to `EntityNameItems`
3. Replace flat DynamoDB args (`prefix`, `from`, `to`, `eq`, `reverse`, `limit`, `nextToken`) with a `filter` input object + standard Relay pagination (`first`, `after`, `last`, `before`)
4. Replace `{ items, nextToken }` return type with a proper Relay `Connection` / `Edge` / `PageInfo` shape — shared with the full-scan connection query
5. Switch cursor encoding from offset integer to keyset (base64 of sort key value), enabling backward pagination on all backends

**What does not change**: `subIdConfig` spec API, in-memory storage structure, `SortKey_Filter` filtering logic, DynamoDB `KeyConditionExpression` operation.

---

## Step 1 — Fix `pluralize` and `singularize` in `Api_Naming.res`

**File**: `reventless/reventless-core/src/components/Api/Api_Naming.res`

Two bugs to fix:

1. **Collision**: names ending in `"s"` (e.g. `Status`, `Address`) currently return the same string from `pluralize`, making `singleFieldName` and `listFieldName` identical — two GraphQL queries with the same name. Fix: append `"es"` instead.
2. **Missing `y → ies` rule**: words ending in a consonant + `y` (e.g. `Category`, `Entry`) should drop the `y` and append `"ies"`.

`singularize` must be updated to be the consistent inverse of the new `pluralize`.

Also fix the inline `++ "s"` in `queryFieldNamesForSliceQueryDb` (line ~59) which bypasses `pluralize` entirely — replace it with a call to `pluralize`.

```rescript
// Before
let pluralize = name =>
  name->String.endsWith("s") ? name : name ++ "s"

let singularize = (n: string) =>
  if n->String.endsWith("ies") {
    n->String.slice(~start=0, ~end=n->String.length - 3) ++ "y"
  } else if n->String.endsWith("s") {
    n->String.slice(~start=0, ~end=n->String.length - 1)
  } else {
    n
  }

// After
let pluralize = name =>
  if Js.Re.test_(%re("/[^aeiou]y$/"), name) {
    name->String.slice(~start=0, ~end=String.length(name) - 1) ++ "ies"
  } else if name->String.endsWith("s") {
    name ++ "es"   // Address → Addresses, Status → Statuses
  } else {
    name ++ "s"
  }

let singularize = (n: string) =>
  if n->String.endsWith("ies") {
    n->String.slice(~start=0, ~end=n->String.length - 3) ++ "y"
  } else if n->String.endsWith("ses") || n->String.endsWith("xes") || n->String.endsWith("zes") || n->String.endsWith("ches") || n->String.endsWith("shes") {
    // covers words where pluralize appended "es" to a stem already ending in s/x/z/ch/sh
    n->String.slice(~start=0, ~end=n->String.length - 2)  // strip "es"
  } else if n->String.endsWith("s") {
    n->String.slice(~start=0, ~end=n->String.length - 1)
  } else {
    n
  }
```

Also replace the hardcoded `++ "s"` in `queryFieldNamesForSliceQueryDb`:

```rescript
// Before
listFieldName: `${plugin}_${queryDbName}s`,
pluralTypeName: `${plugin}_${queryDbName}s`,

// After
listFieldName: `${plugin}_${pluralize(queryDbName)}`,
pluralTypeName: `${plugin}_${pluralize(queryDbName)}`,
```

**Affected names**:
- Names ending in consonant + `y` (e.g. `Category`, `Summary`, `Entry`, `Policy`) — new plural field names, breaking for existing clients
- Names ending in `"s"` (e.g. `Status`, `Address`) — previously broken (collision), now fixed; breaking for any client that happened to use the old (wrong) field

**Scope**: `reventless-core`. No other files change in this step.

---

## Step 2 — Add `SortOrder` enum and `SubIdFilter` input type generation

**File**: `reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`

Add a shared `SortOrder` enum to the SDL base types registered once per schema:

```graphql
enum SortOrder { ASC DESC }
```

Register it alongside `PageInfo` and `Node` in the base type registration path (the same place `PageInfo` is added today).

Add a new generator function `deriveSubIdFilterType`:

```rescript
let deriveSubIdFilterType = (~filterTypeName: string): string =>
  `input ${filterTypeName} {\n  prefix: String\n  from: String\n  to: String\n  eq: String\n  order: SortOrder\n}`
```

The `filterTypeName` is `${returnTypeName}Filter` (e.g. `Plugin_CategoryFilter`).

**Scope**: `reventless-core` only.

---

## Step 3 — Replace `deriveByIdConnectionQueryField` and `deriveByIdConnectionType`

**File**: `reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`

Replace the current ById SDL generators with versions that produce Relay-compatible output and reuse the existing `Connection`/`Edge` types.

```rescript
// Before
let deriveByIdConnectionType = (~typeName): string =>
  `type ${typeName}ByIdConnection {\n  items: [${typeName}!]!\n  nextToken: String\n}`

let deriveByIdConnectionQueryField = (~singleFieldName, ~returnTypeName): string =>
  `  ${singleFieldName}ById(id: ID!, prefix: String, from: String, to: String, eq: String, reverse: Boolean, limit: Int, nextToken: String): ${returnTypeName}ByIdConnection!`

// After
// No separate ByIdConnection type — reuses the existing Connection type

let deriveItemsQueryField = (~singleFieldName, ~returnTypeName, ~filterTypeName): string =>
  `  ${singleFieldName}Items(id: ID!, filter: ${filterTypeName}, first: Int, after: String, last: Int, before: String): ${returnTypeName}Connection!`
```

The `ByIdConnection` type and `ByIdEdge` type are no longer generated. The `Items` query returns the same `${returnTypeName}Connection` already generated by `deriveConnectionTypes`.

Update the call site in `generate` (currently lines ~247–260) to call `deriveItemsQueryField` and `deriveSubIdFilterType` instead of the old pair.

**Scope**: `reventless-core` only. The SDL shape change is breaking for any client using `EntityNameById` or `ByIdConnection`.

---

## Step 4 — Update in-memory resolver in `QueryDbResolvers_GraphQL.res`

**File**: `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`

Replace the current `byIdListResolvers` implementation. The changes:

- Register the resolver under `singleQueryName ++ "Items"` instead of `singleQueryName ++ "ById"`
- Extract `filter` input object (`filter.prefix`, `filter.from`, `filter.to`, `filter.eq`, `filter.order`) instead of flat args
- Replace integer offset cursor with keyset cursor: `after`/`before` args decode to a sort key string (base64)
- Support `last`/`before` via the flip-reverse algorithm
- Return Relay `{ edges, pageInfo }` instead of `{ items, nextToken }`

**Cursor encoding**:
```rescript
// Encode: base64 of the sort key value of the last item in the page
let encodeCursor = (subKeyValue: string): string =>
  Buffer.fromString(subKeyValue)->Buffer.toStringWithEncoding("base64")

// Decode: reverse of the above
let decodeCursor = (cursor: string): string =>
  Buffer.fromStringWithEncoding(cursor, "base64")->Buffer.toString
```

**Forward pagination** (`first`, `after`):
```
1. Decode after cursor → afterKey (sort key string)
2. Filter items: subKey > afterKey  (string comparison)
3. Apply SortKey_Filter for prefix/from/to/eq
4. Apply order (reverse array if DESC)
5. Take first + 1 items
6. hasNextPage = took first+1; return first items
7. endCursor = encodeCursor(last item's subKey)
```

**Backward pagination** (`last`, `before`):
```
1. Decode before cursor → beforeKey
2. Filter items: subKey < beforeKey
3. Apply SortKey_Filter for prefix/from/to/eq
4. Apply REVERSE order (flip relative to filter.order)
5. Take last + 1 items
6. hasPreviousPage = took last+1; take last items
7. Reverse result array (restore logical order)
8. startCursor = encodeCursor(first item's subKey)
```

**Return shape**:
```rescript
{
  "edges": items->Array.map(item => {
    "node": item,
    "cursor": encodeCursor(item[subKeyField])
  }),
  "pageInfo": {
    "hasNextPage": hasNextPage,
    "hasPreviousPage": hasPreviousPage,
    "startCursor": startCursor->Nullable.fromOption,
    "endCursor": endCursor->Nullable.fromOption,
  }
}
```

**Scope**: `reventless-in-memory` only.

---

## Step 5 — Update AWS AppSync resolver functions

**File**: `reventless/reventless-aws/src/adapter/QueryEngine/AppSync_Resolver_Functions.res` (and related resolver template files)

Replace the flat-arg ById resolver with one that reads from the `filter` input object and uses keyset cursor pagination.

**Request function changes**:
- Read `args.filter.prefix`, `args.filter.from`, `args.filter.to`, `args.filter.eq`, `args.filter.order` instead of flat `args.prefix` etc.
- Detect `args.before` / `args.last` to determine backward pagination
- For forward (`first`/`after`): `sk > decodeCursor(args.after)`, `ScanIndexForward: !(args.filter?.order === 'DESC')`
- For backward (`last`/`before`): `sk < decodeCursor(args.before)`, flip `ScanIndexForward`, fetch `last + 1`

**Response function changes**:
- Reverse result array when backward pagination was used
- Build `edges` array with `{ node, cursor: encodeCursor(item[skField]) }`
- Build `pageInfo` with `hasNextPage`, `hasPreviousPage`, `startCursor`, `endCursor`
- Remove `nextToken` from response

**Cursor encoding** (JS in AppSync resolver):
```javascript
const encodeCursor = (skValue) => Buffer.from(skValue).toString('base64')
const decodeCursor = (cursor) => Buffer.from(cursor, 'base64').toString('utf8')
```

**Scope**: `reventless-aws`. No DynamoDB operation changes — still `KeyConditionExpression` with `begins_with`, range, equality; only the args source and cursor encoding change.

---

## Step 6 — Update `queryFieldNamesRegistry` and `Api_Naming` for Items query

**File**: `reventless/reventless-core/src/components/Api/Api_Naming.res`

The `queryNames` record currently has no field for the `Items` query name. Add one:

```rescript
type queryNames = {
  singleFieldName: string,
  listFieldName: string,
  itemsFieldName: option<string>,   // Some only when subIdConfig present
  returnTypeName: string,
  pluralTypeName: string,
  filterTypeName: option<string>,   // Some only when subIdConfig present
  includeIdParam: bool,
  connectionSpec: bool,
}
```

`queryFieldNamesForReadModel` sets `itemsFieldName: None`; the value is populated in `Plugin_Builder` when `subIdField` is present:

```rescript
// Plugin_Builder.res, in the ReadModel query entry construction
let itemsFieldName = subIdField->Option.map(_ => `${singleFieldName}Items`)
let filterTypeName = subIdField->Option.map(_ => `${returnTypeName}Filter`)
```

**Scope**: `reventless-core`. Touches `Api_Naming`, `Plugin_Builder`, and any code that reads `queryNames`.

---

## Completion criteria

- A ReadModel with `subIdConfig` generates exactly three query fields: `Entity(id)`, `Entities(...)`, `EntityItems(id, filter, ...)`
- `Entities` and `EntityItems` both return `EntityConnection` with Relay `edges`/`pageInfo`
- `EntityItems` accepts `first`/`after` (forward) and `last`/`before` (backward)
- Cursor is an opaque base64 string encoding the sort key value; consistent between in-memory and AWS
- No `ByIdConnection` type exists anywhere in the generated SDL
- `pluralize("Category")` returns `"Categories"`
- `pluralize("Status")` returns `"Statuses"` (not `"Status"`)
- `pluralize("Address")` returns `"Addresses"` (not `"Address"`)
- `singularize(pluralize(x)) == x` for all names used in the codebase
- All existing tests for `subIdConfig` ReadModels pass with updated assertions
