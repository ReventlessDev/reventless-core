---
title: "QueryEngine → Lambda + API Gateway"
date: 2026-01-15
draft: false
---

## QueryEngine → DynamoDB

The QueryEngine adapter provides read-side query capabilities for Read Models by translating Reventless query specifications into DynamoDB Query and Scan operations, enabling flexible and efficient data retrieval.

## How QueryEngine Works

QueryEngine bridges the gap between Reventless's abstract query interface and DynamoDB's query capabilities:

1. **Application** calls query methods (e.g., `query`, `scan`) with filters and parameters
2. **QueryEngine** translates query specs into DynamoDB expressions
3. **DynamoDB** executes the query and returns results
4. **QueryEngine** transforms DynamoDB items back to JSON for the application

This pattern allows Read Models to query their data without writing AWS-specific code.

## Deploy-time Configuration

The QueryEngine adapter creates a query engine bound to all QueryDb tables:

```rescript
let make: Reventless.QueryDb_Adapter.queryEngineMaker = allQueryDbs => {
  let allRuntimeQueryDbsOutputs = Js.Dict.map((queryDb: Reventless.QueryDb.outputs) =>
    queryDb.resources
    ->Util.DynamoDb.findResource
    ->Reventless.Adapter.resourceToResolvedOutput
  , allQueryDbs)->Pulumi.Output.allDict

  let tableName = (allRuntimeQueryDbs, readModelName) =>
    (allRuntimeQueryDbs->Reventless.Util_QueryDbRuntime.getRuntimeResource(readModelName)).name

  allRuntimeQueryDbsOutputs->Pulumi.Output.apply(allRuntimeQueryDbs => {
    scan: (~readModelName, ~filterConfigs, ~limit) =>
      scanByTableName(
        ~tableName=allRuntimeQueryDbs->tableName(readModelName),
        ~filterConfigs,
        ~limit,
      ),
    query: (
      ~readModelName,
      ~key=?,
      ~id,
      ~subIdConfig=?,
      ~filterConfigs=?,
      ~ascending=?,
      ~limit=?,
    ) =>
      queryByTableName(
        ~tableName=allRuntimeQueryDbs->tableName(readModelName),
        ~key?,
        ~id,
        ~subIdConfig?,
        ~filterConfigs?,
        ~ascending?,
        ~limit?,
      ),
  })
}
```

**Deploy-time setup:**

- **QueryDb resolution** - Extracts DynamoDB table resources from all QueryDb components
- **Runtime metadata** - Converts Pulumi resources to runtime metadata (table names)
- **Query binding** - Binds `query` and `scan` functions to the runtime metadata
- **Multi-table support** - Supports querying across multiple Read Model tables

## Runtime Operations

The QueryEngine provides two primary operations:

## Query Operation

The `query` operation performs efficient partition-key-based queries:

```rescript
let queryByTableName = async (
  ~tableName,
  ~key="id",
  ~id,
  ~subIdConfig=?,
  ~filterConfigs=[],
  ~ascending=true,
  ~limit=1,
) => {
  let (subIdExpressions, subIdNamesValues) =
    subIdConfig->createSubIdExprNamesValues->Option.getOr(([], []))
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues

  let keyConditionExpression =
    ["#key = :value"]->Array.concat(subIdExpressions)->Js.Array2.joinWith(" AND ")
  let filterExpression = switch filterExpressions {
  | [] => None
  | filterExpressions => Some(filterExpressions->Js.Array2.joinWith(" AND "))
  }

  let (names, values) = subIdNamesValues->Array.concat(filterNamesValues)->Belt.Array.unzip
  let attributeValues =
    Array.flat([[(":value", id->toJson)], values])
    ->Js.Dict.fromArray
    ->Js.Json.object_
    ->Js.Json.stringify
    ->parseJs

  let attributeNames = Array.flat([[("#key", key)], names])->Js.Dict.fromArray

  let params: AwsSdk.DynamoDb.DocumentClient.QueryCommand.input = {
    tableName,
    indexName: ?(if key == "id" { None } else { Some(key) }),
    keyConditionExpression,
    ?filterExpression,
    expressionAttributeNames: attributeNames,
    expressionAttributeValues: attributeValues,
    scanIndexForward: ascending,
    limit,
  }

  switch await AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params) {
  | result =>
    result.items
    ->Option.getOr([])
    ->Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception err =>
    Reventless.Logger.error(~loc=__LOC__, "Error:", err)
    []
  }
}
```

