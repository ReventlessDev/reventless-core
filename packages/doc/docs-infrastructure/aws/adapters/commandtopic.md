---
title: "CommandTopic → SQS FIFO"
---
## CommandTopic → SQS FIFO

The CommandTopic adapter delivers commands over **SQS FIFO queues**: strict ordering per message group (one group per aggregate instance) and exactly-once *publish* deduplication. Processing is still at-least-once — a handler that times out after doing its work sees the same command again, which is why command handlers must be idempotent.

## Queue Configuration

The SQS FIFO queue is configured with specific settings optimized for command processing:

```rescript
let queue = PulumiAws.SQS.Queue.make(
  ~name,
  ~args={
    fifoQueue: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make,
    redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
    ->Pulumi.Output.apply(dlqArn => {
      PulumiAws.SQS.Queue.RedrivePolicy.make(
        ~deadLetterTargetArn=dlqArn,
        ~maxReceiveCount=5
      )
    })
    ->Pulumi.Output.asInput,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
    deduplicationScope: MessageGroup,
    fifoThroughputLimit: PerMessageGroupId,
    tags: AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
  },
  ~opts?,
)
```

**Configuration details:**

- **`fifoQueue: true`** - Enables FIFO (First-In-First-Out) ordering guarantees
- **`contentBasedDeduplication: true`** - Automatic deduplication using SHA-256 hash of message body
  - Eliminates duplicate commands sent within the 5-minute deduplication window
  - No need to explicitly provide deduplication IDs in application code
- **`visibilityTimeoutSeconds: 180`** (6 * 30) - Commands become invisible for 3 minutes while being processed
  - Prevents other consumers from processing the same command concurrently
  - Allows sufficient time for command handler execution
- **`deduplicationScope: MessageGroup`** - Deduplication applied per message group (per aggregate)
  - Commands for different aggregates can have identical content without being deduplicated
- **`fifoThroughputLimit: PerMessageGroupId`** - High throughput mode per message group
  - Enables up to 3,000 messages per second per aggregate instance
  - Different aggregates can process commands in parallel without throttling each other

## Dead Letter Queue (DLQ) Setup

Failed commands are routed to a dead letter queue after exhausting retry attempts:

```rescript
redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
->Pulumi.Output.apply(dlqArn => {
  PulumiAws.SQS.Queue.RedrivePolicy.make(
    ~deadLetterTargetArn=dlqArn,
    ~maxReceiveCount=5
  )
})
```

**Key features:**

- **`maxReceiveCount: 5`** - Commands are retried up to 5 times before moving to DLQ
- **Shared FIFO DLQ** - All CommandTopic queues share a common dead letter queue (`Util_DeadLetterQueue.fifoQueue`)
- **Failure isolation** - Failed commands don't block processing of subsequent commands
- **Manual recovery** - Failed commands can be inspected, corrected, and reprocessed manually

## Publish Operation

The `publishJsons` operation sends commands to the SQS queue with batching for efficiency:

```rescript
let publishJsons = (queue, queueService) => async jsons =>
  switch jsons->Array.length {
  | 0 => Js.log(__MODULE__ ++ ".publishJsons: No commands to send")
  | 1 => await queue->Util_SQS_Runtime.send(queueService, jsons->Array.getUnsafe(0))
  | _ => await queue->Util_SQS_Runtime.sendMessages(queueService, jsons)
  }
```

**Key features:**

- **Adaptive batching** - Uses single send for one command, batch send for multiple
- **Queue service parameter** - Supports both standard SQS and SQS FIFO service clients
- **JSON serialization** - Commands are serialized to JSON before sending
- **Automatic message group ID** - Message group ID is derived from aggregate ID for ordering

## Handle Queue Event

The `handleQueueEvent` operation processes incoming commands from the SQS queue:

```rescript
let handleQueueEvent = (queue, handleCommands) => async (event: PulumiAws.SQS.Queue.event, _) => {
  let records = event.records

  // Parse command JSONs from SQS records
  let jsons = records->Array.filterMap(record => {
    let commandStr = record.body
    switch Js.Json.parseExn(commandStr) {
    | json => Some(json)
    | exception err =>
      Js.log3("CommandTopicChannel_SQS.handleQueueEvent: Couldn't parse command:", commandStr, err)
      None
    }
  })

  // Create topic items with receipt handles for acknowledgment
  let topicItems =
    records
    ->Array.map(record => record.receiptHandle)
    ->Belt.Array.zip(jsons)
    ->Array.map(((reference, command)) => {
      Reventless.CommandTopic.reference,
      command,
    })

  // Process commands and delete successful ones from queue
  switch await handleCommands(topicItems) {
  | exception Js.Exn.Error(err) =>
    Js.log3(__MODULE__ ++ ".handleQueueEvent error:", err, err->Js.Json.stringifyAny)
    Js.Exn.raiseError(
      __MODULE__ ++ ".handleQueueEvent: handleCommands is not allowed to reject (use Belt.Result) !!",
    )
  | results =>
    switch await results
    ->Array.mapWithIndex((result, idx) =>
      switch result {
      | Ok(reference) =>
        // Command processed successfully - prepare for deletion
        let deleteMessageBatchEntry: AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry = {
          id: idx->string_of_int,
          receiptHandle: reference,
        }
        deleteMessageBatchEntry->Some
      | Error(reference) =>
        // Command failed - leave in queue for retry
        Js.log2(
          __MODULE__ ++ ".handleQueueEvent: Error: Couldn't handle command with ReceiptHandle:",
          reference,
        )
        None
      }
    )
    ->Array.filterMap(x => x)
    ->Util.SQS_Runtime.deleteMessages(queue) {
    | () =>
      Reventless.Logger.debug(~loc=__LOC__, "handleQueueEvent:", "Deleted all commands from queue")
    | exception Js.Exn.Error(e) =>
      Js.log2(
        __MODULE__ ++ ".handleQueueEvent: Error: Couldn't deleteMessageBatch:",
        e->Js.Exn.message,
      )
    }
  }
}
```

