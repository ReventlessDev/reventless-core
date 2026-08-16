---
title: "Counter → DynamoDB"
---

## Counter → DynamoDB Streams

The Counter adapter provides atomic counting and aggregation capabilities by listening to DynamoDB Streams, enabling reactive counter updates based on database changes without requiring direct API calls.

## How Counter Works

Counter uses DynamoDB Streams to track changes in two tables:

1. **References Table** - Contains items that should be counted (e.g., new orders, user registrations)
2. **Counts Table** - Stores the aggregated count values

When items are added to the References Table, the Counter handler:
1. Receives the DynamoDB Stream event
2. Extracts the increment value (`inc` field) from new items
3. Updates the corresponding counter in the Counts Table atomically
4. Tracks target references to prevent duplicate counting

## Deploy-time Configuration

The Counter adapter creates a Lambda function that subscribes to DynamoDB Streams from both the references and counts tables:

```rescript
let make: Reventless.Counter_Adapter.handlerMaker = (
  ~name,
  ~referencesName,
  ~referencesDb,
  ~countsName,
  ~countsDb,
  ~counterHandler,
  ~opts,
) => {
  let referencesDbResource = referencesDb.resources->Util.DynamoDbStream.findResource
  let referencesStream = referencesDbResource->Util.DynamoDbStream.toStreamResource
  let countsDbResource = countsDb.resources->Util.DynamoDbStream.findResource
  let countsStream = countsDbResource->Util.DynamoDbStream.toStreamResource

  let eventHandlerLambda = Lambda.CallbackFunction.make(
    ~name,
    ~args=Lambda.CallbackFunction.Args.make(
      ~callback=CounterHandler_DynamoDbStream_Runtime.handleStreamEvent(
        ~referencesStream,
        ~countsStream,
        ~counterHandler,
        ...
      )
    ),
    ~opts,
  )

  let subscribe = (sourceName, source) =>
    Util_EventSourceMapping.subscribe(
      ~lambda=eventHandlerLambda->Pulumi.Output.make,
      ~targetName=name,
      ~sourceName,
      ~source,
      ~opts,
    )

  let _ = subscribe(referencesName, referencesStream)
  let _ = subscribe(countsName, countsStream)

  {
    addToCounterTarget: counterTarget =>
      CounterHandler_DynamoDbStream_Runtime.addToCounterTarget(countsDbResource, counterTarget),
  }
}
```

**Deploy-time setup:**

- **Lambda creation** - Creates a Lambda function to handle DynamoDB Stream events
- **Stream subscriptions** - Subscribes to streams from both references and counts tables
- **Event source mappings** - Configures DynamoDB Stream triggers for the Lambda
- **Dual-table tracking** - Monitors both source (references) and target (counts) tables

## Runtime Operations

The Counter adapter provides two runtime operations:

## Handle Stream Event

The `handleStreamEvent` operation processes DynamoDB Stream records:

```rescript
let handleStreamEvent = (
  ~referencesStream: Reventless.Adapter.resource,
  ~countsStream: Reventless.Adapter.resource,
  ~counterHandler: Reventless.Counter_Callback.counterHandler,
  streamEvent: PulumiAws.DynamoDb.Stream.event,
  _,
) => {
  let referencesARN = referencesStream.urn->Pulumi.Output.get
  let countsARN = countsStream.urn->Pulumi.Output.get

  // Filter and partition records by stream source
  let (dynamoDbRecords, ignoredRecords) =
    streamEvent.records->Belt.Array.partition(record =>
      record.eventSource == "aws:dynamodb" &&
        (record.eventSourceARN == referencesARN || record.eventSourceARN == countsARN)
    )

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Belt.Array.partition(record => record.eventSourceARN == referencesARN)

  // Extract references with increment values
  let references = referenceRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(id, newImage) =>
      let inc = switch newImage->S.parseJsonOrThrow(referencesViewSchema) {
      | {inc} => inc
      | exception err =>
        Js.log3(__MODULE__ ++ " (references): error parsing newImage:", newImage, err)
        1
      }
      Some((id, inc))
    | NewAndOldImage(id, _, _) =>
      Js.log2(__MODULE__ ++ " (references): ignoring duplicate id:", id)
      None
    | _ => None
    }
  )

  // Extract count updates
  let counts = countRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(_, newImage)
    | NewAndOldImage(_, newImage, _) => Some(newImage)
    | _ => None
    }
  )

  counterHandler(~references, ~counts)
}
```