**Query features:**

- **Partition key** - Efficient retrieval using partition key (defaults to `"id"`)
- **Sort key filtering** - Optional subId comparisons (equal, less than, greater than, begins with)
- **Post-query filtering** - Additional filter expressions applied after partition query
- **Index support** - Automatically uses GSI if querying by non-primary key
- **Ordering** - Configurable ascending/descending order
- **Pagination** - Limit parameter for result set size
- **Recursive retrieval** - Automatically handles DynamoDB pagination to fetch all matching items

**Sort key comparators:**

```rescript
type SubId.comparator =
  | Equal              // subId = value
  | Unequal            // subId <> value
  | LessOrEqual        // subId <= value
  | Less               // subId < value
  | GreaterOrEqual     // subId >= value
  | Greater            // subId > value
  | BeginsWith         // begins_with(subId, value)
```

**Filter comparators:**

```rescript
type Filter.comparator =
  | Equal              // field = value
  | Unequal            // field <> value
  | LessOrEqual        // field <= value
  | Less               // field < value
  | GreaterOrEqual     // field >= value
  | Greater            // field > value
  | Exists             // attribute_exists(field)
  | NotExists          // attribute_not_exists(field)
  | Contains           // contains(field, value)
  | NotContains        // NOT contains(field, value)
  | BeginsWith         // begins_with(field, value)
```

## Scan Operation

The `scan` operation performs full table scans with optional filtering:

```rescript
let scanByTableName = async (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues
  let (filterNames, filterValues) = filterNamesValues->Belt.Array.unzip
  let (filterExpression, attributeNames, attributeValues) = switch filterExpressions {
  | [] => (None, None, None)
  | filterExpressions => (
      Some(filterExpressions->Js.Array2.joinWith(" AND ")),
      Some(filterNames->Js.Dict.fromArray),
      Some(filterValues->Js.Dict.fromArray->Js.Json.object_->Js.Json.stringify->parseJs),
    )
  }

  let params: AwsSdk.DynamoDb.DocumentClient.ScanCommand.input = {
    tableName,
    ?filterExpression,
    expressionAttributeNames: ?attributeNames,
    expressionAttributeValues: ?attributeValues,
    limit,
  }

  switch await AwsSdk.DynamoDb.DocumentClient.scanRecursive(~params) {
  | result =>
    result.items
    ->Option.getOr([])
    ->Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception Js.Exn.Error(e) =>
    Reventless.Logger.error(~loc=__LOC__, "Error:", e)
    []
  }
}
```

**Scan features:**

- **Full table scan** - Reads all items in the table (expensive for large tables)
- **Filter expressions** - Filter results during scan (still reads all items)
- **Limit** - Maximum number of items to return
- **Recursive retrieval** - Automatically handles pagination
- **Use sparingly** - Scans are inefficient; prefer queries when possible

## Expression Building

QueryEngine dynamically builds DynamoDB expressions:

**SubId expression builder:**

```rescript
let createSubIdExprNamesValues = (subIdConfig: option<SubId.config>) =>
  subIdConfig->Option.map(((subIdName, comparator, value)) => {
    (
      [
        switch comparator {
        | SubId.Equal => `#${subIdName} = :${subIdName}`
        | Unequal => `#${subIdName} <> :${subIdName}`
        | LessOrEqual => `#${subIdName} <= :${subIdName}`
        | Less => `#${subIdName} < :${subIdName}`
        | GreaterOrEqual => `#${subIdName} >= :${subIdName}`
        | Greater => `#${subIdName} > :${subIdName}`
        | BeginsWith => `begins_with( #${subIdName}, :${subIdName} )`
        },
      ],
      [((`#${subIdName}`, subIdName), (`:${subIdName}`, value->toJson))],
    )
  })
