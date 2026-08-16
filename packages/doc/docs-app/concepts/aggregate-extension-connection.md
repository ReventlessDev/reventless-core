---
title: Aggregate-Extension Connection
---

# Aggregate-Extension Connection

This document explains how aggregates connect to extension points and extensions within a Reventless Plugin, enabling bidirectional communication between the write side (aggregates) and extension logic.

## Overview

The connection between aggregates and extension points/extensions is **bidirectional**:
- **Command Flow**: Extension Points/Extensions → Aggregates (send commands)
- **Event Flow**: Aggregates → Extension Points/Extensions (receive events)

This architecture enables extension points and extensions to both orchestrate aggregate behavior and react to aggregate events.

## Command Flow: Publishing TO Aggregates

Extension points and extensions can send commands to aggregates to trigger business logic.

### Step 1: Aggregate Resources Collection

When a Plugin is created, it collects resources and publish functions from all aggregates:

**File**: `Plugin_Helpers.res:82-102`

```rescript
let aggregateResources = Dict.make()
let publishToAggregates = Dict.make()

let createAggregatesWithoutEventMappers = (aggregates, opts) =>
  aggregates->Array.map((module(SpecificAggregate: Aggregate.T)) => {
    let aggregate = SpecificAggregate.make(~opts)

    // Extract CommandTopic resources (for infrastructure/permissions)
    let resources = (aggregate->Component.outputs).commandTopic
      ->Pulumi.Output.apply(commandTopic => commandTopic.resources)
    aggregateResources->Dict.set(SpecificAggregate.Spec.name, resources)

    // Extract publishJsons function (for sending commands at runtime)
    let publishJsons = aggregate->Component.operations
      ->Pulumi.Output.apply(({publishJsons}) => publishJsons)
    publishToAggregates->Dict.set(SpecificAggregate.Spec.name, publishJsons)
  })
```

This creates two dictionaries keyed by aggregate name:
- **`aggregateResources`**: Infrastructure resources for deploy-time permissions (e.g., SQS queue ARNs)
- **`publishToAggregates`**: Runtime functions to send commands (typed publish operations)

### Step 2: Passing to Extension Points

Extension points receive both the resources and publish functions:

**File**: `Plugin_Helpers.res:218-236`

```rescript
let createExtensionPoints = (
  extensionPoints,
  ~aggregateResources,      // ← Deploy-time resources
  ~publishToAggregates,      // ← Runtime publish functions
  ~scheduler,
  ~queryEngine,
  ~resourceNaming,
  ~opts,
) =>
  extensionPoints->Array.map((module(SpecificExtensionPoint: ExtensionPoint.T)) => {
    let extensionPoint = SpecificExtensionPoint.make(
      ~aggregateResources,     // Can access aggregate infrastructure
      ~publishToAggregates,    // Can publish to any aggregate
      ~scheduler,
      ~queryEngine,
      ~resourceNaming,
      ~opts=Some(opts),
    )
  })
```

### Step 3: Passing to Extensions

Extensions also receive the ability to publish to aggregates:

**File**: `Plugin_Helpers.res:246-263`

```rescript
let createExtensions = (
  extensions: array<module(Extension.Blueprint)>,
  ~pluginName,
  ~publishToPluginExtensionPoint,
  ~publishToAggregates,      // ← Extensions can publish to aggregates
  ~publishToReadModels,
  ~queryEngine,
  ~opts,
) => {
  // Group blueprints by EP name, merge same-EP mappings,
  // name each extension after the plugin, then build.
  // ...
}
```

### Usage Example

Inside an extension or extension point handler, commands can be sent to aggregates:

```rescript
// Get the publish function for a specific aggregate
let publishToMyAggregate = publishToAggregates->Dict.get("MyAggregate")

// Send a command
publishToMyAggregate->Option.forEach(publish => {
  let commandJson = myCommand->MyAggregate.Command.encode
  publish([commandJson])
})
```

## Event Flow: Receiving FROM Aggregates

Extension points and extensions can subscribe to events from aggregates to react to state changes.

### Step 1: Event Topic Collection

The Plugin collects all aggregate event topics:

**File**: `Plugin_Builder.res:36-37`

```rescript
let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(opts)
let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
```

The `allEventTopics` function extracts the EventTopic from each aggregate:

