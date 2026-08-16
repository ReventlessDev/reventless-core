---
title: Component Overview
draft: false
---

## Plugin with Aggregates

The following diagram shows how all components work together in a plugin using Aggregates:

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

## Plugin with DCB Slices

The following diagram shows how the components work together in a plugin using DCB Slices (Dynamic Consistency Boundary). The key differences from the Aggregate approach are the shared **DcbEventLog** across all StateChangeSlices and the **StateViewSlice** that combines the EventCollector and ReadModel roles.

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

  automation: Automation & Translation {
    direction: down
    class: automation-slices-area

    auto_slice: Automation Slice { class: automation-slice }
    outbound_slice: Outbound Translation { class: automation-slice }
    inbound_slice: Inbound Translation { class: automation-slice }
    todo_db: TODO QueryDb { class: query-db }
    external: External System { class: external-system }

    auto_slice -> todo_db: sync state { class: projection-flow }
    outbound_slice -> todo_db: sync state { class: projection-flow }
    outbound_slice -> external: "translate (API call)"
    external -> inbound_slice: "external input"
    inbound_slice -> todo_db: audit log { class: projection-flow }
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
  write_side.event_topic -> automation.outbound_slice: events { class: event-flow }
  write_side.event_topic -> automation.inbound_slice: events { class: event-flow }
  automation.outbound_slice -> write_side.cmd_topic: "commands (optional)" { class: command-flow }
  automation.inbound_slice -> write_side.cmd_topic: commands { class: command-flow }
  scheduling.scheduler -> write_side.cmd_topic: scheduled commands { class: command-flow }
}
```

- **Command Flow**: Client → API → CommandTopic → StateChangeSlices (routed by command type)
- **Write Side**: Each StateChangeSlice reads from and appends to the shared DcbEventLog with optimistic concurrency
- **Event Flow**: DcbEventLog → EventTopic → StateViewSlice → QueryDb
- **Automation**: AutomationSlice consumes events, maintains a TODO list, and issues commands back to CommandTopic
- **Outbound Translation**: OutboundTranslationSlice consumes events, calls external systems, and optionally publishes commands back
- **Inbound Translation**: InboundTranslationSlice receives external input (webhooks, API calls), validates and translates it into domain commands
- **Read Side**: StateViewSlice projects events directly into QueryDb, replacing the EventCollector + ReadModel pair
- **Plugin System**: Cross-plugin communication via ExtensionPoints and Extensions
- **Scheduling**: Time-based command generation and health monitoring

> **Live updates.** A QueryDb table can stream its changes to subscribed clients: the QueryDb
> stream feeds a **StateTopic** Lambda that publishes to the AppSync Events API. See
> [AppSync Events live updates](/infrastructure/appsync-events-live-updates) for the wire path.

## Component reference

Each component is documented in detail on its own page. The table below is a one-line map;
follow the link for types, operations, and examples.

### Write side

| Component | Role | Details |
|---|---|---|
| **Aggregate** | Transactional unit: handles a command against replayed state, emits events to its own EventLog | [aggregate](./components/aggregate.md) |
| **StateChangeSlice** | DCB equivalent of an Aggregate: decides against a tag-scoped read of the shared DcbEventLog and appends with optimistic concurrency | [statechangeslice](./components/statechangeslice.md) |
| **EventLog** | Append-only per-aggregate event storage with replay; publishes to EventTopic | [eventlog](/framework/runtime-components/eventlog) |
| **DcbEventLog** | Shared, tag-queryable event store for DCB slices, with optimistic concurrency | [dcbeventlog](/framework/runtime-components/dcbeventlog) |
| **CommandTopic** | FIFO command queue: in-order delivery per entity, deduplicated publishes, at-least-once processing | [commandtopic](/framework/runtime-components/commandtopic) |
| **CommandGenerator** | Turns GraphQL mutations into commands published to a CommandTopic | [commandgenerator](/framework/runtime-components/commandgenerator) |

### Read side

| Component | Role | Details |
|---|---|---|
| **ReadModel** | Projects events from one or more Aggregates into persisted, queryable state | [readmodel](./components/readmodel.md) |
| **StateViewSlice** | DCB equivalent of a ReadModel: projects DcbEventLog events directly into a QueryDb (no separate EventCollector) | [stateviewslice](./components/stateviewslice.md) |
| **QueryDb** | Stores denormalized read-model state; serves API queries; supports indexes and TTL | [querydb](/framework/runtime-components/querydb) |
| **EventTopic** | Fans events out from an EventLog to multiple EventCollectors | [eventtopic](/framework/runtime-components/eventtopic) |
| **EventCollector** | Subscribes to EventTopics and delivers ordered events to ReadModels, EventMappers, and SideEffectHandlers | [eventcollector](/framework/runtime-components/eventcollector) |

### Reactions, automation & translation

| Component | Role | Details |
|---|---|---|
| **EventMapper** | Maps events (from one or more Aggregates) to commands for a target Aggregate | [eventmapper](/framework/runtime-components/eventmapper) |
| **AutomationSlice** | DCB Automation (TODO-list) pattern: collects work from events, issues commands once, tracks resolution | [automationslice](./components/automationslice.md) |
| **InboundTranslationSlice** | Anti-corruption layer: validates external input (webhooks/APIs) and translates it into domain commands | [inboundtranslationslice](./components/inboundtranslationslice.md) |
| **OutboundTranslationSlice** | Calls external services per event with per-item retry; optionally publishes commands back | [outboundtranslationslice](./components/outboundtranslationslice.md) |
| **SideEffectHandler** | Like an EventMapper but targets Tasks/functions outside the command/event paradigm | [sideeffecthandler](./components/sideeffecthandler.md) |
| **Task** | Escape hatch for logic loosely coupled to events — interval jobs, uploads, foreign API calls | [task](./components/task.md) |
| **Counter** | Atomic counts and dedup, used by EventMappers to avoid duplicate command generation | [counter](/framework/runtime-components/counter) |

### Cross-plugin & platform

| Component | Role | Details |
|---|---|---|
| **Plugin** | A bounded context and deployment unit grouping the components above | [plugin](./components/plugin.md) |
| **ExtensionPoint** | A plugin's outbound contract: maps internal events to a stable public event vocabulary | [extensionpoint](./components/extensionpoint.md) |
| **Extension** | A plugin's inbound subscription: maps a remote ExtensionPoint's events to local commands | [extension](./components/extension.md) |
| **Scheduler** | Time-based command publishing for scheduled/periodic workflows | [scheduler](/framework/runtime-components/scheduler) |
| **Heartbeat** | Periodic health/keepalive signals into the Platform Admin's Plugin ExtensionPoint | [heartbeat](/framework/runtime-components/heartbeat) |
