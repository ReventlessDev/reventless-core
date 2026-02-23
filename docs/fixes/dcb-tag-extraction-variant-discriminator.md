# DCB Tag Extraction: Missing Variant Discriminator Check

## Problem

`DcbTag.extractTagsFromJson` extracted wrong tags when serializing a union-typed value (event or command) whose JSON representation happened to contain a field that was tagged in an **earlier** variant of the schema.

### Concrete example

Given `OrderingEventLog` with these variants (in order):

```rescript
@schema type event =
  | CustomerRegistered({ customerId: @s.matches(Reventless.DcbTag.string) string, ... })
  | ...
  | OrderPlaced({ orderId: @s.matches(Reventless.DcbTag.string) string, customerId: string, ... })
  | OrderShipped({ orderId: @s.matches(Reventless.DcbTag.string) string })
  | OrderCancelled({ orderId: @s.matches(Reventless.DcbTag.string) string })
```

When `OrderPlaced({orderId: "ord-1", customerId: "cust-1", ...})` was stored in the event log, its serialized JSON was:

```json
{ "TAG": "OrderPlaced", "orderId": "ord-1", "customerId": "cust-1", "productIds": [...] }
```

The extracted tags were `[{key: "customerId", value: "cust-1"}]` instead of `[{key: "orderId", value: "ord-1"}]`.

This caused the `PlaceOrder` state change slice to never find previously stored `OrderPlaced` events. Its query used tag `{key: "orderId", value: "ord-1"}`, which never matched the stored `{key: "customerId", value: "cust-1"}` tag — so the decision model always had `exists: false`, and every `PlaceOrder` command produced a new event regardless of history.

### Observed test failures

In `OrderingE2ETest`:

```
✗ duplicate PlaceOrder produces 0 events (OrderAlreadyPlaced)
    Expected: 0  Received: 1

✗ ShipOrder on placed order publishes 1 event
    Expected: 1  Received: 0
```

## Root Cause

The `extractTagsFromJson` function (Union case) iterated through `anyOf` variant schemas and returned the result of the **first variant that yielded any tagged fields** — without checking that the variant's `TAG` constant matched the `TAG` field in the JSON:

```javascript
// Buggy implementation
return Stdlib_Array.reduce(schema.anyOf, [], (acc, variantSchema) => {
  if (acc.length !== 0) {
    return acc;  // stop as soon as any variant produces tags
  } else if (variantSchema.type === "object") {
    return extractTagsFromProperties(variantSchema.properties, jsonDict);
    // ↑ no check that variantSchema's TAG matches jsonDict["TAG"]
  } else {
    return [];
  }
});
```

For `OrderPlaced` JSON:

1. First variant checked: `CustomerRegistered` — has tagged `customerId`.
2. `OrderPlaced` JSON contains `customerId` (as a plain, non-tagged field).
3. `extractTagsFromProperties` finds `customerId` in the JSON dict and returns `[{key: "customerId", value: "cust-1"}]`.
4. Non-empty → iteration stops. Wrong tags returned.

The root cause is that `extractTagsFromProperties` inspects the **variant's schema** for tagged fields but looks them up in the **event's JSON** — a different variant. Without checking the TAG discriminator first, any variant whose tagged fields happen to share names with non-tagged fields of the actual variant will produce false matches.

## Why this was undetected

The `CatalogEventLog` tests passed because all catalog events use two separate tag field names (`productId` for Product events, `categoryId` for Category events). A `ProductAdded` JSON dict has no `categoryId` field, so the first variant always matched correctly by coincidence. The bug only manifests when a later variant's JSON contains a field that is tagged in an earlier variant.

## Fix

Before extracting properties from a variant schema, compare the variant's `TAG` constant against the `TAG` field in the JSON dict. This mirrors the pattern already used in `extractEventTypes`:

```rescript
// packages/reventless-spec/src/components/DcbTag.res

| Union({anyOf}) =>
  switch json->JSON.Decode.object {
  | Some(jsonDict) =>
    let jsonTag = jsonDict->Dict.get("TAG")->Option.flatMap(j =>
      switch j {
      | JSON.String(s) => Some(s)
      | _ => None
      }
    )
    anyOf->Array.reduce([], (acc, variantSchema) =>
      if acc->Array.length > 0 {
        acc
      } else {
        switch variantSchema {
        | Object({items, properties}) =>
          let variantTag = items
            ->Array.find(item => item.location == "TAG")
            ->Option.flatMap(item =>
              switch item.schema {
              | String({const}) => Some(const)
              | _ => None
              }
            )
          if variantTag == jsonTag {
            extractTagsFromProperties(properties, jsonDict)
          } else {
            []
          }
        | _ => []
        }
      }
    )
  | None => []
  }
```

## General Pattern

When working with sury union schemas, always use the TAG discriminator to select the matching variant before operating on its properties. The sury runtime schema object exposes the TAG constant via `items.find(i => i.location === "TAG").schema.const` — the same mechanism used by `extractEventTypes`.

### Pitfall to avoid

If your DCB event log has variants where a field name is tagged in one variant but appears as a plain (non-tagged) field in another, tag extraction will produce wrong results without this fix. This is not an exotic edge case — any event log mixing entity types (e.g., Customer events with `customerId` and Order events that reference a `customerId`) is susceptible.
