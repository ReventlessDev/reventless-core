---
title: ExtensionPoint
date: 2021-11-22
draft: false
---

For a short summary of an ExtensionPoint, see [Reventless Components Overview.](../component-overview.md#extensionpoint)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`ExtensionPoint.res`](../../reventless/src/components/ExtensionPoint/ExtensionPoint.res)), builder logic ([`ExtensionPoint_Builder.res`](../../reventless/src/components/ExtensionPoint/ExtensionPoint_Builder.res)), runtime operations ([`ExtensionPoint_Operations.res`](../../reventless/src/components/ExtensionPoint/ExtensionPoint_Operations.res)), and callbacks ([`ExtensionPoint_Callback.res`](../../reventless/src/components/ExtensionPoint/ExtensionPoint_Callback.res)).
:::

## Overview

An **ExtensionPoint** defines the external interface of a [Plugin](./plugin.md), enabling cross-Plugin communication in a Reventless application. It acts as a translation layer between internal Plugin events/commands and the external world, providing a stable API that other Plugins can consume via [Extensions](./extension.md).

```d2
PluginA: "Plugin A (Provider)" {
  class: plugin-area

  Agg: Aggregate { class: aggregate }
  EPM: ExtensionPoint Mapping { class: event-mapper }

  EP: ExtensionPoint {
    class: extension-point-area
    CT: Command Topic { class: command-topic }
    ET: Event Topic { class: event-topic }
  }

  Agg -> EPM: internal event { class: event-flow }
  EPM -> EP.ET: mapped event { class: event-flow }
  EP.CT -> EPM: command { class: command-flow }
  EPM -> Agg: internal command { class: command-flow }
}

CoreStack: Core Plugin {
  class: plugin-area
  PEP: Plugin ExtensionPoint { class: extension-point }
}

PluginB: "Plugin B (Consumer)" {
  class: plugin-area
  Ext: Extension { class: extension }
}

PluginA.EP.ET -> CoreStack.PEP: event { class: cross-plugin }
CoreStack.PEP -> PluginB.Ext: event { class: cross-plugin }
PluginB.Ext -> CoreStack.PEP: command { class: cross-plugin }
CoreStack.PEP -> PluginA.EP.CT: command { class: cross-plugin }
```

## Purpose and Responsibilities

- **External Interface:** Defines the public API of a Plugin for cross-Plugin communication
- **Event Translation:** Maps internal Aggregate events to external ExtensionPoint events
- **Command Reception:** Receives commands from Extensions and maps them to internal Aggregate commands
- **Decoupling:** Isolates internal Plugin changes from external consumers
- **Stable Contract:** Provides a versioned, stable interface for other Plugins

## ExtensionPoint Spec

An ExtensionPoint Spec defines the contract for cross-Plugin communication. It specifies the commands that can be received, events that will be published, and side-effect commands that can be triggered.

### Spec Structure

```rescript
module type Spec = {
  let name: string           // Unique identifier: "PluginName.ExtensionPointName"
  
  @schema
  type command               // Commands that can be received from Extensions
  
  @schema
  type event                 // Events that will be published to Extensions
  
  @schema
  type callCommand           // Side-effect commands (for async operations)
}
```

### Example Spec

```rescript title="CustomerExtensionPointSpec.res" showLineNumbers
let name = "CustomerPlugin.Customer"

// Commands that Extensions can send to this ExtensionPoint
@decco
type command =
  | RequestCustomerInfo(string)           // Request customer details by ID
  | UpdateCustomerPreferences(string, preferences)

// Events that this ExtensionPoint publishes to Extensions
@decco
type event =
  | CustomerCreated(string, customerInfo)
  | CustomerUpdated(string, customerInfo)
  | CustomerDeleted(string)

// Side-effect commands for async operations
@decco
type callCommand =
  | NotifyExternalSystem(string)
  | SendWelcomeEmail(string, string)
```

### Naming Convention

The `name` field follows the pattern `"PluginName.ExtensionPointName"`:
- `PluginName`: The name of the Plugin containing this ExtensionPoint
- `ExtensionPointName`: A descriptive name for this specific interface

## ExtensionPoint Mappings

ExtensionPointMappings define how internal Aggregate events and commands are translated to/from the ExtensionPoint's external interface.

### Mapping Structure

```rescript
module type Impl = {
  module ExtensionPoint: Spec           // The ExtensionPoint spec
  module Aggregate: Aggregate.Spec      // The internal Aggregate spec
  
  // Map incoming commands to Aggregate commands
  let mapIncomingCommand: mapIncomingCommand<
    ExtensionPoint.command,
    Aggregate.command,
    ExtensionPoint.callCommand,
  >
  
  // Map outgoing Aggregate events to ExtensionPoint events (optional)
  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.event, ExtensionPoint.callCommand>,
  >
}
```

### Mapping Functions

#### mapIncomingCommand

Maps commands received from Extensions to internal Aggregate commands:

```rescript
type mapIncomingCommand<'extensionPointCommand, 'aggregateCommand, 'callCommand> = (
  string,                    // Aggregate ID
  'extensionPointCommand,    // Incoming ExtensionPoint command
  Message.meta,              // Message metadata
) => array<commandAction<'aggregateCommand, 'callCommand>>
```

#### mapOutgoingEvent

Maps internal Aggregate events to ExtensionPoint events for publication:

```rescript
type mapOutgoingEvent<'aggregateEvent, 'extensionPointEvent, 'callCommand> = (
  string,                    // Aggregate ID
  'aggregateEvent,           // Internal Aggregate event
  Message.meta,              // Message metadata
  QueryEngine.operations,    // Query engine for lookups
) => array<eventAction<'extensionPointEvent, 'callCommand>>
```

### Command Actions

When mapping incoming commands, you can return these actions:

```rescript
type commandAction<'command, 'msg> =
  | PublishCommand(string, 'command)     // Publish command to Aggregate
  | Call(callHandler<'msg>, 'msg)        // Execute side-effect
```

### Event Actions

When mapping outgoing events, you can return these actions:

```rescript
type eventAction<'event, 'msg> =
  | PublishEvent(string, 'event)                    // Publish event to Extensions
  | PublishEventAsync(Js.Promise.t<(string, 'event)>) // Async event publication
  | Call(callHandler<'msg>, 'msg)                   // Execute side-effect
```

### Example Mapping

```rescript title="Customer_ExtensionPointMapping.res" showLineNumbers
module ExtensionPoint = CustomerExtensionPointSpec
module Aggregate = Customer

let mapIncomingCommand = (. id, command, meta) =>
  switch command {
  | CustomerExtensionPointSpec.RequestCustomerInfo(customerId) =>
    // This might trigger a query or event, not a command
    []
    
  | CustomerExtensionPointSpec.UpdateCustomerPreferences(customerId, prefs) =>
    [PublishCommand(customerId, Customer.UpdatePreferences(prefs))]
  }

let mapOutgoingEvent = Some((. id, event, meta, queryEngine) =>
  switch event {
  | Customer.Created(customer) =>
    [PublishEvent(id, CustomerExtensionPointSpec.CustomerCreated(id, {
      name: customer.name,
      email: customer.email,
    }))]
    
  | Customer.AddressChanged(address) =>
    [PublishEvent(id, CustomerExtensionPointSpec.CustomerUpdated(id, {
      address: address,
    }))]
    
  | Customer.Deleted =>
    [PublishEvent(id, CustomerExtensionPointSpec.CustomerDeleted(id))]
    
  | _ => []
  }
)
```

## Defining an ExtensionPoint

To create an ExtensionPoint, you need:

1. **Spec:** Define the command, event, and callCommand types
2. **Mappings:** Create mappings for each Aggregate that interacts with this ExtensionPoint
3. **Module:** Combine spec and mappings into an ExtensionPoint module

### Complete Example

```rescript title="Customer_ExtensionPoint.res" showLineNumbers
// 1. Define the Spec
module Spec = CustomerExtensionPointSpec

// 2. Define Mappings for each Aggregate
module CustomerMapping = {
  module ExtensionPoint = Spec
  module Aggregate = Customer
  
  let mapIncomingCommand = (. id, command, meta) =>
    switch command {
    | Spec.UpdateCustomerPreferences(_, prefs) =>
      [PublishCommand(id, Customer.UpdatePreferences(prefs))]
    | _ => []
    }
  
  let mapOutgoingEvent = Some((. id, event, meta, queryEngine) =>
    switch event {
    | Customer.Created(customer) =>
      [PublishEvent(id, Spec.CustomerCreated(id, customer))]
    | Customer.Deleted =>
      [PublishEvent(id, Spec.CustomerDeleted(id))]
    | _ => []
    }
  )
}

// 3. Combine into Mappings module
module Mappings = {
  module Spec = Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)> = [module(CustomerMapping)]
}

// 4. Generate the ExtensionPoint (AWS)
include ReventlessAws.ExtensionPoint.Make(Spec, Mappings)
```

## Runtime Behavior

### Outgoing Event Flow

When an Aggregate emits an event that should be published externally:

```d2
shape: sequence_diagram

Aggregate: Aggregate { class: aggregate }
EventTopic: Aggregate Event Topic { class: event-topic }
EventCollector: Plugin Event Collector { class: event-collector }
EPMapping: ExtensionPoint Mapping { class: event-mapper }
EPEventTopic: ExtensionPoint Event Topic { class: event-topic }
CoreStack: Core Stack { class: external-system }
Extension: Extension { class: extension }

Aggregate -> EventTopic: emit event
EventTopic -> EventCollector: event
EventCollector -> EPMapping: "outgoingEventHandler(event)"
EPMapping -> EPMapping: "mapOutgoingEvent(event)"
EPMapping -> EPEventTopic: "publishEvent(mappedEvent) (if mapOutgoingEvent defined)"
EPEventTopic -> CoreStack: event
CoreStack -> Extension: event
```

### Incoming Command Flow

When an Extension sends a command to this ExtensionPoint:

```d2
shape: sequence_diagram

Extension: Extension { class: extension }
CoreStack: Core Stack { class: external-system }
EPCommandTopic: ExtensionPoint Command Topic { class: command-topic }
EPMapping: ExtensionPoint Mapping { class: event-mapper }
AggCommandTopic: Aggregate Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }

Extension -> CoreStack: command
CoreStack -> EPCommandTopic: forward command
EPCommandTopic -> EPMapping: "handleIncomingCommand(command)"
EPMapping -> EPMapping: "mapIncomingCommand(command)"
EPMapping -> AggCommandTopic: "publishCommand(mappedCommand)"
AggCommandTopic -> Aggregate: command
```

## Side Effects (callCommand)

ExtensionPoints can trigger side effects using the `callCommand` type and `Call` action:

```rescript
// In the Spec
@decco
type callCommand =
  | SendNotification(string, string)
  | CallExternalAPI(string)

// In the Mapping
let mapOutgoingEvent = Some((. id, event, meta, queryEngine) =>
  switch event {
  | Customer.Created(customer) =>
    [
      PublishEvent(id, Spec.CustomerCreated(id, customer)),
      Call(async (create, delete, queryEngine, msg) => {
        // Send notification to external system
        let _ = await ExternalAPI.notify(msg)
      }, SendNotification(customer.email, "Welcome!")),
    ]
  | _ => []
  }
)
```

### Call Handler Signature

```rescript
type callHandler<'msg> = (
  Schedule.create,           // Create scheduled tasks
  Schedule.delete,           // Delete scheduled tasks
  QueryEngine.operations,    // Query read models
  'msg,                      // The callCommand message
) => Js.Promise.t<unit>
```

## Component Outputs

An ExtensionPoint produces the following outputs:

```rescript
type outputs = {
  name: string,                                    // ExtensionPoint name
  aggregateNames: array<string>,                   // Connected Aggregate names
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventTopic: Pulumi.Output.t<EventTopic.outputs>,
}
```

## Integration with Plugin

ExtensionPoints are registered with their parent Plugin:

```rescript title="MyPlugin.res"
include ReventlessAws.Plugin.Make(
  Config,
  {
    let name = "CustomerPlugin"
    let version = "1.0.0"
    let heartbeatInterval = 30000
    
    let extensionPoints = [
      module(Customer_ExtensionPoint),
      module(Order_ExtensionPoint),
    ]
    
    // ... other components
  }
)
```

## Best Practices

### Spec Design

1. **Stable Interface:** Design ExtensionPoint specs to be stable across versions
2. **Minimal Surface:** Only expose events and commands that external Plugins need
3. **Clear Naming:** Use descriptive names for commands and events
4. **Versioning:** Consider versioning your ExtensionPoint spec for breaking changes

### Mapping Design

1. **Translation Layer:** Always translate internal types to external types
2. **Information Hiding:** Don't expose internal implementation details
3. **Selective Publishing:** Only publish events that are relevant to external consumers
4. **Error Handling:** Handle mapping errors gracefully

### Security Considerations

1. **Data Filtering:** Filter sensitive data before publishing events
2. **Command Validation:** Validate incoming commands before processing
3. **Access Control:** Consider which Plugins should have access to this ExtensionPoint

## Pulumi

The ExtensionPoint's Pulumi root component is named using the pattern: `{PluginName}{ExtensionPointName}` (dots removed) and has a type of `reventless:ExtensionPoint`.

### Infrastructure Components

An ExtensionPoint deploys:
- **CommandTopic:** Receives commands from Extensions
- **EventTopic:** Publishes events to Extensions

## Related Components

- [Plugin](./plugin.md) - Container for ExtensionPoints
- [Extension](./extension.md) - Consumes ExtensionPoints from other Plugins
- [Aggregate](./aggregate.md) - Source of events and target of commands
- [CommandTopic](./commandtopic.md) - Command delivery mechanism
- [EventTopic](./eventtopic.md) - Event publication mechanism