**Key features:**

- **Stream filtering** - Separates records by source stream (references vs counts)
- **Duplicate detection** - Ignores records that represent updates rather than new items
- **Increment extraction** - Parses the `inc` field from new reference items
- **Batch processing** - Processes multiple stream records in a single Lambda invocation
- **Error handling** - Logs errors but continues processing other records

## Add to Counter Target

The `addToCounterTarget` operation atomically updates a counter value:

```rescript
let addToCounterTarget = async (
  table: Reventless.Adapter.resource,
  {Reventless.Counter.counterId: counterId, target, targetRef},
) => {
  let tableName = table.name->Pulumi.Output.get
  switch await UpdateCommand.make({
    tableName,
    key: Js.Dict.fromArray([("id", counterId->Js.Json.string)]),
    updateExpression: "ADD #count :inc, #total :inc " ++
    ("SET #targets = list_append(if_not_exists(#targets, :empty), :targetSingle), " ++
    "    #targetRefs = list_append(if_not_exists(#targetRefs, :empty), :targetRefSingle)"),
    expressionAttributeNames: [
      ("#count", Reventless.Counter.countFieldName),
      ("#total", "total"),
      ("#targets", "targets"),
      ("#targetRefs", "targetRefs"),
    ]->Js.Dict.fromArray,
    expressionAttributeValues: [
      (":inc", target->Int.toFloat->Js.Json.number),
      (":targetSingle", [target->Int.toFloat->Js.Json.number]->Js.Json.array),
      (":targetRefSingle", [targetRef->Js.Json.string]->Js.Json.array),
      (":targetRef", targetRef->Js.Json.string),
      (":empty", []->Js.Json.array),
    ]->Js.Dict.fromArray,
    returnValues: #UPDATED_NEW,
    conditionExpression: "NOT contains(#targetRefs, :targetRef)",
  })->UpdateCommand.send {
  | (updateOutput: UpdateCommand.output) =>
    Js.log2(
      __MODULE__ ++ `.addToCounterTarget: current count for ${counterId}:`,
      updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count"),
    )
  | exception _ =>
    Js.Exn.raiseError(__MODULE__ ++ `.addToCounterTarget Error: Couldn't count on ${tableName}`)
  }
}
```

**Atomic update features:**

- **ADD operation** - Uses DynamoDB's atomic ADD to increment both `count` and `total` fields
- **Idempotency** - Tracks `targetRefs` to prevent duplicate counting with conditional expression
- **List append** - Maintains arrays of targets and target references for audit trail
- **Condition expression** - Prevents duplicate counting if target reference already exists
- **Return values** - Returns updated attributes to confirm the new count value

## Use Cases

**Aggregate statistics:**
```rescript
// Count total orders per customer
// References: OrdersTable (new orders)
// Counts: CustomerStatsTable (order count per customer)
```

**Inventory tracking:**
```rescript
// Count items in warehouse locations
// References: InventoryMovementsTable (item additions/removals)
// Counts: WarehouseStatsTable (current counts by location)
```

**Event analytics:**
```rescript
// Count events by type over time
// References: EventsTable (new events)
// Counts: EventStatsTable (counts by event type and time bucket)
```

**Key advantages:**

- **Reactive counting** - Counts are updated automatically as data changes
- **No polling** - DynamoDB Streams provide real-time change notifications
- **Atomic updates** - DynamoDB's ADD operation ensures accurate counts
- **Idempotent** - Duplicate stream events don't cause double-counting
- **Scalable** - DynamoDB Streams scale with table throughput
- **Audit trail** - Tracks all counted items via target references

