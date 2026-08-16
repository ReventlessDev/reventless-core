---
title: Getting Started with Local
sidebar_position: 2
---

# Getting Started with reventless-local

This guide covers setting up and using the Local provider for local development and testing.

## Prerequisites

- Node.js 22.17.1 (see `.node-version`)
- ReScript development setup (see the [App Developer Guide](/app/get-started))

## Install Dependencies

```bash
pnpm add @reventlessdev/reventless-spec @reventlessdev/reventless-infra @reventlessdev/reventless-local sury
```

## Creating a Platform

The Local provider exposes a `Platform.Make()` functor that creates an isolated local platform:

```rescript
module Platform = ReventlessLocal.Platform.Make()
```

This creates a fresh `LocalBus`, wires all adapter builders, and starts the GraphQL and MCP servers after plugin construction.

`Make()` gives you: diagnostic warnings on, **split API**, no cloner, and the
backend taken from `REVENTLESS_LOCAL_BACKEND` (in memory when unset).

### Overriding the defaults

`MakeWithConfig` takes every field — there are no partial defaults, which is
deliberate: a config you can half-specify is a config nobody reads.

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
  let silent = true                       // suppress diagnostic warnings — for tests
  let splitApi = false                    // serve everything on one endpoint
  let cloner = false
  let backend = ReventlessLocal.Backend.Memory
  let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs = {}
})
```

`commandHandlerConfig` exists for parity with the AWS platform; its
Lambda-specific knobs are no-ops here.

### Split versus unified API

Split is the default. It puts the platform's own administrative schema on a
different endpoint from your application's:

| Service | Split (default) | Unified |
|---|---|---|
| Domain GraphQL | 4000 | 4000 |
| Platform/admin GraphQL | 4001 | 4000 |
| Domain MCP | 3001 | 3001 |
| Platform/admin MCP | 3002 | 3001 |

Keeping them apart gives you a boundary to restrict later, and means an AI
assistant pointed at the domain endpoint sees domain tools rather than platform
administration.

## Using in Tests

### Test Setup

Use `TestRunner.setup()` to activate Pulumi mock mode before creating components:

```rescript
// At the top of your test file
ReventlessLocal.TestRunner.setup()

module Platform = ReventlessLocal.Platform.MakeWithConfig({let silent = true; let splitApi = false})
module App = MyPlugin.Make(Platform)
```

### Resolving Outputs

Since components wrap operations in `Pulumi.Output.t`, use `TestRunner.resolve` to unwrap them in tests:

```rescript
let ops = await myComponent
  ->ReventlessCore.Component.operations
  ->ReventlessLocal.TestRunner.resolve
```

### Async Test Registration

The bus registers handlers asynchronously via `Output.apply`. Use `beforeAllAsync` to ensure handlers are registered before tests run:

```rescript
open ReventlessCore.AsyncTest

beforeAllAsync(async () => {
  let _ = await myComponent
    ->ReventlessCore.Component.operations
    ->ReventlessLocal.TestRunner.resolve
})
```

### Cleanup

Stop the GraphQL server in `afterAll`:

```rescript
afterAll(() => {
  ReventlessLocal.TestRunner.stopGraphQLServer()
})
```

## GraphQL server

The local platform starts its GraphQL servers automatically once all plugins are
constructed — the domain API on **port 4000**, and (in the default split mode)
the platform API on 4001. All mutation and query resolvers registered during plugin construction are available immediately.

Access it at `http://localhost:4000/graphql`.

## MCP Server

The MCP server starts alongside the GraphQL server, providing AI-native access to:
- **Tools** — mapped from GraphQL mutations (commands)
- **Resources** — mapped from GraphQL queries (read models) and event log history

## Next Steps

- [Local Provider Overview](./index.md) — architecture and service mappings
- [Infrastructure Overview](/infrastructure) — compare with the AWS provider
- [AWS Getting Started](/infrastructure/aws/get-started) — deploy to production on AWS