**File**: `Aggregate.res:19-20`
```rescript
let allEventTopics = allAggregates =>
  Dict.mapValues(allAggregates, aggregate => aggregate.eventLog.eventTopic)
```

### Step 2: Event Handler Registration

Extension points and extensions declare which aggregates they're interested in:

**ExtensionPoint outputs**: `ExtensionPoint.res:3-14`
```rescript
type outputs = {
  name: string,
  aggregateNames: array<string>,  // ← Declares which aggregates to listen to
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventTopic: Pulumi.Output.t<EventTopic.outputs>,
}
```

**Extension outputs**: `Extension.res:3-7`
```rescript
type outputs = {
  name: string,
  extensionPointName: string,
  aggregateNames: array<string>,  // ← Declares which aggregates to listen to
}
```

The `aggregateNames` field acts as a subscription list - only events from these aggregates will be routed to the handler.

### Step 3: Handler Routing Table Construction

The Plugin builds routing tables that map aggregate names to their event handlers:

**File**: `Plugin_Helpers.res:444-462`

```rescript
let outgoingExtensionPointEventHandlers = serviceNameToEventHandlers(
  extensionPointsOutputs,
  outputs => outputs.aggregateNames,  // Get aggregate names from each extension point
  extensionPointsHandlers->Array.map(handler => {outgoing: handler}),
  getOutgoingEventHandler,
)

let outgoingExtensionEventHandlers = serviceNameToEventHandlers(
  extensionsOutputs,
  outputs => outputs.aggregateNames,  // Get aggregate names from each extension
  extensionsHandlers,
  getOutgoingEventHandler,
)
```

The `serviceNameToEventHandlers` function creates a routing dictionary:

```rescript
// Result structure:
{
  "MyAggregate": [extensionPoint1Handler, extension1Handler],
  "AnotherAggregate": [extension2Handler],
}
```

### Step 4: EventCollector Subscription

The Plugin's EventCollector subscribes to all aggregate event topics:

**File**: `Plugin_Helpers.res:392-398`

```rescript
let eventCollector = PluginEventCollector.make(
  ~name,
  ~eventTopics,  // ← All aggregate event topics
  ~opts
)
```

The EventCollector acts as a centralized event router, receiving events from all aggregates and distributing them to the appropriate handlers.

### Step 5: Event Routing at Runtime

When events arrive at the EventCollector, they're routed by aggregate name:

**File**: `Plugin_Callback.res:17-26`

```rescript
let handleEvent = async (eventJson', eventHandlersByService) =>
  await eventJson'
  ->Message.serviceNameOfMsg           // Extract aggregate name from event
  ->Option.flatMap(serviceName =>
    eventHandlersByService->Dict.get(serviceName)  // Lookup handlers by name
  )
  ->Option.mapOr(Promise.resolve(), async eventHandlers => {
    await eventHandlers
    ->Array.map(eventHandler => eventHandler(eventJson', pluginDefinition))
    ->Promise.all
  })
```

The event processing pipeline (`Plugin_Callback.res:52-58`):

```rescript
// Events are processed in this order:
switch await eventJson'->handleEvent(incomingConnectExtensionEventHandlers) {
| _ =>
  [
    eventJson'->handleEvent(outgoingExtensionPointEventHandlers),  // 1. Extension points
    eventJson'->handleEvent(outgoingExtensionEventHandlers),       // 2. Extensions
    eventJson'->handleEvent(incomingExtensionEventHandlers),       // 3. Extension responses
  ]->Promise.all
}
```

## Architecture Diagram

```d2
Plugin: Plugin {
  class: plugin-area

  ExtensionLayer: Extension Layer {
    EP: Extension Point { class: extension-point }
    EXT: Extension { class: extension }
  }

  AggregateLayer: Aggregate Layer {
    AGG1: "Aggregate 1\nCommandTopic\nEventTopic" { class: aggregate }
    AGG2: "Aggregate 2\nCommandTopic\nEventTopic" { class: aggregate }
    AGG3: "Aggregate 3\nCommandTopic\nEventTopic" { class: aggregate }
  }

  EC: "EventCollector\nCentral Event Router" { class: event-collector }

  ExtensionLayer.EP -> AggregateLayer.AGG1: "publishToAggregates\nsend commands" { class: command-flow }
  ExtensionLayer.EP -> AggregateLayer.AGG2: "publishToAggregates\nsend commands" { class: command-flow }
  ExtensionLayer.EXT -> AggregateLayer.AGG1: "publishToAggregates\nsend commands" { class: command-flow }
  ExtensionLayer.EXT -> AggregateLayer.AGG3: "publishToAggregates\nsend commands" { class: command-flow }

  AggregateLayer.AGG1 -> EC: emit events { class: event-flow }
  AggregateLayer.AGG2 -> EC: emit events { class: event-flow }
  AggregateLayer.AGG3 -> EC: emit events { class: event-flow }

  EC -> ExtensionLayer.EP: route by aggregateName { class: event-flow }
  EC -> ExtensionLayer.EXT: route by aggregateName { class: event-flow }
}
```

