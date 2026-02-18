---
title: Aggregate-Extension Connection (Implementation)
---

# Aggregate-Extension Connection — Framework Implementation

This page covers how the routing between aggregates and extensions is implemented inside the framework. For the application developer's view of how to use this mechanism, see the [App Guide](/app/architecture/aggregate-extension-connection).

## Overview

Extension points and extensions allow one aggregate's events to trigger commands on another aggregate. The framework implements this as a two-layer routing mechanism:

1. **Deploy time**: `ExtensionPoint.make` and `Extension.make` wire up the SQS/SNS subscriptions and Lambda functions
2. **Runtime**: `EventMapper_Callback` decodes the incoming event and produces outgoing commands

## Deploy-Time Wiring

`ExtensionPoint_Builder.Make` constructs:

- An **EventTopic** subscription — SNS/SQS connection from the source aggregate's event topic
- A **Lambda function** — runs the `EventMapper_Callback` at runtime

`Extension_Builder.Make` constructs:

- A **CommandTopic connection** — wires the output of the extension Lambda to the target aggregate's command topic

The connection is established via the `connect` functor parameter, which calls `CommandTopic.connect` with the Lambda's output ARN.

## Runtime Dispatch

`EventMapper_Callback.Make(Spec)` produces a handler that:

1. Receives a batch of events from the source aggregate's event topic
2. Decodes each event using `Spec.eventSchema`
3. Calls `Spec.map(event)` to produce zero or more commands for the target aggregate
4. Encodes commands using `Spec.commandSchema` and publishes them to the target command topic

## Module Types

### `ExtensionPoint.T`

```rescript
module type T = {
  module Spec: ExtensionPoint.Spec
  let make: (
    ~eventTopic: EventTopic.component<EventTopic.operations>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### `Extension.T`

```rescript
module type T = {
  module Spec: Extension.Spec
  let make: (
    ~extensionPoint: ExtensionPoint.component<ExtensionPoint.operations>,
    ~commandTopic: CommandTopic.component<CommandTopic.operations>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

## Adapter Interfaces

Extension points use `EventCollector_Adapter.Channel` for the SNS-to-SQS subscription and `Runtime.Environment` for the Lambda runtime. Extensions use `CommandTopic_Adapter.Channel` to publish commands.

These are the same adapter interfaces used by read models and aggregates respectively, keeping the cloud provider adapter surface minimal.
