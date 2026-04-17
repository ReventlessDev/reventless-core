---
title: Plugin
date: 2021-11-22
draft: false
---

For a short summary of a Plugin, see [Reventless Components Overview.](../component-overview.md#plugin)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions (`Plugin.res`), builder logic (`Plugin_Builder.res`), and helper functions (`Plugin_Helpers.res`).
:::

## Overview

A **Plugin** is the top-level organizational unit in a Reventless application, corresponding to a [Bounded Context](https://martinfowler.com/bliki/BoundedContext.html) in Domain-Driven Design (DDD). It serves as both a logical boundary for domain concepts and a deployment unit for infrastructure.

```d2
vars: { d2-config: { layout-engine: elk } }
grid-columns: 1

Upstream: {
  class: invisible
  grid-rows: 1

  1,1: { class: placeholder; width: 800 }
  # 1,2: X
  Plugin: Upstream Plugin { class: plugin }
}

Plugin: "Plugin (Bounded Context)" {
  class: plugin-area

  Components: Internal Components {
    class: write-side
    grid-rows: 3
    Agg1: Aggregate 1 { class: aggregate }
    Agg2: Aggregate 2 { class: aggregate }
    RM1: ReadModel 1 { class: read-model }
    RM2: ReadModel 2 { class: read-model }
    Task1: Task 1 { class: task }
    Task2: Task 2 { class: task }
  }

  Communication: Internal Communication {
    class: event-processing-area
    grid-rows: 3
    EC: Event Collector { class: event-collector }
    CT: Command Topics { class: command-topic }
    ET: Event Topics { class: event-topic }
  }

  External: External Interface {
    class: plugin-area
    grid-rows: 2
    Ext: Extension { class: extension }
    EP: Extension Point { class: extension-point }
    HB: Heartbeat { class: heartbeat } 
  }

}

Downstream: {
  class: placeholder
  grid-rows: 1
  grid-columns: 3

  1,1: { class: placeholder; width: 800 }
  Plugin: Downstream Plugin { class: plugin }
  Admin: Platform Admin { class: plugin }
}

Plugin.External.EP -> Downstream.Plugin: events/commands { class: cross-plugin }
Upstream.Plugin -> Plugin.External.Ext: events/commands { class: cross-plugin }
Plugin.External.HB -> Downstream.Admin: heartbeat
```

## Purpose and Responsibilities

- **Bounded Context:** Establishes clear boundaries for domain concepts, naming, and functionality
- **Deployment Unit:** Groups all related components for unified deployment
- **Component Container:** Contains and orchestrates Aggregates, ReadModels, Tasks, ExtensionPoints, and Extensions
- **Cross-Plugin Communication:** Manages communication with other Plugins via ExtensionPoints and Extensions
- **Health Monitoring:** Provides heartbeat signals to the Platform Admin for monitoring

## Plugin Structure

A Plugin contains and manages the following components:

| Component | Purpose | Quantity |
|-----------|---------|----------|
| [Aggregates](./aggregate.md) | Business logic and event sourcing | 0..n |
| [ReadModels](./readmodel.md) | Query-optimized projections | 0..n |
| [Tasks](./task.md) | File processing and external integrations | 0..n |
| [ExtensionPoints](./extensionpoint.md) | External interface for other Plugins | 0..n |
| [Extensions](./extension.md) | Consume other Plugins' ExtensionPoints | 0..n |
| [EventCollector](./eventcollector.md) | Centralized event consumption | 1 |
| [Heartbeat](./heartbeat.md) | Health monitoring | 1 |

## Plugin Configuration

A Plugin is configured with the following parameters:

```rescript
let make: (
  ~name: string,                                    // Unique plugin name
  ~heartbeatInterval: int,                          // Health check interval (seconds)
  ~extensionPoints: array<module(ExtensionPoint.T)>=?,
  ~extensions: array<module(Extension.Blueprint)>=?,
  ~aggregates: array<module(Aggregate.T)>=?,
  ~readModels: array<module(ReadModel.T)>=?,
  ~tasks: array<module(Task.T)>=?,
  ~stateChangeSlices: array<module(StateChangeSlice.T)>=?,
  ~stateViewSlices: array<module(StateViewSlice.T)>=?,
  ~automationSlices: array<module(AutomationSlice.T)>=?,
  ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>=?,
  ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => component
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Unique identifier for the Plugin within the system |
| `heartbeatInterval` | `int` | Interval in seconds for health check signals |
| `extensionPoints` | `array<module(ExtensionPoint.T)>` | ExtensionPoints exposed by this Plugin |
| `extensions` | `array<module(Extension.Blueprint)>` | Extension blueprints — auto-merged by EP and named after the plugin |
| `aggregates` | `array<module(Aggregate.T)>` | Aggregates contained in this Plugin |
| `readModels` | `array<module(ReadModel.T)>` | ReadModels for query projections |
| `tasks` | `array<module(Task.T)>` | Tasks for file processing and integrations |
| `stateChangeSlices` | `array<module(StateChangeSlice.T)>` | DCB write-side slices |
| `stateViewSlices` | `array<module(StateViewSlice.T)>` | DCB read-side slices |

## Plugin Outputs

When deployed, a Plugin produces the following outputs:

```rescript
type outputs = {
  id: Pulumi.Output.t<string>,                              // Plugin identifier (name@version)
  version: Pulumi.Output.t<string>,                         // Version string
  heartbeatInterval: Pulumi.Output.t<int>,                  // Configured heartbeat interval
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,  // Event collector outputs
  extensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>,
  extensions: Pulumi.Output.t<dict<Extension.outputs>>,
  aggregates: Pulumi.Output.t<dict<Aggregate.outputs>>,
  readModels: Pulumi.Output.t<dict<ReadModel.outputs>>,
  tasks: Pulumi.Output.t<dict<Task.outputs>>,
  resolvers: Pulumi.Output.t<array<Reventless.Adapter.resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
}
```

## Internal Communication

Within a Plugin, components communicate through internal messaging infrastructure:

```d2
Plugin: Plugin {
  class: plugin-area

  API: API { class: api }
  CG: Command Generator { class: command-generator }
  CT1: Command Topic { class: command-topic }
  Agg: Aggregate { class: aggregate }
  EL: Event Log { class: event-log }
  ET: Event Topic { class: event-topic }
  EC: Event Collector { class: event-collector }
  EM: Event Mapper { class: event-mapper }
  RM: ReadModel { class: read-model }

  API -> CG: mutation { class: command-flow }
  CG -> CT1: command { class: command-flow }
  CT1 -> Agg: command { class: command-flow }
  Agg -> EL: events { class: event-flow }
  EL -> Agg: events { class: event-flow }
  EL -> ET: event { class: event-flow }
  ET -> EC: event { class: event-flow }
  EC -> EM: event { class: event-flow }
  EC -> RM: event { class: projection-flow }
  EM -> CT1: command { class: command-flow }
}
```

### Communication Rules

1. **Aggregates within the same Plugin** can communicate directly via EventMappings
2. **Aggregates in different Plugins** must communicate via ExtensionPoints and Extensions
3. **ReadModels** receive events through the Plugin's EventCollector
4. **Tasks** can publish commands to Aggregates within the same Plugin

## Cross-Plugin Communication

Plugins communicate with each other through ExtensionPoints and Extensions:

```d2
PluginA: Plugin A {
  class: plugin-area
  AggA: Aggregate { class: aggregate }
  EPA: Extension Point { class: extension-point }
  EPM: ExtensionPoint Mapping { class: event-mapper }

  AggA -> EPM: event { class: event-flow }
  EPM -> EPA: mapped event { class: event-flow }
}

PluginB: Plugin B {
  class: plugin-area
  ExtB: Extension { class: extension }
  ExtM: Extension Mapping { class: event-mapper }
  AggB: Aggregate { class: aggregate }

  ExtB -> ExtM: event { class: event-flow }
  ExtM -> AggB: command { class: command-flow }
}

Admin: Platform Admin {
  class: plugin-area
  PEP: Plugin Extension Point { class: extension-point }
}

PluginA.EPA -> Admin.PEP: events/commands { class: cross-plugin }
Admin.PEP -> PluginA.EPA: events/commands { class: cross-plugin }
PluginB.ExtB -> Admin.PEP: events/commands { class: cross-plugin }
Admin.PEP -> PluginB.ExtB: events/commands { class: cross-plugin }
```

### Communication Flow

1. **Outgoing Events:** Aggregate events are mapped to ExtensionPoint events via ExtensionPointMappings
2. **Event Distribution:** ExtensionPoint publishes events to the Platform Admin's Plugin ExtensionPoint
3. **Event Reception:** Extensions receive events from ExtensionPoints they subscribe to
4. **Command Generation:** Extension mappings transform incoming events to commands for local Aggregates
5. **Command Forwarding:** Extensions can also send commands back to ExtensionPoints

## Plugin Definition

At runtime, each Plugin registers itself with the Platform Admin using a plugin definition:

```rescript
type pluginDefinition = {
  id: string,                                    // Unique identifier (name@version)
  name: string,                                  // Plugin name
  version: string,                               // Version string
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,                // Event collector URN
}
```

This definition enables:
- **Discovery:** Other Plugins can discover available ExtensionPoints
- **Routing:** The Platform Admin routes events between Plugins
- **Monitoring:** Health status tracking via heartbeats

## Example Plugin Setup

```rescript title="MyPlugin.res" showLineNumbers
// Include the AWS-specific Plugin builder
include ReventlessAws.Plugin.Make(
  Config,
  {
    let name = "MyDomain"
    let version = "1.0.0"
    let heartbeatInterval = 30000  // 30 seconds
    
    let extensionPoints = [
      module(MyDomain_ExtensionPoint),
    ]
    
    let extensions = [
      module(OtherDomain_Extension),
    ]
    
    let aggregates = [
      module(Customer_Aggregate),
      module(Order_Aggregate),
    ]
    
    let readModels = [
      module(CustomerList_ReadModel),
      module(OrderHistory_ReadModel),
    ]
    
    let tasks = [
      module(ImportCustomers_Task),
    ]
  }
)
```

## Runtime Behavior

### Initialization Sequence

```d2
shape: sequence_diagram

Pulumi: Pulumi { class: external-system }
Plugin: Plugin { class: plugin }
Aggregates: Aggregates { class: aggregate }
ReadModels: ReadModels { class: read-model }
ExtensionPoints: ExtensionPoints { class: extension-point }
Extensions: Extensions { class: extension }
EventCollector: EventCollector { class: event-collector }
Admin: Admin { class: external-system }

Pulumi -> Plugin: deploy
Plugin -> Aggregates: "create (without EventMappers)"
Plugin -> ReadModels: create
Plugin -> ExtensionPoints: create
Plugin -> Extensions: create
Plugin -> Plugin: Add EventMappers to Aggregates
Plugin -> EventCollector: create & connect
Plugin -> Admin: register plugin definition
Plugin --> Pulumi: outputs
```

### Heartbeat Monitoring

The Plugin sends periodic heartbeat signals to the Platform Admin:

```d2
shape: sequence_diagram

Plugin: Plugin { class: plugin }
Heartbeat: Heartbeat { class: heartbeat }
Admin: Admin { class: external-system }

Heartbeat -> Admin: "heartbeat signal (every heartbeatInterval)"
Admin -> Admin: Update plugin health status
```

## Best Practices

### Plugin Design

1. **Single Responsibility:** Each Plugin should represent one bounded context
2. **Cohesive Components:** Group related Aggregates and ReadModels together
3. **Clear Boundaries:** Use ExtensionPoints to define explicit external interfaces
4. **Version Management:** Use semantic versioning for Plugin versions

### Cross-Plugin Communication

1. **Minimize Dependencies:** Limit the number of Extensions per Plugin
2. **Stable Interfaces:** Design ExtensionPoint specs to be stable over time
3. **Event Translation:** Always translate internal events to ExtensionPoint events
4. **Loose Coupling:** Avoid direct dependencies between Plugin internals

### Deployment

1. **Independent Deployment:** Design Plugins to be deployable independently
2. **Version Compatibility:** Ensure ExtensionPoint compatibility across versions
3. **Health Monitoring:** Configure appropriate heartbeat intervals

## Pulumi

The Plugin's Pulumi root component is named using the pattern: `{name}@{version}` and has a type of `reventless:Plugin`.

### Stack Outputs

A Plugin deployment exports the following stack outputs:

- `extensionPoints`: Dictionary of ExtensionPoint outputs for cross-stack references
- `pluginDefinition`: The plugin's registration information

## Related Components

- [Aggregate](./aggregate.md) - Business logic components within a Plugin
- [ReadModel](./readmodel.md) - Query projections within a Plugin
- [Task](./task.md) - File processing and external integrations
- [ExtensionPoint](./extensionpoint.md) - External interface for cross-Plugin communication
- [Extension](./extension.md) - Consume other Plugins' ExtensionPoints
- [EventCollector](./eventcollector.md) - Centralized event consumption
- [Heartbeat](./heartbeat.md) - Health monitoring