## Key Concepts

### 1. Bidirectional Communication

Extension points and extensions can both **send commands to** and **receive events from** aggregates. This enables:
- **Command orchestration**: Extensions coordinate aggregate behavior
- **Event reactions**: Extensions respond to aggregate state changes
- **Workflow coordination**: Complex processes spanning multiple aggregates

### 2. Name-based Routing

Both directions use aggregate names as routing keys:
- **Commands**: `publishToAggregates[aggregateName](commands)`
- **Events**: Handlers subscribe via `aggregateNames` array

### 3. Multiple Handlers

Multiple extension points and extensions can:
- Send commands to the same aggregate
- Listen to events from the same aggregate
- Process events in parallel (extension points and extensions run concurrently)

### 4. Event Filtering

Extension points and extensions declare which aggregates they care about via the `aggregateNames` field. Only events from subscribed aggregates are delivered to each handler.

### 5. Deploy-time vs Runtime

The connection has two aspects:
- **`aggregateResources`**: Deploy-time infrastructure (used for IAM permissions, Lambda configurations)
- **`publishToAggregates`**: Runtime operations (actual command publishing at runtime)

This separation allows Pulumi to set up proper permissions during deployment while keeping runtime code clean and type-safe.

## Example: Order Processing Extension

Here's a concrete example of how an extension might interact with aggregates:

```rescript
module OrderProcessingExtension = Extension_Builder.Make({
  // ... Extension spec ...

  // Declare which aggregates this extension listens to
  let aggregateNames = ["Order", "Inventory", "Payment"]

  // Handler receives events from subscribed aggregates
  let handleEvent = (event, ~publishToAggregates, ~queryEngine) => {
    switch event->decodeEvent {
    | OrderPlaced({orderId, items}) =>
      // React to Order aggregate event by commanding other aggregates
      let publishToInventory = publishToAggregates->Dict.get("Inventory")
      let publishToPayment = publishToAggregates->Dict.get("Payment")

      publishToInventory->Option.forEach(publish => {
        let reserveCommand = ReserveItems({orderId, items})
        publish([reserveCommand->encodeCommand])
      })

      publishToPayment->Option.forEach(publish => {
        let chargeCommand = ChargeCustomer({orderId, amount})
        publish([chargeCommand->encodeCommand])
      })

    | InventoryReserved({orderId}) =>
      // React to Inventory aggregate event
      Console.log(`Inventory reserved for order ${orderId}`)

    | PaymentSucceeded({orderId}) =>
      // React to Payment aggregate event, command Order aggregate
      let publishToOrder = publishToAggregates->Dict.get("Order")
      publishToOrder->Option.forEach(publish => {
        let confirmCommand = ConfirmOrder({orderId})
        publish([confirmCommand->encodeCommand])
      })

    | _ => ()
    }
  }
})
```

This extension:
1. Subscribes to three aggregates: Order, Inventory, Payment
2. Receives events from all three (filtered by EventCollector)
3. Sends commands to aggregates to orchestrate the workflow
4. Implements a saga pattern coordinating multiple aggregates

## Summary

The aggregate-extension connection enables powerful coordination patterns in Reventless:

- **Decoupled**: Aggregates don't know about extensions; extensions subscribe to aggregates
- **Type-safe**: Commands and events are fully typed throughout the pipeline
- **Flexible**: Multiple handlers can process the same events independently
- **Scalable**: The EventCollector pattern supports many aggregates and extensions
- **Infrastructure-aware**: Deploy-time resources enable proper IAM configuration

This architecture supports complex distributed workflows while maintaining strong type safety and clear separation of concerns.
