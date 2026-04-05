---
title: AWS Architecture
sidebar_position: 3
---

# AWS Adapter Architecture

This page covers how the `reventless-aws` adapters are structured internally — deploy-time vs runtime separation, how adapters are built, and how Pulumi values flow into Lambda.

For AWS service mappings and a list of available adapters, see the [AWS Overview](./index.md).

## Deploy-time vs Runtime

A fundamental pattern in Reventless adapters is the separation of **deploy-time** and **runtime** concerns:

- **Deploy-time code** uses [Pulumi](/framework/inner-workings/pulumi) to provision AWS infrastructure (creating DynamoDB tables, SQS queues, SNS topics, etc.)
- **Runtime code** provides functions that execute within Lambda handlers to interact with the provisioned resources

This separation allows the same adapter to orchestrate both infrastructure creation and application logic.

### Why This Separation Matters

1. **Infrastructure as Code** — All AWS resources are defined declaratively using Pulumi
2. **Type Safety** — Deploy-time compilation ensures infrastructure configuration is valid before deployment
3. **Dependency Tracking** — Pulumi automatically manages resource dependencies and ordering
4. **Runtime Efficiency** — Lambda functions receive only the minimal metadata they need (table names, ARNs, URLs), not full Pulumi resources
5. **Testability** — Deploy-time and runtime logic can be tested independently

## Adapter Structure

Each adapter typically consists of two files:

```
<Component>_<Implementation>.res         # Deploy-time: creates AWS resources
<Component>_<Implementation>_Runtime.res # Runtime: provides interaction functions
```

For example:
- `EventLogStorage_DynamoDb.res` — creates DynamoDB table at deploy-time
- `EventLogStorage_DynamoDb_Runtime.res` — provides `append` and `replay` functions at runtime

## The Deploy-time to Runtime Flow

Adapters bridge deploy-time and runtime using a consistent pattern:

1. **Resource Creation** — Create Pulumi resources (tables, queues, topics)
2. **Metadata Extraction** — Convert Pulumi resources to runtime metadata using `toRuntime*Output` functions
3. **Runtime Binding** — Use `Pulumi.Output.apply` to bind runtime functions to the metadata
4. **Lambda Execution** — Runtime functions execute in Lambda with access to resource metadata

```rescript
let make = (~name, ~opts) => {
  // 1. Deploy-time: Create DynamoDB table
  let table = Util.DynamoDb.makeTable(name, ...)

  {
    resources: [table->Util_DynamoDb.toResource],

    // 2-4. Convert to runtime metadata and bind runtime functions
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput  // Extract: {name, arn, streamArn}
    ->Pulumi.Output.apply(runtimeTable => {  // Unwrap and bind
      append: EventLogStorage_DynamoDb_Runtime.append(runtimeTable),
      replay: EventLogStorage_DynamoDb_Runtime.replay(runtimeTable),
    }),
  }
}
```

## Understanding `Pulumi.Output.t`

All deploy-time values that need to be available at runtime are wrapped in `Pulumi.Output.t<'a>`. This wrapper:

- Represents a value that will be known after infrastructure is deployed
- Allows Pulumi to track dependencies between resources
- Requires `Pulumi.Output.apply` to access the actual value
- Gets resolved during deployment; the unwrapped value is passed to Lambda functions

**Conversion Functions** (e.g., `toRuntimeTableOutput`, `toRuntimeQueueOutput`):
- Extract minimal runtime metadata from Pulumi resources
- Return `Pulumi.Output.t<runtimeMetadata>` containing only what Lambda needs (names, ARNs, URLs)
- Bridge the gap between full Pulumi resources and lightweight runtime values

## The `make` Pattern

All adapters follow a consistent `make` pattern that returns a record with:

- `resources` — array of Pulumi resources created (for dependency tracking)
- `operations` or `publishJson` — runtime functions wrapped in `Pulumi.Output.t`
- Additional adapter-specific fields (e.g., `parts`, `connect`, `handleChannelEvent`)

### Example: EventLog Adapter

```rescript title="EventLogStorage_DynamoDb.res"
let make: Reventless.EventLog_Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
    ~rangeKey="sequenceNr",
    ~tags=AWS.Tags.make(~name, Reventless.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      Reventless.EventLog_Adapter.append: EventLogStorage_DynamoDb_Runtime.append(runtimeTable),
      replay: EventLogStorage_DynamoDb_Runtime.replay(runtimeTable),
    }),
  }
}
```

### Example: CommandTopic Adapter

```rescript title="CommandTopicChannel_SQS_FIFO.res"
let make: Reventless.CommandTopic_Adapter.channelMaker = (~name, ~opts=?) => {
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      fifoQueue: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      tags: AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
    },
    ~opts?,
  )

  {
    parts: {queue: queue},
    resources: [queue->Util_SQS_FIFO.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO)
    ),
    connect: CommandTopicChannel_SQS.connect,
    handleChannelEvent: handleCommands =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands)
      ),
  }
}
```

## Runtime Functions

Runtime functions execute within Lambda handlers and interact with AWS SDK clients. They are defined in `*_Runtime.res` files and receive only the minimal metadata extracted at deploy-time.

```rescript title="EventLogStorage_DynamoDb_Runtime.res"
let append = table => async (_sequenceNr, _id, jsons) => {
  let result =
    jsons
    ->Array.map(toPutRequest)
    ->toTable(table.name)
    ->batchWriteWithRetries

  switch await result {
  | Ok() => Ok()
  | Error(unprocessedItems) => Error("...")
  }
}

let replay = table => {
  async id => await tryReplay(table.name, id)
}
```

Runtime functions:
- Accept table/queue/topic metadata (name, ARN, URL) — not full Pulumi resources
- Use AWS SDK to perform operations (query, put, send, etc.)
- Return promises with results or errors
