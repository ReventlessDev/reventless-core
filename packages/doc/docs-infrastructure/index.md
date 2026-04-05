---
title: Providers
sidebar_position: 1
---

# Providers

Reventless is a **provider-agnostic** event-sourced CQRS framework. The core `reventless` package defines components and abstract adapter interfaces but contains no infrastructure code. **Providers** are packages that implement these adapter interfaces for a specific platform.

## What a Provider Does

A provider package:

1. **Implements adapter interfaces** — provides concrete implementations of `EventLog_Adapter.Storage`, `CommandTopic_Adapter.Channel`, `EventTopic_Adapter.Publisher`, and other adapter interfaces defined in `reventless`
2. **Provides pre-configured builders** — exports `Make` functors that wire the framework builders with provider-specific adapters, so application developers get a simple API
3. **Manages infrastructure** — creates the actual resources (tables, queues, topics, functions) needed to run the application

## The Two-Layer Model

Provider packages implement two layers:

- **Deploy-time** — creates infrastructure resources and returns `Pulumi.Output.t`-wrapped identifiers (ARNs, URLs, table names)
- **Runtime** — implements the actual data access logic that executes within handlers, consuming the resolved deploy-time values

For a deep dive into how this separation works, see the [Adapter Pattern](./adapter-pattern.md).

## Available Providers

### InMemory

**Package:** `reventless-in-memory`

The InMemory provider runs everything in a single process using in-memory data structures. No cloud infrastructure is needed.

**Use cases:**
- Local development and rapid prototyping
- Unit and integration testing with Jest
- Exploring the framework without cloud credentials

The InMemory provider includes a shared event bus (`InMemory_Bus`), a built-in GraphQL server, and an MCP server for AI-native access. All adapter interfaces are fully implemented.

[InMemory Provider Documentation &rarr;](./in-memory/)

### AWS

**Package:** `reventless-aws`

The AWS provider is the production-ready implementation, mapping Reventless components to AWS serverless services:

| Component | AWS Service |
|-----------|-------------|
| EventLog | DynamoDB |
| CommandTopic | SQS FIFO |
| EventTopic | SNS |
| QueryDb | DynamoDB |
| EventCollector | DynamoDB Streams / SQS |
| Task | S3 |
| Runtime | Lambda |

[AWS Provider Documentation &rarr;](./aws/)

## Future Providers

The adapter pattern makes it possible to implement Reventless on any serverless platform. Potential future providers include:

- **Azure** — Azure Functions, Cosmos DB, Service Bus, Event Grid
- **GCP** — Cloud Functions, Firestore, Pub/Sub, Cloud Tasks
- **Cloudflare Workers** — Workers, Durable Objects, Queues, R2

Community contributions are welcome. See [Scaffolding a Provider Package](./get-started.md) for how to create a new provider, and the [Adapter Pattern](./adapter-pattern.md) for the full interface checklist.