```

**Filter expression builder:**

```rescript
let createFilterExprNamesValues = filterConfigs =>
  filterConfigs
  ->Array.mapWithIndex(((fieldName, comparator, value), idx) => {
    let valueName = `${fieldName}${idx->Int.toString}`
    (
      switch comparator {
      | Filter.Equal => `#${fieldName} = :${valueName}`
      | Unequal => `#${fieldName} <> :${valueName}`
      | LessOrEqual => `#${fieldName} <= :${valueName}`
      | Less => `#${fieldName} < :${valueName}`
      | GreaterOrEqual => `#${fieldName} >= :${valueName}`
      | Greater => `#${fieldName} > :${valueName}`
      | Exists => `attribute_exists( #${fieldName} )`
      | NotExists => `attribute_not_exists( #${fieldName} )`
      | Contains => `contains( #${fieldName}, :${valueName} )`
      | NotContains => `NOT contains( #${fieldName}, :${valueName} )`
      | BeginsWith => `begins_with( #${fieldName}, :${valueName} )`
      },
      ((`#${fieldName}`, fieldName), (`:${valueName}`, value->toJson)),
    )
  })
  ->Belt.Array.unzip
```

**Expression features:**

- **Placeholder names** - Uses `#fieldName` to avoid reserved word conflicts
- **Placeholder values** - Uses `:valueName` for value substitution
- **Indexed values** - Multiple filters on same field use indexed placeholders
- **Type conversion** - Converts Reventless values to DynamoDB JSON format

## Use Cases

**Partition key queries:**
```rescript
// Get user profile by ID
queryEngine.query(
  ~readModelName="UserProfile",
  ~id=String("user-123"),
  ~limit=1,
)
```

**Range queries:**
```rescript
// Get orders for customer in date range
queryEngine.query(
  ~readModelName="Orders",
  ~key="customerId",
  ~id=String("customer-456"),
  ~subIdConfig=Some(("orderDate", GreaterOrEqual, String("2024-01-01"))),
  ~ascending=false,
  ~limit=10,
)
```

**Filtered queries:**
```rescript
// Get high-value orders for customer
queryEngine.query(
  ~readModelName="Orders",
  ~key="customerId",
  ~id=String("customer-789"),
  ~filterConfigs=[
    ("amount", GreaterOrEqual, Int(1000)),
    ("status", Equal, String("completed")),
  ],
  ~limit=50,
)
```

**Full table scans:**
```rescript
// Find all active sessions (use sparingly!)
queryEngine.scan(
  ~readModelName="Sessions",
  ~filterConfigs=[
    ("expiresAt", Greater, Int(Date.now())),
    ("status", Equal, String("active")),
  ],
  ~limit=100,
)
```

**Key advantages:**

- **Abstract interface** - Read Models don't depend on DynamoDB SDK
- **Type-safe queries** - ReScript types prevent invalid query configurations
- **Expression generation** - No manual expression string building
- **Pagination handling** - Automatically handles DynamoDB's 1MB limit
- **Error handling** - Catches and logs errors, returns empty array on failure
- **Multi-table support** - Single query engine for all Read Models

**Performance considerations:**

- **Prefer Query over Scan** - Queries are O(log n), scans are O(n)
- **Use indexes** - Create GSIs for common query patterns
- **Limit results** - Use limit parameter to control read capacity consumption
- **Filter efficiently** - KeyCondition filtering is cheaper than FilterExpression
- **Pagination** - Consider pagination for large result sets

**When to use Query vs Scan:**

**Use Query when:**
- You know the partition key value
- Querying by indexed attributes
- Need efficient, predictable performance
- Working with large tables

**Use Scan when:**
- Need to examine all items (rare)
- Building admin tools or analytics
- Table is small (< 1000 items)
- Don't mind eventual consistency and high cost

