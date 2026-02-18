---
title: Adapter Pattern
sidebar_position: 3
---

# Adapter Pattern

The Reventless framework separates **deploy-time** (Pulumi infrastructure creation) from **runtime** (Lambda execution). Cloud provider packages implement this separation for each component.

## The Two-Layer Pattern

Every component adapter consists of two layers:

### Deploy-Time Layer

Creates cloud resources and captures their identifiers (ARNs, URLs, table names) as `Pulumi.Output.t` values.

```rescript
// Example: EventLog storage adapter (deploy time)
module Make = (Spec: ReventlessSpec.EventLog.Spec) => {
  // Creates the DynamoDB table during `pulumi up`
  let table = aws.dynamodb.Table.make(~name=Spec.name, ...)

  // Returns the table ARN wrapped in Pulumi.Output.t
  let tableArn: Pulumi.Output.t<string> = table.arn
}
```

### Runtime Layer

Implements the actual data operations. Uses the `Pulumi.Output.t` values captured during deploy time — Pulumi serializes these into the Lambda bundle with their resolved values.

```rescript
// Example: EventLog storage runtime
let append = (~events, ~condition) => async {
  // tableArn is captured from deploy time; resolved at Lambda startup
  let client = DynamoDB.makeClient()
  await client->putItem(~tableName=tableArn, ...)
}
```

## Adapter Interfaces Checklist

The following adapter interfaces must be implemented for a complete provider package. Each is defined in `packages/reventless/src/components/`.

### Core Event Sourcing

| Interface | File | Purpose |
|-----------|------|---------|
| `EventLog_Adapter.Storage` | `EventLog/EventLog_Adapter.res` | Append-only event log with optimistic concurrency |
| `EventTopic_Adapter.Publisher` | `EventTopic/EventTopic_Adapter.res` | Pub/sub event delivery |
| `CommandTopic_Adapter.Channel` | `CommandTopic/CommandTopic_Adapter.res` | Command queue with FIFO ordering |

### Read Models

| Interface | File | Purpose |
|-----------|------|---------|
| `EventCollector_Adapter.Channel` | `EventCollector/EventCollector_Adapter.res` | Subscribe to event topics |
| `QueryDb_Adapter.Storage` | `QueryDb/QueryDb_Adapter.res` | Key-value store for projections |
| `QueryDb_Adapter.QueryEngineAdapter` | `QueryDb/QueryDb_Adapter.res` | Query execution (scan, filter) |

### Supporting Services

| Interface | File | Purpose |
|-----------|------|---------|
| `Task_Adapter.Storage` | `Task/Task_Adapter.res` | Binary object storage |
| `Heartbeat_Adapter.Runner` | `Heartbeat/Heartbeat_Adapter.res` | Scheduled health checks |
| `Counter_Adapter.Storage` | `Counter/Counter_Adapter.res` | Atomic counters |

### DCB (Dynamic Consistency Boundary)

| Interface | File | Purpose |
|-----------|------|---------|
| `DcbEventLog_Adapter.Storage` | `DcbEventLog/DcbEventLog_Adapter.res` | Tag-based event log |

## Runtime Environment

The runtime environment adapter provides the Lambda execution context. It is defined in `src/adapter/Runtime/Runtime.res` in the `reventless` package.

```rescript
module type Environment = {
  let makeHandler: (
    ~handler: Runtime.eventHandler<'event, 'context, 'result>,
  ) => Lambda.handler<'event, 'context, 'result>
}
```

Cloud provider packages provide their own `Runtime.Environment` that adapts the generic handler type to the specific Lambda invocation model (e.g., SQS event format for AWS).

## Pre-Configured Builder Modules

After implementing all adapter interfaces, export pre-configured builder modules that combine the framework builder functors with your adapters:

```rescript
// ReventlessMyprovider.res — the package entry point
module Aggregate = {
  module Make = (Spec: ReventlessSpec.Aggregate.Spec) =>
    Aggregate_Builder.Make(Spec, MyRuntimeEnvironment, MyEventLogStorage, MyEventTopicPublisher, MyCommandTopicChannel)
}

module ReadModel = {
  module Make = (Spec: ReventlessSpec.ReadModel.Spec) =>
    ReadModel_Builder.Make(Spec, MyRuntimeEnvironment, MyEventCollectorChannel, MyQueryDbStorage, MyQueryEngineAdapter)
}

// ... etc
```

This is the API surface for application developers. They call `ReventlessMyprovider.Aggregate.Make(MySpec)` and get a fully wired `Aggregate.T`.
