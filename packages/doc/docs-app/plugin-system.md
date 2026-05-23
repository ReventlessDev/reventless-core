---
title: Plugin System
date: 2025-01-01
draft: false
sidebar_position: 6
---

# Plugin System

A **Plugin** is the fundamental deployment unit in Reventless. It encapsulates a bounded context—its aggregates, DCB slices, read models, extension points, and extensions—and produces the cloud infrastructure needed to run them.

## Overview

A plugin can contain any combination of the following building blocks:

- **[Aggregates](./aggregates.md)** — entity-scoped event logs with sequential command processing
- **[DCB Slices](./dcb-slices.md)** — shared event log with optimistic concurrency across entities
- **Read Models** — query-side projections of aggregate or slice events
- **Extension Points** — the plugin's public outbound interface (events out, commands in)
- **Extensions** — subscriptions to another plugin's Extension Point (events in, commands out)

These are not mutually exclusive. A single plugin can have aggregates for self-contained entities alongside DCB slices for cross-entity operations.

## The Platform Abstraction

The `Platform.T` module type is a factory interface that decouples your application code from infrastructure. Your plugin modules import only `reventless-spec`; the actual AWS wiring lives in `reventless-aws` and is applied at the **composition root**.

```
catalog/                          ← the plugin package
  src/
    Category/
      Aggregate/
        Category.res              ← spec   (@@reventless.spec)
        Category_Behavior.res     ← behavior (@@reventless.behavior)
      ReadModel/
        Categories.res            ← spec
        Categories_Projections.res ← mappings (@@reventless.mappings)
    Plugin.res                    ← GENERATED composition root, wraps everything in Make(Platform)
platform-aws/                     ← the composition root package
  src/
    Main.res                      ← imports reventless-aws, the only file that does
```

### Creating the AWS Platform

`ReventlessAws.Platform.Make` produces a `Platform.T` wired to DynamoDB, Lambda, SQS, SNS, and DynamoDB Streams:

```rescript
// Main.res — composition root
module Platform = ReventlessAws.Platform.Make(Config)
```

`Config` provides the AWS environment configuration (stack name, region, etc.).

### What Platform.T Provides

| Builder | Purpose |
|---------|---------|
| `Platform.Aggregate.Make(Spec, Behavior, EventMappings)` | Builds an aggregate component |
| `Platform.ReadModel.Make(Spec, Projections)` | Builds a read model component |
| `Platform.ReadModelStream.Make(Spec, Projections)` | Builds a stream-fed read model component |
| `Platform.StateChangeSlice.Make(Spec, Behavior)` | Builds a DCB write-side slice |
| `Platform.StateViewSliceStream.Make(Spec, Projection)` | Builds a DCB read-side view slice |
| `Platform.AutomationSlice.Make(Spec, Automation)` | Builds a DCB automation slice |
| `Platform.InboundTranslationSlice.Make(Spec, Translation)` | Builds a DCB inbound translation slice |
| `Platform.OutboundTranslationSlice.Make(Spec, Translation)` | Builds a DCB outbound translation slice |
| `Platform.ExtensionPoint.Make(Mapping)` | Builds an extension point |
| `Platform.Extension.Make(X.Mapping)` | Builds an extension |
| `Platform.Task.Make(Spec)` | Builds a task component |

## Plugin Assembly

All plugins follow the same pattern: a **module function** over `Platform.T` that builds components and calls `Plugin.make`. This file — `src/Plugin.res` — is **generated** by `generate-plugin` before each build by scanning the `src/` folders; you don't write it by hand:

```rescript
// Plugin.res — AUTO-GENERATED
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ... the generator pairs each spec with its body file via Platform builders ...

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~aggregates=[...],
      ~readModels=[...],
      ~extensionPoints=[...],
      ~extensions=[...],
    )
}
```

See [Aggregates](./aggregates.md) and [DCB Slices](./dcb-slices.md) for step-by-step guides.

### Composition Root (AWS-specific)

The composition root is the only file that imports `reventless-aws`. It instantiates the platform and passes it to every plugin:

```rescript
// Main.res
module Platform = ReventlessAws.Platform.Make(Config)
module Catalog = CatalogPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog)],
)
```

## Cross-Plugin Communication

Plugins communicate through **Extension Points** and **Extensions**. This keeps plugins fully decoupled — no direct imports, no shared event logs across plugin boundaries.

```d2
PluginA: "Plugin A (Provider)" {
  class: plugin-area
  Agg: Aggregate { class: aggregate }
  EPM: EP Mapping { class: event-mapper }
  EP: ExtensionPoint {
    class: extension-point-area
    ET: Event Topic { class: event-topic }
    CT: Command Topic { class: command-topic }
  }
  Agg -> EPM: internal event { class: event-flow }
  EPM -> EP.ET: mapped event { class: event-flow }
  EP.CT -> EPM: command { class: command-flow }
  EPM -> Agg: internal command { class: command-flow }
}

Admin: Platform Admin { class: plugin-area }

PluginB: "Plugin B (Consumer)" {
  class: plugin-area
  Ext: Extension { class: extension }
}

PluginA.EP.ET -> Admin: event { class: cross-plugin }
Admin -> PluginB.Ext: event { class: cross-plugin }
PluginB.Ext -> Admin: command { class: cross-plugin }
Admin -> PluginA.EP.CT: command { class: cross-plugin }
```

