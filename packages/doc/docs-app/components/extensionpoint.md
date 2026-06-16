---
title: ExtensionPoint
date: 2021-11-22
draft: false
---

For a short summary of an ExtensionPoint, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`ExtensionPoint.res`), builder logic (`ExtensionPoint_Builder.res`), runtime operations (`ExtensionPoint_Operations.res`), and callbacks (`ExtensionPoint_Callback.res`).
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

Admin: Platform Admin {
  class: plugin-area
  PEP: Plugin ExtensionPoint { class: extension-point }
}

PluginB: "Plugin B (Consumer)" {
  class: plugin-area
  Ext: Extension { class: extension }
}

PluginA.EP.ET -> Admin.PEP: event { class: cross-plugin }
Admin.PEP -> PluginB.Ext: event { class: cross-plugin }
PluginB.Ext -> Admin.PEP: command { class: cross-plugin }
Admin.PEP -> PluginA.EP.CT: command { class: cross-plugin }
```

## Purpose and Responsibilities

- **External Interface:** Defines the public API of a Plugin for cross-Plugin communication
- **Event Translation:** Maps internal Aggregate events to external ExtensionPoint events
- **Command Reception:** Receives commands from Extensions and maps them to internal Aggregate commands
- **Decoupling:** Isolates internal Plugin changes from external consumers
- **Stable Contract:** Provides a versioned, stable interface for other Plugins

## ExtensionPoint Spec

An ExtensionPoint Spec defines the contract for cross-Plugin communication. It specifies the commands that can be received, events that will be published, and directives (side effects) that can be triggered.

### Spec Structure

```rescript
module type Spec = {
  let name: string           // Unique identifier: "PluginName.ExtensionPointName"
  
  @schema
  type command               // Commands that can be received from Extensions
  
  @schema
  type event                 // Events that will be published to Extensions
  
  @schema
  type directive             // Side effects the mapping can trigger (see Directives)
}
```

### Example Spec

The spec file lives in the provider plugin's spec package and is annotated with
`@@reventless.spec`. The PPX auto-injects `let name`, `module Id`, and
`let moduleUrl` — derived from the filename and (in a `*Spec` namespace)
prefixed with the plugin name to form the dotted EP name. You only declare the
`@schema` types:

```rescript title="Customer_ExtensionPoint.res" showLineNumbers
// In CustomerSpec — @@reventless.spec derives the name "Customer.Customer".
@@reventless.spec

// Commands that Extensions can send to this ExtensionPoint
@schema
type command =
  | RequestCustomerInfo({customerId: string})
  | UpdateCustomerPreferences({customerId: string, preferences: preferences})

// Events that this ExtensionPoint publishes to Extensions
@schema
type event =
  | CustomerCreated({customerId: string, name: string, email: string})
  | CustomerUpdated({customerId: string, name: string, email: string})
  | CustomerDeleted({customerId: string})

// Side effects this ExtensionPoint's mapping can fire from `mapOutgoingEvent` /
// `mapIncomingCommand`. Defaults to `unit` (no side effects). For a typed
// example, see `EmitPricingUpdate` in the hybrid online-shop example at
// `examples/online-shop-hybrid/catalog-spec/src/Products_ExtensionPoint.res`.
@schema
type directive = unit
```

### Naming Convention

The dotted EP name follows the pattern `"PluginName.ExtensionPointName"`. You do
not write `let name` by hand — `@@reventless.spec` derives it from the filename
and, in a `*Spec` namespace, prefixes the plugin name automatically.

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
    ExtensionPoint.directive,
  >
  
  // Map outgoing Aggregate events to ExtensionPoint events (optional)
  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.event, ExtensionPoint.directive>,
  >
}
```

### Mapping Functions

#### mapIncomingCommand

Maps commands received from Extensions to internal Aggregate commands:

```rescript
type mapIncomingCommand<'extensionPointCommand, 'aggregateCommand, 'directive> = (
  string,                    // Aggregate ID
  'extensionPointCommand,    // Incoming ExtensionPoint command
  Message.meta,              // Message metadata
) => array<commandAction<'aggregateCommand, 'directive>>
```

#### mapOutgoingEvent

Maps internal Aggregate events to ExtensionPoint events for publication:

