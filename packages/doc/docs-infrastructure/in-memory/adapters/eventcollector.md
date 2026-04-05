---
title: EventCollector
sidebar_position: 4
---

# EventCollector — InMemory

**Source:** `reventless-in-memory/src/adapter/EventCollector/EventCollectorChannel_InMemory.res`

**AWS equivalent:** [EventCollector → SQS FIFO](/infrastructure/aws/adapters/eventcollector)

## How It Works

The `connect` function subscribes to bus event topics using `Bus.subscribeToEventStream`. For each event topic resource, it starts an Effect fiber that drains the PubSub stream and calls the runtime handler for each event.

Each message includes a `done_` Effect that must be run after processing to unblock the publisher — this ensures that `publishEvent` does not return until all subscribers have finished processing.

A `subscriptionLatch` on the runtime signals when subscriptions are registered, so tests can await readiness before publishing.

## Operations

| Operation | Description |
|-----------|-------------|
| `handleChannelEvent` | Wraps the event handler for single-event processing |
| `connect` | Subscribes to all event topic resources via the bus |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Transport | Effect PubSub stream subscription | DynamoDB Streams / SQS |
| Backpressure | Bounded PubSub queues (configurable) | SQS visibility timeout |
| Ordering | Guaranteed within topic | DynamoDB Streams: per-partition ordered |
| Completion signal | `done_` Effect per message | SQS message deletion |
