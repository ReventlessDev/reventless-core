# Plan: Fix `position` in FilterExpression — DcbEventLog DynamoDB

## Problem

`DcbEventLogStorage_DynamoDb_Runtime.res` uses `FilterExpression` with `#pos > :after`
(where `#pos` maps to `"position"`) in every query and scan that accepts an `~after`
argument. DynamoDB rejects this with:

```
Filter Expression can only contain non-primary key attributes:
Primary key attribute: position
```

`position` is the sort key of the base table **and** the range key of every GSI. Neither
the base table nor GSI queries may reference their own sort key in `FilterExpression`; it
must appear in `KeyConditionExpression` instead.

For `Scan` (which has no key condition), `position` cannot appear in `FilterExpression`
either — the only valid fix there is post-filtering in application code.

## Root cause location

**File:** `reventless/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`

Seven functions all contain the same pattern:

```rescript
let (filterExpression, expressionAttributeNames) = switch after {
| None => (None, None)
| Some(afterPos) => {
    expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
    (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
  }
}
```

then pass `?filterExpression` to a `QueryCommand.input` or `ScanCommand.input`.

## Affected functions

| Function | Operation | Fix |
|---|---|---|
| `queryBySingleTag` (~line 141) | Query — GSI | KeyConditionExpression |
| `queryByCompositeTags` (~line 174) | Query — GSI | KeyConditionExpression |
| `queryByPartitionKey` (~line 262) | Query — base table | KeyConditionExpression |
| `queryByPartitionKeyStream` (~line 521) | Query — base table (paginated) | KeyConditionExpression |
| `queryBySingleTagStream` (~line 563) | Query — GSI (paginated) | KeyConditionExpression |
| `queryByCompositeTagsStream` (~line 606) | Query — GSI (paginated) | KeyConditionExpression |
| `scanWithFilter` (~line 207) | Scan | Post-filter in code |

---

## Step 1 — Fix all six Query functions

For each query function the pattern changes as follows. The `filterExpression` for position
is dropped and the condition is appended to `keyConditionExpression` instead.

```rescript
// Before — in each query function:
let keyConditionExpression = `${indexName} = :val`   // (or equivalent)
let (filterExpression, expressionAttributeNames) = switch after {
| None => (None, None)
| Some(afterPos) => {
    expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
    (Some("#pos > :after"), Some(Dict.fromArray([("#pos", "position")])))
  }
}
// ... passed as: ?filterExpression, ?expressionAttributeNames

// After — same pattern for all six:
let (keyConditionExpression, expressionAttributeNames) = switch after {
| None => (`${baseKeyCondition}`, None)
| Some(afterPos) => {
    expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
    (`${baseKeyCondition} AND #pos > :after`, Some(Dict.fromArray([("#pos", "position")])))
  }
}
// filterExpression: removed (no longer passed for the position condition)
```

Where `baseKeyCondition` is the existing hash-key-only condition for each function:

| Function | `baseKeyCondition` |
|---|---|
| `queryBySingleTag` | `` `${indexName} = :val` `` |
| `queryByCompositeTags` | `"tag_composite = :composite"` |
| `queryByPartitionKey` | `"id = :pk"` |
| `queryByPartitionKeyStream` | `"id = :pk"` |
| `queryBySingleTagStream` | `` `${indexName} = :val` `` |
| `queryByCompositeTagsStream` | `"tag_composite = :composite"` |

For the non-stream functions (`queryBySingleTag`, `queryByCompositeTags`,
`queryByPartitionKey`) the `QueryCommand.input` record then has no `?filterExpression`
field for position — any existing `filterExpression` for non-position conditions
(e.g. event type) is preserved separately and combined with `AND` if both are present.

For the stream functions (`queryByPartitionKeyStream`, `queryBySingleTagStream`,
`queryByCompositeTagsStream`) the same edit applies to `baseParams`.

---

## Step 2 — Fix `scanWithFilter`

`Scan` has no `KeyConditionExpression`. Remove the position condition from the
`FilterExpression` build and instead filter the collected results in application code:

```rescript
// Before — position added to filterParts:
switch after {
| None => ()
| Some(afterPos) => {
    expressionAttributeNames->Dict.set("#pos", "position")
    expressionAttributeValues->Dict.set(":after", afterPos->JSON.Encode.string)
    filterParts->Array.push("#pos > :after")
  }
}
// ... scan and return results

// After — position removed from filterParts, applied post-scan:
// (remove the `after` switch block entirely from filterParts)
let rawItems = await scanStream(scanParams)->Stream.runCollect->Effect.runPromise
switch after {
| None => rawItems
| Some(afterPos) => rawItems->Array.filter(item => item["position"] > afterPos)
}
```

Note: `item["position"]` must access the raw DynamoDB item's `position` field as a
string before `fromItem` conversion, or `fromItem` must be called first and `event.position`
used. Whichever is cleaner given the surrounding code.

---

## Step 3 — Build

```sh
npm run build
```

Expected: clean build across the monorepo. No callers pass `position` in
`FilterExpression` directly — all usage goes through these seven functions.

---

## Step 4 — Deploy and verify

After deploying any consumer stack that uses the DcbEventLog:

- Lambda invocation succeeds (no `Invoke Error` in CloudWatch)
- DcbEventLog `append` with a non-None `condition.after` completes without error
- New events appear in the DynamoDB table after the command is processed

---

## Checklist

- [x] Step 1: Fix `queryBySingleTag` — move position to KeyConditionExpression
- [x] Step 1: Fix `queryByCompositeTags` — move position to KeyConditionExpression
- [x] Step 1: Fix `queryByPartitionKey` — move position to KeyConditionExpression
- [x] Step 1: Fix `queryByPartitionKeyStream` — move position to KeyConditionExpression
- [x] Step 1: Fix `queryBySingleTagStream` — move position to KeyConditionExpression
- [x] Step 1: Fix `queryByCompositeTagsStream` — move position to KeyConditionExpression
- [x] Step 2: Fix `scanWithFilter` — remove position from FilterExpression, post-filter
- [x] Step 2 (extra): Fix `scanWithFilterStream` — same bug, post-filter stream (not in original plan)
- [x] Step 3: Build passes
- [ ] Step 4: Deploy and verify — Lambda succeeds, events written to DynamoDB