```rescript
type mapOutgoingEvent<'aggregateEvent, 'extensionPointEvent, 'directive> = (
  string,                    // Aggregate ID
  'aggregateEvent,           // Internal Aggregate event
  Message.meta,              // Message metadata
  QueryEngine.operations,    // Query engine for lookups
) => array<eventAction<'extensionPointEvent, 'directive>>
```

### Command Actions

When mapping incoming commands, you can return these actions:

```rescript
type commandAction<'command, 'directive> =
  | PublishCommand(string, 'command)                          // Publish command to Aggregate
  | HandleDirective(directiveHandler<'directive>, 'directive) // Run a directive side-effect
```

### Event Actions

When mapping outgoing events, you can return these actions:

```rescript
type eventAction<'event, 'directive> =
  | PublishEvent(string, 'event)                              // Publish event to Extensions
  | PublishEventAsync(promise<(string, 'event)>)              // Async event publication
  | HandleDirective(directiveHandler<'directive>, 'directive) // Run a directive side-effect
```

### Example Mapping

The mapping file is `<Name>_ExtensionPointMapping.res`, annotated with
`@@reventless.spec`. It references the EP spec via `module ExtensionPoint` and
declares a `module Delegate` — the local source (an Aggregate spec, or a DCB
adapter whose `name` is `<pluginName>DcbEventLog`). The action constructors
(`PublishEvent`, `PublishCommand`, `PublishEventAsync`, `HandleDirective`) are
injected by the PPX — never `open` them manually:

```rescript title="Customer_ExtensionPointMapping.res" showLineNumbers
@@reventless.spec

module ExtensionPoint = CustomerSpec.Customer_ExtensionPoint

// Delegate: the local Customer Aggregate whose events feed the EP.
module Delegate = Customer

let mapIncomingCommand = (_id, command, _meta) =>
  switch command {
  | RequestCustomerInfo(_) =>
    // This might trigger a query or event, not a command
    []
  | UpdateCustomerPreferences({customerId, preferences}) => [
      PublishCommand(customerId, Customer.UpdatePreferences({preferences: preferences})),
    ]
  }

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Created({customerId, name, email}) => [
      PublishEvent(customerId, CustomerSpec.Customer_ExtensionPoint.CustomerCreated({customerId, name, email})),
    ]
  | Delegate.Deleted({customerId}) => [
      PublishEvent(customerId, CustomerSpec.Customer_ExtensionPoint.CustomerDeleted({customerId})),
    ]
  | _ => []
  }
)
```

## Defining an ExtensionPoint

To create an ExtensionPoint, you write two files:

