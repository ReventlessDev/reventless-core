# Resource Info — Generic Storage Key Names

## Context

`resourceInfo.StorageKeys` uses `hashKey` / `rangeKey` — DynamoDB-specific terminology. Rename to `partitionKey` / `sortKey`, which are provider-agnostic and used across cloud storage systems (DynamoDB, Cosmos DB, Spanner, etc.).

---

## Status

| Step | Description | Status |
|------|-------------|--------|
| 1 | Rename fields in `Adapter.res` | done |
| 2 | Rename fields in `Resource.res` (interop) | done |
| 3 | Update `Util_DynamoDb.res` constructor site | done |
| 4 | Update `Util_DynamoDb_Runtime.res` pattern match | done |
| 5 | Update `ResolvedOutputsTest.res` | done |
| 6 | Build and verify | done |

---

## Step 1 — `reventless-infra/src/adapter/Adapter.res`

```rescript
// Before:
| StorageKeys({hashKey: string, rangeKey: option<string>})

// After:
| StorageKeys({partitionKey: string, sortKey: option<string>})
```

## Step 2 — `reventless-interop/src/Resource.res`

```rescript
// Before:
| StorageKeys({hashKey: string, rangeKey: option<string>})

// After:
| StorageKeys({partitionKey: string, sortKey: option<string>})
```

## Step 3 — `reventless-aws/src/util/Util_DynamoDb.res`

The DynamoDB `table` struct keeps its own `hashKey`/`rangeKey` fields. Only the `StorageKeys` constructor call is updated:

```rescript
// Before:
->Pulumi.Output.apply(((hashKey, rangeKey)) => ReventlessInfra.Adapter.StorageKeys({hashKey, rangeKey}))

// After:
->Pulumi.Output.apply(((hashKey, rangeKey)) => ReventlessInfra.Adapter.StorageKeys({partitionKey: hashKey, sortKey: rangeKey}))
```

## Step 4 — `reventless-aws/src/util/Util_DynamoDb_Runtime.res`

```rescript
// Before:
| StorageKeys({hashKey, rangeKey}) => (hashKey, rangeKey)

// After:
| StorageKeys({partitionKey, sortKey}) => (partitionKey, sortKey)
```

## Step 5 — `reventless-interop/tests/ResolvedOutputsTest.res`

```rescript
// Before:
resourceInfo: StorageKeys({hashKey: "id", rangeKey: None}),

// After:
resourceInfo: StorageKeys({partitionKey: "id", sortKey: None}),
```

## Step 6 — Build and verify

```
cd reventless/reventless-infra && npm run build
cd reventless/reventless-interop && npm run build
cd reventless/reventless-aws && npm run build
```

No runtime behaviour changes — pure rename.
