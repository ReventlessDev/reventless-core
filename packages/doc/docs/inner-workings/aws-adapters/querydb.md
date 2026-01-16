---
title: "QueryDb → DynamoDB"
date: 2026-01-15
draft: false
---

## QueryDb → DynamoDB

The QueryDb adapter provides read model storage using DynamoDB, enabling efficient querying of projected state with configurable indexes, TTL support, and integration with AWS AppSync for GraphQL APIs.

## Table Structure

The QueryDb DynamoDB table uses a flexible key design optimized for read model queries:

- **Partition key: `id`** (String) - The primary entity identifier (e.g., user ID, order ID)
- **Optional sort key: `subIdField`** (String) - Configurable secondary key for range queries (e.g., timestamp, status)
- **Global Secondary Indexes (GSIs)** - Custom indexes for alternative query patterns
- **TTL attribute** - Optional time-to-live for automatic data expiration

This design enables:
- **Flexible querying** - Query by primary ID or use GSIs for alternative access patterns
- **Range queries** - Optional sort key enables range-based queries (e.g., "all orders after date X")
- **Multiple access patterns** - GSIs provide additional query capabilities without duplicating data
- **Automatic cleanup** - TTL automatically removes expired items

## Deploy-time Configuration

The QueryDb adapter creates a DynamoDB table with comprehensive configuration:

```rescript
let make = (~name, ~indexes, ~subIdField=?, ~ttl=?, ~api, ~apiRole, ~opts) => {
  // Create table with attributes derived from sort key and indexes
  let table = Util_DynamoDb.makeTable(
    name,
    ~attributes=attributes(subIdField, indexes),
    ~rangeKey=?subIdField,
    ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
    ~ttl?,
    ~tags=AWS.Tags.make(~name, Reventless.QueryDb.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    dataSourceName: dataSource(name, table, api, apiRole, opts).name,
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      load: runtimeTable->load,
      save: runtimeTable->save,
      saveBatch: runtimeTable->saveBatch,
      count: runtimeTable->count,
      delete: runtimeTable->delete,
      deleteBatch: runtimeTable->deleteBatch,
    }),
  }
}
```

**Configuration parameters:**

- **`name`** - DynamoDB table name
- **`indexes`** - Array of GSI configurations (see Global Secondary Indexes section)
- **`subIdField`** - Optional sort key name for range queries
- **`ttl`** - Optional TTL configuration for automatic data expiration
- **`api`** - AppSync GraphQL API for DataSource integration
- **`apiRole`** - IAM role for AppSync to access DynamoDB
- **`opts`** - Pulumi resource options for dependency management

## Global Secondary Indexes (GSIs)

GSIs enable alternative query patterns beyond the primary key. Each index configuration specifies:

```rescript
type indexConfig = {
  index: string,                    // Index name
  type_: string,                     // Key type: "S" (string), "N" (number), "B" (binary)
  idField: option<string>,           // Optional custom hash key (defaults to index name)
  subIdField: option<string>,        // Optional range key for the index
  projectionType: projectionType,    // What attributes to project into the index
}

type projectionType =
  | ALL                              // Project all attributes
  | KEYS_ONLY                        // Project only key attributes
  | INCLUDE(array<string>)           // Project specific attributes
```

**GSI creation example:**

```rescript
let globalSecondaryIndexes = indexes =>
  indexes
  ->Array.map(({index, projectionType} as indexConfig) => {
    let (projectionType, includes) = switch projectionType {
    | ALL as _projection => (PulumiAws.DynamoDb.Table.ALL, None)
    | KEYS_ONLY as _projection => (KEYS_ONLY, None)
    | INCLUDE(includes) => (INCLUDE, Some(includes))
    }
    {
      name: index,
      hashKey: indexConfig.idField->Option.getOr(index),
      rangeKey: ?indexConfig.subIdField,
      projectionType,
      nonKeyAttributes: ?includes,
    }->Pulumi.Input.make
  })
```

**Projection type trade-offs:**

- **`ALL`** - Projects all attributes; highest storage cost but no need to fetch from base table
- **`KEYS_ONLY`** - Projects only key attributes; lowest storage cost but requires fetching non-key attributes from base table
- **`INCLUDE`** - Projects specific attributes; balanced storage cost and query performance

