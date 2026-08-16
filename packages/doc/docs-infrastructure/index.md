---
title: Infrastructure & Providers
sidebar_position: 1
---

# Infrastructure & Providers

Reventless is a **provider-agnostic** event-sourced CQRS framework. The core `reventless-core` package defines components and abstract adapter interfaces but contains no infrastructure code. **Providers** are packages that implement these adapter interfaces for a specific platform.

> **Deploying an app?** Jump to **[AWS Provider](./aws/)** → [AWS Get Started](./aws/get-started.md)
> and the [Deployment Guide](./deployment-guide.md). For local runs, see the
> [Local Provider](./local/).
>
> **Writing a new provider?** Start at [Scaffolding a Provider Package](./scaffolding-a-provider.md)
> and the [Adapter Pattern](./adapter-pattern.md).

## What a Provider Does

A provider package:

1. **Implements adapter interfaces** — provides concrete implementations of `EventLog_Adapter.Storage`, `CommandTopic_Adapter.Channel`, `EventTopic_Adapter.Publisher`, and other adapter interfaces defined in `reventless-core`
2. **Provides pre-configured builders** — exports `Make` functors that wire the framework builders with provider-specific adapters, so application developers get a simple API
3. **Manages infrastructure** — creates the actual resources (tables, queues, topics, functions) needed to run the application

## The Two-Layer Model

Provider packages implement two layers:

- **Deploy-time** — creates infrastructure resources and returns `Pulumi.Output.t`-wrapped identifiers (ARNs, URLs, table names)
- **Runtime** — implements the actual data access logic that executes within handlers, consuming the resolved deploy-time values

For a deep dive into how this separation works, see the [Adapter Pattern](./adapter-pattern.md).

## Available Providers

### Local

**Package:** `reventless-local`

The Local provider runs everything in a single process. It offers two interchangeable
backends — an in-memory store and a SQLite store (selected via `Backend.Memory` /
`Backend.Sqlite` or the `REVENTLESS_LOCAL_BACKEND` env var). No cloud infrastructure is needed.

**Use cases:**
- Local development and rapid prototyping
- Unit and integration testing with Jest
- Exploring the framework without cloud credentials

The Local provider includes a shared event bus (`LocalBus`), a built-in GraphQL server, and an MCP server for AI-native access. All adapter interfaces are fully implemented.

[Local Provider Documentation &rarr;](./local/)

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

Community contributions are welcome. See [Scaffolding a Provider Package](./scaffolding-a-provider.md) for how to create a new provider, and the [Adapter Pattern](./adapter-pattern.md) for the full interface checklist.
