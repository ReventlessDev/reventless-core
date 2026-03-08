# Multi-Clause DCB Queries for Cross-Entity Decision Models

## Motivation

The hybrid approach promises cross-entity validation at command time — for example, `PlaceOrder` should verify that all referenced products exist by replaying `CatalogProductSynced` events from the shared DCB event log. Today this is impossible because `StateChangeSlice_Callback` builds a **single query clause** from the command's tagged fields.

When `PlaceOrder({orderId: "ord-1", productId: ["prod-1", "prod-2"]})` arrives, the query is:

```
[{eventTypes: [...all types...], tags: [{key: "orderId", value: "ord-1"}]}]
```

This only fetches events tagged with `orderId = "ord-1"` (Order events). It **never** fetches `CatalogProductSynced` events, which are tagged with `productId = "prod-1"` or `productId = "prod-2"`.

What we need is a multi-clause query:

```
[
  {eventTypes: [...], tags: [{key: "orderId", value: "ord-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-2"}]},
]
```

The `query` type already supports this (it's `array<queryItem>` with OR semantics). The in-memory adapter's `matchesQuery` and the AWS adapter's multi-clause read with k-way merge-sort already handle it. The missing piece is in the **query construction** inside `StateChangeSlice_Callback`.

---

## Current Architecture

### Tag Extraction (`DcbTag.res`)

- `extractTags(schema, value)` serializes the value to JSON and calls `extractTagsFromProperties`
- `extractTagsFromProperties` iterates over record fields, checks `isTagged(fieldSchema)`, and converts each tagged field to `{key: fieldName, value: jsonValueToString(jsonValue)}`
- `jsonValueToString` handles scalar values: `String(s) → s`, `Number(n) → Float.toString(n)`, etc.
- **Array values** are stringified as JSON: `["prod-1","prod-2"]` → the literal string `'["prod-1","prod-2"]'` — useless for per-element tag matching

### Query Construction (`StateChangeSlice_Callback.res`)

```rescript
let commandTags = Reventless.DcbTag.extractTags(Spec.commandSchema, command'.command)
let query: Reventless.DcbTag.query = [{
  eventTypes: queryEventTypes,
  tags: commandTags,
}]
```

Always produces a single clause. All tags from the command go into one AND group.

### Query Execution

- **In-memory**: `query->Array.some(queryItem => typeMatch && tagMatch)` — OR across clauses, AND within
- **AWS DynamoDB**: Executes each `queryItem` separately, then k-way merge-sorts results (for tag-based clauses) or eager-collects + sorts (for scan-based clauses). Deduplicates by position.

Both adapters **already support multi-clause queries**. No adapter changes needed.

### Append Condition

The append condition uses the same `query` type for optimistic concurrency. It must match the read query exactly to detect concurrent writes.

---

## Recommended Approach: Automatic Schema-Driven Query Construction

### Core Insight

The command schema already contains all the information needed to determine query mode:

- **Scalar tagged fields** (`@s.matches(DcbTag.string) string`) → single-entity tag, AND'd in one clause
- **Tagged array fields** (`array<@s.matches(DcbTag.string) string>`) → cross-entity tag, each element becomes its own OR clause

No per-spec configuration is needed. The presence of a tagged array field inherently signals a cross-entity query.

### Algorithm

Given a command with tags extracted from the schema:

1. **Scalar tagged fields** produce one tag each: `{key: fieldName, value: scalarValue}`
2. **Tagged array fields** produce one tag per element: `{key: fieldName, value: element}` for each array element
3. **Query construction**:
   - If all tags came from scalar fields → single AND clause (identical to today's behavior)
   - If any tags came from array fields → per-element OR clauses (each tag gets its own clause)

### Example: PlaceOrder

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,        // scalar → single tag
      customerId: string,                                 // not tagged → ignored
      productId: array<@s.matches(DcbTag.string) string>, // array → per-element tags
    })
```

For `PlaceOrder({orderId: "ord-1", productId: ["prod-1", "prod-2"]})`:

**Extracted tags:**
```
[{key: "orderId", value: "ord-1"},
 {key: "productId", value: "prod-1"},   // from array expansion
 {key: "productId", value: "prod-2"}]   // from array expansion
