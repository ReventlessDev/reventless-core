---
title: Component Overview
date: 2022-09-27
draft: false
---

## Aggregate-Based Plugin

The following diagram shows how all components of an **aggregate-based plugin** work together:

```d2
direction: down

client: GraphQL Client { class: client }
api: GraphQL API { class: api }

write_side: Write Side {
  direction: right
  class: write-side

  cmd_gen: Command Generator { class: command-generator }
  cmd_topic: Command Topic { class: command-topic }
  aggregate: Aggregate { class: aggregate }
  event_log: Event Log { class: event-log }
  event_topic: Event Topic { class: event-topic }

  cmd_gen -> cmd_topic: commands { class: command-flow }
  cmd_topic -> aggregate: commands { class: command-flow }
  aggregate -> event_log: append { class: event-flow }
  event_log -> aggregate: replay { class: replay }
  event_log -> event_topic: publish { class: event-flow }
}

consumers: {
  direction: right
  style.fill: "transparent"
  style.stroke: "transparent"

  side_effects: Side Effects {
    direction: right
    class: side-effects-area

    collector: Event Collector { class: event-collector }
    handler: Side Effect Handler { class: side-effect }
    task: Task { class: task }
    external: External System { class: external-system }

    collector -> handler: events { class: event-flow }
    handler -> task: trigger
    handler -> external: calls
  }

  event_processing: Event Processing {
    direction: right
    class: event-processing-area

    collector: Event Collector { class: event-collector }
    mapper: Event Mapper { class: event-mapper }
    counter: Counter { class: counter }

    collector -> mapper: events { class: event-flow }
    mapper -> counter: dedup check
  }

  read_side: Read Side {
    direction: right
    class: read-side

    collector: Event Collector { class: event-collector }
    read_model: Read Model { class: read-model }
    query_db: Query DB { class: query-db }

    collector -> read_model: events { class: event-flow }
    read_model -> query_db: save/update { class: projection-flow }
  }
}

plugins: Plugin System {
  direction: right
  class: plugin-area

  ext_point: Extension Point { class: extension-point }
  extension: Extension { class: extension }

  ext_point -> extension: events { class: event-flow }
  extension -> ext_point: commands { class: cross-plugin }
}

scheduling: Scheduling {
  direction: right
  class: scheduling-area

  heartbeat: Heartbeat { class: heartbeat }
  scheduler: Scheduler { class: scheduler }
}

client -> api: GraphQL mutations { class: command-flow }
api -> write_side.cmd_gen: resolver invocation { class: command-flow }

api -> consumers.read_side.query_db: queries

write_side.event_topic -> consumers.side_effects.collector: events { class: event-flow }
write_side.event_topic -> consumers.event_processing.collector: events { class: event-flow }
write_side.event_topic -> consumers.read_side.collector: events { class: event-flow }

consumers.event_processing.mapper -> write_side.cmd_topic: commands { class: command-flow }

plugins.ext_point -> write_side.cmd_topic: commands { class: cross-plugin }
scheduling.scheduler -> write_side.cmd_topic: scheduled commands { class: command-flow }
scheduling.heartbeat -> plugins.ext_point: periodic signals { class: event-flow }
```

- **Command Flow**: Client → API → CommandGenerator → CommandTopic → Aggregate
- **Event Flow**: Aggregate → EventLog → EventTopic → EventCollectors → Processing Components
- **Read Side**: EventCollector → ReadModel → QueryDb ← API ← Client
- **Event Processing**: EventMapper and SideEffectHandler consuming events
- **Plugin System**: Cross-plugin communication via ExtensionPoints and Extensions
- **Scheduling**: Time-based command generation and health monitoring

## DCB-Based Plugin

The following diagram shows how the components of a **DCB-based plugin** (Dynamic Consistency Boundary) work together. The key differences from the aggregate-based approach are the shared **DcbEventLog** across all StateChangeSlices and the **StateViewSlice** that combines the EventCollector and ReadModel roles.