**Processing flow:**

1. **Parse commands** - Extract JSON from SQS record bodies, filtering out parse errors
2. **Create references** - Pair each command with its SQS receipt handle for later acknowledgment
3. **Handle commands** - Pass commands to the command handler function
4. **Acknowledge success** - Delete successfully processed commands from the queue using `deleteMessages`
5. **Retry failures** - Failed commands remain in queue and become visible again after visibility timeout

**Key features:**

- **Partial failure handling** - Successfully processed commands are deleted even if some fail
- **Receipt handle tracking** - Uses SQS receipt handles as references for acknowledgment
- **Error resilience** - Parse errors don't crash the handler; failed commands are logged and skipped
- **Batch deletion** - Successful commands are deleted in a single batch operation for efficiency
- **Automatic retry** - Failed commands become visible again after visibility timeout, triggering Lambda re-invocation

## Message Ordering and Deduplication

### FIFO Ordering

CommandTopic uses **message groups** to guarantee ordering:

- **Message Group ID** = Aggregate Instance ID
- Commands for the **same aggregate** are processed in strict order
- Commands for **different aggregates** can be processed in parallel

```rescript
// These commands are guaranteed to execute in order
await commandTopic.publish({id: "customer-1", command: Create(...)})
await commandTopic.publish({id: "customer-1", command: ChangeAddress(...)})
await commandTopic.publish({id: "customer-1", command: Delete})

// This command can execute in parallel with the above
await commandTopic.publish({id: "customer-2", command: Create(...)})
```

### Content-Based Deduplication

The CommandTopic automatically deduplicates identical commands:

- **5-minute deduplication window**
- **SHA-256 hash** of command content
- **Per message group** (commands for different aggregates with same content are not deduplicated)

```rescript
// Second command is automatically deduplicated if sent within 5 minutes
await commandTopic.publish({id: "customer-1", command: Create({...})})
await commandTopic.publish({id: "customer-1", command: Create({...})}) // Deduplicated
```

## Error Handling and Retries

### Automatic Retries

Failed commands are automatically retried:

1. Command fails during processing
2. Message visibility timeout expires (3 minutes)
3. Command becomes visible in queue again
4. Lambda is triggered again
5. Process repeats up to **5 times** (maxReceiveCount)

### Dead Letter Queue

After 5 failed attempts, commands move to the Dead Letter Queue (DLQ):

- **Shared FIFO DLQ** for all CommandTopics
- Failed commands can be inspected manually
- Commands can be corrected and reprocessed
- Prevents blocking of subsequent commands

### Partial Failure Handling

The CommandTopic handles batch processing failures gracefully:

```rescript
// Process batch of commands
let results = await commandsHandler([cmd1, cmd2, cmd3])

// Results: [Ok(ref1), Error(ref2), Ok(ref3)]
// - cmd1 and cmd3 are deleted from queue (success)
// - cmd2 remains in queue for retry (failure)
```
## Performance Considerations

### Throughput

- **Per aggregate**: Up to 3,000 commands/second
- **System-wide**: Limited only by number of distinct aggregates
- **Batching**: Multiple commands processed per Lambda invocation

### Latency

- **Typical**: below 100ms from publish to processing
- **Factors**: Queue backlog, Lambda cold starts, command complexity
- **Optimization**: Keep commands small, batch when possible

### Cost Optimization

- **Batch processing**: Process multiple commands per Lambda invocation
- **Visibility timeout**: Set appropriately to avoid premature retries
- **DLQ monitoring**: Clean up failed commands to avoid storage costs

## Pulumi

The CommandTopic component creates these infrastructure resources:

```rescript
type outputs = {
  resources: array<resource>,    // SQS queue resources
}
```

**Resource Naming:**
- Component type: `reventless:CommandTopic`
- Resource name pattern: `{aggregateName}CommandTopic`

**Dependencies:**
- Aggregate depends on CommandTopic (cannot process commands without queue)
- Lambda execution role needs `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` permissions


