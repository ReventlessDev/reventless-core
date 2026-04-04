---
title: Plugin System
date: 2025-01-01
draft: false
sidebar_position: 6
---

# Plugin System

A **Plugin** is the fundamental deployment unit in Reventless. It encapsulates a bounded context—its aggregates or DCB slices, read models, and optional extension points—and produces the cloud infrastructure needed to run them.

## Overview

Reventless supports two approaches for building plugins:

1. **[Aggregate-Based Plugin](./aggregate-based-plugin.md)** — Uses the traditional Aggregate pattern with a per-aggregate event log and sequential command processing
2. **[DCB-Based Plugin](./dcb-based-plugin.md)** — Uses Dynamic Consistency Boundaries with a shared event log and optimistic concurrency control

Both approaches follow the same assembly pattern: write **platform-agnostic specs** and **behaviors**, then wire them together using the `Platform` abstraction.

## The Platform Abstraction

The `Platform.T` module type is a factory interface that decouples your application code from infrastructure. Your plugin modules import only `reventless-spec`; the actual AWS wiring lives in `reventless-aws` and is applied at the **composition root**.

```
packages/
  my-plugin/
    CatalogItemSpec.res        ← only imports reventless-spec
    CatalogItemBehavior.res    ← only imports reventless-spec
    CatalogItemProjection.res  ← only imports reventless (for Projection.Mapping.Make)
    CatalogItemPlugin.res      ← only imports reventless-spec, wraps in Make(Platform)
  infra/
    index.res                  ← imports reventless-aws, the only file that does
```

### Creating the AWS Platform