```

**Built query** (automatic — tagged array detected):
```
[
  {eventTypes: [...], tags: [{key: "orderId", value: "ord-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-1"}]},
  {eventTypes: [...], tags: [{key: "productId", value: "prod-2"}]},
]
```

### Example: CreateItem (single-entity, unchanged behavior)

```rescript
@schema
type command =
  | CreateItem({itemId: @s.matches(DcbTag.string) string, name: string})
```

**Extracted tags:** `[{key: "itemId", value: "item-1"}]`

**Built query** (automatic — no tagged arrays):
```
[{eventTypes: [...], tags: [{key: "itemId", value: "item-1"}]}]
```

Identical to today's behavior. No change for single-entity slices.

### Why Per-Element Clauses (Not Multi-Value Tags)

Each array element becomes its own OR clause rather than combining values in a single clause because:
- Events are tagged with a single `productId` value (e.g., `CatalogProductSynced({productId: "prod-1"})`)
- A clause with `tags: [{key: "productId", value: "prod-1"}, {key: "productId", value: "prod-2"}]` would require an event to match BOTH values (AND semantics) — no single event does
- Per-element clauses correctly match events for each product independently

---

## Implementation Plan

### Step 1: Add `buildQueryFromCommand` to DcbTag ✅ (partially done)

File: `reventless/reventless-spec/src/components/DcbTag.res`

Replace the existing `queryMode`-based functions with a single `buildQueryFromCommand` function:

```rescript
let buildQueryFromCommand = (~eventTypes, ~schema, ~value): query => {
  let tags = extractTags(schema, value)
  let expandedTags = extractTagsExpanded(schema, value)

  if tags->Array.length == expandedTags->Array.length {
    // No array expansion happened → single-entity (all scalar tags)
    [{eventTypes, tags}]
  } else {
    // Array expansion occurred → cross-entity (per-element OR clauses)
    expandedTags->Array.map(tag => {eventTypes, tags: [{key: tag.key, value: tag.value}]})
  }
}
```

Or more directly, add a `hasTaggedArrays` schema introspection function:

```rescript
let hasTaggedArrays = (schema: S.t<'a>): bool => {
  // Inspect schema properties for any field where isTaggedArray returns true
}