1. **Spec** (`<Name>_ExtensionPoint.res`, in the plugin's spec package) — declares
   the `command`, `event`, and `directive` `@schema` types.
2. **Mapping** (`<Name>_ExtensionPointMapping.res`, in the plugin) — references
   the EP spec and a `Delegate`, and implements `mapIncomingCommand` /
   `mapOutgoingEvent`.

The plugin generator wires the EP automatically into the generated `Plugin.res`
as `Platform.ExtensionPoint.Make(<Name>_ExtensionPointMapping)` — a single
argument. You never write the composition root by hand.

### Complete Example

The spec (see [Example Spec](#example-spec)) plus the mapping (see
[Example Mapping](#example-mapping)) are all you write. The generated wiring is:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ExtensionPoints
  module Customer_ExtensionPoint = Platform.ExtensionPoint.Make(Customer_ExtensionPointMapping)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Customer",
      ~extensionPoints=[module(Customer_ExtensionPoint)],
      // ... other components
    )
}
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
Admin: Platform Admin { class: external-system }
Extension: Extension { class: extension }

Aggregate -> EventTopic: emit event
EventTopic -> EventCollector: event
EventCollector -> EPMapping: "outgoingEventHandler(event)"
EPMapping -> EPMapping: "mapOutgoingEvent(event)"
EPMapping -> EPEventTopic: "publishEvent(mappedEvent) (if mapOutgoingEvent defined)"
EPEventTopic -> Admin: event
Admin -> Extension: event
```

### Incoming Command Flow

When an Extension sends a command to this ExtensionPoint:

```d2
shape: sequence_diagram

Extension: Extension { class: extension }
Admin: Platform Admin { class: external-system }
EPCommandTopic: ExtensionPoint Command Topic { class: command-topic }
EPMapping: ExtensionPoint Mapping { class: event-mapper }
AggCommandTopic: Aggregate Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }

Extension -> Admin: command
Admin -> EPCommandTopic: forward command
EPCommandTopic -> EPMapping: "handleIncomingCommand(command)"
EPMapping -> EPMapping: "mapIncomingCommand(command)"
EPMapping -> AggCommandTopic: "publishCommand(mappedCommand)"
AggCommandTopic -> Aggregate: command
```

## Directives (side effects)

Besides publishing events and commands — which stay inside the event-sourced
system — an ExtensionPoint mapping can perform **side effects** that reach outside
it (call an external API, send a notification, create a schedule). These are
modelled as **directives**: the `directive` `@schema` type on the Spec, returned
from a mapping as a `HandleDirective(handler, directive)` action. The runtime then
calls `handler(directive)` as a fire-and-forget side effect — nothing is
published, logged to the event store, or replayed.

For the full picture — including the difference between ExtensionPoint and
Extension directives and when to prefer a translation slice — see the
[Directives concept guide](../concepts/directives.md).

```rescript
// In the Spec — directives are a variant type, like events
@schema
type directive =
  | SendNotification({email: string, message: string})
  | CallExternalAPI({url: string})

// In the Mapping — a handler closing over the injected Schedule/QueryEngine,
// returned via HandleDirective alongside the published event
let handleDirective: directiveHandler<ExtensionPoint.directive> = async (
  _createSchedule, _deleteSchedule, _queryEngine, directive,
) =>
  switch directive {
  | SendNotification({email, message}) => let _ = await ExternalAPI.notify(email, message)
  | CallExternalAPI({url}) => let _ = await ExternalAPI.get(url)
  }

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Created({customerId, name, email}) => [
      PublishEvent(customerId, ExtensionPoint.CustomerCreated({customerId, name, email})),
      HandleDirective(handleDirective, SendNotification({email, message: "Welcome!"})),
    ]
  | _ => []
  }
)
```

### Directive Handler Signature

An ExtensionPoint runs on the provider plugin's command/event-dispatch path, which
the framework already wires with a scheduler and query engine — so the EP component
threads them into the directive handler:

```rescript
type directiveHandler<'directive> = (
  Schedule.create,           // Create scheduled tasks
  Schedule.delete,           // Delete scheduled tasks
  QueryEngine.operations,    // Query read models
  'directive,                // The directive payload
) => promise<unit>
```

This is why the ExtensionPoint side is the practical place for infra-bound effects
such as scheduling. (An [Extension](./extension.md) directive handler is a bare
`'directive => promise<unit>` with no scheduler — not because extensions are "less
trusted," but because the consumer's EventCollector path isn't wired with one. See
the [concept guide](../concepts/directives.md).)

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

ExtensionPoints are wired automatically into the **generated** `Plugin.res` —
the plugin generator scans the `ExtensionPoint/` folder and emits the wiring. You
never hand-write the composition root:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ExtensionPoints
  module Customer_ExtensionPoint = Platform.ExtensionPoint.Make(Customer_ExtensionPointMapping)
  module Order_ExtensionPoint = Platform.ExtensionPoint.Make(Order_ExtensionPointMapping)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Customer",
      ~extensionPoints=[module(Customer_ExtensionPoint), module(Order_ExtensionPoint)],
      // ... other components
    )
}
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

## Protocol Versioning

When you evolve an ExtensionPoint's commands or events over time, you need to maintain backwards compatibility with Extensions that may be on an older version. See [Extension Point Protocol Versioning](/framework/architecture/extension-point-protocol-versioning) for the framework's approach to versioning extension point protocols.

## Related Components

- [Plugin](./plugin.md) - Container for ExtensionPoints
- [Extension](./extension.md) - Consumes ExtensionPoints from other Plugins
- [Aggregate](./aggregate.md) - Source of events and target of commands
- [CommandTopic](./commandtopic.md) - Command delivery mechanism
- [EventTopic](./eventtopic.md) - Event publication mechanism
