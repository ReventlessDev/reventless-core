---
title: "EventTopic → SNS + SQS FIFO"
date: 2026-01-15
draft: false
---

## EventTopic → SNS

The EventTopic adapter provides event publishing capabilities using Amazon SNS (Simple Notification Service), enabling fan-out distribution of events to multiple subscribers with both standard and FIFO topic support.

## Topic Configuration

The EventTopic adapter supports two SNS topic types: **standard** and **FIFO**, each optimized for different use cases.

## Standard SNS Topic

Standard SNS topics provide best-effort ordering with at-least-once delivery:

```rescript
let topic = SNS.Topic.make(
  ~name,
  ~args={
    SNS.Topic.tags: AWS.Tags.make(~name, Reventless.EventTopic.componentType)
  },
  ~opts,
)
```

**Standard topic characteristics:**

- **High throughput** - Supports virtually unlimited messages per second
- **At-least-once delivery** - Messages may be delivered more than once
- **Best-effort ordering** - No strict ordering guarantees
- **Multiple protocols** - Can deliver to SQS, Lambda, HTTP/S, email, SMS, etc.
- **Fan-out** - Automatically delivers events to all subscribers in parallel

## FIFO SNS Topic

FIFO SNS topics provide strict ordering with exactly-once delivery:

```rescript
let topic = SNS.Topic.make(
  ~name,
  ~args={
    SNS.Topic.fifoTopic: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    tags: AWS.Tags.make(~name, Reventless.EventTopic.componentType),
  },
  ~opts,
)
```

**FIFO topic configuration details:**

- **`fifoTopic: true`** - Enables FIFO (First-In-First-Out) ordering guarantees
- **`contentBasedDeduplication: true`** - Automatic deduplication using SHA-256 hash of message body
  - Eliminates duplicate events published within the 5-minute deduplication window
  - No need to explicitly provide deduplication IDs in application code

**FIFO topic characteristics:**

- **Strict ordering** - Events are delivered in the exact order they were published (per message group)
- **Exactly-once delivery** - No duplicate messages delivered to subscribers
- **Limited throughput** - Up to 300 messages per second (or 3,000 with batching)
- **FIFO queue subscribers** - Can only subscribe SQS FIFO queues (not Lambda, HTTP, etc.)
- **Message group ordering** - Ordering is maintained per message group ID (typically aggregate ID)

## Publish Operations

The EventTopic adapter provides two publish functions, one for each topic type, both defined in `EventTopicPublisher_SNS_Runtime.res`:

## Standard Topic Publish

```rescript
let publish = (topic, _id, _meta, json) =>
  topic->Util_SNS_Runtime.publish(json->Js.Json.stringify)->Reventless.Util.Promise.toUnit
```

**Key features:**

- **Simple publish** - Publishes JSON-serialized events to SNS topic
- **No ordering constraints** - Events are distributed immediately without ordering considerations
- **Fan-out delivery** - SNS automatically delivers to all subscribers in parallel
- **Fire-and-forget** - Returns unit after successful publish

## FIFO Topic Publish

```rescript
let publishFifo = (topic, id, _meta, json) =>
  topic
  ->Util_SNS_Runtime.publishFifo(~messageGroupId=id, ~message=json->Js.Json.stringify)
  ->Reventless.Util.Promise.toUnit
```

**Key features:**

- **Message group ID** - Uses the aggregate ID as the message group for ordering
- **Ordered delivery** - Events within the same message group are delivered in strict order
- **Deduplication** - Content-based deduplication prevents duplicate events
- **FIFO guarantee** - Maintains ordering and exactly-once semantics end-to-end

## Deploy-time to Runtime Flow

The EventTopic adapter follows the standard deploy-time/runtime pattern:

```rescript
let make: Reventless.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  // Deploy-time: Create SNS topic
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: AWS.Tags.make(~name, Reventless.EventTopic.componentType)},
    ~opts,
  )

  {
    resources: [topic->Util_SNS.toResource],

    // Runtime: Bind publish function to topic metadata
    publishJson: topic
    ->Util_SNS.toRuntimeTopicOutput        // Extract: {arn, name}
    ->Pulumi.Output.apply(runtimeTopic =>   // Unwrap and bind
      EventTopicPublisher_SNS_Runtime.publish(runtimeTopic, ...)
    ),
  }
}
```

**Flow steps:**

1. **Create SNS topic** - Pulumi provisions the SNS topic resource
2. **Extract metadata** - `toRuntimeTopicOutput` converts the topic to runtime metadata (ARN, name)
3. **Bind runtime function** - `Pulumi.Output.apply` binds the `publish` function to the topic metadata
4. **Lambda execution** - Runtime function executes in Lambda with access to topic ARN for publishing

## When to Use Standard vs FIFO

**Use Standard SNS topics when:**
- High throughput is required (> 300 msgs/sec)
- Subscribers include Lambda, HTTP endpoints, email, or SMS
- Best-effort ordering is acceptable
- At-least-once delivery is sufficient (duplicate handling in subscribers)
- Low latency is critical

**Use FIFO SNS topics when:**
- Strict event ordering is required per aggregate
- Exactly-once delivery is essential
- Subscribers are SQS FIFO queues
- Event deduplication is needed
- Throughput requirements are within FIFO limits (< 300 msgs/sec)

## SNS Fan-out Pattern

EventTopic leverages SNS's native fan-out capability to deliver events to multiple subscribers:

```
EventTopic (SNS)
    ├─> EventCollector (SQS FIFO Queue)
    ├─> ReadModel Updater (Lambda subscription)
    ├─> External Integration (HTTP endpoint)
    └─> Monitoring/Logging (Lambda subscription)
```

**Benefits of SNS fan-out:**
- **Decoupling** - Publishers don't need to know about subscribers
- **Parallel delivery** - Events are delivered to all subscribers concurrently
- **Flexible subscribers** - Mix different subscriber types (SQS, Lambda, HTTP, etc.)
- **Dynamic subscriptions** - Subscribers can be added/removed without changing publishers
- **Retry logic** - SNS handles retries and dead-letter queues per subscription

