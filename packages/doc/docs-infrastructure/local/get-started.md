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
npm install @reventless/reventless @reventless/local @reventless/spec
```

## Creating a Platform

The Local provider exposes a `Platform.Make()` functor that creates an isolated local platform:

```rescript
module Platform = ReventlessLocal.Platform.Make()
```

This creates a fresh `LocalBus`, wires all adapter builders, and starts the GraphQL and MCP servers after plugin construction.

### Silent Mode

For tests where you don't want diagnostic warnings (e.g., missing command handlers), use `MakeWithConfig`:

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
  let silent = true
  let splitApi = false
})
```

### Split API Mode

To serve core administrative schema (plugin management) and plugin business domain schema on separate ports:

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
  let silent = false
  let splitApi = true
})
```

When `splitApi = true`:
- **Plugin GraphQL** on port 4000 — business domain queries and mutations
- **Core GraphQL** on port 4001 — plugin management queries and mutations
- **Plugin MCP** on port 3001 — business domain tools and resources
- **Core MCP** on port 3002 — administrative tools and resources

When `splitApi = false` (default), all schema is served from the unified endpoints (port 4000 for GraphQL, port 3001 for MCP).

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

## GraphQL Server

The Local platform starts a GraphQL server on **port 4000** automatically after all plugins are constructed. All mutation and query resolvers registered during plugin construction are available immediately.

Access it at `http://localhost:4000/graphql`.

## MCP Server

The MCP server starts alongside the GraphQL server, providing AI-native access to:
- **Tools** — mapped from GraphQL mutations (commands)
- **Resources** — mapped from GraphQL queries (read models) and event log history

## Next Steps

- [Local Provider Overview](./index.md) — architecture and service mappings
- [Infrastructure Overview](/infrastructure) — compare with the AWS provider
- [AWS Getting Started](/infrastructure/aws/get-started) — deploy to production on AWS
