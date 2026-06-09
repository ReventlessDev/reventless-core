---
title: EventTopic
date: 2026-01-24
draft: false
---

For a short summary of EventTopic, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`EventTopic.res`), builder logic (`EventTopic_Builder.res`), adapter interface (`EventTopic_Adapter.res`), and runtime operations (`EventTopic_Operations.res`).
:::

## Overview

```d2
EventLog: EventLog { class: event-log }
EventTopic: Event Topic { class: event-topic }
EventCollector1: Event Collector 1 { class: event-collector }
EventCollector2: Event Collector 2 { class: event-collector }
EventCollector3: Event Collector 3 { class: event-collector }
ReadModel: Read Model { class: read-model }
EventMapper: Event Mapper { class: event-mapper }
SideEffectHandler: Side Effect Handler { class: side-effect }

EventLog -> EventTopic: publish events { class: event-flow }
EventTopic -> EventCollector1: fan-out { class: event-flow }
EventTopic -> EventCollector2: fan-out { class: event-flow }
EventTopic -> EventCollector3: fan-out { class: event-flow }
EventCollector1 -> ReadModel: events { class: event-flow }
EventCollector2 -> EventMapper: events { class: event-flow }
EventCollector3 -> SideEffectHandler: events { class: event-flow }
```

The **EventTopic** is the event distribution component that enables fan-out delivery of events to multiple subscribers. It receives events from the EventLog and distributes them to EventCollectors, which then deliver events to ReadModels, EventMappers, and SideEffectHandlers.

## Purpose and Responsibilities

- **Responsibility**: Distribute events from EventLog to multiple subscribers; enable fan-out pattern for event-driven architecture; provide ordering guarantees per aggregate
- **In**: Events from EventLog (via `publish` operation)
- **Out**: Events to EventCollectors (via SNS subscriptions)

## Component Spec

The EventTopic requires a spec defining the aggregate's event type:

```rescript
module type Spec = {
  @schema
  type event
}
```

For example, a Customer aggregate might define its spec as follows:

```rescript title="Customer.res"
@@reventless.spec

@schema
type event =
  | Created({name: string, address: string})
  | AddressChanged(string)
  | NameChanged(string)
  | Deleted
```

This spec is used to create a type-safe EventTopic for the Customer aggregate.

## Usage Pattern

EventTopics are typically created as part of an EventLog component and are not used directly by application code. The EventLog handles all interactions with the EventTopic internally.

### Creating an EventTopic

```rescript title="Customer_EventLog.res"
module CustomerEventTopic = Reventless.EventTopic_Builder.Make(
  Customer,
  EventTopicPublisher_SNS,
)

let eventTopic = CustomerEventTopic.make(
  ~name="Customer",
  ~storageResources=eventLogResources,
  ~opts=pulumiOptions,
)
```

### EventTopic Operations

The EventTopic provides operations for publishing events:

#### Publish Operation

The `publish` operation sends events to the topic for distribution:

```rescript
type publish<'id, 'event> = (
  array<Message.event'<'id, 'event>>
) => promise<unit>
```

**Usage:**

```rescript
let events' = [
  {
    Message.id: customerId,
    event: Created({name: "John Doe", address: "123 Main St"}),
    meta: {...},
  },
]

await eventTopic.publish(events')
```

#### Publish JSON Operation

The `publishJson` operation publishes a single event in JSON format:

```rescript
type publishJson = (
  string,           // aggregate id
  Message.meta,     // event metadata
  Js.Json.t         // event JSON
) => promise<unit>
```

This is used internally by the EventLog after storing events.

## Runtime Behavior

### Event Publishing Flow

```d2
shape: sequence_diagram

EL: Event Log{ class: event-log }
ET: Event Topic{ class: event-topic }
Publisher: Event Topic Publisher { class: aws-service }
EC1: EventCollector 1 { class: event-collector }
EC2: EventCollector 2{ class: event-collector }

EL -> ET: "publish(events')"
ET -> ET: "Encode to JSON (for each event)"
ET -> Publisher: "publishJson(event)"
Publisher -> EC1: "Deliver (fan-out)"
Publisher -> EC2: "Deliver (fan-out)"
Publisher --> ET: Ok/Error
ET --> EL: Ok/Error
```

## Integration with EventLog

The EventTopic is automatically created and managed by the EventLog component:

```d2
ELComponent: EventLog Component {
  class: write-side
  Storage: DynamoDB { class: event-log }
  EventTopic: Event Topic { class: event-topic }
}

Aggregate: Aggregate { class: aggregate }
Subscribers: Subscribers

Aggregate -> ELComponent.Storage: 1. append events { class: event-flow }
ELComponent.Storage -> ELComponent.EventTopic: 2. success
ELComponent.EventTopic -> Subscribers: 3. publish { class: event-flow }
```

**Flow:**
1. Aggregate appends events to EventLog storage
2. After successful storage, EventLog publishes to EventTopic
3. EventTopic distributes events to all subscribers

## Event Metadata

All events published to the EventTopic include metadata:

```rescript
type event'<'id, 'event> = {
  id: 'id,                // Aggregate instance ID
  meta: meta,             // Metadata
  event: 'event,          // The actual domain event
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
- **Event tracing** across the system
- **Debugging** event flows
- **Auditing** who initiated events
- **Causality tracking** for event sourcing

## Common Patterns

### Event Fan-out to Multiple Consumers

```d2
EventTopic: Event Topic { class: event-topic }
ReadModel: "Read Model\nQuery Projection" { class: read-model }
EventMapper: "Event Mapper\nCommand Generation" { class: event-mapper }
SideEffect: "Side Effect Handler\nExternal Integration" { class: side-effect }
Analytics: "Analytics\nMetrics Collection" { class: task }

EventTopic -> ReadModel: { class: event-flow }
EventTopic -> EventMapper: { class: event-flow }
EventTopic -> SideEffect: { class: event-flow }
EventTopic -> Analytics: { class: event-flow }
```

### Event-Driven Saga Pattern

```rescript
// Order aggregate publishes OrderCreated event
// EventTopic distributes to:
// 1. Inventory EventMapper -> Reserve inventory
// 2. Payment EventMapper -> Process payment
// 3. Notification SideEffectHandler -> Send confirmation email
```

### Cross-Plugin Event Distribution

```rescript
// Plugin A's EventTopic publishes events
// Plugin B's Extension subscribes via ExtensionPoint
// Events flow across plugin boundaries
```

## Pulumi

The EventTopic component creates these infrastructure resources:

```rescript
type outputs = {
  resources: array<resource>,    // adapter resources
}
```

**Resource Naming:**
- Component type: `reventless:EventTopic`
- Resource name pattern: `{aggregateName}EventTopic`

**Dependencies:**
- EventLog depends on EventTopic (events published after storage)
- EventCollectors subscribe to EventTopic

## Related Components

- **[EventLog](./eventlog.md)** - Publishes events to EventTopic after storage
- **[EventCollector](./eventcollector.md)** - Subscribes to EventTopic for event consumption
- **[ReadModel](./readmodel.md)** - Consumes events via EventCollector
- **[EventMapper](./eventmapper.md)** - Consumes events via EventCollector
- **[SideEffectHandler](./sideeffecthandler.md)** - Consumes events via EventCollector
- **[CommandTopic](./commandtopic.md)** - Similar pattern for command distribution

## AWS Implementation

For detailed implementation, see [EventTopic AWS Adapter Documentation](/infrastructure/aws/adapters/eventtopic).