**Attribute definition:**

All table attributes (primary key, sort key, and GSI keys) are automatically derived:

```rescript
let attributes = (sortField, indexes) =>
  [
    [{name: "id", type_: "S"}],                           // Primary partition key
    sortField->Option.mapOr([], sortField =>
      [{name: sortField, type_: "S"}]                    // Optional sort key
    ),
    indexes
    ->Array.map(({index, type_} as indexConfig) =>
      [
        [{name: index, type_}],                           // GSI hash key
        indexConfig.subIdField->Option.mapOr([], sortField =>
          [{name: sortField, type_: "S"}]                // GSI range key
        ),
      ]->Array.flat
    )
    ->Array.flat,
  ]->Array.flat
```

This automatic attribute derivation ensures all keys are properly defined in the DynamoDB schema.

## AppSync DataSource Integration

The QueryDb adapter automatically creates an AWS AppSync DataSource, enabling GraphQL resolvers to query the DynamoDB table directly:

```rescript
let dataSource = (name, table, api, apiRole, opts) => {
  // Create IAM policy granting DynamoDB access
  let _dataSourceRolePolicy = {
    IAM.RolePolicy.make(
      ~name,
      ~args={
        policy: table.arn
        ->Pulumi.Output.apply(tableArn => {
          PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowDynamoDbActions",
                effect: Allow,
                actions: Action("dynamodb:*"),
                resources: Resource(tableArn),
              },
            ],
          )->toJsonString
        })
        ->Pulumi.Output.asInput,
        role: apiRole->Pulumi.Output.flatMap(role => role.id)->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  // Create AppSync DataSource
  AppSync.DataSource.makeDynamoDBDataSource(
    ~name,
    ~api,
    ~table,
    ~serviceRole=apiRole,
    ~opts
  )
}
```

**Integration benefits:**

- **Direct GraphQL access** - AppSync resolvers can query DynamoDB without Lambda functions
- **Automatic IAM management** - Permissions are configured automatically
- **VTL template support** - Use Velocity Template Language (VTL) for efficient queries
- **Real-time subscriptions** - AppSync can trigger GraphQL subscriptions on data changes

The `dataSourceName` is returned from the adapter and can be referenced in AppSync resolver configurations.

## Runtime Operations

The QueryDb adapter provides six runtime operations for interacting with the DynamoDB table:

## Load Operation

Retrieves all items with a specific partition key:

```rescript
let load = table => async id =>
  switch await queryById(table, id) {
  | arr => arr->Ok
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(`load: Error: Couldn't load state for ${id} from ${table.name}: ${errorMsg}`)
    Error(ReventlessSpec.QueryDb.NotLoadedFromStorage(errorMsg))
  }
```

**Key features:**

- **Query by partition key** - Returns all items matching the `id`
- **Automatic ordering** - If sort key exists, items are ordered by sort key value
- **Error handling** - Converts exceptions to typed errors
- **Array result** - Returns array of items (empty array if none found)

## Save Operation

Saves a single item with configurable write behavior:

```rescript
let save = table => async (id, json, saveMode: Reventless.QueryDb.saveMode, ttl) => {
  let json = json->insertTtl(ttl)  // Add TTL if provided

  switch saveMode {
  | Init =>
    // Conditional write: only succeeds if item doesn't exist
    switch await table->putIfNotExistsWithRetries(
      ~idKey=table.hashKey,
      ~sortKey=?table.rangeKey,
      id,
      json,
    ) {
    | Ok() => Ok()
    | Error(errorMsg) => Error(NotSavedToStorage(errorMsg))
    }
  | Any
  | Overwrite =>
    // Unconditional write: always succeeds
    switch await table->putWithRetries(id, json) {
    | Ok() => Ok()
    | Error(errorMsg) => Error(NotSavedToStorage(errorMsg))
    }
  }
}
```

**Save modes:**

- **`Init`** - Conditional write using `putIfNotExistsWithRetries`
  - Only succeeds if item doesn't already exist
  - Uses DynamoDB's conditional expression: `attribute_not_exists(id)`
  - Useful for initializing read models to prevent race conditions
  - Returns error if item already exists

- **`Any` / `Overwrite`** - Unconditional write using `putWithRetries`
  - Always overwrites existing item (or creates new)
  - No conditional checks
  - Used for normal read model updates

**TTL handling:**

If `ttl` is provided (as a Unix timestamp), the `insertTtl` function adds a TTL attribute to the JSON:

```rescript
let json = json->insertTtl(ttl)  // Adds {"ttl": timestamp} to JSON
```

DynamoDB automatically deletes items when the TTL timestamp is reached, enabling automatic cleanup of expired data.

## Save Batch Operation

Saves multiple items efficiently using batch writes:

```rescript
let saveBatch = table => async items =>
  switch items {
  | [] => Ok()                                         // No-op for empty batch
  | [(id, json, ttl)] => await save(table)(id, json, Any, ttl)  // Single item: use save
  | items =>                                           // Multiple items: use batch
    let ids = items->Array.map(((id, _, _)) => id)
    await items
    ->Array.map(((_id, json, ttl)) => {
      json->insertTtl(ttl)->toPutRequest
    })
    ->writeMultiple("finished put", ids, table)
  }