```d2
vars: {
  d2-config: {
    layout-engine: elk
  }
}

dcb_layout: "" {
  grid-rows: 3
  grid-columns: 3
  style.fill: "transparent"
  style.stroke: "transparent"

  # ── Row 1 ──────────────────────────────────────────────────────────────────

  1,1: "" { class: placeholder }

  scheduling: Scheduling {
    grid-rows: 1
    direction: right
    class: scheduling-area

    heartbeat: Heartbeat { class: heartbeat }
    scheduler: Scheduler { class: scheduler }
  }

  client: "" { 
    class: placeholder 
    
    client: GraphQL Client { class: client }
  }

  # ── Row 2 ──────────────────────────────────────────────────────────────────

  plugins: Plugin System {
    direction: down
    class: plugin-area

    ext_point: Extension Point { class: extension-point }
    extension: Extension { class: extension }

    ext_point -> extension: events { class: event-flow }
    extension -> ext_point: commands { class: cross-plugin }
  }

  write_side: Write Side {
    direction: down
    class: write-side

    cmd_topic: Command Topic { class: command-topic }

    slices: State Change Slices {
      direction: down
      class: slices-area

      slice1: Slice 1 { class: state-change-slice }
      slice2: Slice 2 { class: state-change-slice }
      slice3: Slice 3 { class: state-change-slice }
    }

    dcb_log: DCB Event Log { class: dcb-event-log }
    event_topic: Event Topic { class: event-topic }

    cmd_topic -> slices: "commands (routed by type)" { class: command-flow }
    slices -> dcb_log: append { class: event-flow }
    dcb_log -> slices: replay { class: replay }
    dcb_log -> event_topic: publish { class: event-flow }
  }

  graphql: API {
    class: api-area

    api: GraphQL API { class: api }
  }

  # ── Row 3 ──────────────────────────────────────────────────────────────────

  automation: Automation {
    direction: down
    class: automation-slices-area

    auto_slice: Automation Slice { class: automation-slice }
    todo_db: TODO QueryDb { class: query-db }

    auto_slice -> todo_db: sync state { class: projection-flow }
  }

  read_side: Read Side {
    direction: down
    class: read-side

    view_slices_row: State View Slices {
      direction: right
      class: view-slices-area

      slice1: Slice 1 { class: state-view-slice }
      slice2: Slice 2 { class: state-view-slice }
      slice3: Slice 3 { class: state-view-slice }
    }

    query_dbs_row: Query DBs {
      direction: right
      class: query-dbs-area

      db1: Query DB { class: query-db }
      db2: Query DB { class: query-db }
      db3: Query DB { class: query-db }
    }

    view_slices_row.slice1 -> query_dbs_row.db1: project state { class: projection-flow }
    view_slices_row.slice2 -> query_dbs_row.db2: project state { class: projection-flow }
    view_slices_row.slice3 -> query_dbs_row.db3: project state { class: projection-flow }
  }

  # ── Edges ──────────────────────────────────────────────────────────────────

  client.client -> graphql.api: GraphQL mutations { class: command-flow }
  graphql.api -> write_side.cmd_topic: commands { class: command-flow }
  graphql.api -> read_side.query_dbs_row.db3: queries
  write_side.event_topic -> read_side.view_slices_row: events { class: event-flow }
  write_side.event_topic -> automation.auto_slice: events { class: event-flow }
  automation.auto_slice -> write_side.cmd_topic: commands { class: command-flow }
  plugins.ext_point -> write_side.cmd_topic: commands { class: cross-plugin }
  scheduling.heartbeat -> plugins.ext_point: periodic signals { class: event-flow }
  scheduling.scheduler -> write_side.cmd_topic: scheduled commands { class: command-flow }
}
```

- **Command Flow**: Client → API → CommandTopic → StateChangeSlices (routed by command type)
- **Write Side**: Each StateChangeSlice reads from and appends to the shared DcbEventLog with optimistic concurrency
- **Event Flow**: DcbEventLog → EventTopic → StateViewSlice → QueryDb
- **Automation**: AutomationSlice consumes events, maintains a TODO list, and issues commands back to CommandTopic
- **Read Side**: StateViewSlice projects events directly into QueryDb, replacing the EventCollector + ReadModel pair
- **Plugin System**: Cross-plugin communication via ExtensionPoints and Extensions
- **Scheduling**: Time-based command generation and health monitoring

### Aggregate

