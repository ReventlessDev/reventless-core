# Plan: Allow plural `*Ids: array<string>` field names for DCB tags

## Problem

Today the DCB tag convention requires the **singular** form even when a field stores multiple values:

```rescript
@schema type event =
  OrderPlaced({orderId: string, productId: array<string>})  // singular field, array type
```

The reason is that the runtime tag extractor uses the field name *verbatim* as the tag key
([DcbTag.res:217-228, 352-373](reventless/reventless-spec/src/components/DcbTag.res#L217)).
A consumer that wrote `productIds: array<string>` would store tags under key `productIds`,
mismatching producers that store under `productId`. The convention sidesteps this by forcing
all parties to write the singular name.

This shows up as awkward read-model state in `online-shop-hybrid/ordering`:

- [Orders.res:22](examples/online-shop-hybrid/ordering/src/Order/StateViewSlice/Orders.res#L22) — `productId: array<string>` on the projected state
- [CancelOrder_Behavior.res:3](examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/CancelOrder_Behavior.res#L3) — same on the decision-model state
- [Orders.res:8](examples/online-shop-hybrid/ordering/src/Order/StateViewSlice/Orders.res#L8), [Orders_ExtensionPointMapping.res:13-14](examples/online-shop-hybrid/ordering/src/ExtensionPoint/Orders_ExtensionPointMapping.res#L13-L14) — singular field on a clearly multi-value payload

## Goal

Let users write `productIds: array<string>` and have the runtime stamp tags with key
`productId`, so plural-named fields interoperate with the existing singular tag-key
convention.

Out of scope: general English pluralization. The rule is the trivial `*Ids` → `*Id`
(strip trailing `s`). Anything more exotic uses the explicit `@dcbTag("name")` escape
hatch.

## Approach

The PPX already detects both `*Id: array<string>` (`Util.ends_with_id`) and
`*Ids: array<string>` (`DcbTagInference.ends_with_ids`). What's missing is a mechanism
to stamp a different tag key than the field name.

We add a metadata-based key override on the sury schema. The PPX, when it sees a plural
form, emits the override-carrying schema. The runtime tag extractors consult the metadata.

### Step 1 — Add `dcbTagKeyOverride` metadata + `stringForKey` constructor

File: [reventless/reventless-spec/src/components/DcbTag.res](reventless/reventless-spec/src/components/DcbTag.res)

Add:

```rescript
let dcbTagKeyOverrideId: S.Metadata.Id.t<string> =
  S.Metadata.Id.make(~namespace="dcb", ~name="tagKeyOverride")

let stringForKey = (~key: string): S.t<string> =>
  S.string
  ->S.Metadata.set(~id=dcbTagId, true)
  ->S.Metadata.set(~id=dcbTagKeyOverrideId, key)
```

Helper:

```rescript
let resolveTagKey = (fieldName: string, fieldSchema: S.t<unknown>): string =>
  S.Metadata.get(fieldSchema, ~id=dcbTagKeyOverrideId)->Option.getOr(fieldName)
```

For array element types (where the metadata sits on the inner schema, not the array),
add a small helper that pulls the override from `Array.additionalItems`.

### Step 2 — Update tag extraction to consult the override

Same file. In `extractTagsFromProperties` ([line 217](reventless/reventless-spec/src/components/DcbTag.res#L217)):

```rescript
->Option.map(jsonValue => {
  key: resolveTagKey(fieldName, fieldSchema),
  value: jsonValue->jsonValueToString,
})
```

In `extractTagsFromPropertiesExpanded` ([line 352](reventless/reventless-spec/src/components/DcbTag.res#L352)) for both
the scalar and array branches: replace the literal `fieldName` with the resolved key
(for the array branch, read the override from the inner schema and fall back to
`fieldName`).

No other call sites read tag keys from field names directly — `extractTaggedFields`
already returns names for diagnostics only and is unaffected.

### Step 3 — PPX emits the override constructor for `*Ids`

File: [packages/reventless-ppx/src/ppx/DcbTagInference.ml](packages/reventless-ppx/src/ppx/DcbTagInference.ml)

Today ([lines 117-128](packages/reventless-ppx/src/ppx/DcbTagInference.ml#L117-L128)) the array branch injects a bare `@s.matches(Reventless.DcbTag.string)`.
Split the branch:

- If `ends_with_id` matches → keep current behavior (singular name, no override).
- If `ends_with_ids` matches → emit
  `@s.matches(Reventless.DcbTag.stringForKey(~key="<name minus s>"))` on the element type.

Add a tiny `singularize_ids` helper in `Util.ml` (just `String.sub name 0 (len-1)`,
guarded by `ends_with_ids`).

### Step 4 — Extend `@dcbTag` to accept an explicit key override

The current `@dcbTag` annotation injects `DcbTag.string` with no payload. Allow:

```rescript
@dcbTag("productId") productIds: array<string>
@dcbTag("sku") productSkus: array<string>
```

In `DcbTagInference.transform_explicit_dcb_tags` ([line 198](packages/reventless-ppx/src/ppx/DcbTagInference.ml#L198)):
parse the optional string payload of `@dcbTag` and, when present, emit
`DcbTag.stringForKey(~key="...")` instead of `DcbTag.string`. Existing payload-less
usages keep working unchanged.

### Step 5 — Migrate the hybrid example

In `examples/online-shop-hybrid/ordering/`:

- `StateChangeSlice/PlaceOrder.res` — rename `productId: array<string>` to `productIds: array<string>` in command + event types
- `StateChangeSlice/CancelOrder.res` — same in `consumedEvent.OrderPlaced` and `event.OrderCancelled`
- `StateChangeSlice/CancelOrder_Behavior.res` — rename state field to `productIds`
- `StateViewSlice/Orders.res` — rename in `consumedEvent` and `state`
- `StateViewSlice/Orders_Projection.res` — replace field-punning with explicit field copy
- `ExtensionPoint/Orders_ExtensionPointMapping.res` — rename in `Delegate.event`; rename the destructure-and-iterate variable to `productIds`
- Update the comment in `PlaceOrder.res:5` to mention the singularization rule

Verify: stored tag keys for these events stay `productId` (assert with a unit test in
the next step).

### Step 6 — Tests

Add to `reventless/reventless-spec/tests/components/DcbTagTest.res` (create if absent):

1. `extractTags` on a schema declared with `stringForKey(~key="productId")` returns tags
   keyed `productId` even though the field is `productIds`.
2. `extractTagsExpanded` with an array-tagged field that uses the override returns one
   tag per element, all keyed `productId`.
3. `buildQueryFromCommand` produces query items keyed `productId` for a plural-array
   field.
4. Round-trip: an event written via the plural-named producer matches a query built by
   a singular-named consumer (or vice versa).

PPX golden tests in `packages/reventless-ppx/test/dcb_tags/`: add fixtures for the
`*Ids` array case and the `@dcbTag("name")` payload form, confirm the emitted schema
calls `DcbTag.stringForKey`.

### Step 7 — Rebuild PPX binaries

Per the project memory: macOS `pnpm run build:ppx`, then Linux Docker build for
`ppx-linux.exe`. Commit both binaries.

### Step 8 — Update docs and conventions

- `.claude/rules/app-developer.md` (the dcbTags section quoted in `CLAUDE.md`):
  document that `*Ids: array<string>` is now an accepted alternative spelling and
  produces the same tag key as `*Id: array<string>`. Document the extended
  `@dcbTag("name")` payload form.
- `docs/guides/dcb-usage.md`: update the example snippets, prefer plural names where
  the field is multi-value.
- `packages/reventless-ppx/README` (or its equivalent doc) if it enumerates the rules.

## Acceptance

- `pnpm run build` and `pnpm test` clean across the monorepo.
- The hybrid example compiles with plural names; existing singular usages elsewhere
  remain valid (no breaking change to the singular form).
- A test asserts that singular-producer + plural-consumer (and vice versa) interoperate
  at the storage tag key.
- `online-shop-aggregates` and `online-shop-dcb` examples need no changes (they don't
  use array-tag fields today).

## Non-goals

- General English pluralization (no `categories` → `category`, no `entries` → `entry`).
  Use `@dcbTag("category")` for irregular plurals.
- Renaming singular field names project-wide. The convention now permits both forms;
  cleanup of existing singular array fields is opportunistic.
- Composite partition tags or partition tag fields — the override only affects scalar
  and array `DcbTag.string` schemas.
