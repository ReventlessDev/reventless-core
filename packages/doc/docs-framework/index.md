---
title: Framework Developer Guide
sidebar_position: 1
---

# Reventless — Framework Developer Guide

This guide is for contributors to the **`reventless`** package — the cloud-agnostic framework core that application developers build on top of.

If you are building an application with Reventless, see the [App Developer Guide](/app). If you are writing a new cloud provider adapter package, see the [Cloud Provider Guide](/cloud-provider).

## What the Framework Is

The `reventless` package defines:

- **Component module types** (`Aggregate.T`, `ReadModel.T`, `Plugin.T`, etc.) — the contracts that all implementations must satisfy
- **Builder functors** (`Aggregate_Builder.Make`, `ReadModel_Builder.Make`, etc.) — generic implementations parameterized over adapter interfaces
- **Adapter interfaces** (`EventLog_Adapter.Storage`, `CommandTopic_Adapter.Channel`, etc.) — the contracts that cloud providers must implement
- **Spec types** (`Aggregate.Spec`, `ReadModel.Spec`, etc.) — the contracts that application developers implement

The framework itself does not depend on any cloud provider. All infrastructure concerns are injected through adapter interfaces.

## Repository Structure

```
packages/
├── reventless-spec/    # Type specs and shared interfaces (no impl)
├── reventless/         # Framework core (this package)
│   └── src/
│       ├── components/   # Component definitions and builders
│       │   ├── Aggregate/
│       │   ├── ReadModel/
│       │   ├── Plugin/
│       │   └── ...
│       └── adapter/      # Adapter interfaces and runtime builders
└── reventless-aws/     # AWS cloud provider implementation
```

## Key Abstractions

### Component Structure Pattern

Each component follows a consistent file structure:

- `Component.res` — type definitions (the `component` type, `outputs`, etc.)
- `Component_Builder.res` — the `Make` functor that constructs components
- `Component_Adapter.res` — adapter interfaces (Storage, Channel, etc.)
- `Component_Operations.res` — runtime business logic
- `Component_Callback.res` — runtime event/command handlers

See [Component Structure Pattern](./inner-workings/component-structure-pattern.md) for a full walkthrough using EventLog as an example.

### Pulumi.Output.t Wrapping

All infrastructure values are wrapped in `Pulumi.Output.t<'a>`. This separates deploy-time values (which may not be resolved yet) from runtime values. Adapter interfaces return `Pulumi.Output.t`-wrapped values; the framework composes them using `Pulumi.Output.apply`.

### Builder Pattern with Module Types

Components use first-class modules and functors for type-safe configuration:

```rescript
module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}

module Make = (Spec: Spec, Storage: Storage, Channel: Channel): T => { ... }
```

## Where to Start

1. [Get started](./get-started.md) — clone, build, and run tests
2. [Inner workings](./inner-workings/framework-inner-workings.md) — how the framework fits together
3. [Component structure](./inner-workings/component-structure-pattern.md) — the file pattern used across all components
4. [Messages](./inner-workings/messages.md) — how commands and events are serialized and routed