let buildQueryFromCommand = (~eventTypes, ~schema, ~value): query => {
  if hasTaggedArrays(schema) {
    let tags = extractTagsExpanded(schema, value)
    tags->Array.map(tag => {eventTypes, tags: [{key: tag.key, value: tag.value}]})
  } else {
    let tags = extractTags(schema, value)
    [{eventTypes, tags}]
  }
}
```

**Keep existing helpers** (`isTaggedArray`, `extractTagsExpanded`, `extractTags`, `buildQuery`) — they are tested and used by `buildQueryFromCommand`.

**Remove**: `queryMode` type (no longer needed).

### Step 2: Remove `queryMode` from StateChangeSlice.Spec

File: `reventless/reventless-spec/src/components/StateChangeSlice.res`

Remove `let queryMode: DcbTag.queryMode` from the `Spec` module type.

### Step 3: Update StateChangeSlice_Callback

File: `reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res`

Replace:
```rescript
let commandTags = switch Spec.queryMode {
| SingleEntity => Reventless.DcbTag.extractTags(Spec.commandSchema, command'.command)
| CrossEntity => Reventless.DcbTag.extractTagsExpanded(Spec.commandSchema, command'.command)
}
let query = Reventless.DcbTag.buildQuery(
  ~queryMode=Spec.queryMode,
  ~eventTypes=queryEventTypes,
  ~tags=commandTags,
)
```

With:
```rescript
let query = Reventless.DcbTag.buildQueryFromCommand(
  ~eventTypes=queryEventTypes,
  ~schema=Spec.commandSchema,
  ~value=command'.command,
)
```

### Step 4: Remove `let queryMode` from All Specs

Remove `let queryMode = DcbTag.SingleEntity` (or `CrossEntity`) from all 24 StateChangeSlice specs and 2 test fixtures:

**Example specs (online-shop-hybrid):**
- `ordering/src/Order/StateChangeSlice/PlaceOrder.res` — remove `let queryMode = DcbTag.CrossEntity`
- `ordering/src/Order/StateChangeSlice/ShipOrder.res` — remove `let queryMode = DcbTag.SingleEntity`
- `ordering/src/Order/StateChangeSlice/CancelOrder.res` — remove `let queryMode = DcbTag.SingleEntity`
- `ordering/src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res` — remove `let queryMode = DcbTag.SingleEntity`
- All `catalog-spec/src/` and `catalog/src/` slices — remove `let queryMode = DcbTag.SingleEntity`

**Example specs (online-shop-dcb):**
- All `reventless-example-dcb/src/` slices — remove `let queryMode = DcbTag.SingleEntity`

**Test fixtures:**
- `reventless/reventless-core/tests/dcb/DcbFixtures.res` — remove `let queryMode`
- `reventless/reventless-in-memory/tests/components/DcbE2EFixtures.res` — remove `let queryMode`

### Step 5: Update Tests

1. **Update `buildQuery` tests** to test `buildQueryFromCommand` instead
2. **Verify existing E2E tests pass** (single-entity behavior unchanged)
3. **Verify cross-entity E2E test passes** (PlaceOrder with synced products)
4. **Add test**: command with only scalar tags → single clause (regression)
5. **Add test**: command with tagged array → per-element OR clauses (automatic detection)

### Step 6: Clean Up

- Remove `queryMode` type from `DcbTag.res`
- Remove `extractTagsFromJsonExpanded` if only used internally by `buildQueryFromCommand`
- Consider consolidating `extractTags` / `extractTagsExpanded` into one function with a flag, or keep both for clarity

---

## Append Condition Consideration

The append condition also uses a `query`. For cross-entity slices, the condition should check for new events matching **any** of the clauses (same multi-clause query). This ensures optimistic concurrency covers all entity types involved in the decision.

The current code in `StateChangeSlice_Callback.res` already uses the same `query` variable for both read and append condition — so this works automatically.

---

## AWS Performance Implications

- **Single tag per clause**: Each clause hits a GSI directly — efficient
- **Multiple clauses**: The AWS adapter already k-way merge-sorts them — efficient for tag-based clauses
- **Array expansion**: N product IDs → N additional clauses → N GSI queries. For large arrays this could be slow, but typical cross-entity commands reference a small number of related entities (< 10)
- **No new GSIs needed**: The existing per-tag GSIs handle single-tag clauses

---

## Files to Change

| File | Change |
|------|--------|
| `reventless/reventless-spec/src/components/DcbTag.res` | Add `buildQueryFromCommand`, remove `queryMode` type |
| `reventless/reventless-spec/src/components/StateChangeSlice.res` | Remove `let queryMode` from Spec |
| `reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res` | Use `buildQueryFromCommand` |
| All existing StateChangeSlice specs (24 files) | Remove `let queryMode = ...` |
| Test fixtures (2 files) | Remove `let queryMode = ...` |
| `reventless/reventless-core/tests/dcb/` | Update tests for new API |

## Checklist

- [x] Add `isTaggedArray` helper to DcbTag.res (detects `array<@s.matches(DcbTag.string) string>`)
- [x] Add `extractTagsExpanded` to DcbTag.res (array value expansion)
- [x] Add `buildQuery` helper to DcbTag.res
- [x] Update PlaceOrder with product validation logic + tagged array field
- [x] Unit tests for tag expansion and query building (11 new tests)
- [x] E2E test for cross-entity PlaceOrder validation (syncs products before PlaceOrder)
- [x] Verify no AWS adapter changes needed
- [x] Add `buildQueryFromCommand` to DcbTag.res (automatic schema-driven query construction)
- [x] Remove `queryMode` type from DcbTag.res
- [x] Remove `let queryMode` from StateChangeSlice.Spec module type
- [x] Update StateChangeSlice_Callback to use `buildQueryFromCommand`
- [x] Remove `let queryMode = ...` from all 24 StateChangeSlice specs + 2 test fixtures
- [x] Update unit tests for new automatic API
- [x] Verify all tests pass (776 tests across 93 suites)

## Implementation Notes

- Command field `productId` (singular) matches event tag key `productId` on `CatalogProductSynced`. Named singular despite holding an array to ensure tag key alignment.
- `isTaggedArray` detects `array<@s.matches(DcbTag.string) string>` by inspecting the sury `Array({additionalItems: Schema(...)})` structure.
- `extractTagsFromPropertiesExpanded` handles both scalar tagged fields and array tagged fields (per-element expansion).
- The automatic approach eliminates the `queryMode` field entirely — no boilerplate in specs. The schema IS the configuration.
