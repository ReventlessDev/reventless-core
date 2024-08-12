---
title: Reventless Components
date: 2022-09-27
draft: true
---

### Aggregate

[*Aggregate*s](https://www.martinfowler.com/bliki/DDD_Aggregate.html) are the entities in your system.  
An Aggregate receives Commands and outputs Events (or Errors) based on the current State. (`(Command + current State) => (new Event or Error)`). A single Command can result in *any number* of Events.  
Only the Aggregate's Events will be stored. If a new Command gets handled the actual State will be calculated based on the previous Events ([Event-Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)). The current State will never be persisted to storage.

```mermaid
graph LR
    Command((Command)):::Command -->|1| Aggregate:::aggregate -->|*| Events((Events)):::Event

    classDef Command stroke:#66f,color:#66f,fill:none;
    classDef Event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
```

- **responsibility**: ensure only valid Commands create Events having the necessary information attached; emit Events
- **in**: Command
- **out**: Events

[Read more about the Aggregate component.](./reventless-components/aggregate.md)

### ReadModel

A `ReadModel` is a queryable projection based on Events per `Aggregate` id. It takes `Event`s and persists a State calculated on the previous State and the incoming Event to some storage.

Usually a `ReadModel` doesn't have any outputs, although some infrastructure services may offer "lower level" data, which may be used in some provider specific `adapter`s.

```mermaid
graph LR
    Event((Event)):::Event -->|*| ReadModel:::readmodel

    classDef Command stroke:#66f,color:#66f,fill:none;
    classDef Event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
```

- **responsibility**: create and persist State to be queried
- **in**: `Event`s
- **out**: -

[Read more about the ReadModel component.](./rEventless-components/readmodel.md)

### EventMapper

One `EventMapper` maps `Event`s of (potentially multiple `Aggregate`s) to `Command`s for a single `Aggregate`. This is always needed if some occurrence in one `Aggregate` needs to trigger a reaction for another.

```mermaid
graph LR
    Events((Events)):::Event -->|*| EventMapper{EventMapper}:::Eventmapper -->|*| Commands((Commands)):::Command

    classDef Command stroke:#66f,color:#66f,fill:none;
    classDef Event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
    classDef Eventmapper fill:#66f,color:#fa0,stroke:#fa0;
```

- **responsibility**: generate `Commands` for a given `aggregate` based on (multiple) other `aggregate`s' `Events`
- **in**: `Event`s
- **out**: `Command`s

[Read more about the EventMapper component.](./rEventless-components/Eventmapper.md)

### Task

`Task`s are the "escape-hatch" of the dogmatic Command/Event paradigm. They allow to implement logic loosely coupled to Events (or even not at all). An example would be some calculation, which needs to be done in some specific interval.

Another intention of `Task`s is to interface with the outside world (e.g. other systems). An example of this would be up-/downloads or calling foreign APIs.

`Task`s may be implemented provider specific, since it's not possible to provide adapter for any possible scenario.

[Read more about the Task component.](./rEventless-components/task.md)

#### SideEffectHandler

A `SideEffectHandler` is similar to an `EventMapper`, but targeting `Task`s (and functions) outside of the Command/Event paradigm. For example: calling a foreign API everytime a specific `Event` occurs.
It takes `Event`s of (potentially multiple) `Aggregate`s as input and calls functions dependent on the `Event`.

```mermaid
graph LR
    Events((Events)):::Event -->|*| SideEffect{SideEffect}:::sideeffect -->|calls| Task>Task]:::task

    classDef Command stroke:#66f,color:#66f,fill:none;
    classDef Event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
    classDef Eventmapper fill:#66f,color:#fa0,stroke:#fa0;
    classDef sideeffect fill:#f4f,color:#fa0,stroke:#fa0;
    classDef task fill:#f4f,color:#333,stroke:#333;
```

- **responsibility**: execute `functions` of a given `task` based on (multiple) `aggregate`s' `Events`
- **in**: `Event`s
- **out**: -

[Read more about the SideEffectHandler component.](./rEventless-components/sideeffecthanlder.md)

### Plugin

A `Plugin` usually corresponds to a [`Bounded Context`](https://www.martinfowler.com/bliki/BoundedContext.html) in `DDD` (Domain Driven Design) as well to a single deployment unit. A `Plugin` is defined by it's configuration (name, version, etc) and it's child-components (`Aggregate`s, `ReadModel`s, `Task`s, etc)

[Read more about the Plugin component.](./rEventless-components/plugin.md)

### ExtensionPoint

`ExtensionPoint`s (together with their relatign `Extension`s) are the mechanics to share data between several `Plugin`s. The `ExtensionPoint`'s `Spec` defines the `Event`s, which will be sent and the `Command`s which will be received by it.

[Read more about the ExtensionPoint component.](./rEventless-components/extensionpoint.md)

#### ExtensionPointMapping
An `ExtensionPointMapping` defines a `Plugin`s border. It maps `Event`s from single `Aggregate`s to `Event`s of the `ExtensionPoint`. These are totally different Events (and therefore types), although they may seem similar. This is done to decouple outside dependencies from changes of the plugin and provide a simple interface to interact with.
A `Command` sent to the `ExtensionPoint` will be mapped to a specific `Command` inside the plugin by this component.

- **responsibility**: map plugin specific Command & Events to those of the `ExtensionPoint`
- **in**: `Plugin` sepcific `Event`s (from inside the `Plugin`) / `ExtensionPoint` Command`s (from `Extension`s)
- **out**: `ExtensionPoint` `Event`s (to `Extension`s) / `Plugin` specific `Command`s (to components inside the `Plugin`)

### Extension

> TODO

#### ExtensionMapping

> TODO
