---
title: Aggregate-Based Plugin
date: 2025-01-01
draft: false
sidebar_position: 4
---

# Aggregate-Based Plugin

An Aggregate-Based Plugin uses the traditional Domain-Driven Design Aggregate pattern. Each aggregate maintains its own private event stream and processes commands sequentially against a state machine.

## When to Use

Choose the Aggregate-Based approach when:
- You need strong consistency within a single aggregate
- Commands are processed one at a time per aggregate instance
- You have clear, isolated bounded contexts
- A simpler consistency model is preferred

## Architecture

```d2
Client: Client { class: client }
CommandTopic: "Command Topic\n(SQS FIFO)" { class: command-topic }
Handler: "Command Handler\n(Lambda)" { class: aggregate }
Aggregate: "Aggregate\n(State Machine)" { class: aggregate }
EventLog: "Event Log\n(DynamoDB)" { class: event-log }
EventTopic: "Event Topic\n(DynamoDB Streams)" { class: event-topic }
ReadModel: "Read Model\n(Lambda + DynamoDB)" { class: read-model }
EventMapper: "Event Mapper\n(Lambda)" { class: event-mapper }
OtherCommandTopic: Other Command Topic { class: command-topic }

Client -> CommandTopic: { class: command-flow }
CommandTopic -> Handler: { class: command-flow }
Handler -> Aggregate: { class: command-flow }
Aggregate -> EventLog: { class: event-flow }
EventLog -> EventTopic: { class: event-flow }
EventTopic -> ReadModel: { class: projection-flow }
EventTopic -> EventMapper: { class: event-flow }
EventMapper -> OtherCommandTopic: { class: command-flow }
```

## Building an Aggregate-Based Plugin

The following example builds a **CatalogItem** plugin step by step. A catalog item can be created, updated, and archived.

### Step 1: Define the Aggregate Spec

The Spec defines the aggregate's **identity**, **commands**, **events**, and **errors**. It lives in its own file so both the behavior and any event mappings can reference it without creating circular dependencies.

```rescript
// CatalogItemSpec.res
@@reventless.spec

@schema
type command =
  | CreateItem({itemId: string, name: string, description: string})
  | UpdateItem({itemId: string, name: string, description: string})
  | ArchiveItem({itemId: string})

@schema
type event =
  | ItemCreated({itemId: string, name: string, description: string})
  | ItemUpdated({itemId: string, name: string, description: string})
  | ItemArchived({itemId: string})

@schema
type error =
  | ItemAlreadyExists
  | ItemNotFound
  | ItemAlreadyArchived
```

The `@@reventless.spec` annotation auto-injects `let name` (derived from filename), `module Id`, and `let moduleUrl`. The `@schema` annotation generates JSON serialization code via the [Sury `ppx`](./rescript-syntax.md#ppx). Every `command`, `event`, and `error` type must be annotated. See the [Reventless PPX Guide](/guides/reventless-ppx) for details.

### Step 2: Implement the Behavior

The Behavior implements the aggregate's state machine. It defines three values:

- **`initialState`** — the starting state before any events have been applied (represents a "not yet created" instance)
- **`evolve`** — calculates the next state from the current state and an event; called once per historic event during replay
- **`decide`** — takes the current state and a command, returns `result<array<event>, error>`; `Ok([...events])` accepts the command, `Error(err)` rejects it

```rescript
// CatalogItemBehavior.res
@@reventless.behavior

// The internal state of a catalog item
@schema
type state =
  | NotCreated
  | Active({name: string, description: string})
  | Archived

let initialState = NotCreated

// Evolve state by applying an event
let evolve = (state, event) =>
  switch (state, event) {
  | (_, CatalogItemSpec.ItemCreated({name, description})) => Active({name, description})
  | (Active(_), CatalogItemSpec.ItemUpdated({name, description})) => Active({name, description})
  | (Active(_), CatalogItemSpec.ItemArchived(_)) => Archived
  | _ => state
  }

// Decide whether to accept or reject a command
let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, CatalogItemSpec.CreateItem({itemId, name, description})) =>
    Ok([CatalogItemSpec.ItemCreated({itemId, name, description})])
  | (NotCreated, _) =>
    Error(CatalogItemSpec.ItemNotFound)
  | (Active(_), CatalogItemSpec.CreateItem(_)) =>
    Error(CatalogItemSpec.ItemAlreadyExists)
  | (Active(_), CatalogItemSpec.UpdateItem({itemId, name, description})) =>
    Ok([CatalogItemSpec.ItemUpdated({itemId, name, description})])
  | (Active(_), CatalogItemSpec.ArchiveItem({itemId})) =>
    Ok([CatalogItemSpec.ItemArchived({itemId})])
  | (Archived, _) =>
    Error(CatalogItemSpec.ItemAlreadyArchived)
  }
```

### Step 3: Define the ReadModel Spec

The ReadModel Spec defines the **shape of the read-side state** stored in the query database.

```rescript
// CatalogItemReadModelSpec.res
@@reventless.spec

@schema
type state = {
  itemId: string,
  name: string,
  description: string,
  archived: bool,
}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

### Step 4: Implement the Projection

The Projection maps aggregate events to actions on the read model. Use `Projection.Mapping.Make` with three arguments: the **source spec**, the **target read model spec**, and an anonymous module with a `map` function.

```rescript
// CatalogItemProjection.res
open Reventless.Projection

module ItemMapping = Reventless.Projection.Mapping.Make(
  CatalogItemSpec,         // Source: name, Id, @schema type event
  CatalogItemReadModelSpec, // Target: name, Id, @schema type state, subIdConfig
  {
    // map receives {id, meta, event} and returns a single Projection action
    let map = ({event, id, meta: _}) =>
      switch event {
      | CatalogItemSpec.ItemCreated({name, description}) =>
        Set(id, {CatalogItemReadModelSpec.itemId: id, name, description, archived: false})
      | CatalogItemSpec.ItemUpdated({name, description}) =>
        Update(id, state => {...state, name, description})
      | CatalogItemSpec.ItemArchived(_) =>
        Update(id, state => {...state, archived: true})
      }
  },
)

// Create a helper to generate the Mapping module type for this read model
module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)

