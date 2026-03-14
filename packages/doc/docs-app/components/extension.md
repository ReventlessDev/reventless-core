---
title: Extension
date: 2021-11-22
draft: false
---

For a short summary of an Extension, see [Reventless Components Overview.](../component-overview.md#extension)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`Extension.res`](../../reventless/src/components/Extension/Extension.res)), builder logic ([`Extension_Builder.res`](../../reventless/src/components/Extension/Extension_Builder.res)), and runtime operations ([`Extension_Operations.res`](../../reventless/src/components/Extension/Extension_Operations.res)).
:::

## Overview

An **Extension** enables a [Plugin](./plugin.md) to consume events from and send commands to another Plugin's [ExtensionPoint](./extensionpoint.md). It acts as the consumer side of cross-Plugin communication, translating external events into internal commands and optionally forwarding internal events back to the ExtensionPoint.

```d2
PluginA: "Plugin A (Provider)" {
  class: plugin-area
  EP: ExtensionPoint { class: extension-point }
}

Admin: Platform Admin {
  class: external-system
  PEP: Plugin ExtensionPoint { class: extension-point }
}

PluginB: "Plugin B (Consumer)" {
  class: plugin-area

  Ext: Extension {
    class: extension
    ExtM: Extension Mapping { class: event-mapper }
  }

  Agg: Aggregate { class: aggregate }
  RM: ReadModel { class: read-model }

  Ext.ExtM -> Agg: command { class: command-flow }
  Ext.ExtM -> RM: event { class: projection-flow }
  Agg -> Ext.ExtM: event { class: event-flow }
}

PluginA.EP -> Admin.PEP: events/commands { class: cross-plugin }
Admin.PEP -> PluginA.EP: events/commands { class: cross-plugin }
Admin.PEP -> PluginB.Ext: events/commands { class: cross-plugin }
PluginB.Ext -> Admin.PEP: events/commands { class: cross-plugin }
```

## Purpose and Responsibilities

- **Event Consumption:** Receives events from remote ExtensionPoints
- **Command Generation:** Transforms incoming events into commands for local Aggregates
- **Event Forwarding:** Optionally forwards local Aggregate events back to ExtensionPoints
- **ReadModel Updates:** Can forward events to local ReadModels for projection
- **Cross-Plugin Integration:** Enables loose coupling between Plugins

## Extension vs ExtensionPoint

| Aspect | ExtensionPoint | Extension |
|--------|----------------|-----------|
| Role | Provider (publishes events, receives commands) | Consumer (receives events, sends commands) |
| Location | In the Plugin that owns the data | In the Plugin that needs the data |
| Events | Publishes events to Extensions | Receives events from ExtensionPoints |
| Commands | Receives commands from Extensions | Sends commands to ExtensionPoints |
| Infrastructure | Has CommandTopic and EventTopic | No dedicated infrastructure |

## Extension Mappings

ExtensionMappings define how external ExtensionPoint events are translated to internal commands and how internal events are forwarded back.

### Mapping Spec

An Extension uses the same Spec as the ExtensionPoint it connects to:

```rescript
module type Spec = {
  let name: string           // ExtensionPoint name: "PluginName.ExtensionPointName"
  
  @schema
  type command               // Commands that can be sent to the ExtensionPoint
  
  @schema
  type event                 // Events received from the ExtensionPoint
  
  @schema
  type callCommand           // Side-effect commands
}
```

### Mapping Implementation

```rescript
module type Impl = {
  module ExtensionPoint: Spec           // The ExtensionPoint spec being consumed
  module Aggregate: Aggregate.Spec      // The local Aggregate spec
  
  // Map incoming ExtensionPoint events to local Aggregate commands
  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Aggregate.command,
    ExtensionPoint.command,
    ExtensionPoint.callCommand,
  >
  
  // Map outgoing Aggregate events to ExtensionPoint commands (optional)
  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.command, ExtensionPoint.callCommand>,
  >
}
```

### Mapping Functions

#### mapIncomingEvent

Maps events received from the ExtensionPoint to commands for local Aggregates:

```rescript
type mapIncomingEvent<'epEvent, 'aggCommand, 'epCommand, 'callCommand> = (
  string,                              // Event ID
  'epEvent,                            // Incoming ExtensionPoint event
  Message.meta,                        // Message metadata
  PluginExtensionPointSpec.pluginDefinition,  // Plugin definition for routing
  QueryEngine.operations,              // Query engine for lookups
) => array<incomingCommandAction<'aggCommand, 'epCommand, 'callCommand>>
```

#### mapOutgoingEvent

Maps local Aggregate events to commands for the ExtensionPoint:

```rescript
type mapOutgoingEvent<'aggEvent, 'epCommand, 'callCommand> = (
  string,                              // Event ID
  'aggEvent,                           // Local Aggregate event
  Message.meta,                        // Message metadata
  PluginExtensionPointSpec.pluginDefinition,  // Plugin definition for routing
) => array<outgoingCommandAction<'epCommand, 'callCommand>>
```

### Incoming Command Actions

When mapping incoming events, you can return these actions:

```rescript
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'msg> =
  | PublishAggregateCommand(id, 'aggregateCommand)           // Send command to local Aggregate
  | PublishAggregateCommandAsync(Js.Promise.t<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(Js.Promise.t<array<(id, 'aggregateCommand)>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand) // Send command back to ExtensionPoint
  | ForwardCommand(forwardCommand)                           // Forward to another ExtensionPoint
  | Call('msg => Js.Promise.t<unit>, 'msg)                   // Execute side-effect
```

### Outgoing Command Actions

When mapping outgoing events, you can return these actions:

```rescript
type outgoingCommandAction<'extensionPointCommand, 'msg> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand) // Send command to ExtensionPoint
  | ForwardCommand(forwardCommand)                           // Forward to another ExtensionPoint
  | Call('msg => Js.Promise.t<unit>, 'msg)                   // Execute side-effect
```

### Forward Command

For routing commands to specific ExtensionPoints:

```rescript
type forwardCommand = {
  extensionPointName: string,    // Target ExtensionPoint name
  id: string,                    // Entity ID
  commandJson: Js.Json.t,        // Serialized command
}
```

## Example Extension

### Scenario

Plugin B (Order Plugin) needs to react to customer events from Plugin A (Customer Plugin):

```d2
CustomerPlugin: Customer Plugin {
  class: plugin-area
  CustomerAgg: Customer Aggregate { class: aggregate }
  CustomerEP: Customer ExtensionPoint { class: extension-point }

  CustomerAgg -> CustomerEP: CustomerCreated { class: event-flow }
}

OrderPlugin: Order Plugin {
  class: plugin-area
  CustomerExt: Customer Extension { class: extension }
  OrderAgg: Order Aggregate { class: aggregate }

  CustomerExt -> OrderAgg: CreateCustomerProfile { class: command-flow }
}

CustomerPlugin.CustomerEP -> OrderPlugin.CustomerExt: CustomerCreated { class: cross-plugin }
```

### Extension Spec (reuse ExtensionPoint Spec)

```rescript title="CustomerExtensionPointSpec.res" showLineNumbers
// This is the same spec used by the ExtensionPoint
let name = "CustomerPlugin.Customer"

@decco
type command =
  | RequestCustomerInfo(string)
  | UpdateCustomerPreferences(string, preferences)

@decco
type event =
  | CustomerCreated(string, customerInfo)
  | CustomerUpdated(string, customerInfo)
  | CustomerDeleted(string)

@decco
type callCommand =
  | NotifyExternalSystem(string)
```

### Extension Mapping

```rescript title="Customer_ExtensionMapping.res" showLineNumbers
module ExtensionPoint = CustomerExtensionPointSpec
module Aggregate = Order

let aggregateName = Order.name

// Map incoming events from Customer ExtensionPoint to Order commands
let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
  switch event {
  | CustomerExtensionPointSpec.CustomerCreated(customerId, customerInfo) =>
    // When a customer is created, create a customer profile in the Order system
    [PublishAggregateCommand(
      customerId,
      Order.CreateCustomerProfile({
        customerId: customerId,
        name: customerInfo.name,
        email: customerInfo.email,
      })
    )]
    
  | CustomerExtensionPointSpec.CustomerUpdated(customerId, customerInfo) =>
    // Update the customer profile when customer info changes
    [PublishAggregateCommand(
      customerId,
      Order.UpdateCustomerProfile({
        name: customerInfo.name,
        email: customerInfo.email,
      })
    )]
    
  | CustomerExtensionPointSpec.CustomerDeleted(customerId) =>
    // Mark customer as inactive in the Order system
    [PublishAggregateCommand(customerId, Order.DeactivateCustomer)]
  }

// Optionally map outgoing Order events back to Customer ExtensionPoint
let mapOutgoingEvent = Some((. id, event, meta, pluginDef) =>
  switch event {
  | Order.CustomerPreferencesUpdated(customerId, prefs) =>
    // Notify Customer Plugin about preference changes
    [PublishExtensionPointCommand(
      customerId,
      CustomerExtensionPointSpec.UpdateCustomerPreferences(customerId, prefs)
    )]
    
  | _ => []
  }
)
```

### Complete Extension Module

```rescript title="Customer_Extension.res" showLineNumbers
// Reference the ExtensionPoint Spec
module Spec = CustomerExtensionPointSpec

// Define the mapping
module OrderMapping = {
  module ExtensionPoint = Spec
  module Aggregate = Order
  
  let aggregateName = Order.name
  
  let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
    switch event {
    | Spec.CustomerCreated(customerId, info) =>
      [PublishAggregateCommand(customerId, Order.CreateCustomerProfile(info))]
    | Spec.CustomerUpdated(customerId, info) =>
      [PublishAggregateCommand(customerId, Order.UpdateCustomerProfile(info))]
    | Spec.CustomerDeleted(customerId) =>
      [PublishAggregateCommand(customerId, Order.DeactivateCustomer)]
    }
  
  let mapOutgoingEvent = None
}

// Combine mappings
module Mappings = {
  module Spec = Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "Order"  // Extension name suffix
  let mappings: array<module(Mapping)> = [module(OrderMapping)]
}

// Generate the Extension (AWS)
include ReventlessAws.Extension.Make(Spec, Mappings)
```

## NoAggregate Mapping

For Extensions that don't map to a specific Aggregate (e.g., only trigger side effects):

```rescript title="Notification_ExtensionMapping.res" showLineNumbers
module ExtensionPoint = CustomerExtensionPointSpec
module Aggregate = Reventless.ExtensionMapping.NoAggregate

let aggregateName = Reventless.ExtensionMapping.NoAggregate.name

let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
  switch event {
  | CustomerExtensionPointSpec.CustomerCreated(customerId, info) =>
    // Only trigger side effect, no Aggregate command
    [Call(async msg => {
      let _ = await NotificationService.sendWelcomeEmail(msg)
    }, info.email)]
    
  | _ => []
  }

let mapOutgoingEvent = None
```

## Runtime Behavior

### Incoming Event Flow

When an event arrives from an ExtensionPoint:

```d2
shape: sequence_diagram

EP: ExtensionPoint { class: extension-point }
Admin: Platform Admin { class: external-system }
EC: Plugin Event Collector { class: event-collector }
ExtOps: Extension Operations { class: extension }
AggCT: Aggregate Command Topic { class: command-topic }
Agg: Aggregate { class: aggregate }
RM: ReadModel { class: read-model }

EP -> Admin: event
Admin -> EC: event
EC -> ExtOps: "incomingEventHandler(event, pluginDef)"
ExtOps -> ExtOps: "mapIncomingEvent(event)"
ExtOps -> AggCT: "command (PublishAggregateCommand)"
AggCT -> Agg: command
ExtOps -> RM: "event (Forward to ReadModel)"
```

### Outgoing Event Flow

When a local Aggregate emits an event that should be forwarded:

```d2
shape: sequence_diagram

Agg: Aggregate { class: aggregate }
ET: Event Topic { class: event-topic }
EC: Plugin Event Collector { class: event-collector }
ExtOps: Extension Operations { class: extension }
Admin: Platform Admin { class: external-system }
EP: ExtensionPoint { class: extension-point }

Agg -> ET: event
ET -> EC: event
EC -> ExtOps: "outgoingEventHandler(event, pluginDef)"
ExtOps -> ExtOps: "mapOutgoingEvent(event)"
ExtOps -> Admin: "command (PublishExtensionPointCommand)"
Admin -> EP: command
```

## Component Outputs

An Extension produces the following outputs:

```rescript
type outputs = {
  name: string,                    // Full extension name: "ExtensionPointName.MappingName"
  extensionPointName: string,      // Name of the consumed ExtensionPoint
  aggregateNames: array<string>,   // Names of Aggregates with outgoing mappings
}
```

## Integration with Plugin

Extensions are registered with their parent Plugin:

```rescript title="OrderPlugin.res" showLineNumbers
include ReventlessAws.Plugin.Make(
  Config,
  {
    let name = "OrderPlugin"
    let version = "1.0.0"
    let heartbeatInterval = 30000
    
    let extensionPoints = []  // This Plugin doesn't expose ExtensionPoints
    
    let extensions = [
      module(Customer_Extension),      // Consumes CustomerPlugin.Customer
      module(Inventory_Extension),     // Consumes InventoryPlugin.Stock
    ]
    
    let aggregates = [
      module(Order_Aggregate),
    ]
    
    // ... other components
  }
)
```

## Multiple Mappings per Extension

An Extension can have multiple mappings for different Aggregates:

```rescript title="Customer_Extension.res" showLineNumbers
module Spec = CustomerExtensionPointSpec

// Mapping for Order Aggregate
module OrderMapping = {
  module ExtensionPoint = Spec
  module Aggregate = Order
  let aggregateName = Order.name
  
  let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
    switch event {
    | Spec.CustomerCreated(customerId, info) =>
      [PublishAggregateCommand(customerId, Order.CreateCustomerProfile(info))]
    | _ => []
    }
  
  let mapOutgoingEvent = None
}

// Mapping for Shipping Aggregate
module ShippingMapping = {
  module ExtensionPoint = Spec
  module Aggregate = Shipping
  let aggregateName = Shipping.name
  
  let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
    switch event {
    | Spec.CustomerUpdated(customerId, info) =>
      [PublishAggregateCommand(customerId, Shipping.UpdateAddress(info.address))]
    | _ => []
    }
  
  let mapOutgoingEvent = None
}

module Mappings = {
  module Spec = Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "OrderPlugin"
  let mappings: array<module(Mapping)> = [
    module(OrderMapping),
    module(ShippingMapping),
  ]
}

include ReventlessAws.Extension.Make(Spec, Mappings)
```

## Async Command Generation

For complex scenarios requiring async operations:

```rescript
let mapIncomingEvent = (. id, event, meta, pluginDef, queryEngine) =>
  switch event {
  | Spec.CustomerCreated(customerId, info) =>
    // Async command generation with query
    [PublishAggregateCommandAsync(
      queryEngine.query("CustomerDefaults", customerId)
      ->Js.Promise.then_(defaults => {
        Js.Promise.resolve((
          customerId,
          Order.CreateCustomerProfile({
            ...info,
            defaultShipping: defaults.shippingMethod,
          })
        ))
      }, _)
    )]
    
  | _ => []
  }
```

## Best Practices

### Mapping Design

1. **Single Responsibility:** Each mapping should handle one Aggregate's concerns
2. **Idempotency:** Design mappings to handle duplicate events gracefully
3. **Error Handling:** Handle missing or invalid data in events
4. **Selective Mapping:** Only map events that are relevant to your Plugin

### Cross-Plugin Communication

1. **Loose Coupling:** Don't assume internal details of the source Plugin
2. **Event Filtering:** Filter events early to reduce processing
3. **Async Operations:** Use async actions for complex transformations
4. **Query Sparingly:** Minimize QueryEngine usage in mappings

### Testing

1. **Unit Test Mappings:** Test mapping functions in isolation
2. **Integration Tests:** Test full event flow between Plugins
3. **Edge Cases:** Test handling of missing or malformed events

## Pulumi

Extensions don't deploy dedicated infrastructure. They are registered with the Plugin and their handlers are connected to the Plugin's EventCollector.

The Extension's name follows the pattern: `{ExtensionPointName}.{MappingName}` and is registered in the Plugin's extension list.

## Related Components

- [Plugin](./plugin.md) - Container for Extensions
- [ExtensionPoint](./extensionpoint.md) - The interface being consumed
- [Aggregate](./aggregate.md) - Target of generated commands
- [ReadModel](./readmodel.md) - Can receive forwarded events
- [EventCollector](./eventcollector.md) - Delivers events to Extension handlers
