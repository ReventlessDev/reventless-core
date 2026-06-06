---
title: CommandGenerator
sidebar_position: 7
---

# CommandGenerator — Local

**Source:** `reventless-local/src/adapter/CommandGenerator/LocalCommandGeneratorResolvers.res`

**AWS equivalent:** [CommandGenerator → AppSync](/infrastructure/aws/adapters/commandgenerator)

## How It Works

The Local CommandGenerator is a lightweight adapter. The `handleResolversEvent` function wraps the `commandGenerator` callback in a `Pulumi.Output.make` — the event is passed directly to the generator function.

The `make` function is a no-op that returns no resources (no AppSync API to create).

In practice, the Local platform uses `CommandGeneratorResolvers_GraphQL` instead, which registers GraphQL mutation resolvers on the built-in GraphQL server.

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| API | Built-in GraphQL server (port 4000) | AppSync GraphQL API |
| Resolvers | Direct function binding | AppSync DynamoDB resolvers |
| Authentication | None | AppSync API key / IAM |
