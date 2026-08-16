---
title: AWS Adapters
---

## Overview

The `reventless-aws` package provides AWS-specific implementations of the adapter interfaces defined in the core `reventless` framework. Adapters bridge the gap between Reventless's provider-agnostic components and AWS infrastructure services.

[Reventless](/app/component-overview) components are designed to be cloud-provider-agnostic. The `reventless` package defines abstract adapter interfaces, while `reventless-aws` implements these interfaces using AWS services like DynamoDB, SQS, SNS, S3, and Lambda.

```d2
vars: { d2-config: { layout-engine: elk } }

Reventless: Generic Components - reventless {
  class: reventless-area

  Aggregate: { class: aggregate }
  EventTopic: { class: event-topic }
  EventLog: { class: event-log }
  CommandTopic: { class: command-topic }
  CommandGenerator: { class: command-generator }

  Aggregate -> EventTopic
  Aggregate -> EventLog
  Aggregate -> CommandTopic
  Aggregate -> CommandGenerator

  ReadModel: { class: read-model }
  QueryDb: { class: query-db }
  EventCollector: { class: event-collector }

  ReadModel -> QueryDb
  ReadModel -> EventCollector

  Task: { class: task }
  Plugin: Plugin { class: plugin }

  Adapter: Adapter Interfaces - Core Framework {
    class: adapter-area

    EventTopicPublisher: { class: adapter }
    EventLogStorage: { class: adapter }
    CommandTopicChannel: { class: adapter }
    CommandGeneratorResolvers: { class: adapter }

    QueryDbResolvers: { class: adapter }
    QueryDbStorage: { class: adapter }
    EventCollectorChannel: { class: adapter }

    TaskBucket: { class: adapter }
    Runtime: { class: adapter }

    # Component to Adapter Interface connections
    _.EventTopic -> EventTopicPublisher
    _.EventLog -> EventLogStorage
    _.CommandTopic -> CommandTopicChannel
    _.CommandGenerator -> CommandGeneratorResolvers

    _.QueryDb -> QueryDbResolvers
    _.QueryDb -> QueryDbStorage
    _.EventCollector -> EventCollectorChannel

    _.Task -> TaskBucket
    _.Plugin -> Runtime
  }

 }

ReventlessAws: AWS Adapter - reventless-aws {
  class: reventless-aws-area

  DeployTime: Deploy-time - Pulumi Resources {
    class: adapter-area

    EventTopicPublisher: EventTopicPublisher_SNS { class: adapter }
    EventLogStorage: EventLogStorage_DynamoDb { class: adapter }
    CommandTopicChannel: CommandTopicChannel_SQS_FIFO { class: adapter }
    CommandGeneratorResolvers: CommandGeneratorResolvers_AppSync { class: adapter }
    QueryDbResolvers: QueryDbResolvers_AppSync { class: adapter }
    QueryDbStorage: QueryDbStorage_DynamoDb { class: adapter }
    EventCollectorChannel: EventCollectorChannel_SQS { class: adapter }
    TaskBucket: TaskBucket_S3 { class: adapter }
    Runtime: Runtime_Lambda { class: adapter }
  }

  Runtime: Runtime - Lambda Handlers {
    class: adapter-area
    EventTopicPublisher: EventTopicPublisher_SNS_Runtime { class: adapter }
    EventLogStorage: EventLogStorage_DynamoDb_Runtime { class: adapter }
    CommandTopicChannel: CommandTopicChannel_SQS_Runtime { class: adapter }
    CommandGeneratorResolvers: CommandGeneratorResolvers_AppSync_Runtime { class: adapter }
    QueryDbResolvers: QueryDbResolvers_AppSync_Runtime { class: adapter }
    QueryDbStorage: QueryDbStorage_DynamoDb_Runtime { class: adapter }
    EventCollectorChannel: EventCollectorChannel_SQS_Runtime { class: adapter }
    TaskBucket: TaskBucket_S3_Runtime { class: adapter }
  }
}

AWSServices: AWS Services {
  class: scheduling-area

  SNS: { class: aws-service }
  DynamoDB: { class: aws-service }
  AppSync: { class: aws-service }
  SQS: { class: aws-service }
  DynamoDBStreams: { class: aws-service }
  S3: { class: aws-service }
  CloudWatchEvents: { class: aws-service }
  Lambda: { class: aws-service }
}

# Adapter Interface to AWS Implementation connections (dashed = implements)
Reventless.Adapter.CommandTopicChannel <-- ReventlessAws.DeployTime.CommandTopicChannel: implements
Reventless.Adapter.EventLogStorage <-- ReventlessAws.DeployTime.EventLogStorage: implements
Reventless.Adapter.EventTopicPublisher <-- ReventlessAws.DeployTime.EventTopicPublisher: implements
Reventless.Adapter.CommandGeneratorResolvers <-- ReventlessAws.DeployTime.CommandGeneratorResolvers: implements
Reventless.Adapter.QueryDbResolvers <-- ReventlessAws.DeployTime.QueryDbResolvers: implements
Reventless.Adapter.QueryDbStorage <-- ReventlessAws.DeployTime.QueryDbStorage: implements
Reventless.Adapter.EventCollectorChannel <-- ReventlessAws.DeployTime.EventCollectorChannel: implements
Reventless.Adapter.TaskBucket <-- ReventlessAws.DeployTime.TaskBucket: implements
Reventless.Adapter.Runtime <-- ReventlessAws.DeployTime.Runtime: implements

# Deploy-time to Runtime conversion
ReventlessAws.DeployTime.CommandTopicChannel -> ReventlessAws.Runtime.CommandTopicChannel
ReventlessAws.DeployTime.EventLogStorage -> ReventlessAws.Runtime.EventLogStorage
ReventlessAws.DeployTime.EventTopicPublisher -> ReventlessAws.Runtime.EventTopicPublisher
ReventlessAws.DeployTime.CommandGeneratorResolvers -> ReventlessAws.Runtime.CommandGeneratorResolvers
ReventlessAws.DeployTime.QueryDbResolvers -> ReventlessAws.Runtime.QueryDbResolvers
ReventlessAws.DeployTime.QueryDbStorage -> ReventlessAws.Runtime.QueryDbStorage
ReventlessAws.DeployTime.EventCollectorChannel -> ReventlessAws.Runtime.EventCollectorChannel
ReventlessAws.DeployTime.TaskBucket -> ReventlessAws.Runtime.TaskBucket

# Runtime to AWS Services connections
ReventlessAws.Runtime.EventLogStorage -> AWSServices.DynamoDB: read/write
ReventlessAws.Runtime.CommandTopicChannel -> AWSServices.SQS: send/receive
ReventlessAws.Runtime.EventTopicPublisher -> AWSServices.SNS: publish
ReventlessAws.Runtime.CommandGeneratorResolvers -> AWSServices.AppSync: resolve
ReventlessAws.Runtime.QueryDbResolvers -> AWSServices.AppSync: resolve
ReventlessAws.Runtime.QueryDbStorage -> AWSServices.DynamoDB: read/write
ReventlessAws.Runtime.EventCollectorChannel -> AWSServices.SQS: receive
ReventlessAws.Runtime.EventCollectorChannel -> AWSServices.DynamoDBStreams: consume
ReventlessAws.Runtime.TaskBucket -> AWSServices.S3: read/write
ReventlessAws.DeployTime.Runtime-> AWSServices.Lambda: executes in
```