```

**Batch processing logic:**

The `writeMultiple` function handles DynamoDB's 25-item batch limit:

```rescript
let writeMultiple = async (writeRequests, op, ids, table) => {
  let size = writeRequests->Array.length
  let batches = (size / 25)->Js.Math.ceil_int  // DynamoDB limit: 25 items per batch

  // Split into batches of 25 items
  let results = Array.fromInitializer(~length=batches, batchNr =>
    writeRequests
    ->sliceBatch(batchNr)                      // Get items [batchNr*25 .. (batchNr+1)*25]
    ->toTable(table.name)
    ->batchWriteWithRetries                    // Write batch with retries
  )->Reventless.Util.Promise.allSettled        // Execute all batches in parallel

  // Collect errors from failed batches
  switch await results {
  | results =>
    let errors = results->Array.filterMap(/* extract errors */)
    switch errors {
    | [] => Ok()                               // All batches succeeded
    | errors => Error(BatchNotFullyWrittenToStorage(errors))  // Some batches failed
    }
  }
}
```

**Key features:**

- **Automatic batching** - Single items use `save`, multiple use batch writes
- **Batch splitting** - Automatically splits into multiple batches if > 25 items
- **Parallel execution** - Multiple batches are executed concurrently using `Promise.allSettled`
- **Partial failure handling** - Reports which batches failed while allowing others to succeed
- **Automatic retries** - Uses `batchWriteWithRetries` for transient failure recovery

## Count Operation

Performs atomic counter increments using DynamoDB's `ADD` operation:

```rescript
let count = table => async (id, fieldName, inc) => {
  switch await UpdateCommand.make({
    tableName: table.name,
    key: [("id", id->Js.Json.string)]->Js.Dict.fromArray,
    updateExpression: "ADD #fieldName :inc",
    expressionAttributeNames: [("#fieldName", fieldName)]->Js.Dict.fromArray,
    expressionAttributeValues: [(":inc", inc->Int.toFloat->Js.Json.number)]->Js.Dict.fromArray,
    returnValues: #UPDATED_NEW,
  })->UpdateCommand.send {
  | updateOutput =>
    switch updateOutput.attributes->getIntAttribute("count") {
    | Some(value) => Ok(value)
    | None => Error(NotCountedOnStorage("Invalid updateOutput"))
    }
  | exception Js.Exn.Error(e) =>
    Error(NotCountedOnStorage(e->message))
  }
}
```

**Key features:**

- **Atomic increment** - Uses DynamoDB's `ADD` operation for atomic counter updates
  - Thread-safe: multiple concurrent increments are handled correctly
  - No read-modify-write race conditions
- **Flexible increment** - Supports positive and negative increments
- **Return new value** - Returns updated counter value after increment
- **Expression attributes** - Uses placeholder names to avoid conflicts with reserved keywords

**Use cases:**

- Aggregate counters (e.g., total order count per customer)
- Statistics tracking (e.g., page view counts)
- Quota management (e.g., API rate limits)

## Delete Operation

Deletes a single item by partition key and optional sort key:

```rescript
let delete = table => async (id, sort) => {
  switch await table->deleteWithRetries(id, ~sort?) {
  | Ok() =>
    Js.log2(`delete: deleted state from ${table.name}: id=${id}, sort=`, sort)
    Ok()
  | Error(errorMsg) =>
    Error(ReventlessSpec.QueryDb.NotDeletedFromStorage(errorMsg))
  }
}
```

**Key features:**

- **Partition key required** - `id` parameter specifies the partition key
- **Optional sort key** - `sort` parameter provides `(fieldName, value)` tuple for composite keys
- **Automatic retries** - Uses `deleteWithRetries` for transient failure recovery
- **Idempotent** - Deleting a non-existent item succeeds (no error)

## Delete Batch Operation

Deletes multiple items efficiently using batch writes:

```rescript
let deleteBatch = table => async items =>
  switch items {
  | [] => Ok()                                    // No-op for empty batch
  | [(id, sort)] => await delete(table)(id, sort) // Single item: use delete
  | items =>                                      // Multiple items: use batch
    let ids = items->Array.map(((id, _)) => id)
    await items
    ->Array.map(((id, sort)) =>
      switch sort {
      | Some((sortField, sortKey)) =>
        [("id", id->Js.Json.string), (sortField, sortKey->Js.Json.string)]
        ->Js.Dict.fromArray
        ->toDeleteRequest
      | None =>
        [("id", id->Js.Json.string)]
        ->Js.Dict.fromArray
        ->toDeleteRequest
      }
    )
    ->writeMultiple("deleted", ids, table)
  }
