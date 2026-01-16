---
title: "EventCollector → S3 + DynamoDB"
date: 2026-01-15
draft: false
---

## EventCollector → SQS FIFO

The EventCollector adapter provides event consumption capabilities using SQS FIFO queues subscribed to SNS topics, enabling ReadModels and other components to receive and process events with ordering guarantees.

## Queue Configuration

The EventCollector creates an SQS FIFO queue that subscribes to one or more EventTopic SNS topics:

```rescript
let queue = PulumiAws.SQS.Queue.make(
  ~name,
  ~args={
    PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
    deduplicationScope: MessageGroup,
    fifoThroughputLimit: PerMessageGroupId,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: 30->Pulumi.Input.make,
    redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
    ->Pulumi.Output.apply(dlqArn =>
      PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
    )
    ->Pulumi.Output.asInput,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
    tags: AWS.Tags.make(~name, Reventless.EventCollector.componentType),
  },
  ~opts,
)
```

**Configuration details:**

- **`fifoQueue: true`** - Enables FIFO ordering to preserve event order from EventTopics
- **`contentBasedDeduplication: true`** - Prevents duplicate event processing using message body hash
- **`visibilityTimeoutSeconds: 30`** - Events become invisible for 30 seconds while being processed
  - Prevents other consumers from processing the same event concurrently
  - Shorter timeout than CommandTopic since event processing is typically faster
- **`deduplicationScope: MessageGroup`** - Deduplication applied per message group (per aggregate)
- **`fifoThroughputLimit: PerMessageGroupId`** - High throughput mode per message group
  - Enables up to 3,000 messages per second per aggregate instance
- **`redrivePolicy`** - Failed events move to dead letter queue after 5 retries
  - Shares the common FIFO dead letter queue (`Util_DeadLetterQueue.fifoQueue`)

## SNS Topic Subscription

The EventCollector automatically subscribes to EventTopic SNS topics during deployment:

```rescript
let eventTopicResources =
  eventTopics
  ->Js.Dict.values
  ->Array.map(outputs => outputs.resources->Array.getUnsafe(0))
```

**Subscription flow:**

1. **EventTopic publishes** - Events are published to SNS FIFO topic by EventLog or Aggregate
2. **SNS delivers** - SNS pushes events to all subscribed SQS FIFO queues
3. **SQS queues** - EventCollector's SQS queue receives events with ordering preserved
4. **Lambda polls** - Lambda continuously polls the queue and invokes handlers

**Key benefits of SNS → SQS pattern:**

- **Decoupling** - EventTopics don't need to know about EventCollectors
- **Buffering** - SQS queues buffer events during processing delays or Lambda cold starts
- **Parallel consumers** - Multiple EventCollectors can subscribe to the same EventTopic
- **Retry isolation** - Failed events in one EventCollector don't affect others
- **FIFO preservation** - Ordering is maintained end-to-end from EventTopic through SQS to Lambda

## Handle Channel Event - Multi-source Support

The EventCollector runtime handler supports events from **two sources**: SQS queues and DynamoDB Streams. This flexibility allows EventCollectors to consume events either from EventTopics (via SNS → SQS) or directly from EventLog DynamoDB tables (via DynamoDB Streams).

```rescript
let handleDynamoDbOrSqsEvent = (queue, handleEvents) => async (
  event: PulumiAws.Lambda.CallbackFunction.event,
  _,
) => {
  let records = event.records

  // Parse events from either SQS or DynamoDB Stream records
  let jsons = records->Array.filterMap(record =>
    switch record.eventSource {
    | "aws:sqs" =>
        record->PulumiAws.SQS.Queue.asRecord->Util.SQS_Runtime.parseSqsRecord
    | "aws:dynamodb" =>
        switch record
        ->PulumiAws.DynamoDb.Stream.asRecord
        ->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
        | NewImage(_, newImage)
        | NewAndOldImage(_, newImage, _) =>
          Some(newImage)
        | _ =>
          Js.log(__MODULE__ ++ ".handleChannelEvent: no NewImage included in Stream event !")
          None
        }
    | eventSource =>
      Js.log2(__MODULE__ ++ ".handleChannelEvent: ignoring record from eventSource:", eventSource)
      None
    }
  )

  // Process events
  switch await handleEvents(jsons) {
  | _ =>
    // Delete successfully processed SQS messages
    let entries =
      records
      ->Array.filter(record =>
        switch record.eventSource {
        | "aws:sqs" => true
        | _ => false
        }
      )
      ->Array.mapWithIndex((record, idx): AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry => {
        id: idx->string_of_int,
        receiptHandle: (record->PulumiAws.SQS.Queue.asRecord).receiptHandle,
      })
    switch entries {
    | [] => ()
    | entries => await Util.SQS_Runtime.deleteMessages(entries, queue)
    }
  }
}
```