### Extension Point

An **ExtensionPoint** is the public outbound interface of a plugin. It:
- **Publishes events** translated from internal aggregate/slice events
- **Receives commands** from other plugins and routes them to internal aggregates

The EP's public contract (its `command`/`event`/`directive` types) lives in a spec package, declared with `@@reventless.spec`:

```rescript
// catalog-spec/src/Products_ExtensionPoint.res
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

An Extension Point Mapping file (in the plugin) translates internal events to that public contract. `PublishEvent`/`PublishCommand` are in scope via the PPX. Note `mapOutgoingEvent` is an **option**, and `PublishEvent` takes the entity **id** as its first argument:

```rescript
// ExtensionPoint/Products_ExtensionPointMapping.res
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter: the internal event subset this EP maps from.
// `name` MUST equal `<pluginName>DcbEventLog`.
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
```

The plugin generator registers it as `Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)` and passes it via `~extensionPoints`. See [ExtensionPoint component](./components/extensionpoint.md) for full documentation.

### Extension

An **Extension** connects a plugin to another plugin's Extension Point. It subscribes to the EP's events and can send commands back. The extension file declares a `module Mapping` with an `ExtensionPoint` (the EP spec), a `Delegate` (the local component to command), `mapIncomingEvent`, and `mapOutgoingEvent`. Actions are `PublishStateChangeSliceCommand` / `PublishAggregateCommand`:

```rescript
// Extension/Products_Extension.res — inside the Ordering plugin
// Subscribes to Catalog plugin's Products_ExtensionPoint
@@reventless.extension

module Mapping = {
  module ExtensionPoint = CatalogSpec.Products_ExtensionPoint
  module Delegate = SyncCatalogProduct // local StateChangeSlice to command

  open ExtensionPoint
  open SyncCatalogProduct
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ProductBecameAvailable({productId, name, price}) => [
        PublishStateChangeSliceCommand(SyncNewProduct({productId, name, price})),
      ]
    | ProductPriceChanged({productId, price}) => [
        PublishStateChangeSliceCommand(ChangeSyncedPrice({productId, price})),
      ]
    }

  let mapOutgoingEvent = None
}
```

The plugin generator registers it as `Platform.Extension.Make(Products_Extension.Mapping)` and passes it via `~extensions`. See [Extension component](./components/extension.md) for full documentation.

## Plugin.make Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `~name` | `string` | Yes | Plugin name (used for resource naming) |
| `~heartbeatInterval` | `int` | Yes | Seconds between heartbeat signals to the core |
| `~aggregates` | `array<module(Aggregate.T)>` | No | Aggregate components |
| `~readModels` | `array<module(ReadModel.T)>` | No | Read model components |
| `~extensionPoints` | `array<module(ExtensionPoint.T)>` | No | Public API surfaces for cross-plugin communication |
| `~extensions` | `array<module(Extension.Blueprint)>` | No | Extension blueprints — auto-merged by EP, named after the plugin |
| `~tasks` | `array<module(Task.T)>` | No | Scheduled or triggered tasks |
| `~stateChangeSlices` | `array<module(StateChangeSlice.T)>` | No | DCB write-side slices — sync (`CommandAccepted`/`CommandRejected`) by default; opt into async (FIFO, `CommandPending`) by adding `@@reventless.async` at the top of the slice spec file |
| `~stateViewSlices` | `array<module(StateViewSlice.T)>` | No | DCB read-side slices |
| `~automationSlices` | `array<module(AutomationSlice.T)>` | No | DCB automation slices |
| `~outboundTranslationSlices` | `array<module(OutboundTranslationSlice.T)>` | No | DCB outbound translation slices |
| `~inboundTranslationSlices` | `array<module(InboundTranslationSlice.T)>` | No | DCB inbound translation slices |
| `~opts` | `Pulumi.ComponentResource.options` | No | Pulumi parent/provider options |

## When to Use Which Pattern

| Aspect | Aggregates | DCB Slices |
|--------|------------|------------|
| Event log | One per entity | Single shared log |
| Consistency boundary | Per entity instance | Per command (optimistic) |
| Concurrency | Sequential per instance | Optimistic with retry |
| Cross-entity consistency | No | Yes |
| Best for | Independent entities | Related entities needing cross-boundary consistency |

## Next Steps

- [Aggregates](./aggregates.md) — step-by-step guide for the Aggregate pattern
- [DCB Slices](./dcb-slices.md) — step-by-step guide for the DCB pattern
- [ExtensionPoint component](./components/extensionpoint.md) — full ExtensionPoint reference
- [Extension component](./components/extension.md) — full Extension reference
