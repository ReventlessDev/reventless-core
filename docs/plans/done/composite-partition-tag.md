# Plan: `@compositePartitionTag` PPX Attribute

**Analysis:** `docs/analysis/platform-inspector-dcb-partition-keys.md` (in the downstream consumer repo)

**Goal:** Support composite DCB partition keys via a field-level PPX annotation. The annotation marks
N fields whose values are concatenated (in declaration order) with a configurable separator to form
the partition key, while each field remains individually queryable as a regular DCB tag.

---

## Background

`@partitionTag` (Approach 1) already works: the caller pre-computes a composite key string into a
dedicated field and that field becomes the partition. `@compositePartitionTag` (Approach 2) achieves
the same result without the redundant key field — the PPX derives the composite from individual
payload fields.

```rescript
// Approach 2 target syntax
| SyncPlugin({
    @compositePartitionTag environment: string,    // sep after = "/" (default)
    @compositePartitionTag platformName: string,   // sep after = "/" (default)
    @compositePartitionTag pluginName: string,     // last field — sep ignored
    version: string,
  })
// Composite key value: "{environment}/{platformName}/{pluginName}"
```

Each `@compositePartitionTag` field becomes a regular `DcbTag.string` (individually queryable).
The composite key is computed at runtime by reading the extracted tags in declared order.

**Separator semantics:** the separator specified on field N is placed *between* field N and field
N+1. The separator on the last field is ignored (nothing follows it). Default separator is `"/"`.

```rescript
@compositePartitionTag("{sep}") fieldN: string  // uses "{sep}" after this field
@compositePartitionTag           fieldM: string  // uses "/" after this field
```

---

## Design

### Annotation syntax

```rescript
@compositePartitionTag                    // uses "/" after this field
@compositePartitionTag("/")               // explicit default — same behaviour
@compositePartitionTag(":")               // uses ":" after this field
```

The PPX reads the optional string payload of the `@compositePartitionTag` attribute. If absent,
`"/"` is used.

### What the PPX generates

For a variant with K fields annotated `@compositePartitionTag`:

1. Each annotated field is transformed from `string` →
   `@s.matches(Reventless.DcbTag.compositePartitionMember(~position=N, ~sep="S")) string`
   where N is the zero-based declaration index among composite fields and S is the resolved separator.
2. The `@compositePartitionTag` attribute is stripped from the field.
3. Non-annotated fields are untouched.

### New DcbTag schema value

```rescript
let compositePartitionMemberId: S.Metadata.Id.t<{position: int, sep: string}> =
  S.Metadata.Id.make(~namespace="dcb", ~name="compositePartitionMember")

let compositePartitionMember = (~position: int, ~sep: string="/"): S.t<string> =>
  S.string
  ->S.Metadata.set(~id=dcbTagId, true)
  ->S.Metadata.set(~id=dcbCompositePartitionMemberId, {position, sep})
```

Each composite field is still a `DcbTag.string` (carries `dcbTagId=true`), so it is indexed and
queryable. The extra metadata encodes its role in the composite key.

### Extended `partitionTag` type

```rescript
// existing — unchanged
type partitionTag = {key: string}

// new
type compositePartitionSpec = {
  /** Field names in composition order. */
  keys: array<string>,
  /**
   Separators: seps[i] is inserted between keys[i] and keys[i+1].
   Length is always keys.length - 1.
   */
  seps: array<string>,
}

type derivedPartitionTag =
  | Simple(partitionTag)
  | Composite(compositePartitionSpec)
```

`derivePartitionTag` currently returns `partitionTag`. It will be renamed to
`derivePartitionTagLegacy` (or an overload) and a new `derivePartitionTag` returns
`derivedPartitionTag`. Callers are updated.

### Composite key value computation

```rescript
let getCompositePartitionKeyValue = (
  tags: array<dcbTag>,
  spec: compositePartitionSpec,
): string => {
  spec.keys
  ->Array.mapWithIndex((fieldName, i) =>
    tags
    ->Array.find(t => t.key == fieldName)
    ->Option.map(t => t.value)
    ->Option.getOr("")
  )
  ->Array.reduceWithIndex("", (acc, value, i) =>
    if i == 0 { value }
    else { acc ++ spec.seps->Array.getUnsafe(i - 1) ++ value }
  )
}
```

---

## Implementation steps

### 1 — `DcbTag.res`: new types and schema value ✅

