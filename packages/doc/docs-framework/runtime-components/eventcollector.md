---
title: EventCollector
---

For a short summary of EventCollector, see [Reventless Components Overview.](/app/component-overview)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`EventCollector.res`), builder logic (`EventCollector_Builder.res`), and adapter interface (`EventCollector_Adapter.res`).
:::

## Overview

```d2
EventTopic1: Event Topic { class: event-topic }
EventTopic2: Event Topic { class: event-topic }
EventCollector: Event Collector { class: event-collector }
ReadModel: Read Model { class: read-model }
EventMapper: Event Mapper { class: event-mapper }
SideEffectHandler: Side Effect Handler { class: side-effect }

EventTopic1 -> EventCollector: events { class: event-flow }
EventTopic2 -> EventCollector: events { class: event-flow }
EventCollector -> ReadModel: events { class: event-flow }
EventCollector -> EventMapper: events { class: event-flow }
EventCollector -> SideEffectHandler: events { class: event-flow }
```

The **EventCollector** is the event consumption component that receives events from EventTopics . It provides a unified interface for components like ReadModels, EventMappers, and SideEffectHandlers to consume events with ordering guarantees.

## Purpose and Responsibilities

- **Responsibility**: Subscribe to EventTopics; buffer events; deliver events to handlers with ordering guarantees; handle retries and dead letter processing
- **In**: Events from EventTopics
- **Out**: Events to ReadModel projections, EventMapper mappings, or SideEffectHandler functions

## Usage Pattern

EventCollectors are typically created as part of higher-level components (ReadModel, EventMapper, SideEffectHandler) and are not used directly by application code.

### Creating an EventCollector

- create an EventCollector module by providing an EventCollectorChannel adapter
- call make() on that module and provide the name and the EventTopics to subscribe to

```rescript title="Customer_ReadModel.res"
module CustomerEventCollector = Reventless.EventCollector_Builder.Make(
  EventCollectorChannel_SQS,
)

let eventCollector = CustomerEventCollector.make(
  ~name="CustomerReadModel",
  ~eventTopics=allEventTopics,
  ~opts=pulumiOptions,
)
```

### EventCollector Operations

The EventCollector provides operations for event handling:

#### Enqueue Event Operation

The `enqueueEvent` operation allows programmatic event injection:

```rescript
type enqueueEvent = (
  int,      // delay in seconds
  string,   // aggregate id
  string    // message content
) => promise<unit>
```

**Usage:**

```rescript
// Enqueue an event with 5 second delay
await eventCollector.enqueueEvent(5, "customer-123", eventJson)
```

#### Events Handler

The `jsonEventsHandler` type defines how events are processed:

```rescript
type jsonEventsHandler = array<Js.Json.t> => promise<unit>
```

This handler receives batches of events and processes them.

## Runtime Behavior

### Event Collection Flow

```d2
shape: sequence_diagram

EventTopic: Event Topic
EventCollectorChannel: Event Collector Channel { class: external-system }
EventCollector: Event Collector
EventHandler: Event Handler { class: external-system }

EventTopic -> EventCollectorChannel: "publishJson(event)"
EventCollectorChannel -> EventCollector: "handleChannelEvent(event)"
EventCollector -> EventHandler: "handleEvents(events)"
EventHandler -> EventHandler: Process events
EventHandler --> EventCollector: Ok / Error
EventCollector --> EventCollectorChannel: Ok / Error
```

## Integration with Components

### ReadModel Integration

```d2
ReadModelComponent: ReadModel Component {
  class: read-side

  EventCollector: Event Collector { class: event-collector }
  Projections: Projections
  QueryDb: Query DB { class: query-db }

  EventCollector -> Projections: events
  Projections -> QueryDb: update
}

EventTopic: Event Topic { class: event-topic }

EventTopic -> ReadModelComponent.EventCollector: events { class: event-flow }
```

### EventMapper Integration

```d2
EventMapperComponent: EventMapper Component {
  class: event-processing-area

  EventCollector: Event Collector { class: event-collector }
  Mappings: Event Mappings

  EventCollector -> Mappings: events
}

EventTopic: Event Topic { class: event-topic }
CommandTopic: Command Topic { class: command-topic }

EventTopic -> EventMapperComponent.EventCollector: events { class: event-flow }
EventMapperComponent.Mappings -> CommandTopic: commands { class: command-flow }
```

### SideEffectHandler Integration

```d2
SideEffectHandlerComponent: SideEffectHandler Component {
  class: side-effects-area

  EventCollector: Event Collector { class: event-collector }
  Effects: Side Effects { class: side-effect }

  EventCollector -> Effects: events
}

EventTopic: Event Topic { class: event-topic }
External: External System

EventTopic -> SideEffectHandlerComponent.EventCollector: events { class: event-flow }
SideEffectHandlerComponent.Effects -> External: call
```

**Resource Naming:**
- Component type: `reventless:EventCollector`
- Resource name pattern: `{componentName}EventCollector`

**Dependencies:**
- EventCollector subscribes to EventTopics
- ReadModel/EventMapper/SideEffectHandler depend on EventCollector
- Lambda execution role needs `sqs:ReceiveMessage`, `sqs:DeleteMessage` permissions

## Related Components

- **[EventTopic](./eventtopic.md)** - Publishes events that EventCollector subscribes to
- **[EventLog](./eventlog.md)** - Source of DynamoDB Stream events
- **[ReadModel](/app/components/readmodel)** - Uses EventCollector for projection updates
- **[EventMapper](./eventmapper.md)** - Uses EventCollector for event-to-command mapping
- **[SideEffectHandler](/app/components/sideeffecthandler)** - Uses EventCollector for side effect execution
- **[CommandTopic](./commandtopic.md)** - Similar pattern for command consumption

## AWS Implementation

For detailed implementation, see [EventCollector AWS Adapter Documentation](/infrastructure/aws/adapters/eventcollector).