```

**Key features:**

- **Automatic batching** - Single items use `delete`, multiple use batch deletes
- **Sort key support** - Each item can specify optional `(sortField, sortKey)` tuple
- **Batch splitting** - Reuses `writeMultiple` for automatic splitting (25-item limit)
- **Parallel execution** - Multiple batches execute concurrently
- **Partial failure handling** - Reports which batches failed

## Deploy-time to Runtime Flow

The QueryDb adapter follows the standard deploy-time/runtime pattern with AppSync integration:

```
1. Deploy-time:
   └─> Create DynamoDB table with GSIs and TTL
   └─> Create IAM Role Policy for AppSync
   └─> Create AppSync DataSource
   └─> Extract runtime metadata (table name, ARN)

2. Runtime:
   └─> Lambda receives table metadata {name, hashKey, rangeKey, arn}
   └─> Operations use DynamoDB Document Client
   └─> Automatic retries with exponential backoff
   └─> Batch operations split into 25-item chunks
```

**Flow steps:**

1. **Create DynamoDB table** - Pulumi provisions table with GSIs, TTL, and attributes
2. **Create AppSync integration** - IAM policy and DataSource are created for GraphQL access
3. **Extract metadata** - `toRuntimeTableOutput` converts table to runtime metadata
4. **Bind runtime functions** - `Pulumi.Output.apply` binds all six operations to metadata
5. **Lambda execution** - Runtime functions execute in Lambda with DynamoDB Document Client

## Error Handling and Retries

All QueryDb runtime operations implement comprehensive error handling:

- **Automatic retries** - Transient failures (throttling, network errors) are retried with exponential backoff
- **Typed errors** - Errors are converted to typed variants (e.g., `NotLoadedFromStorage`, `NotSavedToStorage`)
- **Logging** - All operations log success and failure with context (table name, ID, error message)
- **Partial failure handling** - Batch operations report partial failures without failing entire batch
- **Conditional write failures** - `Init` save mode returns error if item exists (not retried)

## When to Use QueryDb

**Use QueryDb for:**

- **Read model storage** - Project aggregate events into queryable views
- **Denormalized queries** - Store pre-computed query results for fast access
- **Time-series data** - Use sort key for timestamp-based range queries
- **Multi-index queries** - Use GSIs for alternative query patterns
- **Temporary data** - Use TTL for automatic cleanup of expired items
- **GraphQL APIs** - Integrate with AppSync for direct GraphQL access
- **High-throughput reads** - DynamoDB scales automatically for read-heavy workloads

**Common patterns:**

- **User profiles** - Partition key: user ID, sort key: profile version
- **Order history** - Partition key: customer ID, sort key: order timestamp, GSI: order status
- **Session storage** - Partition key: session ID, TTL: session expiration
- **Analytics** - Partition key: metric name, sort key: timestamp, GSI: aggregation period

