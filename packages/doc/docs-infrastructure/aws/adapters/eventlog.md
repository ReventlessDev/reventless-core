---
title: EventLog → DynamoDB
date: 2024-08-28
draft: false
---

## EventLog → DynamoDB

The EventLog adapter provides append-only event storage using DynamoDB, enabling event sourcing patterns with efficient event replay capabilities.

### Table Structure

The DynamoDB table uses a composite key design optimized for event sourcing:

- **Partition key: `id`** (String) - The aggregate instance ID
- **Sort key: `sequenceNr`** (String) - The event sequence number within the aggregate

This design enables:
- **Efficient event replay** - Query all events for a specific aggregate ID in sequence order
- **Strong consistency** - Events for the same aggregate are stored in the same partition
- **Natural ordering** - DynamoDB automatically orders items by the sort key

### Append Operation

The `append` operation writes new events to the EventLog using DynamoDB's batch write capability:

```rescript
let append = table => async (_sequenceNr, _id, jsons) => {
  let result =
    jsons
    ->Array.map(toPutRequest)           // Convert to DynamoDB put requests
    ->toTable(table.name)                // Associate with table name
    ->batchWriteWithRetries              // Batch write with automatic retries

  switch await result {
  | Ok() => Ok()
  | Error(unprocessedItems) =>
    // Handle partial failures
    Error("batchWriteWithRetries resulted in unprocessed items!")
  | exception _ =>
    // Handle exceptions
    Error("batchWriteWithRetries failed!")
  }
}
```

**Key features:**
- **Batch writes** - Multiple events are written in a single batch operation for efficiency
- **Automatic retries** - The `batchWriteWithRetries` utility handles transient failures
- **Error handling** - Distinguishes between partial failures (unprocessed items) and complete failures

### Replay Operation

The `replay` operation retrieves all events for an aggregate ID, with built-in retry logic:

```rescript
let rec tryReplay = async (~retry=0, tableName, id) =>
  switch await AwsSdk.DynamoDb.DocumentClient.queryById(tableName, id) {
  | exception Js.Exn.Error(e) =>
    // Log warning and retry with exponential backoff
    Reventless.Logger.warn(
      ~loc=__LOC__,
      `Couldn't replay events for id ${id}, retry:${retry->Js.Int.toString}`,
      e,
    )
    let timeout = 100 * retry + Js.Math.random_int(0, 100)
    await Reventless.Util.Promise.finishTimeout(timeout)
    await tableName->tryReplay(~retry=retry + 1, id)
  | history => history
  }

let replay = table => {
  async id => await tryReplay(table.name, id)
}
```

**Key features:**
- **Query by partition key** - Uses `queryById` to retrieve all events for an aggregate
- **Automatic ordering** - DynamoDB returns events ordered by `sequenceNr` (sort key)
- **Retry logic** - Implements exponential backoff with jitter for transient failures
- **Error resilience** - Recursive retry until successful or operation times out

The query operation leverages DynamoDB's efficient partition-based retrieval, returning all events for an aggregate in a single request (or paginated requests for large event histories).
