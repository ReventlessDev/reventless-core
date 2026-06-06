---
title: InMemory Provider
sidebar_position: 1
---

# InMemory Provider

The `reventless-local` package implements all Reventless adapter interfaces using in-memory data structures. It is designed for local development and testing — no cloud infrastructure, no deployment, no costs.

## Key Features

- **Shared Event Bus** — `LocalBus` provides event fan-out (PubSub) and command dispatch using Effect's `PubSub` and `Queue` primitives
- **Synchronous Processing** — events flow through the entire system within a single process, making tests deterministic
- **Test Runner** — `TestRunner.setup()` activates Pulumi mock mode so components can be instantiated in Jest
- **Built-in GraphQL Server** — starts automatically on port 4000 after all plugins are constructed
- **Built-in MCP Server** — provides AI-native access to commands and read models

## Architecture

Unlike the AWS provider which creates separate Lambda functions connected by SQS and SNS, the InMemory provider runs everything in a single Node.js process:

```
Platform.Make()
  ├── LocalBus (shared event + command bus)
  ├── Aggregate Builders → EventLogStorage_InMemory + LocalCommandTopicChannel + ...
  ├── ReadModel Builders → QueryDbStorage_InMemory + LocalEventCollectorChannel + ...
  ├── DCB Builders → DcbEventLogStorage_InMemory + ...
  ├── GraphQL Server (port 4000)
  └── MCP Server
```

The bus acts as the glue: aggregates publish events to the bus, and read models subscribe to the bus for event delivery. Command handlers are registered on the bus and invoked directly.

## Service Mappings

| Component | InMemory Implementation | Data Structure |
|-----------|------------------------|----------------|
| **EventLog** | `EventLogStorage_InMemory` | `Dict<string, array<JSON.t>>` via STM TRef |
| **CommandTopic** | `LocalCommandTopicChannel` | Bus command dispatch (direct handler call) |
| **EventTopic** | `LocalEventTopicPublisher` | Bus PubSub fan-out |
| **EventCollector** | `LocalEventCollectorChannel` | Bus event subscription |
| **QueryDb** | `QueryDbStorage_InMemory` | `Dict<string, JSON.t>` via STM TRef |
| **Task** | `LocalTaskBucket` | `Dict<string, string>` via STM TRef |
| **CommandGenerator** | `LocalCommandGeneratorResolvers` | Direct function binding |
| **Counter** | `LocalCounterHandler` | `Dict<string, int>` via STM TRef |
| **Heartbeat** | `LocalHeartbeatRunner` | `setInterval` timer |
| **QueryEngine** | `LocalQueryEngine` | In-memory scan + filter over QueryDb |
| **ScheduledPublisher** | `LocalScheduledPublisher` | `setInterval` timer + Bus dispatch |
| **SideEffectHandler** | `LocalSideEffectHandler` | Bus event subscription with handler callback |
| **DcbEventLog** | `DcbEventLogStorage_InMemory` | `array<event>` with tag-based filtering |

## Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Persistence | None — data lost on process exit | DynamoDB, S3 |
| Event delivery | Synchronous (2-3 microtask ticks) | Asynchronous (SQS/SNS) |
| Concurrency | Single-threaded | Multi-Lambda concurrent execution |
| Infrastructure | None | Pulumi-managed AWS resources |
| Cost | Free | Pay-per-use AWS pricing |
| Ordering | Guaranteed (single process) | FIFO queues provide per-aggregate ordering |

## Next Steps

- [Getting Started](./get-started.md) — set up and run with the InMemory provider
- [Adapter details](./adapters/eventlog.md) — how each adapter works internally