**Processing flow:**

1. **Detect event source** - Inspect `record.eventSource` to determine if the event came from SQS or DynamoDB
2. **Parse events** - Use appropriate parser for each source:
   - **SQS events**: Extract JSON message body from `record.body`
   - **DynamoDB events**: Extract `NewImage` from stream record (new or updated item)
3. **Handle events** - Pass all parsed events to the `handleEvents` callback function
4. **Acknowledge SQS messages** - Delete successfully processed SQS messages from the queue
5. **DynamoDB stream handling** - No acknowledgment needed; stream position is managed by Lambda

**Key features:**

- **Multi-source support** - Single handler processes events from both SQS and DynamoDB Streams
- **Source-specific parsing** - Different parsing logic for each event source
- **Selective acknowledgment** - Only deletes SQS messages (DynamoDB stream position is automatic)
- **Error resilience** - Parse errors are logged but don't crash the handler
- **Batch processing** - All events in the Lambda invocation are processed together

## DynamoDB Stream Event Types

When consuming from DynamoDB Streams, the EventCollector handles different event types:

- **`NewImage`** - New item inserted into EventLog table
- **`NewAndOldImage`** - Item updated in EventLog table (both old and new versions)
- **`OldImage`** - Item removed from EventLog table (ignored by EventCollector)
- **`KeysOnly`** - Only key attributes included (ignored by EventCollector)

The EventCollector only processes `NewImage` and `NewAndOldImage` events, extracting the new item data for event handling.

## Enqueue Event Operation

The EventCollector also provides an `enqueueEvent` function for programmatically adding events to its queue:

```rescript
let enqueueEvent = queue
  ->Util_SQS.toRuntimeQueueOutput
  ->Pulumi.Output.apply(runtimeQueue =>
    EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
  )
```

**Runtime implementation:**

```rescript
let enqueueEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, _id, messageBody) => {
  let queueName = queue.name
  Js.log4(__MODULE__ ++ ".enqueueEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendMessage(~delay, messageBody)
}
```

**Key features:**

- **Programmatic enqueueing** - Allows components to directly enqueue events without publishing to SNS
- **Delay support** - Events can be delayed before becoming visible in the queue
- **Direct queue access** - Bypasses SNS topic, useful for testing or internal event routing

## When to Use DynamoDB Streams vs SQS Subscription

**Use SQS subscription (SNS → SQS) when:**
- Consuming events from EventTopics that may have multiple publishers
- Need buffering and retry isolation from other EventCollectors
- Want to decouple EventCollectors from event sources
- Prefer SNS fan-out pattern for multiple subscribers
- Need to subscribe/unsubscribe dynamically

**Use DynamoDB Stream subscription when:**
- Consuming events directly from EventLog table
- Need lowest possible latency (no SNS hop)
- Want guaranteed delivery of all events (stream is source of truth)
- Processing events in near real-time as they're written to EventLog
- Building projections that must stay synchronized with EventLog

## Deploy-time to Runtime Flow

The EventCollector adapter follows the standard deploy-time/runtime pattern:

```rescript
let make = (~name, ~eventTopics, ~opts) => {
  // 1. Deploy-time: Create SQS FIFO queue
  let queue = PulumiAws.SQS.Queue.make(~name, ~args={...}, ~opts)

  // 2. Subscribe to EventTopics (SNS subscriptions created automatically)
  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0))

  {
    parts: {queue: queue},
    resources: eventTopicResources->Array.concat([queue->Util_SQS.toResource]),

    // 3. Runtime: Enqueue events programmatically
    enqueueEvent: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    ),

    // 4. Runtime: Handle incoming events from SQS or DynamoDB
    handleChannelEvent: handleEvents =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->(EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...))
      ),
  }
}
```

**Flow steps:**

1. **Create SQS queue** - Pulumi provisions the SQS FIFO queue resource
2. **Subscribe to topics** - SNS subscriptions are created for each EventTopic
3. **Extract metadata** - `toRuntimeQueueOutput` converts the queue to runtime metadata (URL, name, ARN)
4. **Bind runtime functions** - `Pulumi.Output.apply` binds handler functions to queue metadata
5. **Lambda execution** - Runtime functions execute in Lambda, polling SQS and processing events