[*Aggregate*s](https://www.martinfowler.com/bliki/DDD_Aggregate.html) are the transactional units in your system.  
An Aggregate receives Commands and outputs Events based on the current State. A single Command can result in _any number_ of Events.  
Only the Aggregate's Events will be stored. If a new Command gets handled the actual State will be calculated based on the previous Events ([Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)). The current State will never be persisted to storage.

```d2
direction: right

command: Command { class: msg-command }
aggregate: Aggregate { class: aggregate }
event: Event { class: msg-event }

command -> aggregate: 1 { class: command-flow }
aggregate -> event: many { class: event-flow }
```

- **responsibility**: ensure only valid Commands create Events having the necessary information attached; emit Events
- **in**: Command
- **out**: Events

[Read more about the Aggregate component.](./components/aggregate.md)

### AutomationSlice

The **AutomationSlice** implements the Event Modeling **Automation** pattern (TODO List Pattern) for DCB-based plugins. It subscribes to a shared DcbEventLog, accumulates pending work items into a TODO list, processes them exactly once by issuing commands, and marks items as completed when resolution events arrive.

```d2
direction: right

events: Events { class: msg-event }
automation: AutomationSlice { class: automation-slice }
commands: Commands { class: msg-command }

events -> automation: collect { class: event-flow }
automation -> commands: process { class: command-flow }
events -> automation: resolve { class: event-flow }
```

- **responsibility**: collect pending work items from events; process each item exactly once; track completion via resolution events; provide retry and heartbeat semantics
- **in**: Events from DcbEventLog
- **out**: Commands to CommandTopic

[Read more about the AutomationSlice component.](./components/automationslice.md)

### EventLog

The **EventLog** is the foundational storage component for event sourcing in Reventless. It provides append-only event storage with efficient replay capabilities, ensuring that all domain events are durably persisted and can be replayed to reconstruct aggregate state.

```d2
direction: right

aggregate: Aggregate { class: aggregate }
event_log: EventLog { class: event-log }
event_topic: Event Topic { class: event-topic }

aggregate -> event_log: append events { class: event-flow }
event_log -> event_topic: publish events { class: event-flow }
event_log -> aggregate: replay events { class: replay }
```

- **responsibility**: durably store events in append-only fashion; provide event replay for aggregate state reconstruction; publish events to EventTopic for distribution
- **in**: Events from Aggregate (via `append` operation)
- **out**: Events to EventTopic (automatic); Events to Aggregate (via `replay` operation)

[Read more about the EventLog component.](./components/eventlog.md)

### DcbEventLog

The **DcbEventLog** (Dynamic Consistency Boundary Event Log) is the shared event storage component used by DCB state change slices. It provides tag-based querying and optimistic concurrency control for handling commands across multiple slices that share the same event log.

```d2
direction: right

slice1: Slice 1 { class: state-change-slice }
slice2: Slice 2 { class: state-change-slice }
dcb_log: DcbEventLog { class: dcb-event-log }
event_topic: Event Topic { class: event-topic }

slice1 -> dcb_log: append { class: event-flow }
slice2 -> dcb_log: append { class: event-flow }
dcb_log -> slice1: read/query { class: replay }
dcb_log -> slice2: read/query { class: replay }
dcb_log -> event_topic: publish events { class: event-flow }
```

- **responsibility**: tag-based event queries for decision model building; optimistic concurrency control; shared event storage for DCB slices
- **in**: Events from StateChangeSlices (via `append` operation)
- **out**: Events to EventTopic (automatic); Events to StateChangeSlices (via `read` operation)

[Read more about the DcbEventLog component.](./components/dcbeventlog.md)

### CommandTopic

The **CommandTopic** is the message queue component that delivers commands to Aggregates with strict ordering guarantees and reliable delivery. It ensures commands are processed exactly once per aggregate instance, in the order they were sent.

```d2
direction: right

api: API / CommandGenerator { class: command-generator }
event_mapper: Event Mapper { class: event-mapper }
cmd_topic: Command Topic { class: command-topic }
aggregate: Aggregate { class: aggregate }

api -> cmd_topic: command { class: command-flow }
event_mapper -> cmd_topic: commands { class: command-flow }
cmd_topic -> aggregate: commands { class: command-flow }
```

- **responsibility**: queue commands for delivery to Aggregates; ensure FIFO ordering per aggregate; provide exactly-once delivery guarantees; handle retries and dead letter processing
- **in**: Commands from API (via CommandGenerator), EventMapper, Extensions, or ExtensionPoints
- **out**: Commands to Aggregate command handlers

[Read more about the CommandTopic component.](./components/commandtopic.md)

### EventTopic

The **EventTopic** is the event distribution component that enables fan-out delivery of events to multiple subscribers. It receives events from the EventLog and distributes them to EventCollectors, which then deliver events to ReadModels, EventMappers, and SideEffectHandlers.

```d2
direction: right

event_log: EventLog { class: event-log }
event_topic: Event Topic { class: event-topic }
collector1: Event Collector 1 { class: event-collector }
collector2: Event Collector 2 { class: event-collector }
collector3: Event Collector 3 { class: event-collector }

event_log -> event_topic: publish events { class: event-flow }
event_topic -> collector1: fan-out { class: event-flow }
event_topic -> collector2: fan-out { class: event-flow }
event_topic -> collector3: fan-out { class: event-flow }
```

- **responsibility**: distribute events from EventLog to multiple subscribers; enable fan-out pattern for event-driven architecture; provide ordering guarantees per aggregate
- **in**: Events from EventLog (via `publish` operation)
- **out**: Events to EventCollectors (via SNS subscriptions)

[Read more about the EventTopic component.](./components/eventtopic.md)

### EventCollector

The **EventCollector** is the event consumption component that receives events from EventTopics. It provides a unified interface for components like ReadModels, EventMappers, and SideEffectHandlers to consume events with ordering guarantees.

```d2
direction: right

topic1: Event Topic 1 { class: event-topic }
topic2: Event Topic 2 { class: event-topic }
collector: Event Collector { class: event-collector }
read_model: Read Model { class: read-model }
event_mapper: Event Mapper { class: event-mapper }
side_effect_handler: Side Effect Handler { class: side-effect }

topic1 -> collector: events { class: event-flow }
topic2 -> collector: events { class: event-flow }
collector -> read_model: events { class: event-flow }
collector -> event_mapper: events { class: event-flow }
collector -> side_effect_handler: events { class: event-flow }
```

- **responsibility**: subscribe to EventTopics; buffer events; deliver events to handlers with ordering guarantees; handle retries and dead letter processing
- **in**: Events from EventTopics
- **out**: Events to ReadModel projections, EventMapper mappings, or SideEffectHandler functions

[Read more about the EventCollector component.](./components/eventcollector.md)

### QueryDb

The **QueryDb** is the read model storage component that provides efficient querying of projected state. It stores denormalized views of aggregate data, enabling fast queries without replaying events. QueryDb integrates with AWS AppSync for GraphQL APIs and supports configurable indexes, TTL, and batch operations.

```d2
direction: right

client: Client { class: client }
api: GraphQL API { class: api }
read_model: Read Model { class: read-model }
query_db: Query DB { class: query-db }

client -> api: request { class: command-flow }
api -> query_db: query
read_model -> query_db: save/update { class: projection-flow }
```

- **responsibility**: store projected read model state; provide efficient query operations; support multiple access patterns via indexes; integrate with GraphQL APIs; handle automatic data expiration via TTL
- **in**: State updates from ReadModel projections (via `save`, `saveBatch` operations)
- **out**: Query results to API resolvers (via `load` operation)

[Read more about the QueryDb component.](./components/querydb.md)

### CommandGenerator

The **CommandGenerator** bridges the gap between external clients and event-sourced aggregates by transforming GraphQL mutations into Reventless commands. It enables web and mobile applications to interact with aggregates through a type-safe GraphQL API.

```d2
direction: right

client: GraphQL Client { class: client }
api: GraphQL API { class: api }
cmd_gen: Command Generator { class: command-generator }
cmd_topic: Command Topic { class: command-topic }
aggregate: Aggregate { class: aggregate }

client -> api: GraphQL mutation { class: command-flow }
api -> cmd_gen: resolver invocation { class: command-flow }
cmd_gen -> cmd_topic: command { class: command-flow }
cmd_topic -> aggregate: command { class: command-flow }
```

- **responsibility**: transform GraphQL mutations into aggregate commands; validate and enrich command metadata; publish commands to CommandTopic; provide type-safe API for external clients
- **in**: GraphQL mutations from clients (via API Gateway/AppSync)
- **out**: Commands to target aggregate's CommandTopic

[Read more about the CommandGenerator component.](./components/commandgenerator.md)

### Counter

The **Counter** component provides atomic counting operations and deduplication capabilities for event processing. It's primarily used by EventMappers to prevent duplicate command generation and maintain accurate event processing metrics.

```d2
direction: right

event_mapper: Event Mapper { class: event-mapper }
counter: Counter { class: counter }

event_mapper -> counter: increment/check
counter -> event_mapper: count result
```

- **responsibility**: provide atomic increment/decrement operations; prevent duplicate event processing; maintain processing metrics; support conditional operations based on count values
- **in**: Count operations from EventMapper or other components
- **out**: Count results and deduplication status

[Read more about the Counter component.](./components/counter.md)

### ReadModel

A _ReadModel_ is a queryable persisted state: It takes Events from one or more Aggregates and persists a newly calculated state. The new state is based on the previous state and the incoming Event.

```d2
direction: right

event: Event { class: msg-event }
read_model: Read Model { class: read-model }

event -> read_model: many { class: event-flow }
```

- **responsibility**: create and persist State to be queried
- **in**: Events
- **out**: -

[Read more about the ReadModel component.](./components/readmodel.md)

### EventMapper

An EventMapper attached to an Aggregate maps Events of (potentially multiple Aggregates) to Commands for this Aggregate. This is always needed if some Event in one Aggregate needs to trigger a reaction in another.

```d2
direction: right

events: Events { class: msg-event }
event_mapper: EventMapper { class: event-mapper }
commands: Commands { class: msg-command }

events -> event_mapper: many { class: event-flow }
event_mapper -> commands: many { class: command-flow }
```

- **responsibility**: generate Commands for a given Aggregate based on (multiple) other Aggregates' Events
- **in**: Events
- **out**: Commands

[Read more about the EventMapper component.](./components/eventmapper.md)

### Task

Tasks are the "escape-hatch" of the dogmatic Command/Event paradigm. They allow to implement logic loosely coupled to Events (or even not at all). An example would be some calculation, which needs to be done in some specific interval.

Another intention of Tasks is to interface with the outside world (e.g. other systems). An example of this would be up-/downloads or calling foreign APIs.

Tasks may be implemented provider specific, since it's not possible to provide adapter for any possible scenario.

[Read more about the Task component.](./components/task.md)

### Scheduler

The Scheduler component provides time-based command publishing capabilities, enabling scheduled workflows, periodic tasks, and cron-like event generation. It allows applications to create and manage schedules dynamically at runtime.

```d2
direction: right

application: Application { class: client }
scheduler: Scheduler { class: scheduler }
cmd_topic: Command Topic { class: command-topic }

application -> scheduler: createSchedule { class: command-flow }
scheduler -> cmd_topic: triggers { class: command-flow }
```

- **responsibility**: manage time-based event scheduling and command publishing
- **in**: schedule definitions with timing patterns and payloads
- **out**: scheduled events/commands published to configured targets

[Read more about the Scheduler component.](./components/scheduler.md)

### Heartbeat

The Heartbeat component provides periodic health check signals and keepalive mechanisms, specifically designed to integrate with the Core Plugin's ExtensionPoint system. It enables health monitoring, periodic extension invocations, and watchdog timer functionality.

```d2
direction: right

cloudwatch: CloudWatch Events { class: scheduler }
lambda: Lambda { class: heartbeat }
core_plugin: Core Plugin { class: extension-point }

cloudwatch -> lambda: triggers
lambda -> core_plugin: heartbeat { class: event-flow }
```

- **responsibility**: generate periodic heartbeat signals for health monitoring and extension triggering
- **in**: timeout configuration and Core Plugin connection details
- **out**: periodic heartbeat messages sent to Core Plugin ExtensionPoint

[Read more about the Heartbeat component.](./components/heartbeat.md)

#### SideEffectHandler

A `SideEffectHandler` is similar to an `EventMapper`, but targeting `Task`s (and functions) outside of the Command/Event paradigm. For example: calling a foreign API everytime a specific `Event` occurs.
It takes `Event`s of (potentially multiple) `Aggregate`s as input and calls functions dependent on the `Event`.

```d2
direction: right

events: Events { class: msg-event }
side_effect_handler: SideEffectHandler { class: side-effect }
task: Task { class: task }

events -> side_effect_handler: many { class: event-flow }
side_effect_handler -> task: calls
```

- **responsibility**: execute `functions` of a given `task` based on (multiple) `aggregate`s' `Events`
- **in**: `Event`s
- **out**: -

[Read more about the SideEffectHandler component.](./components/sideeffecthandler.md)

### Plugin

A `Plugin` usually corresponds to a [`Bounded Context`](https://www.martinfowler.com/bliki/BoundedContext.html) in `DDD` (Domain Driven Design) as well to a single deployment unit. A `Plugin` is defined by it's configuration (name, version, etc) and it's child-components (`Aggregate`s, `ReadModel`s, `Task`s, etc)

[Read more about the Plugin component.](./components/plugin.md)

### ExtensionPoint

`ExtensionPoint`s (together with their relatign `Extension`s) are the mechanics to share data between several `Plugin`s. The `ExtensionPoint`'s `Spec` defines the `Event`s, which will be sent and the `Command`s which will be received by it.

[Read more about the ExtensionPoint component.](./components/extensionpoint.md)

#### ExtensionPointMapping

An `ExtensionPointMapping` defines a `Plugin`s border. It maps `Event`s from single `Aggregate`s to `Event`s of the `ExtensionPoint`. These are totally different Events (and therefore types), although they may seem similar. This is done to decouple outside dependencies from changes of the plugin and provide a simple interface to interact with.
A `Command` sent to the `ExtensionPoint` will be mapped to a specific `Command` inside the plugin by this component.

- **responsibility**: map plugin specific Command & Events to those of the `ExtensionPoint`
- **in**: `Plugin` sepcific `Event`s (from inside the `Plugin`) / `ExtensionPoint` Command`s (from `Extension`s)
- **out**: `ExtensionPoint` `Event`s (to `Extension`s) / `Plugin` specific `Command`s (to components inside the `Plugin`)

### Extension

An `Extension` enables a `Plugin` to consume events from and send commands to another `Plugin`'s `ExtensionPoint`. It acts as the consumer side of cross-Plugin communication, translating external events into internal commands and optionally forwarding internal events back to the `ExtensionPoint`.

```d2
direction: right

ext_point: ExtensionPoint { class: extension-point }
extension: Extension { class: extension }
aggregate: Aggregate { class: aggregate }

ext_point -> extension: events { class: event-flow }
extension -> aggregate: commands { class: command-flow }
aggregate -> extension: events { class: event-flow }
extension -> ext_point: commands { class: cross-plugin }
```

- **responsibility**: consume events from remote `ExtensionPoint`s and generate commands for local `Aggregate`s; optionally forward local events back to `ExtensionPoint`s
- **in**: `ExtensionPoint` `Event`s (from remote `Plugin`s)
- **out**: `Aggregate` `Command`s (to local `Aggregate`s) / `ExtensionPoint` `Command`s (to remote `Plugin`s)

[Read more about the Extension component.](./components/extension.md)

#### ExtensionMapping

An `ExtensionMapping` defines how a `Plugin` interacts with a remote `ExtensionPoint`. It maps incoming `ExtensionPoint` `Event`s to local `Aggregate` `Command`s and optionally maps outgoing `Aggregate` `Event`s to `ExtensionPoint` `Command`s.

- **responsibility**: translate between remote `ExtensionPoint` events/commands and local `Aggregate` commands/events
- **in**: `ExtensionPoint` `Event`s (from remote `Plugin`) / `Aggregate` `Event`s (from local `Aggregate`s)
- **out**: `Aggregate` `Command`s (to local `Aggregate`s) / `ExtensionPoint` `Command`s (to remote `Plugin`)

[Read more about Extension Mappings.](./components/extension.md#extension-mappings)