// The concrete mappings list used when assembling the plugin
let mappings: array<module(MappingsHelper.Mapping)> = [module(ItemMapping)]
```

The available `action` variants are: `Create`, `Set`, `Update`, `UpdateWithDefault`, `Delete`, `DeleteIf`, `Ignore`, and others. See `Reventless.Projection` for the full list.

### Step 5: Define Event Mappings (Optional)

Event Mappings let one aggregate's events trigger commands in another aggregate. Implement `Reventless.EventMapping.T`:

```rescript
// CatalogItemEventMapping.res

// When an item is created, notify another aggregate
module ItemCreatedMapping: Reventless.EventMapping.T = {
  module Source = CatalogItemSpec    // source aggregate: name, Id, @schema type event
  module Target = NotificationSpec   // target aggregate: name, Id, @schema type command

  let map = (id, event, _queryEngine) =>
    switch event {
    | CatalogItemSpec.ItemCreated({name}) =>
      let notificationId = id->Reventless.Id.String.toString
      [
        Reventless.EventMapping.Publish(
          Reventless.Id.String.makeFromString(notificationId),
          NotificationSpec.SendCreationAlert({message: `New item "${name}" is available`}),
        ),
      ]
    | _ => []
    }
}

// Package mappings into the EventMapper.Mappings module type
module EventMappings: Reventless.EventMapper.Mappings with module Target := NotificationSpec = {
  module Target = NotificationSpec
  module type Mapping = Reventless.EventMapping.T with module Target := NotificationSpec
  let mappings = [module(ItemCreatedMapping: Mapping)]
  let counter = None
}
```

If you have no event mappings, use `Reventless.NoEventMappings.Make(CatalogItemSpec)`.

### Step 6: Assemble the Plugin

The Plugin is assembled as a **[module function](./rescript-syntax.md#functors) over `Platform.T`**. This keeps your application code decoupled from the AWS infrastructure—only the composition root imports `reventless-aws`.

```rescript
// CatalogItemPlugin.res
// Imports only `reventless-spec`, not `reventless` or `reventless-aws`

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Build the aggregate component from spec + behavior + event mappings
  module ItemAggregate = Platform.Aggregate.Make(
    CatalogItemSpec,
    CatalogItemBehavior,
    Reventless.NoEventMappings.Make(CatalogItemSpec),
  )

  // Wire the read model projection into a concrete Mappings module
  module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)
  module Mappings: Reventless.Projection.Mappings with module Target := CatalogItemReadModelSpec = {
    module Target = CatalogItemReadModelSpec
    module type Mapping = MappingsHelper.Mapping
    let mappings = CatalogItemProjection.mappings
  }

  // Build the read model component from spec + mappings
  module ItemReadModel = Platform.ReadModel.Make(CatalogItemReadModelSpec, Mappings)
}
```

## Deploying the Plugin

The composition root is the only file that imports `reventless-aws`. It instantiates the Platform with AWS config and passes it to the [plugin module function](./rescript-syntax.md#functors), then calls `ReventlessAws.Plugin.make` to create the Pulumi infrastructure.

```rescript
// index.res — composition root

// Create the AWS platform (wires DynamoDB, Lambda, SQS, SNS, etc.)
module Platform = ReventlessAws.Platform.Make(Config)

// Instantiate the plugin module function with the AWS platform
module App = CatalogItemPlugin.Make(Platform)

// Deploy the plugin as a Pulumi component resource
Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
)
```

## Next Steps

- [Plugin System Overview](./plugin-system.md) - Understand the full plugin system
- [DCB-Based Plugin](./dcb-based-plugin.md) - Learn about the alternative DCB approach
