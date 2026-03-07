---
title: InMemory Provider
sidebar_position: 1
---

# InMemory Provider

The `reventless-in-memory` package implements all Reventless adapter interfaces using in-memory data structures. It is designed for local development and testing — no cloud infrastructure, no deployment, no costs.

## Key Features

- **Shared Event Bus** — `InMemory_Bus` provides event fan-out (PubSub) and command dispatch using Effect's `PubSub` and `Queue` primitives
- **Synchronous Processing** — events flow through the entire system within a single process, making tests deterministic
- **Test Runner** — `TestRunner.setup()` activates Pulumi mock mode so components can be instantiated in Jest
- **Built-in GraphQL Server** — starts automatically on port 4000 after all plugins are constructed
- **Built-in MCP Server** — provides AI-native access to commands and read models

## Architecture

Unlike the AWS provider which creates separate Lambda functions connected by SQS and SNS, the InMemory provider runs everything in a single Node.js process:

```
Platform.Make()
  ├── InMemory_Bus (shared event + command bus)
  ├── Aggregate Builders → EventLogStorage_InMemory + CommandTopicChannel_InMemory + ...
  ├── ReadModel Builders → QueryDbStorage_InMemory + EventCollectorChannel_InMemory + ...
  ├── DCB Builders → DcbEventLogStorage_InMemory + ...
  ├── GraphQL Server (port 4000)
  └── MCP Server
```

The bus acts as the glue: aggregates publish events to the bus, and read models subscribe to the bus for event delivery. Command handlers are registered on the bus and invoked directly.

## Service Mappings

| Component | InMemory Implementation | Data Structure |
|-----------|------------------------|----------------|
| **EventLog** | `EventLogStorage_InMemory` | `Dict<string, array<JSON.t>>` via STM TRef |
| **CommandTopic** | `CommandTopicChannel_InMemory` | Bus command dispatch (direct handler call) |
| **EventTopic** | `EventTopicPublisher_InMemory` | Bus PubSub fan-out |
| **EventCollector** | `EventCollectorChannel_InMemory` | Bus event subscription |
| **QueryDb** | `QueryDbStorage_InMemory` | `Dict<string, JSON.t>` via STM TRef |
| **Task** | `TaskBucket_InMemory` | `Dict<string, string>` via STM TRef |
| **CommandGenerator** | `CommandGeneratorResolvers_InMemory` | Direct function binding |
| **Counter** | `CounterHandler_InMemory` | `Dict<string, int>` via STM TRef |
| **Heartbeat** | `HeartbeatRunner_InMemory` | `setInterval` timer |
| **QueryEngine** | `QueryEngine_InMemory` | In-memory scan + filter over QueryDb |
| **ScheduledPublisher** | `ScheduledPublisher_InMemory` | `setInterval` timer + Bus dispatch |
| **SideEffectHandler** | `SideEffectHandler_InMemory` | Bus event subscription with handler callback |
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