`ReventlessAws.Platform.Make` is a **[module function](./rescript-syntax.md#functors)** that produces a `Platform.T` wired to DynamoDB, Lambda, SQS, SNS, and DynamoDB Streams:

```rescript
// index.res — composition root
module Platform = ReventlessAws.Platform.Make(Config)
```

`Config` provides the AWS environment configuration (stack name, region, etc.).

### What Platform.T Provides

| Builder | Purpose |
|---------|---------|
| `Platform.Aggregate.Make(Spec, Behavior, EventMappings)` | Builds an aggregate component |
| `Platform.ReadModel.Make(Spec, Mappings)` | Builds a read model component |
| `Platform.StateChangeSlice.Make(Spec)` | Builds a DCB state change slice |
| `Platform.StateViewSlice.Make(Spec)` | Builds a DCB state view slice |
| `Platform.DcbEventLog.Make(Spec)` | Builds a DCB event log (used internally) |
| `Platform.ExtensionPoint.Make(Mappings)` | Builds an extension point |
| `Platform.Task.Make(Spec)` | Builds a task component |
| `Platform.Counter` | Pre-built counter component |

## Aggregate-Based Plugin — Full Example

The following shows all the pieces in context for a `CatalogItem` aggregate.

### Specs and Behavior (app code)

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

```rescript
// CatalogItemBehavior.res
@@reventless.behavior

@schema
type state =
  | Active({name: string, description: string})
  | Archived

let init: Behavior.init<state, Spec.event> = event =>
  switch event {
  | CatalogItemSpec.ItemCreated({name, description}) => Active({name, description})
  | _ => throw(Message.InvalidEvent(event->Message.encode(CatalogItemSpec.eventSchema)))
  }

let apply: Behavior.apply<state, Spec.event> = (state, event) =>
  switch (state, event) {
  | (Active(_), CatalogItemSpec.ItemUpdated({name, description})) => Active({name, description})
  | (Active(_), CatalogItemSpec.ItemArchived(_)) => Archived
  | _ => throw(Message.InvalidEvent(event->Message.encode(CatalogItemSpec.eventSchema)))
  }

let create: Behavior.create<Spec.command, Spec.event, Spec.error> = (command, context, error) =>
  switch command {
  | CatalogItemSpec.CreateItem({itemId, name, description}) =>
    [CatalogItemSpec.ItemCreated({itemId, name, description})]
  | CatalogItemSpec.UpdateItem(_) | CatalogItemSpec.ArchiveItem(_) =>
    error(CatalogItemSpec.ItemNotFound, command, context)
  }

let execute: Behavior.execute<state, Spec.command, Spec.event, Spec.error> = (
  state, command, context, error,
) =>
  switch state {
  | Active(_) =>
    switch command {
    | CatalogItemSpec.CreateItem(_) => error(CatalogItemSpec.ItemAlreadyExists, command, context)
    | CatalogItemSpec.UpdateItem({itemId, name, description}) =>
      [CatalogItemSpec.ItemUpdated({itemId, name, description})]
    | CatalogItemSpec.ArchiveItem({itemId}) => [CatalogItemSpec.ItemArchived({itemId})]
    }
  | Archived =>
    switch command {
    | CatalogItemSpec.CreateItem(_) | CatalogItemSpec.UpdateItem(_) =>
      error(CatalogItemSpec.ItemAlreadyArchived, command, context)
    | CatalogItemSpec.ArchiveItem(_) => []
    }
  }
```

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

```rescript
// CatalogItemProjection.res
open Reventless.Projection

module ItemMapping = Reventless.Projection.Mapping.Make(
  CatalogItemSpec,
  CatalogItemReadModelSpec,
  {
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

module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)
let mappings: array<module(MappingsHelper.Mapping)> = [module(ItemMapping)]
```

### Plugin Assembly (app code, no AWS dependency)

```rescript
// CatalogItemPlugin.res
module Make = (Platform: Reventless.Platform.T) => {
  module ItemAggregate = Platform.Aggregate.Make(
    CatalogItemSpec,
    CatalogItemBehavior,
    Reventless.NoEventMappings.Make(CatalogItemSpec),
  )

  module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)
  module Mappings: Reventless.Projection.Mappings with module Target := CatalogItemReadModelSpec = {
    module Target = CatalogItemReadModelSpec
    module type Mapping = MappingsHelper.Mapping
    let mappings = CatalogItemProjection.mappings
  }

  module ItemReadModel = Platform.ReadModel.Make(CatalogItemReadModelSpec, Mappings)
}
```

### Composition Root (AWS-specific)

```rescript
// index.res
module Platform = ReventlessAws.Platform.Make(Config)
module App = CatalogItemPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
)
```

## DCB-Based Plugin — Full Example

```rescript
// ItemEventLogSpec.res
@@reventless.dcbTags

@schema
type event =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})
  | ItemDeleted({itemId: string})
```

```rescript
// ItemCatalogPlugin.res
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CreateItem = Platform.StateChangeSlice.Make(CreateItemSpec)
  module RenameItem = Platform.StateChangeSlice.Make(RenameItemSpec)
  module DeleteItem = Platform.StateChangeSlice.Make(DeleteItemSpec)
  module ItemView   = Platform.StateViewSlice.Make(ItemViewSpec)

  let make = () =>
    Platform.Plugin.make(
      ~name="ItemCatalog",
      ~heartbeatInterval=60,
      ~stateChangeSlices=[module(CreateItem), module(RenameItem), module(DeleteItem)],
      ~stateViewSlices=[module(ItemView)],
    )
}
```

```rescript
// index.res
module Platform = ReventlessAws.Platform.Make(Config)
module App = ItemCatalogPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
)
```

## Plugin.make Parameters

`ReventlessAws.Plugin.make` accepts the following parameters:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `~name` | `string` | Yes | Plugin name (used for resource naming) |
| `~heartbeatInterval` | `int` | Yes | Seconds between heartbeat signals to the core |
| `~aggregates` | `array<module(Aggregate.T)>` | No | Aggregate-based components |
| `~readModels` | `array<module(ReadModel.T)>` | No | Read model components (for aggregate-based plugins) |
| `~extensionPoints` | `array<module(ExtensionPoint.T)>` | No | Public API surfaces for cross-plugin communication |
| `~extensions` | `array<module(Extension.Blueprint)>` | No | Extension blueprints — auto-merged by EP, named after the plugin |
| `~tasks` | `array<module(Task.T)>` | No | Scheduled or triggered tasks |
| `~stateChangeSlices` | `array<module(StateChangeSlice.T)>` | No | DCB write-side slices |
| `~stateViewSlices` | `array<module(StateViewSlice.T)>` | No | DCB read-side slices |
| `~automationSlices` | `array<module(AutomationSlice.T)>` | No | DCB automation (TODO list) slices |
| `~outboundTranslationSlices` | `array<module(OutboundTranslationSlice.T)>` | No | DCB outbound translation slices |
| `~inboundTranslationSlices` | `array<module(InboundTranslationSlice.T)>` | No | DCB inbound translation slices |
| `~opts` | `Pulumi.ComponentResource.options` | No | Pulumi parent/provider options |

## When to Use Which Approach

| Aspect | Aggregate-Based | DCB-Based |
|--------|-----------------|-----------|
| Event log | One per aggregate | Single shared log |
| Consistency boundary | Per aggregate instance | Per command (optimistic) |
| Concurrency | Sequential per instance | Optimistic with retry |
| Complexity | Lower | Higher |
| Cross-entity consistency | No | Yes |
| Best for | Independent entities | Related entities needing cross-boundary consistency |

## Next Steps

- [Aggregate-Based Plugin Guide](./aggregate-based-plugin.md) - Step-by-step aggregate plugin walkthrough
- [DCB-Based Plugin Guide](./dcb-based-plugin.md) - Step-by-step DCB plugin walkthrough