## AWS Service Mappings

Reventless components map to AWS services as follows:

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| **EventLog** | DynamoDB | Append-only event storage with partition key `id` and sort key `sequenceNr` |
| **CommandTopic** | SQS FIFO | Command message queues with FIFO ordering and deduplication |
| **EventTopic** | SNS / SNS FIFO | Event publishing with fan-out to multiple subscribers |
| **QueryDb** | DynamoDB | Read model storage with configurable indexes and TTL |
| **EventCollector** | DynamoDB Streams / SQS | Consumes events from EventLog or EventTopic |
| **Task** | S3 | Stores task data; S3 events trigger Lambda on object create/delete |
| **CommandGenerator** | AppSync | GraphQL API for command generation with DynamoDB resolvers |
| **Counter** | DynamoDB Streams | Atomic counter updates triggered by DynamoDB stream events |
| **ScheduledPublisher** | EventBridge | Time-based event publishing using EventBridge rules |
| **Heartbeat** | EventBridge | Periodic heartbeat signals using EventBridge |
| **Runtime** | Lambda | Execution environment for all runtime operations |

## Adapter Details

The following AWS adapters are available. For how adapters are structured internally (deploy-time vs runtime, the `make` pattern, `Pulumi.Output.t`), see [AWS Architecture](./architecture.md).

### Core Event Sourcing Adapters

- **[EventLog → DynamoDB](./adapters/eventlog)** - Append-only event storage with efficient replay
- **[DcbEventLog → DynamoDB](./adapters/dcbeventlog)** - Tag-routed shared event store for DCB slices with per-tag consistency fences
- **[CommandTopic → SQS FIFO](./adapters/commandtopic)** - Reliable command delivery with strict ordering
- **[EventTopic → SNS](./adapters/eventtopic)** - Event publishing with fan-out to multiple subscribers
- **[EventCollector → SQS FIFO](./adapters/eventcollector)** - Multi-source event collection from SNS and DynamoDB Streams

### Data Storage Adapters

- **[QueryDb → DynamoDB](./adapters/querydb)** - Read model storage with GSI support and AppSync integration
- **[Task → S3](./adapters/task)** - File-based task triggering with Lambda subscriptions

### Supporting Adapters

- **[ScheduledPublisher → EventBridge](./adapters/scheduledpublisher)** - Scheduled command execution
- **[Heartbeat → EventBridge](./adapters/heartbeat)** - Health check and keep-alive monitoring
- **[Counter → DynamoDB Streams](./adapters/counter)** - Atomic counting via change data capture
- **[StateTopic → DynamoDB Streams](./adapters/statetopic)** - State change publishing via DynamoDB Streams
- **[CommandGenerator → AppSync](./adapters/commandgenerator)** - GraphQL mutation resolvers for command generation
- **[QueryEngine → DynamoDB](./adapters/queryengine)** - Advanced query and scan operations

## Folder Structure

```sh
reventless-aws/src/adapter/
├── AWS.res                     # AWS service constants and principals
├── AWS_Tags.res                # Tagging utilities
├── Adapter_Helpers.res         # Shared adapter utilities
├── Cloner/                     # Fargate-based data cloning
├── CommandGenerator/           # AppSync resolvers for commands
├── CommandTopic/               # SQS-based command channels
├── Counter/                    # DynamoDB Stream counter handlers
├── EventCollector/             # DynamoDB Stream / SQS event collection
├── EventLog/                   # DynamoDB event storage
├── EventTopic/                 # SNS event publishing
├── Heartbeat/                  # EventBridge heartbeat
├── QueryDb/                    # DynamoDB read model storage
├── QueryEngine/                # DynamoDB query execution
├── Runtime/                    # Lambda runtime environment
├── ScheduledPublisher/         # EventBridge scheduled publishing
├── StateTopic/                 # DynamoDB Stream state publishing
└── Task/                       # S3 task buckets
```

