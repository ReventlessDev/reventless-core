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
packages/
  my-plugin/
    ProductSpec.res           ← only imports reventless-spec
    ProductBehavior.res       ← only imports reventless-spec
    ProductsProjections.res   ← only imports reventless (for Projection.Mapping.Make)
    CatalogPlugin.res         ← only imports reventless-spec, wraps in Make(Platform)
  infra/
    index.res                 ← imports reventless-aws, the only file that does
```

### Creating the AWS Platform

`ReventlessAws.Platform.Make` produces a `Platform.T` wired to DynamoDB, Lambda, SQS, SNS, and DynamoDB Streams:

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
| `Platform.StateChangeSlice.Make(Spec)` | Builds a DCB write-side slice |
| `Platform.StateViewSlice.Make(Spec)` | Builds a DCB read-side view slice |
| `Platform.DcbEventLog.Make(Spec)` | Builds a DCB event log (used internally) |
| `Platform.ExtensionPoint.Make(Mappings, Env)` | Builds an extension point |
| `Platform.Extension.Make(Mapping)` | Builds an extension |
| `Platform.Task.Make(Spec)` | Builds a task component |
| `Platform.Counter` | Pre-built counter component |

## Plugin Assembly

All plugins follow the same pattern: a **module function** over `Platform.T` that builds components and calls `Plugin.make`:

```rescript
// CatalogPlugin.res
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ... build components using Platform builders ...

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
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
// index.res
module Platform = ReventlessAws.Platform.Make(Config)
module App = CatalogPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
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

An Extension Point Mapping file defines the translation:

```rescript
// ProductsExtensionPointMapping.res
@@reventless.spec

// The spec (ProductsExtensionPoint) defines command/event/callCommand types
// The mapping translates between internal and external representations

module Delegate = ProductDemand  // internal aggregate to delegate commands to

let map = event =>
  switch event {
  | Product.Added({productId, name, price}) =>
    PublishEvent(ProductsExtensionPoint.ProductAdded({productId, name, price}))
  | _ => PublishEvent(ProductsExtensionPoint.Unchanged)
  }
```

Register it in the plugin:

```rescript
module ProductsEP = Platform.ExtensionPoint.Make(
  ProductsExtensionPointMapping,
  {let moduleUrl: string = %raw(`import.meta.url`)},
)
// ...
Platform.Plugin.make(~extensionPoints=[module(ProductsEP)], ...)
```

See [ExtensionPoint component](./components/extensionpoint.md) for full documentation.

### Extension

An **Extension** connects a plugin to another plugin's Extension Point. It subscribes to the EP's events and can send commands back.

```rescript
// OrdersExtension.res — inside the Catalog plugin
// Subscribes to Ordering plugin's OrdersExtensionPoint

module DemandMapping = {
  module Source = OrdersExtensionPoint  // the EP's spec package
  module Target = ProductDemand         // internal aggregate to command

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | OrdersExtensionPoint.OrderPlaced({items}) =>
      items->Array.map(item =>
        Reventless.EventMapping.Publish(
          item.productId->ProductDemand.Id.fromString,
          ProductDemand.RecordSale({orderId, quantity: item.quantity}),
        )
      )
    | _ => []
    }
}
```

Register it in the plugin:

```rescript
module OrdersExt = Platform.Extension.Make(OrdersExtension.DemandMapping)
// ...
Platform.Plugin.make(~extensions=[module(OrdersExt)], ...)
```

See [Extension component](./components/extension.md) for full documentation.

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
| `~stateChangeSlices` | `array<module(StateChangeSlice.T)>` | No | DCB write-side slices |
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
