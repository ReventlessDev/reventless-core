---
title: Component Relations
date: 2024-08-19
draft: true
---

:::note[TODO]

- adapt existing diagram to desired representation

:::

## Runtime Communication

```mermaid
flowchart LR
subgraph Plugin1 [Plugin 1]
  Plugin1Extension["Extension (out)"]
  Plugin1ExtensionPoint["Extension Point (out)"]
end

subgraph UiRequest [UI]
  UiClientRequest((Client))
end

subgraph Plugin
  Api[API]
  ExtensionIn["Extension (in)"]
  ExtensionOut["Extension (out)"]
  ExtensionPointIn["Extension Point (in)"]
  ExtensionPointOut["Extension Point (out)"]

  subgraph AggregateSub [Aggregate]
    Aggregate[Aggregate]:::aggregate
    CommandGenerator[Command Generator]
    CommandTopic[Command Topic]
    EventLog[Event Log]
    EventMapper[Event Mapper]
    EventTopic[Event Topic]

    Aggregate -->|event| EventLog
    EventLog -->|event| EventTopic
  end

  subgraph ReadModelSub [Read Model]
    ReadModel[Read Model]
    QueryDb[Query DB]

    ReadModel -->|state| QueryDb
  end

  subgraph Task
    SideEffectHandler[Side Effect Handler]

    SideEffectHandler -->|command| CommandTopic
    EventTopic -->|event| SideEffectHandler
  end

  Api -->|json| CommandGenerator
  CommandGenerator -->|command| CommandTopic
  CommandTopic -->|command| Aggregate
  EventMapper -->|command| CommandTopic
  EventTopic --->|event| ExtensionOut
  EventTopic --->|event| ExtensionPointOut
  EventTopic --->|event| ReadModel
  EventTopic -->|event| EventMapper
  ExtensionIn --->|command| CommandTopic
  ExtensionPointIn --->|command| CommandTopic
  Plugin1Extension -->|command| ExtensionPointIn
  Plugin1ExtensionPoint -->|event| ExtensionIn
  UiClientRequest -->|mutation| Api
end

subgraph Plugin2 [Plugin 2]
  Plugin2Extension["Extension (in)"]
  Plugin2ExtensionPoint["Extension Point (in)"]

  ExtensionOut --->|command| Plugin2Extension
  ExtensionPointOut --->|event| Plugin2ExtensionPoint
end

subgraph UiQuery [UI]
  UiClientQuery((Client))
  QueryDb <-->|query| UiClientQuery
end

```

## Pulumi Component Hierarchy

TODO
