---
title: Extension
---

For a short summary of an Extension, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`Extension.res`), builder logic (`Extension_Builder.res`), and runtime operations (`Extension_Operations.res`).
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
  RM: ReadModel { class: read model }

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
  type directive             // Directives (side effects) — mirrored from the ExtensionPoint
}
```

### Mapping Implementation

```rescript
module type Impl = {
  module ExtensionPoint: Spec           // The ExtensionPoint spec being consumed
  module Delegate: Aggregate.Spec       // The local spec that receives commands
  
  // Map incoming ExtensionPoint events to local Aggregate commands
  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Aggregate.command,
    ExtensionPoint.command,
    ExtensionPoint.directive,
  >
  
  // Map outgoing Aggregate events to ExtensionPoint commands (optional)
  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.command, ExtensionPoint.directive>,
  >
}
```

### Mapping Functions

#### mapIncomingEvent

Maps events received from the ExtensionPoint to commands for local Aggregates:

```rescript
type mapIncomingEvent<'epEvent, 'aggCommand, 'epCommand, 'directive> = (
  string,                              // Event ID
  'epEvent,                            // Incoming ExtensionPoint event
  Message.meta,                        // Message metadata
  PluginExtensionPointSpec.pluginDefinition,  // Plugin definition for routing
  QueryEngine.operations,              // Query engine for lookups
) => array<incomingCommandAction<'aggCommand, 'epCommand, 'directive>>
```

#### mapOutgoingEvent

Maps local Aggregate events to commands for the ExtensionPoint:

```rescript
type mapOutgoingEvent<'aggEvent, 'epCommand, 'directive> = (
  string,                              // Event ID
  'aggEvent,                           // Local Aggregate event
  Message.meta,                        // Message metadata
  PluginExtensionPointSpec.pluginDefinition,  // Plugin definition for routing
) => array<outgoingCommandAction<'epCommand, 'directive>>
```

### Incoming Command Actions

When mapping incoming events, you can return these actions:

```rescript
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'directive> =
  | PublishAggregateCommand(id, 'aggregateCommand)           // Send command to local Aggregate
  | PublishAggregateCommandAsync(promise<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(promise<array<(id, 'aggregateCommand)>>)
  | PublishStateChangeSliceCommand('aggregateCommand)        // Send command to local StateChangeSlice
  | PublishStateChangeSliceCommandAsync(promise<'aggregateCommand>)
  | PublishStateChangeSliceCommandsAsync(promise<array<'aggregateCommand>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand) // Send command back to ExtensionPoint
  | ForwardCommand(forwardCommand)                           // Forward to another ExtensionPoint
  | HandleDirective(Reventless.Handler.handler<'directive>, 'directive) // Run a directive side-effect
```

Use `PublishAggregateCommand(id, …)` when the `Delegate` is an `Aggregate` — the
`id` is the aggregate's identity. Use `PublishStateChangeSliceCommand(…)` when
the `Delegate` is a `StateChangeSlice` — no id is needed because the framework
derives the FIFO grouping id from the command's `@partitionTag` (or
`@compositePartitionTag`) field.

### Outgoing Command Actions

When mapping outgoing events, you can return these actions:

```rescript
type outgoingCommandAction<'extensionPointCommand, 'directive> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand) // Send command to ExtensionPoint
  | ForwardCommand(forwardCommand)                           // Forward to another ExtensionPoint
  | HandleDirective(Reventless.Handler.handler<'directive>, 'directive) // Run a directive side-effect
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

### Directives (side effects)

Both `mapIncomingEvent` and `mapOutgoingEvent` can return a
`HandleDirective(handler, directive)` action to perform a **side effect** outside
the event-sourced flow (call an external API, send a notification). The directive
type is mirrored from the ExtensionPoint. Unlike an ExtensionPoint directive
handler, an Extension's is a **bare** function — no scheduler, no query-engine
argument. That is a wiring difference (the extension runs on the consumer's
EventCollector path, which the framework doesn't wire a scheduler into), not a
statement about who owns the code — extension mappings are app code just like
ExtensionPoint mappings:

```rescript
// Reventless.Handler.handler
type handler<'directive> = 'directive => promise<unit>

let handleDirective: Reventless.Handler.handler<ExtensionPoint.directive> = directive =>
  switch directive {
  | NotifyDownstream({url}) => ExternalAPI.notify(url)
  }

let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
  switch event {
  | CustomerCreated({customerId, email}) => [
      PublishStateChangeSliceCommand(SyncCustomer({customerId, email})),
      HandleDirective(handleDirective, NotifyDownstream({url: "https://…"})),
    ]
  }
```

If you need a *schedule* you cannot create it here (extensions are never handed a
scheduler) — route to a local command or declare the directive on the
ExtensionPoint side instead. See the
[Directives concept guide](../concepts/directives.md) for the full comparison.

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

### ExtensionPoint Spec (in the provider plugin's spec package)

The Extension references the provider's `*_ExtensionPoint` spec. It lives in the
provider plugin's spec package and is annotated with `@@reventless.spec`:

```rescript title="CustomerExtensionPoint.res" showLineNumbers
// In CustomerSpec — the stable public API from Customer to Order.
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | CustomerCreated({customerId: string, name: string, email: string})
  | CustomerUpdated({customerId: string, name: string, email: string})
  | CustomerDeleted({customerId: string})

// Side effects an Extension subscribing to this EP can fire from
// `mapIncomingEvent`. Defaults to `unit`. For a typed example with two
// constructors (`EmitOrderRecordedTelemetry` / `EmitOrderCancelledTelemetry`)
// fired from a subscriber alongside its state-change commands, see
// `examples/online-shop-hybrid/ordering-spec/src/Orders_ExtensionPoint.res`
// and `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res`.
@schema
type directive = unit
```

### Extension Mapping

An Extension is a single file `<Name>_Extension.res` annotated with
`@@reventless.extension`. It exposes a `module Mapping` that references the
remote `ExtensionPoint` spec and the local `Delegate` (an Aggregate or
StateChangeSlice). The PPX injects the action constructors (`PublishAggregateCommand`,
`PublishStateChangeSliceCommand`, etc.) — never `open` them manually.

```rescript title="Customer_Extension.res" showLineNumbers
// Order's extension subscribing to Customer's CustomerExtensionPoint.
@@reventless.extension

module Mapping = {
  module ExtensionPoint = CustomerSpec.CustomerExtensionPoint
  module Delegate = Order

  open ExtensionPoint
  open Order
  // Map incoming events from the Customer ExtensionPoint to Order commands
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | CustomerCreated({customerId, name, email}) => [
        PublishAggregateCommand(customerId, Order.CreateCustomerProfile({customerId, name, email})),
      ]
    | CustomerUpdated({customerId, name, email}) => [
        PublishAggregateCommand(customerId, Order.UpdateCustomerProfile({name, email})),
      ]
    | CustomerDeleted({customerId}) => [
        PublishAggregateCommand(customerId, Order.DeactivateCustomer),
      ]
    }

  // Optionally map outgoing Order events back to the Customer ExtensionPoint
  let mapOutgoingEvent = None
}
```

## Targeting a StateChangeSlice instead of an Aggregate

When the local `Delegate` is a `StateChangeSlice` (the DCB write side) rather than
an Aggregate, use `PublishStateChangeSliceCommand(command)` — no id is needed
because the framework derives the FIFO grouping id from the command's
`@partitionTag` (or `@compositePartitionTag`) field:

```rescript title="Orders_Extension.res" showLineNumbers
@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand // a StateChangeSlice

  open ExtensionPoint
  open RecordProductDemand
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(RecordDemand({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
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
RM: ReadModel { class: read model }

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

Extensions are wired automatically by the **generated** `Plugin.res`. You never
hand-write the plugin composition root — the plugin generator scans the
`Extension/` folder and emits the wiring. For reference, the generated form is:

```rescript title="src/Plugin.res (generated — do not edit)" showLineNumbers
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Extensions
  module Customer_Extension = Platform.Extension.Make(Customer_Extension.Mapping)

  // ... aggregates, read models, slices, etc.

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~extensions=[module(Customer_Extension)],
      ~aggregates=[module(OrderAggregate)],
      // ... other components
    )
}
```

`Platform.Extension.Make` takes a single argument: the `Mapping` module from your
`<Name>_Extension.res` file.

## Async Command Generation

For complex scenarios requiring async operations, return an async action
constructor from `mapIncomingEvent`:

```rescript
let mapIncomingEvent = (_id, event, _meta, _pluginDef, queryEngine) =>
  switch event {
  | CustomerCreated({customerId, name, email}) =>
    // Async command generation with query
    [
      PublishAggregateCommandAsync(
        queryEngine.query("CustomerDefaults", customerId)->Promise.thenResolve(defaults => (
          customerId,
          Order.CreateCustomerProfile({customerId, name, email, defaultShipping: defaults.shippingMethod}),
        )),
      ),
    ]
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
- [EventCollector](/framework/runtime-components/eventcollector) - Delivers events to Extension handlers