- [x] Add `compositePartitionMemberId` alongside `dcbPartitionTagId`.
- [x] Add helper `isCompositePartitionMember(schema): bool`.
- [x] Add `compositePartitionMember(~position, ~sep="/")` schema value.
- [x] Add `type compositePartitionSpec = {keys: array<string>, seps: array<string>}`.
- [x] Add `type derivedPartitionTag = Simple(partitionTag) | Composite(compositePartitionSpec)`.
- [x] Add `extractCompositePartitionFields(schema)`.
- [x] Add `getCompositePartitionKeyValue(tags, spec)`.
- [x] Add `derivePartitionTagV2(namedSchemas): derivedPartitionTag`.

### 2 — `DcbTagInference.ml`: new PPX pass ✅

- [x] Add `has_composite_partition_tag_field_attr`, `get_composite_sep`, `strip_composite_partition_tag_field_attr`.
- [x] Add `dcb_composite_member_attr ~loc ~position ~sep`.
- [x] Add `transform_composite_partition_tags ~loc`.
- [x] Wire in `ReventlessPpx.ml` after `transform_partition_tags`.

### 3 — `DcbEventLogStorage_DynamoDb_Runtime.res`: runtime composite key ✅

- [x] Updated `derivePartitionKey` to accept `~partitionTag: option<derivedPartitionTag>=?`.
- [x] Added `Composite(spec)` branch calling `getCompositePartitionKeyValue`.

### 4 — `Dcb_Builder.res`: wire `derivePartitionTagV2` ✅

- [x] Replaced `derivePartitionTag` call with `derivePartitionTagV2`.
- [x] Updated `DcbEventLog_Adapter.res`, `DcbEventLog.res`, `DcbEventLog_Builder.res` (in-memory) to use `derivedPartitionTag`.

### 5 — Tests ✅

- [x] **PPX output test** — ReScript fixtures in `DcbFixtures.res` using `compositePartitionMember`
      with default and custom separators. Tests assert field types carry the expected metadata
      via `extractCompositePartitionFields` and `isCompositePartitionMember`.
- [x] **DcbTag unit tests** in `DcbTagTest.res`:
  - `extractCompositePartitionFields` on a single-variant and multi-variant schema.
  - `derivePartitionTagV2` returns `Composite` for a schema with ≥ 2 composite fields.
  - `derivePartitionTagV2` returns `Composite` with custom separators.
  - `derivePartitionTagV2` returns `Simple` for a schema with only `@partitionTag`.
  - `derivePartitionTagV2` returns `Simple` for a schema with single tagged field.
  - `derivePartitionTagV2` throws on mixed strategy within one schema.
  - `derivePartitionTagV2` throws on single composite field (< 2).
  - `getCompositePartitionKeyValue` with default `"/"` separators.
  - `getCompositePartitionKeyValue` with a mixed separator (`":"` between first two fields,
    `"/"` between the rest).
  - `getCompositePartitionKeyValue` with missing tag values.
  - `getCompositePartitionKeyValue` with tags in different order than keys.
  - `isCompositePartitionMember` positive and negative cases.
- [x] **Runtime test** — `getCompositePartitionKeyValue` (called by `derivePartitionKey`'s
      `Composite` branch) tested directly with spec `{keys, seps}` producing
      `"prod/aws/catalog"` and `"acme:eu-west-1/auth"` strings.

### 6 — Documentation ✅

- [x] Update `docs/analysis/platform-inspector-dcb-partition-keys.md` (in the downstream consumer repo)
      to mark Approach 2 as implemented.
- [x] Add a short reference entry to the sury PPX patterns reference in the skills plugin.

---

## Constraints and validation rules (summary)

| Rule | Behaviour |
|---|---|
| `@compositePartitionTag` on non-`string` field | PPX: no-op (leave untouched); log warning if possible |
| `@compositePartitionTag` and `@partitionTag` on same field | `derivePartitionTagV2` throws |
| Mixed strategies across variants in one schema | `derivePartitionTagV2` throws with variant names |
| Only 1 field annotated `@compositePartitionTag` | `derivePartitionTagV2` throws |
| Composite field position conflicts (e.g., two fields with same position) | Cannot happen — positions are assigned sequentially by the PPX in declaration order |

---

## Files changed

| File | Change |
|---|---|
| `reventless/reventless-spec/src/components/DcbTag.res` | New types, metadata ID, schema value, helper functions |
| `packages/reventless-ppx/src/ppx/DcbTagInference.ml` | New composite pass |
| `packages/reventless-ppx/src/ppx/ReventlessPpx.ml` | Wire new pass in `transform` |
| `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` | Composite branch in `derivePartitionKey` |
| `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res` | Use `derivePartitionTagV2` |
| `reventless/reventless-core/tests/dcb/DcbFixtures.res` or new test file | Composite partition tag tests |
