---
title: CommandTopic
date: 2026-01-24
draft: false
---

For a short summary of CommandTopic, see [Reventless Components Overview.](../component-overview.md#commandtopic)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`CommandTopic.res`](../../reventless/src/components/CommandTopic/CommandTopic.res)), builder logic ([`CommandTopic_Builder.res`](../../reventless/src/components/CommandTopic/CommandTopic_Builder.res)), adapter interface ([`CommandTopic_Adapter.res`](../../reventless/src/components/CommandTopic/CommandTopic_Adapter.res)), runtime operations ([`CommandTopic_Operations.res`](../../reventless/src/components/CommandTopic/CommandTopic_Operations.res)), and callback handlers ([`CommandTopic_Callback.res`](../../reventless/src/components/CommandTopic/CommandTopic_Callback.res)).
:::

## Overview

```d2
API: API / CommandGenerator { class: api }
EventMapper: Event Mapper { class: event-mapper }
CommandTopic: Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }

API -> CommandTopic: command { class: command-flow }
EventMapper -> CommandTopic: commands { class: command-flow }
CommandTopic -> Aggregate: commands { class: command-flow }
```

The **CommandTopic** is the message queue component that delivers commands to Aggregates with strict ordering guarantees and reliable delivery. It ensures commands are processed exactly once per aggregate instance, in the order they were sent.

## Purpose and Responsibilities

- **Responsibility**: Queue commands for delivery to Aggregates; ensure FIFO ordering per aggregate; provide exactly-once delivery guarantees; handle retries and dead letter processing
- **In**: Commands from API (via CommandGenerator), EventMapper, Extensions, or ExtensionPoints
- **Out**: Commands to Aggregate command handlers

## Component Spec

The CommandTopic requires a spec defining the Aggregate's id type and command type:

```rescript
module type Spec = {
  module Id: Reventless.Id.T

  @schema
  type command
}
```

Take the following spec for a Customer aggregate as an example:
```rescript title="Customer.res"
module Id = Reventless.Id.String

@schema
type command =
  | Create({name: string, address: string})
  | ChangeAddress(string)
  | ChangeName(string)
  | Delete
```

This spec is used to create a type-safe CommandTopic for the Customer aggregate.

## Usage Pattern

CommandTopics are typically created as part of an Aggregate component and used internally by the framework for command delivery.

### Creating a CommandTopic

To create a CommandTopic module you have to provide the spec and a channel adapter:

```rescript title="Customer_Aggregate.res"
module CustomerCommandTopic = Reventless.CommandTopic_Builder.Make(
  Customer,
  CommandTopicChannel_SQS_FIFO,
)

let commandTopic = CustomerCommandTopic.make(
  ~name="Customer",
  ~opts=pulumiOptions,
)
```

### CommandTopic Operations

The CommandTopic provides operations for publishing and handling commands:

#### Publish a Single Command

The `publish` operation sends a single typed command to the topic:

```rescript
type publish<'id, 'command> = (
  Message.command'<'id, 'command>
) => promise<unit>
```

**Usage:**

```rescript
await commandTopic.publish({id, meta, command})
```

#### Publish Multiple Commands

The `publishJsons` operation sends multiple JSON commands efficiently:

```rescript
type publishJsons = (
  array<Reventless.Message.commandJson>
) => promise<unit>
```

This is used internally for batch command publishing (e.g. from EventMappers). Each command is a record with the following structure (as defined in the reventless-spec package):

```rescript
type commandJson = {
  id: string,
  meta: meta,
  commandJson: Js.Json.t,
  delay?: int,
}
```


## Runtime Behavior

### Command Publishing Flow

```d2
shape: sequence_diagram

Source: Command Source { class: command-generator }
CT: Command Topic { class: command-topic }
Channel: Command Topic Channel { class: aws-service }

Source -> CT: "publish(command')"
CT -> CT: Encode to JSON
CT -> Channel: "publishJsons([json])"
Channel --> CT: Completed
CT --> Source: Completed
```

### Command Handling Flow

```d2
shape: sequence_diagram

Channel: Command Topic Channel { class: aws-service }
CT: Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }

Channel -> CT: "handleChannelEvent(records)"
CT -> CT: Parse JSON commands
CT -> CT: Decode to typed commands
CT -> Aggregate: "handleCommands(commands)"
Aggregate -> Aggregate: "Process command (for each)"
Aggregate --> CT: "Results (Ok/Error per command)"
CT --> Channel: Completed
```

## Integration with Aggregate

The CommandTopic is the delivery mechanism between command sources and Aggregates:

```d2
Sources: Sources {
  API: API { class: api }
  EventMapper: Event Mapper { class: event-mapper }
  Extension: Extension
}

CTComponent: CommandTopic Component {
  class: write-side
  Queue: SQS FIFO Queue { class: command-topic }
  Handler: Command Handler
}

AggComponent: Aggregate Component {
  class: write-side
  CommandProcessor: Command Processor { class: aggregate }
  EventLog: Event Log { class: event-log }
}

Sources.API -> CTComponent.Queue: 1. publish { class: command-flow }
Sources.EventMapper -> CTComponent.Queue: 1. publish { class: command-flow }
Sources.Extension -> CTComponent.Queue: 1. publish { class: command-flow }

CTComponent.Queue -> CTComponent.Handler: 2. trigger Lambda
CTComponent.Handler -> AggComponent.CommandProcessor: 3. decode & deliver { class: command-flow }
AggComponent.CommandProcessor -> AggComponent.EventLog: 4. events { class: event-flow }
```

**Flow:**
1. Command sources publish commands to the CommandTopic queue
2. Lambda is triggered when messages arrive
3. Handler decodes commands and calls the Aggregate's command handler
4. Aggregate processes commands and appends events to EventLog

## Command Structure

All commands include metadata for traceability:

```rescript
type command'<'id, 'command> = {
  id: 'id,                // Aggregate instance id
  meta: meta,             // Metadata
  command: 'command,      // The actual command
}

type meta = {
  service: service,       // service name that created event or is addressed by command
  time: string,           // when message was created
  ip: string,             // IP of service that created message
  user: string,           // user name that initiated message (if any)
  msgId: string,          // unique message id
  correlationId: string,  // id of message that caused this message
}
```

This metadata enables:
- **Command tracing** across the system
- **Debugging** command flows
- **Auditing** who initiated commands
- **Causality tracking** for event sourcing

## Related Components

- **[Aggregate](./aggregate.md)** - Consumes commands from CommandTopic
- **[CommandGenerator](./commandgenerator.md)** - Publishes commands to CommandTopic from API
- **[EventMapper](./eventmapper.md)** - Publishes commands to CommandTopic based on events
- **[Extension](./extension.md)** - Publishes commands to ExtensionPoint CommandTopics
- **[EventTopic](./eventtopic.md)** - Similar pattern for event distribution

## AWS Implementation

For detailed implementation, see [CommandTopic AWS Adapter Documentation](/providers/aws/adapters/commandtopic).

